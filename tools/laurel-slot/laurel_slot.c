/* See laurel_slot.h. docs/laurel_sprout/boot-menu.md. */
#include "laurel_slot.h"

#define HDR_SIZE 92u
#define OFF_HDR_CRC 16u
#define OFF_MY_LBA 24u
#define OFF_ALT_LBA 32u
#define OFF_FIRST 40u
#define OFF_LAST 48u
#define OFF_GUID 56u
#define OFF_ENTRIES_LBA 72u
#define OFF_COUNT 80u
#define OFF_ENTRY_SIZE 84u
#define OFF_ENTRIES_CRC 88u
#define ENTRY_SIZE 128u
#define OFF_ATTR 48u
#define FLAG_BYTE (OFF_ATTR + 6u)
#define OFF_NAME 56u

/* static: UEFI stack is small, and the same buffers serve one call at a time (the menu is single-threaded) */
#define LS_ALIGNED __attribute__((aligned(4096)))
static ls_u8 g_hdr_p[LS_MAX_BLOCK] LS_ALIGNED, g_hdr_b[LS_MAX_BLOCK] LS_ALIGNED;
static ls_u8 g_ent_p[LS_MAX_ENTRIES] LS_ALIGNED, g_ent_b[LS_MAX_ENTRIES] LS_ALIGNED;
/* primary: header + entries in one run; backup: entries + header in one run */
static ls_u8 g_run[LS_MAX_BLOCK + LS_MAX_ENTRIES] LS_ALIGNED, g_check[LS_MAX_BLOCK + LS_MAX_ENTRIES] LS_ALIGNED;

static ls_u32 rd32(const ls_u8 *p) { return (ls_u32)p[0] | (ls_u32)p[1] << 8 | (ls_u32)p[2] << 16 | (ls_u32)p[3] << 24; }
static ls_u64 rd64(const ls_u8 *p) { return (ls_u64)rd32(p) | (ls_u64)rd32(p + 4) << 32; }
static void wr32(ls_u8 *p, ls_u32 v) { p[0] = (ls_u8)v; p[1] = (ls_u8)(v >> 8); p[2] = (ls_u8)(v >> 16); p[3] = (ls_u8)(v >> 24); }
static int same(const ls_u8 *a, const ls_u8 *b, ls_u32 n) { ls_u32 i; for (i = 0; i < n; i++) if (a[i] != b[i]) return 0; return 1; }
static void copy(ls_u8 *d, const ls_u8 *s, ls_u32 n) { ls_u32 i; for (i = 0; i < n; i++) d[i] = s[i]; }

ls_u32 ls_crc32(const void *p, ls_u32 n)
{
  const ls_u8 *b = (const ls_u8 *)p;
  ls_u32 c = 0xFFFFFFFFu, i;
  int k;
  for (i = 0; i < n; i++) {
    c ^= b[i];
    for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
  }
  return ~c;
}

const char *ls_status_text(ls_status s)
{
  switch (s) {
  case LS_OK: return "ok";
  case LS_ERR_IO: return "read failed";
  case LS_ERR_BLOCK_SIZE: return "block size not 512 or 4096";
  case LS_ERR_HEADER: return "GPT header not valid";
  case LS_ERR_LAYOUT: return "GPT layout not the expected one";
  case LS_ERR_ENTRY_CRC: return "GPT entries fail their CRC";
  case LS_ERR_COPIES_DIFFER: return "GPT copies differ outside the slot flags";
  case LS_NOT_THIS_LUN: return "no single boot_a and boot_b here";
  case LS_ERR_STATE: return "slot flags refuse this";
  case LS_ERR_WRITE_BACKUP: return "backup GPT write failed; nothing changed for the boot";
  case LS_ERR_WRITE_PRIMARY: return "primary GPT write failed; backup holds the new flags";
  }
  return "?";
}

