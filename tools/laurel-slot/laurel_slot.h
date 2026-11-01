/*
 * Slot flags of the Mi A3 (laurel_sprout) in the GPT of the boot LUN: the core of the Mu boot menu. No EDK2 and no libc in the logic, so the
 * same file runs in UniXNULib and in the host test (tools/laurel-slot/test). docs/laurel_sprout/boot-menu.md.
 *
 * What it writes: byte 6 of the 8-byte attributes (bits 48-55) of boot_a and boot_b, plus the two CRC32 fields of each GPT header. Nothing else.
 * Bits [V QRD abl PartitionTableUpdate.h, LineageOS bootctrl boot_control.cpp]: 48-49 priority, 50 active, 51-53 retries, 54 successful, 55 unbootable.
 */
#ifndef LAUREL_SLOT_H
#define LAUREL_SLOT_H

#ifdef LAUREL_SLOT_HOST
#include <stdint.h>
typedef uint8_t ls_u8; typedef uint16_t ls_u16; typedef uint32_t ls_u32; typedef uint64_t ls_u64;
#else
#include <Base.h>
typedef UINT8 ls_u8; typedef UINT16 ls_u16; typedef UINT32 ls_u32; typedef UINT64 ls_u64;
#endif

#define LS_PRIO_MASK    0x03u
#define LS_ACTIVE       0x04u
#define LS_RETRY_SHIFT  3
#define LS_RETRY_MASK   0x38u
#define LS_SUCCESSFUL   0x40u
#define LS_UNBOOTABLE   0x80u
#define LS_RETRIES(f)   (((f) & LS_RETRY_MASK) >> LS_RETRY_SHIFT)

#define LS_RETRY_MAX     7u  /* what the HAL and ABL write */
#define LS_REFILL_AT     3u  /* the menu writes again only at or below this: one GPT write per 4 boots, and a broken Mu still has at least 3 boots to fall */

/* IMEM restart_reason (0x0C125000 + 0x65C, the word the kernel writes anyway, laurel_reboot.c). Kernel patch 2956 writes this value at a panic */
#define LS_IMEM_RESTART_PA  0x0C12565Cu
#define LS_PANIC_WORD       0x4C504E43u  /* 'LPNC' */

#define LS_MAX_BLOCK     4096u
#define LS_MAX_ENTRIES   16384u /* ABL's MAX_PARTITION_ENTRIES_SZ */

typedef enum {
  LS_OK = 0,
  LS_ERR_IO,            /* a read failed */
  LS_ERR_BLOCK_SIZE,    /* block size is not 512 or 4096 */
  LS_ERR_HEADER,        /* a header fails signature, revision, size, LBA fields or CRC */
  LS_ERR_LAYOUT,        /* entries are not where ABL expects them, or the array is too big */
  LS_ERR_ENTRY_CRC,     /* an entry array fails its CRC */
  LS_ERR_COPIES_DIFFER, /* primary and backup differ outside the flag byte of boot_a and boot_b */
  LS_NOT_THIS_LUN,      /* valid table, no boot_a or boot_b, or more than one */
  LS_ERR_STATE,         /* flags refuse this step: see ls_state_text */
  LS_ERR_WRITE_BACKUP,  /* backup write or read-back failed; primary not touched, the phone boots as before */
  LS_ERR_WRITE_PRIMARY  /* primary write or read-back failed; the backup holds the new flags */
} ls_status;

typedef struct {
  void *ctx;
  ls_u32 block_size;
  ls_u64 last_lba;
  int (*read)(void *ctx, ls_u64 lba, ls_u32 blocks, void *buf);          /* 0 = ok */
  int (*write)(void *ctx, ls_u64 lba, ls_u32 blocks, const void *buf);   /* one device command per call */
  int (*flush)(void *ctx);
} ls_disk;

typedef struct {
  ls_u8 flags_a, flags_b;        /* from the primary copy, what ABL reads */
  ls_u8 backup_a, backup_b;
  ls_u32 index_a, index_b;       /* entry numbers */
  ls_u32 entries_blocks;
  ls_u32 entry_count;
  ls_u64 alt_lba;
} ls_table;

const char *ls_status_text(ls_status s);

/* Read and check the whole table. Writes nothing. */
ls_status ls_load(const ls_disk *d, ls_table *t);

/*
 * Flag changes. Each returns 0 and fills *new_a, *new_b, or returns -1 and a reason (static text). None touches the disk.
 *
 * ls_plan_android: the way from slot b to slot a [V ABL source; V strings in the phone's ABL]. ABL refuses a slot whose boot and abl type GUIDs are equal
 * (ValidateSlotGuids) and a slot that does not match the UFS boot LUN, so flags alone cannot select slot a. But a slot with successful = 0 and retries = 0
 * sends ABL into HandleActiveSlotUnbootable: it marks that slot unbootable, takes the successful slot, swaps the GUIDs of all A/B partitions, sets the boot
 * LUN and resets. So: b = retries 0, successful 0. What ABL needs of slot a: successful, not unbootable, priority > 0. If not, this refuses: slot a's state stays, a
 * broken Android stays visible, and ABL would stop in fastboot anyway. Same state of slot b as 7 failed boots. Slot a's byte is never changed.
 *
 * ls_plan_refill: retries of b back to 7 when they are at LS_REFILL_AT or lower. The successful bit stays clear: ABL keeps counting, so a broken Mu that
 * never reaches the menu falls back to slot a after its retries.
 *
 * ls_refill_gate: may this boot refill at all? Only after a real key event in this menu (a handle count proves nothing: ButtonsDxe can install and give no event, a GOP can
 * exist on a dark panel), and not when the last iOS boot left the panic word. No: ABL's count goes on, and it returns to Android with no computer.
 */
int ls_refill_gate(int key_heard, ls_u32 imem_word, const char **why);
int ls_plan_android(ls_u8 a, ls_u8 b, ls_u8 *new_a, ls_u8 *new_b, const char **why);
int ls_plan_refill(ls_u8 a, ls_u8 b, ls_u8 *new_a, ls_u8 *new_b, const char **why);

/*
 * Write new flags, backup first, then primary. Each copy goes in one device command (header + entries for the primary, entries + header for the backup), is
 * flushed and read back. It reloads and checks the table itself first. Same flags in both copies already: no write, *written = 0.
 * Power cut: docs/laurel_sprout/boot-menu.md section "Power cut". Every point leaves a slot that boots.
 */
ls_status ls_commit(const ls_disk *d, ls_u8 new_a, ls_u8 new_b, int *written);

ls_u32 ls_crc32(const void *p, ls_u32 n);

#endif
