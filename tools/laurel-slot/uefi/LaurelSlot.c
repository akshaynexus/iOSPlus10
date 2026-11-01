/** @file
  Mi A3 dual boot: slot flags from the UniXNU menu. Glue between UEFI BlockIo and tools/laurel-slot/laurel_slot.c (copied into UniXNULib by
  scripts/laurel/mu-build.sh). docs/laurel_sprout/boot-menu.md.

  Only active when the config has an entry with action "laurel-android" (scripts/laurel/mkdarwinboot.py). One line: LAUREL SLOT: on|off: reason.
  No failure here stops iOS: the menu goes on, the "Android" entry says why it cannot run, and ABL's retries still fall back to Android.
**/

#include "Internal.h"
#include "laurel_slot.h"

#include <Pi/PiDxeCis.h>
#include <Library/DxeServicesTableLib.h>
#include <Protocol/BlockIo.h>

STATIC ls_disk                mDisk;
STATIC BOOLEAN                mEnabled;
CHAR16                        gLaurelSlotWhy[96];

//
// The Qualcomm battery protocol, as ABL calls it on this phone: [V] the GUID and the text "Error getting battery voltage" are in the phone's ABL; layout from QcomPkg EFIChargerEx.h, same in QRD abl r12.
//
typedef struct {
  UINT64        Revision;
  EFI_STATUS    (EFIAPI *GetChargerPresence)(BOOLEAN *Present);
  EFI_STATUS    (EFIAPI *GetBatteryPresence)(BOOLEAN *Present);
  EFI_STATUS    (EFIAPI *GetBatteryVoltage)(UINT32 *MilliVolt);
} LAUREL_CHARGER_EX;

STATIC EFI_GUID  mChargerExGuid = { 0x6edc8a6d, 0x2663, 0x43cd, { 0x90, 0xff, 0x46, 0x21, 0xff, 0xd1, 0x0d, 0xf5 }};
#define LAUREL_MIN_WRITE_MV  3600   // below this, and no charger: no GPT write. A power cut while the primary is written is the worst case: boot-menu.md section 3

//
// FALSE: the battery is low with no charger: no write. No protocol or a failed read: TRUE with a note, this check only lowers a risk.
//
STATIC
BOOLEAN
BatteryAllowsWrite (
  OUT CHAR16  *Why,
  IN  UINTN   WhySize
  )
{
  LAUREL_CHARGER_EX  *C;
  UINT32             Mv;
  BOOLEAN            Plugged;

  if (EFI_ERROR (gBS->LocateProtocol (&mChargerExGuid, NULL, (VOID **)&C))) {
    UniXNULog ("LAUREL SLOT: battery: no protocol, not checked");
    return TRUE;
  }

  Mv = 0;
  if (EFI_ERROR (C->GetBatteryVoltage (&Mv)) || (Mv == 0)) {
    UniXNULog ("LAUREL SLOT: battery: read failed, not checked");
    return TRUE;
  }

  Plugged = FALSE;
  if (EFI_ERROR (C->GetChargerPresence (&Plugged))) {
    Plugged = FALSE;
  }

  UniXNULog ("LAUREL SLOT: battery %u mV, charger %a", Mv, Plugged ? "yes" : "no");
  if ((Mv < LAUREL_MIN_WRITE_MV) && !Plugged) {
    UnicodeSPrint (Why, WhySize, L"battery %u mV: connect the charger first", Mv);
    return FALSE;
  }

  return TRUE;
}

//
// The word kernel patch 2956 leaves in IMEM at a panic. Read only if the firmware's memory map says the page is device memory (Mu "IMEM Cookie Base"); QEMU has no such page. The kernel writes
// the word back to normal at its next start, so this needs no write here. Nothing here depends on it surviving the reset: without it the gate still needs a key.
//
STATIC
UINT32
ReadImemWord (
  VOID
  )
{
  EFI_GCD_MEMORY_SPACE_DESCRIPTOR  D;

  if (EFI_ERROR (gDS->GetMemorySpaceDescriptor (LS_IMEM_RESTART_PA, &D)) || (D.GcdMemoryType != EfiGcdMemoryTypeMemoryMappedIo)) {
    return 0;
  }

  return *(volatile UINT32 *)(UINTN)LS_IMEM_RESTART_PA;
}

STATIC INT32 BioRead (VOID *Ctx, ls_u64 Lba, ls_u32 Blocks, VOID *Buf)
{
  EFI_BLOCK_IO_PROTOCOL  *B = Ctx;

  return EFI_ERROR (B->ReadBlocks (B, B->Media->MediaId, Lba, (UINTN)Blocks * B->Media->BlockSize, Buf)) ? 1 : 0;
}

