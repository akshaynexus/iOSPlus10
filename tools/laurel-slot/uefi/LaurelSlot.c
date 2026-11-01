/** @file
  Mi A3 dual boot: slot flags from the UniXNU menu. Glue between UEFI BlockIo and tools/laurel-slot/laurel_slot.c (copied into UniXNULib by
  scripts/laurel/mu-build.sh). docs/laurel_sprout/boot-menu.md.

  Only active when the config has an entry with action "laurel-android" (scripts/laurel/mkdarwinboot.py). One line: LAUREL SLOT: on|off: reason.
  No failure here stops iOS: the menu goes on, the "Android" entry says why it cannot run, and ABL's retries still fall back to Android.
**/

#include "Internal.h"
#include "laurel_slot.h"

#include <Protocol/BlockIo.h>

STATIC ls_disk                mDisk;
STATIC BOOLEAN                mEnabled;
CHAR16                        gLaurelSlotWhy[96];

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

  Status = ls_commit (&mDisk, NewA, NewB, &Written);
  UniXNULog ("LAUREL SLOT: Android: a %02x->%02x b %02x->%02x: %a", Table.flags_a, NewA, Table.flags_b, NewB, ls_status_text (Status));
  if (Status != LS_OK) {
    UnicodeSPrint (gLaurelSlotWhy, sizeof (gLaurelSlotWhy), L"Android failed: %a", ls_status_text (Status));
    return EFI_DEVICE_ERROR;
  }

  return EFI_SUCCESS;
}

//
// Before an iOS boot, only when the menu did run with a screen and keys: retries of slot b back to 7 at or below LS_REFILL_AT. A Mu that does not reach this point
// never writes, so ABL's count goes on and it falls back to Android. A failure here does not stop iOS.
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
  VOID         *Gop;

  if (!mEnabled) {
    return;
  }

  //
  // Input: the serial console driver (SimpleTextInOutSerial) always counts as one device, so the side keys (ButtonsDxe) make at least 2.
  //
  if (EFI_ERROR (gBS->LocateProtocol (&gEfiGraphicsOutputProtocolGuid, NULL, &Gop)) || (UniXNUMenuInputDevices () < 2)) {
    UniXNULog ("LAUREL SLOT: refill off: no screen or no side keys (%u input devices), ABL keeps counting", (UINT32)UniXNUMenuInputDevices ());
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

  Status = ls_commit (&mDisk, NewA, NewB, &Written);
  UniXNULog ("LAUREL SLOT: refill: b %02x->%02x: %a", Table.flags_b, NewB, ls_status_text (Status));
}
