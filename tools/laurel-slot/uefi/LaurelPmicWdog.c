/** @file
  Mi A3: the PM6125 PON watchdog, armed by the boot menu right before DarwinBoot (mu 0202). Copied into UniXNULib by scripts/laurel/mu-build.sh.

  Why: a kernel that hangs before its own watchdog runs (2026-11-07 03:45: "SWEET EARLY ... PE_init", no USB) came back only with a key. Now the PMIC counts
  from the jump into DarwinBoot: no pet for LPW_S1_BOOT_S + LPW_S2_S seconds and it hard-resets the SoC (no CPU, no TrustZone), ABL counts one more retry
  of slot b and the menu shows again. The kernel takes the count over in laurel_pmic_wdog_start (kernel 3030) and pets it every second. Registers and
  times: the same numbers as the kernel's laurel_pmic_wdog_core.h (checked by scripts/laurel/pmic-wdog-test.sh).

  Access: the SPMI arbiter by its registers, as the kernel's sweet_spmi.c (laurel 2018/2710; [V] on this phone: "PON APID 112 rw lane mapped", every
  ctl bootloader goes through it): core 0x1C40000 (version, APID count, PPID map at 0x900), config 0x1C0A000 (owner EE per APID at 0x700), observer
  channel 0x3E00000 + 0x80 * APID for reads (EE 0), rw channel 0x1E00000 + 0x10000 * APID for writes. The Mu memory map has this range as device memory
  ("PMIC ARB SPMI" 0x1C00000, MemoryMapLib.c). At TPL_HIGH_LEVEL: no firmware event callback interleaves its own transaction.

  Lines: LAUREL PMIC WDOG: on: ... | off: REASON. Kill switch: laurelpmicwdog=0 in the entry's command line (the kernel reads the same word). A watchdog
  found armed at the menu start is disarmed: the menu waits for the owner. Nothing here stops a boot.
**/

#include "Internal.h"

#include <Pi/PiDxeCis.h>
#include <Library/DxeServicesTableLib.h>

#define LPW_S1_TIMER    0x854u
#define LPW_S2_TIMER    0x855u
#define LPW_S2_CTL      0x856u
#define LPW_S2_CTL2     0x857u
#define LPW_PET         0x858u
#define LPW_TIMER_MASK  0x7fu
#define LPW_TYPE_MASK   0x0fu
#define LPW_TYPE_HARD   0x07u
#define LPW_EN          0x80u
#define LPW_PET_BIT     0x01u
#define LPW_S1_BOOT_S   100u
#define LPW_S2_S        2u

#define SP_CORE_PA      0x01C40000u
#define SP_CFG_PA       0x01C0A000u
#define SP_OBS_PA       0x03E00000u
#define SP_RW_PA        0x01E00000u
#define SP_PON_PPID     0x008u
#define SP_MAX_APID     512u
#define SP_ERR_BITS     0x0Eu
#define SP_TIMEOUT_US   1000u

STATIC UINTN    mPonApid;       // 0: not found
STATIC BOOLEAN  mReady;
STATIC CHAR8    mWhy[96];

STATIC
UINT32
SpRead32 (
  IN UINTN  Address
  )
{
  UINT32  Value;

  Value = *(volatile UINT32 *)Address;
  __asm__ volatile ("dmb oshld" ::: "memory");
  return Value;
}

STATIC
BOOLEAN
IsMmio (
  IN UINTN  Address
  )
{
  EFI_GCD_MEMORY_SPACE_DESCRIPTOR  D;

  if (EFI_ERROR (gDS->GetMemorySpaceDescriptor (Address, &D))) {
    return FALSE;
  }

  return D.GcdMemoryType == EfiGcdMemoryTypeMemoryMappedIo;
}

//
// One transaction on the PON APID: EXT_READL on the observer channel, EXT_WRITEL on the rw channel. 0 = ok, -1 = failed, -2 = timeout.
//
STATIC
INTN
SpXfer (
  IN BOOLEAN  Write,
  IN UINTN    Reg,
  IN OUT UINT8  *Value
  )
{
  UINTN   Ch;
  UINT32  Cmd;
  UINT32  Status;
  UINTN   I;
  EFI_TPL Tpl;
  INTN    Rc;

  if (!mReady) {
    return -1;
  }

  Ch  = Write ? (SP_RW_PA + 0x10000u * mPonApid) : (SP_OBS_PA + 0x80u * mPonApid);
  Cmd = ((Write ? 0u : 1u) << 27) | (((UINT32)Reg & 0xFFu) << 4);
  Tpl = gBS->RaiseTPL (TPL_HIGH_LEVEL);
  __asm__ volatile ("dmb oshst" ::: "memory");
  if (Write) {
    *(volatile UINT32 *)(Ch + 0x10u) = *Value;
  }

  *(volatile UINT32 *)Ch = Cmd;
  __asm__ volatile ("dsb osh" ::: "memory");
  Rc = -2;
  for (I = 0; I < SP_TIMEOUT_US; I++) {
    Status = SpRead32 (Ch + 0x08u);
    if (Status & 1u) {
      Rc = (Status & SP_ERR_BITS) ? -1 : 0;
      break;
    }

    gBS->Stall (1);
  }

  if ((Rc == 0) && !Write) {
    *Value = (UINT8)SpRead32 (Ch + 0x18u);
  }

  gBS->RestoreTPL (Tpl);
  return Rc;
}