STATIC INT32 BioWrite (VOID *Ctx, ls_u64 Lba, ls_u32 Blocks, CONST VOID *Buf)
{
  EFI_BLOCK_IO_PROTOCOL  *B = Ctx;

  return EFI_ERROR (B->WriteBlocks (B, B->Media->MediaId, Lba, (UINTN)Blocks * B->Media->BlockSize, (VOID *)Buf)) ? 1 : 0;
}

STATIC INT32 BioFlush (VOID *Ctx)
{
  EFI_BLOCK_IO_PROTOCOL  *B = Ctx;

  return EFI_ERROR (B->FlushBlocks (B)) ? 1 : 0;
}

//
// The LUN from the actual tables: every whole-device BlockIo is read, and the one LUN whose table passes every check and holds one boot_a and one boot_b is taken.
// Not one, or a table that fails: no LUN, no write. Never a fixed LUN number.
//
STATIC
EFI_STATUS
FindLun (
  OUT ls_table    *Table,
  OUT CONST CHAR8 **Why
  )
{
  EFI_HANDLE  *Handles;
  UINTN       Count;
  UINTN       Index;
  UINTN       Found;
  ls_status   Status;
  ls_status   Worst;
  ls_table    Probe;

  if (EFI_ERROR (gBS->LocateHandleBuffer (ByProtocol, &gEfiBlockIoProtocolGuid, NULL, &Count, &Handles))) {
    *Why = "no block devices";
    return EFI_NOT_FOUND;
  }

  Found = 0;
  Worst = LS_NOT_THIS_LUN;
  for (Index = 0; Index < Count; Index++) {
    EFI_BLOCK_IO_PROTOCOL  *B;
    ls_disk                D;

    if (EFI_ERROR (gBS->HandleProtocol (Handles[Index], &gEfiBlockIoProtocolGuid, (VOID **)&B))) {
      continue;
    }

    if (B->Media->LogicalPartition || !B->Media->MediaPresent || B->Media->ReadOnly || (B->Media->LastBlock < 64)) {
      continue;
    }

    D.ctx        = B;
    D.block_size = B->Media->BlockSize;
    D.last_lba   = B->Media->LastBlock;
    D.read       = BioRead;
    D.write      = BioWrite;
    D.flush      = BioFlush;
    Status       = ls_load (&D, &Probe);
    if (Status == LS_OK) {
      if (Found++ == 0) {
        mDisk = D;
        CopyMem (Table, &Probe, sizeof (Probe));
      }
    } else if (Status != LS_NOT_THIS_LUN) {
      // a table on a LUN we have no use for says nothing about ours; only reported when no LUN passes
      Worst = Status;
    }
  }

  FreePool (Handles);
  if (Found == 1) {
    return EFI_SUCCESS;
  }

  *Why = (Found > 1) ? "boot_a and boot_b on more than one LUN" : ls_status_text (Worst);
  return EFI_NOT_FOUND;
}

STATIC
BOOLEAN
HasLaurelEntry (
  IN UNIXNU_CONFIG  *Config
  )
{
  UINTN  Index;

  for (Index = 0; Index < Config->EntryCount; Index++) {
    if ((Config->Entries[Index].Type == UniXNUEntryAction) && (Config->Entries[Index].Action == UniXNUActionLaurelAndroid)) {
      return TRUE;
    }
  }

  return FALSE;
}

//
// Self-check at menu start, reads only. The one feature line.
//
VOID
LaurelSlotSelfCheck (
  IN  UNIXNU_CONFIG  *Config,
  OUT CHAR16         *Notice,
  IN  UINTN          NoticeSize
  )
{
  ls_table     Table;
  CONST CHAR8  *Why;

  mEnabled = HasLaurelEntry (Config);
  if (!mEnabled) {
    return;
  }

  Why = "?";
  if (EFI_ERROR (FindLun (&Table, &Why))) {
    UniXNULog ("LAUREL SLOT: off: %a", Why);
    UnicodeSPrint (Notice, NoticeSize, L"Android entry off: %a", Why);
    mEnabled = FALSE;
    return;
  }

  UniXNULog (
    "LAUREL SLOT: on: boot_a %02x boot_b %02x (copy %02x %02x), block %u, last LBA %lu",
    Table.flags_a,
    Table.flags_b,
    Table.backup_a,
    Table.backup_b,
    mDisk.block_size,
    mDisk.last_lba
    );

  //
  // The owner must see what happens with no key: at most 7 boots, then Android.
  //
  if ((Table.flags_b & LS_ACTIVE) && !(Table.flags_b & LS_SUCCESSFUL) && (LS_RETRIES (Table.flags_b) <= LS_REFILL_AT)) {
    //
    // [V ABL] retries R: R more iOS boots, then Android. This boot is already counted.
    //
    UnicodeSPrint (
      Notice,
      NoticeSize,
      L"%sAndroid after %u more boots: press a key to stay",
      (ReadImemWord () == LS_PANIC_WORD) ? L"iOS panicked. " : L"",
      LS_RETRIES (Table.flags_b)
      );
  } else if (ReadImemWord () == LS_PANIC_WORD) {
    UnicodeSPrint (Notice, NoticeSize, L"The last iOS boot panicked");
  }
}