/* header in this copy: crc over the 92 bytes with its crc field zero */
static int header_ok(const ls_u8 *h, ls_u64 my, ls_u64 alt)
{
  static const ls_u8 sig[8] = { 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
  ls_u8 tmp[HDR_SIZE];
  ls_u32 crc;
  if (!same(h, sig, 8) || rd32(h + 8) != 0x00010000u || rd32(h + 12) != HDR_SIZE) return 0;
  if (rd64(h + OFF_MY_LBA) != my || rd64(h + OFF_ALT_LBA) != alt) return 0;
  crc = rd32(h + OFF_HDR_CRC);
  copy(tmp, h, HDR_SIZE);
  wr32(tmp + OFF_HDR_CRC, 0);
  return ls_crc32(tmp, HDR_SIZE) == crc;
}

static int name_is(const ls_u8 *e, const char *name)
{
  ls_u32 i;
  for (i = 0; i < 36; i++) {
    ls_u32 c = (ls_u32)e[OFF_NAME + 2 * i] | (ls_u32)e[OFF_NAME + 2 * i + 1] << 8;
    if (c != (ls_u8)name[i]) return 0;
    if (c == 0) return 1;
  }
  return 0;
}

static ls_status load_all(const ls_disk *d, ls_table *t)
{
  ls_u32 bs = d->block_size, count, bytes, blocks, i, na = 0, nb = 0;
  ls_u64 alt, backup_lba;
  if (bs != 512u && bs != 4096u) return LS_ERR_BLOCK_SIZE;
  if (d->read(d->ctx, 1, 1, g_hdr_p)) return LS_ERR_IO;
  alt = rd64(g_hdr_p + OFF_ALT_LBA);
  if (!header_ok(g_hdr_p, 1, alt)) return LS_ERR_HEADER;
  if (alt != d->last_lba) return LS_ERR_HEADER;
  if (d->read(d->ctx, alt, 1, g_hdr_b)) return LS_ERR_IO;
  if (!header_ok(g_hdr_b, alt, 1)) return LS_ERR_HEADER;

  count = rd32(g_hdr_p + OFF_COUNT);
  if (rd32(g_hdr_p + OFF_ENTRY_SIZE) != ENTRY_SIZE || count == 0 || count > LS_MAX_ENTRIES / ENTRY_SIZE) return LS_ERR_LAYOUT;
  bytes = count * ENTRY_SIZE;
  /* ABL's own writes (UpdatePartitionAttributes) take this layout for granted: entries right after the primary header, and a reserved run right before the
   * backup header. [V dump] 16 KiB reserved on every LUN (first usable LBA 6, backup entries at last - 4), so the run is longer than the entries in use */
  if (rd64(g_hdr_p + OFF_ENTRIES_LBA) != 2) return LS_ERR_LAYOUT;
  backup_lba = rd64(g_hdr_b + OFF_ENTRIES_LBA);
  if (backup_lba >= alt || alt - backup_lba > LS_MAX_ENTRIES / bs) return LS_ERR_LAYOUT;
  blocks = (ls_u32)(alt - backup_lba);
  if (blocks * bs < bytes) return LS_ERR_LAYOUT;
  if (rd64(g_hdr_p + OFF_LAST) >= backup_lba || rd64(g_hdr_p + OFF_FIRST) < 2 + blocks) return LS_ERR_LAYOUT;
  /* the two headers may differ only in their own LBA fields and CRC */
  if (!same(g_hdr_p + OFF_FIRST, g_hdr_b + OFF_FIRST, OFF_ENTRIES_LBA - OFF_FIRST)) return LS_ERR_COPIES_DIFFER;
  if (rd32(g_hdr_b + OFF_COUNT) != count || rd32(g_hdr_b + OFF_ENTRY_SIZE) != ENTRY_SIZE) return LS_ERR_COPIES_DIFFER;

  if (d->read(d->ctx, 2, blocks, g_ent_p) || d->read(d->ctx, backup_lba, blocks, g_ent_b)) return LS_ERR_IO;
  if (ls_crc32(g_ent_p, bytes) != rd32(g_hdr_p + OFF_ENTRIES_CRC)) return LS_ERR_ENTRY_CRC;
  if (ls_crc32(g_ent_b, bytes) != rd32(g_hdr_b + OFF_ENTRIES_CRC)) return LS_ERR_ENTRY_CRC;

  for (i = 0; i < count; i++) {
    const ls_u8 *e = g_ent_p + i * ENTRY_SIZE;
    if (name_is(e, "boot_a")) { t->index_a = i; na++; }
    if (name_is(e, "boot_b")) { t->index_b = i; nb++; }
  }
  if (na != 1 || nb != 1) return LS_NOT_THIS_LUN;
  /* whole arrays equal except byte 6 of the attributes of these two entries */
  for (i = 0; i < bytes; i++) {
    if (g_ent_p[i] != g_ent_b[i] && i != t->index_a * ENTRY_SIZE + FLAG_BYTE && i != t->index_b * ENTRY_SIZE + FLAG_BYTE)
      return LS_ERR_COPIES_DIFFER;
  }
  t->flags_a = g_ent_p[t->index_a * ENTRY_SIZE + FLAG_BYTE];
  t->flags_b = g_ent_p[t->index_b * ENTRY_SIZE + FLAG_BYTE];
  t->backup_a = g_ent_b[t->index_a * ENTRY_SIZE + FLAG_BYTE];
  t->backup_b = g_ent_b[t->index_b * ENTRY_SIZE + FLAG_BYTE];
  t->entries_blocks = blocks;
  t->entry_count = count;
  t->alt_lba = alt;
  return LS_OK;
}

ls_status ls_load(const ls_disk *d, ls_table *t) { return load_all(d, t); }

int ls_plan_android(ls_u8 a, ls_u8 b, ls_u8 *new_a, ls_u8 *new_b, const char **why)
{
  if (!(b & LS_ACTIVE)) { *why = "slot b is not active"; return -1; }
  if (a & LS_ACTIVE) { *why = "both slots are active"; return -1; }
  if ((a & LS_PRIO_MASK) == 0) { *why = "slot a has priority 0: fastboot set_active a"; return -1; }
  /* [V ABL HandleActiveSlotUnbootable] only a successful, not unbootable slot is a fallback target. Not forced: that would hide a broken Android */
  if (!(a & LS_SUCCESSFUL)) { *why = "slot a is not marked successful: fastboot set_active a"; return -1; }
  if (a & LS_UNBOOTABLE) { *why = "slot a is marked unbootable: fastboot set_active a"; return -1; }
  *new_a = a;
  *new_b = (ls_u8)(b & ~(LS_RETRY_MASK | LS_SUCCESSFUL));
  return 0;
}

int ls_fallback_plan(ls_u8 b, int has_lastgood, unsigned *failed)
{
  unsigned r = LS_RETRIES(b);
  *failed = 0;
  if (!(b & LS_ACTIVE) || (b & LS_SUCCESSFUL) || (b & LS_UNBOOTABLE)) return 0;
  if (r < LS_RETRY_MAX - 1) *failed = LS_RETRY_MAX - 1 - r;
  return (has_lastgood && *failed >= LS_LASTGOOD_AT && r > 0) ? 1 : 0;
}

int ls_refill_gate(int key_heard, ls_u32 imem_word, const char **why)
{
  if (imem_word == LS_PANIC_WORD) { *why = "the last iOS boot panicked"; return -1; }
  if (!key_heard) { *why = "no key event in this menu"; return -1; }
  return 0;
}

int ls_plan_refill(ls_u8 a, ls_u8 b, ls_u8 *new_a, ls_u8 *new_b, const char **why)
{
  *new_a = a;
  *new_b = b;
  if (!(b & LS_ACTIVE) || (a & LS_ACTIVE)) { *why = "slot b is not the one active slot"; return -1; }
  if (b & LS_UNBOOTABLE) { *why = "slot b is marked unbootable"; return -1; }
  if (!(a & LS_SUCCESSFUL) || (a & LS_UNBOOTABLE)) { *why = "slot a is no fallback target"; return -1; }
  /* successful set: ABL does not count, nothing to refill. Never set here: it would turn off the fallback for a broken Mu */
  if (b & LS_SUCCESSFUL) return 0;
  if (LS_RETRIES(b) <= LS_REFILL_AT) *new_b = (ls_u8)((b & ~LS_RETRY_MASK) | (LS_RETRY_MAX << LS_RETRY_SHIFT));
  return 0;
}

/* set flags and both CRCs in copy (hdr, ent) */
static void apply(ls_u8 *hdr, ls_u8 *ent, const ls_table *t, ls_u8 a, ls_u8 b)
{
  ls_u8 tmp[HDR_SIZE];
  ent[t->index_a * ENTRY_SIZE + FLAG_BYTE] = a;
  ent[t->index_b * ENTRY_SIZE + FLAG_BYTE] = b;
  wr32(hdr + OFF_ENTRIES_CRC, ls_crc32(ent, t->entry_count * ENTRY_SIZE));
  copy(tmp, hdr, HDR_SIZE);
  wr32(tmp + OFF_HDR_CRC, 0);
  wr32(hdr + OFF_HDR_CRC, ls_crc32(tmp, HDR_SIZE));
}

ls_status ls_commit(const ls_disk *d, ls_u8 new_a, ls_u8 new_b, int *written)
{
  ls_table t;
  ls_status s;
  ls_u32 bs = d->block_size, run_bytes, run_blocks;
  ls_u64 backup_lba;
  *written = 0;
  s = load_all(d, &t);
  if (s != LS_OK) return s;
  run_blocks = 1 + t.entries_blocks;
  run_bytes = run_blocks * bs;
  backup_lba = t.alt_lba - t.entries_blocks;

  /* 1. backup: entries, then header, one command. The first write goes to the copy no loader reads while the primary is valid: a refused or failing write path
   *    shows here, before the primary is touched. */
  if (t.backup_a != new_a || t.backup_b != new_b) {
    apply(g_hdr_b, g_ent_b, &t, new_a, new_b);
    copy(g_run, g_ent_b, t.entries_blocks * bs);
    copy(g_run + t.entries_blocks * bs, g_hdr_b, bs);
    if (d->write(d->ctx, backup_lba, run_blocks, g_run) || d->flush(d->ctx)) return LS_ERR_WRITE_BACKUP;
    *written = 1;
    if (d->read(d->ctx, backup_lba, run_blocks, g_check) || !same(g_check, g_run, run_bytes)) return LS_ERR_WRITE_BACKUP;
  }
  /* 2. primary: header, then entries up to the block with the last flag byte, one command: the shortest window in which the primary is not valid. ABL writes the same way at every retry, with more blocks */
  if (t.flags_a != new_a || t.flags_b != new_b) {
    ls_u32 top = t.index_a > t.index_b ? t.index_a : t.index_b;
    ls_u32 ent_blocks = (top * ENTRY_SIZE + FLAG_BYTE) / bs + 1;
    /* the entry CRC covers the whole array: apply() works on the whole array, the blocks after ent_blocks do not change */
    apply(g_hdr_p, g_ent_p, &t, new_a, new_b);
    run_blocks = 1 + ent_blocks;
    run_bytes = run_blocks * bs;
    copy(g_run, g_hdr_p, bs);
    copy(g_run + bs, g_ent_p, ent_blocks * bs);
    if (d->write(d->ctx, 1, run_blocks, g_run) || d->flush(d->ctx)) return LS_ERR_WRITE_PRIMARY;
    *written = 1;
    if (d->read(d->ctx, 1, run_blocks, g_check) || !same(g_check, g_run, run_bytes)) return LS_ERR_WRITE_PRIMARY;
  }
  /* 3. the whole table again, as a loader would read it */
  s = load_all(d, &t);
  if (s != LS_OK) return LS_ERR_WRITE_PRIMARY;
  if (t.flags_a != new_a || t.flags_b != new_b || t.backup_a != new_a || t.backup_b != new_b) return LS_ERR_WRITE_PRIMARY;
  return LS_OK;
}