STATIC
INTN
PonRead (
  IN UINTN   Reg,
  OUT UINT8  *Value
  )
{
  *Value = 0;
  return SpXfer (FALSE, Reg, Value);
}

STATIC
INTN
PonWrite (
  IN UINTN  Reg,
  IN UINT8  Value
  )
{
  return SpXfer (TRUE, Reg, &Value);
}

//
// The arbiter: version, APID count, the PON's APID with owner EE 0 (apps). FALSE with the reason in mWhy.
//
STATIC
BOOLEAN
FindArbiter (
  VOID
  )
{
  UINT32  Version;
  UINT32  Count;
  UINT32  Map;
  UINT32  Owner;
  UINTN   I;

  if (mReady) {
    return TRUE;
  }

  if (!IsMmio (SP_CORE_PA) || !IsMmio (SP_CFG_PA) || !IsMmio (SP_OBS_PA) || !IsMmio (SP_RW_PA)) {
    AsciiSPrint (mWhy, sizeof (mWhy), "the SPMI arbiter is not device memory in this map");
    return FALSE;
  }

  Version = SpRead32 (SP_CORE_PA);
  Count   = SpRead32 (SP_CORE_PA + 4) & 0x7FFu;
  if ((Version < 0x50000000u) || (Version >= 0x70000000u) || (Count == 0) || (Count > SP_MAX_APID)) {
    AsciiSPrint (mWhy, sizeof (mWhy), "arbiter %x with %u APIDs is not v5", Version, Count);
    return FALSE;
  }

  mPonApid = 0;
  for (I = 0; I < Count; I++) {
    Map = SpRead32 (SP_CORE_PA + 0x900u + 4u * I);
    if ((Map == 0) || (((Map >> 8) & 0xFFFu) != SP_PON_PPID)) {
      continue;
    }

    Owner = SpRead32 (SP_CFG_PA + 0x700u + 4u * I) & 7u;
    if (Owner == 0) {
      mPonApid = I;
      break;
    }
  }

  if (mPonApid == 0) {
    AsciiSPrint (mWhy, sizeof (mWhy), "no APID of the PON (PPID 0x%x) is owned by EE 0 (arbiter %x, %u APIDs)", SP_PON_PPID, Version, Count);
    return FALSE;
  }

  mReady = TRUE;
  AsciiSPrint (mWhy, sizeof (mWhy), "arbiter %x, PON APID %u", Version, (UINT32)mPonApid);
  return TRUE;
}

//
// 0 = off now, -1 = the PMIC did not take the write (or no arbiter)
//
STATIC
INTN
Disarm (
  VOID
  )
{
  UINT8  Ctl2;

  if (PonRead (LPW_S2_CTL2, &Ctl2) != 0) {
    return -1;
  }

  if ((Ctl2 & LPW_EN) == 0) {
    return 0;
  }

  if (PonWrite (LPW_S2_CTL2, (UINT8)(Ctl2 & ~LPW_EN)) != 0) {
    return -1;
  }

  gBS->Stall (200);
  if ((PonRead (LPW_S2_CTL2, &Ctl2) != 0) || ((Ctl2 & LPW_EN) != 0)) {
    return -1;
  }

  return 0;
}

//
// Menu start: the arbiter, and a watchdog left armed (a warm reset keeps the PMIC's registers) goes off: the menu may wait for minutes.
//
VOID
LaurelPmicWdogSelfCheck (
  VOID
  )
{
  UINT8  S1;
  UINT8  S2;
  UINT8  Ctl;
  UINT8  Ctl2;

  if (!FindArbiter ()) {
    UniXNULog ("LAUREL PMIC WDOG: off: %a", mWhy);
    return;
  }

  if ((PonRead (LPW_S1_TIMER, &S1) != 0) || (PonRead (LPW_S2_TIMER, &S2) != 0) || (PonRead (LPW_S2_CTL, &Ctl) != 0) || (PonRead (LPW_S2_CTL2, &Ctl2) != 0)) {
    mReady = FALSE;
    UniXNULog ("LAUREL PMIC WDOG: off: a read of the PON failed (%a)", mWhy);
    return;
  }

  if (Ctl2 & LPW_EN) {
    UniXNULog (
      "LAUREL PMIC WDOG: on: %a; found armed (S1 %u s S2 %u s type %u): %a",
      mWhy,
      S1 & LPW_TIMER_MASK,
      S2 & LPW_TIMER_MASK,
      Ctl & LPW_TYPE_MASK,
      (Disarm () == 0) ? "disarmed for the menu" : "NOT disarmed: the PMIC refused the write"
      );
  } else {
    UniXNULog ("LAUREL PMIC WDOG: on: %a; found off (S1 %u s S2 %u s type %u); armed at the jump into DarwinBoot", mWhy, S1 & LPW_TIMER_MASK, S2 & LPW_TIMER_MASK, Ctl & LPW_TYPE_MASK);
  }
}