//
// Entry "Android". Success = the flags are on the flash and verified; the caller resets, ABL then does the slot change.
//
EFI_STATUS
LaurelSlotToAndroid (
  VOID
  )
{
  ls_table     Table;
  ls_u8        NewA;
  ls_u8        NewB;
  CONST CHAR8  *Why;
  ls_status    Status;
  INT32        Written;

  gLaurelSlotWhy[0] = L'\0';
  Why               = "?";
  if (EFI_ERROR (FindLun (&Table, &Why))) {
    UniXNULog ("LAUREL SLOT: Android refused: %a", Why);
    UnicodeSPrint (gLaurelSlotWhy, sizeof (gLaurelSlotWhy), L"Android refused: %a", Why);
    return EFI_NOT_READY;
  }

  if (ls_plan_android (Table.flags_a, Table.flags_b, &NewA, &NewB, &Why) != 0) {
    UniXNULog ("LAUREL SLOT: Android refused: %a (a %02x b %02x)", Why, Table.flags_a, Table.flags_b);
    UnicodeSPrint (gLaurelSlotWhy, sizeof (gLaurelSlotWhy), L"Android refused: %a", Why);
    return EFI_NOT_READY;
  }

  if (!BatteryAllowsWrite (gLaurelSlotWhy, sizeof (gLaurelSlotWhy))) {
    UniXNULog ("LAUREL SLOT: Android refused: %s", gLaurelSlotWhy);
    return EFI_NOT_READY;
  }

  Status = ls_commit (&mDisk, NewA, NewB, &Written);
  UniXNULog ("LAUREL SLOT: Android: a %02x->%02x b %02x->%02x: %a", Table.flags_a, NewA, Table.flags_b, NewB, ls_status_text (Status));
  if (Status != LS_OK) {
    UnicodeSPrint (gLaurelSlotWhy, sizeof (gLaurelSlotWhy), L"Android failed: %a", ls_status_text (Status));
    return EFI_DEVICE_ERROR;
  }

  return EFI_SUCCESS;
}

//
// Before an iOS boot: retries of slot b back to 7 at or below LS_REFILL_AT, only after a real key event in this menu and with no panic word (ls_refill_gate). Everything else writes nothing, so
// ABL's count goes on and it falls back to Android with no computer: a Mu that does not get here, a dark panel, dead keys, nobody at the phone, a panic loop.
// A failure here does not stop iOS.
//
VOID
LaurelSlotRefill (
  VOID
  )
{
  ls_table     Table;
  ls_u8        NewA;
  ls_u8        NewB;
  CONST CHAR8  *Why;
  ls_status    Status;
  INT32        Written;
  CHAR16       Low[64];

  if (!mEnabled) {
    return;
  }

  Why = "?";
  if (ls_refill_gate (gLaurelKeyHeard ? 1 : 0, ReadImemWord (), &Why) != 0) {
    UniXNULog ("LAUREL SLOT: refill off: %a, ABL keeps counting", Why);
    return;
  }

  Why = "?";
  if (EFI_ERROR (FindLun (&Table, &Why))) {
    UniXNULog ("LAUREL SLOT: refill off: %a", Why);
    return;
  }

  if (ls_plan_refill (Table.flags_a, Table.flags_b, &NewA, &NewB, &Why) != 0) {
    UniXNULog ("LAUREL SLOT: refill off: %a (a %02x b %02x)", Why, Table.flags_a, Table.flags_b);
    return;
  }

  if ((NewA == Table.flags_a) && (NewB == Table.flags_b)) {
    return;
  }

  if (!BatteryAllowsWrite (Low, sizeof (Low))) {
    UniXNULog ("LAUREL SLOT: refill off: %s", Low);
    return;
  }

  Status = ls_commit (&mDisk, NewA, NewB, &Written);
  UniXNULog ("LAUREL SLOT: refill: b %02x->%02x: %a", Table.flags_b, NewB, ls_status_text (Status));
}