//
// Right before DarwinBoot. Args: the entry's command line; "laurelpmicwdog=0" in it: nothing is armed. A failure here does not stop the boot.
//
VOID
LaurelPmicWdogArm (
  IN CONST CHAR16  *Args
  )
{
  UINT8  S1;
  UINT8  S2;
  UINT8  Ctl;
  UINT8  Ctl2;
  INTN   W;

  if ((Args != NULL) && (StrStr (Args, L"laurelpmicwdog=0") != NULL)) {
    UniXNULog ("LAUREL PMIC WDOG: off: laurelpmicwdog=0 in the command line: not armed");
    return;
  }

  if (!mReady && !FindArbiter ()) {
    UniXNULog ("LAUREL PMIC WDOG: off: not armed: %a", mWhy);
    return;
  }

  if ((PonRead (LPW_S1_TIMER, &S1) != 0) || (PonRead (LPW_S2_TIMER, &S2) != 0) || (PonRead (LPW_S2_CTL, &Ctl) != 0) || (PonRead (LPW_S2_CTL2, &Ctl2) != 0)) {
    UniXNULog ("LAUREL PMIC WDOG: off: not armed: a read of the PON failed");
    return;
  }

  W = 0;
  if (Ctl2 & LPW_EN) {
    W |= PonWrite (LPW_S2_CTL2, (UINT8)(Ctl2 & ~LPW_EN));
    gBS->Stall (200);
  }

  W |= PonWrite (LPW_S1_TIMER, (UINT8)((S1 & ~LPW_TIMER_MASK) | LPW_S1_BOOT_S));
  W |= PonWrite (LPW_S2_TIMER, (UINT8)((S2 & ~LPW_TIMER_MASK) | LPW_S2_S));
  W |= PonWrite (LPW_S2_CTL, (UINT8)((Ctl & ~LPW_TYPE_MASK) | LPW_TYPE_HARD));
  gBS->Stall (200);
  W |= PonWrite (LPW_S2_CTL2, (UINT8)(Ctl2 | LPW_EN));
  gBS->Stall (200);
  W |= PonWrite (LPW_PET, LPW_PET_BIT);
  if ((W != 0) || (PonRead (LPW_S1_TIMER, &S1) != 0) || (PonRead (LPW_S2_TIMER, &S2) != 0) || (PonRead (LPW_S2_CTL, &Ctl) != 0) || (PonRead (LPW_S2_CTL2, &Ctl2) != 0) ||
      ((S1 & LPW_TIMER_MASK) != LPW_S1_BOOT_S) || ((S2 & LPW_TIMER_MASK) != LPW_S2_S) || ((Ctl & LPW_TYPE_MASK) != LPW_TYPE_HARD) || ((Ctl2 & LPW_EN) == 0))
  {
    UniXNULog (
      "LAUREL PMIC WDOG: off: not armed: the PMIC does not hold the setting (writes %d; read back S1 %u S2 %u type %u enable 0x%02x): %a",
      (INT32)W,
      S1 & LPW_TIMER_MASK,
      S2 & LPW_TIMER_MASK,
      Ctl & LPW_TYPE_MASK,
      Ctl2,
      (Disarm () == 0) ? "disarmed" : "NOT disarmed"
      );
    return;
  }

  UniXNULog ("LAUREL PMIC WDOG: on: armed: no pet for %u s + %u s from here: hard reset by the PMIC, then the menu again; the kernel takes it over at LAUREL PMIC WDOG", LPW_S1_BOOT_S, LPW_S2_S);
}

//
// Before a reset of the menu's own (the Android entry): nothing of ours may count on.
//
VOID
LaurelPmicWdogDisarm (
  VOID
  )
{
  if (!mReady) {
    return;
  }

  UniXNULog ("LAUREL PMIC WDOG: off: %a before the reset", (Disarm () == 0) ? "disarmed" : "NOT disarmed: the PMIC refused the write");
}
