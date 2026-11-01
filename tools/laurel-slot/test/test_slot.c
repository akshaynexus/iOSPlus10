/*
 * Host test of tools/laurel-slot/laurel_slot.c on the phone's own table: the GPT dump of the backup (head + tail of each LUN). Out of git.
 *   test_slot DIR   (DIR/gpt-sd?-head.bin, -tail.bin)
 * The disk is a map of those two 1 MiB areas; any read or write outside them is a test failure. Contains a model of ABL's slot rules (QRD abl FindBootableSlot,
 * HandleActiveSlotUnbootable, SetActiveSlot, ValidateSlotGuids) and of the HAL's set_active_boot_slot (LineageOS bootctrl), both with the GUID swap.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../laurel_slot.h"

#define AREA (1u << 20)
#define BS 4096u
static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

typedef struct {
  unsigned char head[AREA], tail[AREA];
  unsigned long long blocks;      /* LUN size in blocks */
  int writes;                     /* write commands */
  long cut_after;                 /* power cut: number of blocks that still reach the flash; -1 = no cut */
  int dead;                       /* power is gone: no more I/O counts */
  int outside;                    /* I/O outside the two areas */
  int fail_write_at;              /* 1-based write command that returns an error, 0 = none */
} disk_t;

static unsigned char *loc(disk_t *d, unsigned long long lba)
{
  unsigned long long tail0 = d->blocks - AREA / BS;
  if (lba < AREA / BS) return d->head + lba * BS;
  if (lba >= tail0 && lba < d->blocks) return d->tail + (lba - tail0) * BS;
  return NULL;
}
static int d_read(void *c, ls_u64 lba, ls_u32 n, void *buf)
{
  disk_t *d = c; ls_u32 i;
  for (i = 0; i < n; i++) {
    unsigned char *p = loc(d, lba + i);
    if (!p) { d->outside++; return 1; }
    memcpy((char *)buf + i * BS, p, BS);
  }
  return 0;
}
static int d_write(void *c, ls_u64 lba, ls_u32 n, const void *buf)
{
  disk_t *d = c; ls_u32 i;
  d->writes++;
  if (d->fail_write_at && d->writes == d->fail_write_at) return 1;
  for (i = 0; i < n; i++) {
    unsigned char *p = loc(d, lba + i);
    if (!p) { d->outside++; return 1; }
    if (d->dead) return 1;
    if (d->cut_after == 0) { d->dead = 1; return 1; }
    if (d->cut_after > 0) d->cut_after--;
    memcpy(p, (const char *)buf + i * BS, BS);
  }
  return 0;
}
static int d_flush(void *c) { (void)c; return 0; }

static unsigned char g_clean[2][AREA];
static disk_t *new_disk(const char *dir, const char *lun)
{
  char p[600]; FILE *f; disk_t *d = calloc(1, sizeof(*d));
  snprintf(p, sizeof(p), "%s/gpt-%s-head.bin", dir, lun); f = fopen(p, "rb"); if (!f || fread(d->head, 1, AREA, f) != AREA) { printf("cannot read %s\n", p); exit(2); } fclose(f);
  snprintf(p, sizeof(p), "%s/gpt-%s-tail.bin", dir, lun); f = fopen(p, "rb"); if (!f || fread(d->tail, 1, AREA, f) != AREA) { printf("cannot read %s\n", p); exit(2); } fclose(f);
  /* LUN size: the backup header's own LBA + 1; the tail's last block is the backup header */
  d->blocks = 0; { unsigned long long alt; memcpy(&alt, d->head + BS + 32, 8); d->blocks = alt + 1; }
  d->cut_after = -1;
  return d;
}
static ls_disk io(disk_t *d) { ls_disk x = { d, BS, d->blocks - 1, d_read, d_write, d_flush }; return x; }

/* ---- table helpers for the models (they work on both copies, as ABL and the HAL do) ---- */
static unsigned rd32le(const unsigned char *p) { unsigned v; memcpy(&v, p, 4); return v; }
static void wr32le(unsigned char *p, unsigned v) { memcpy(p, &v, 4); }
static void fix_crc(unsigned char *h, const unsigned char *e)
{
  unsigned n = rd32le(h + 80) * 128;
  wr32le(h + 88, ls_crc32(e, n));
  wr32le(h + 16, 0);
  wr32le(h + 16, ls_crc32(h, 92));
}
static unsigned char *copy_entries(disk_t *d, int backup)
{
  unsigned long long alt, lba; memcpy(&alt, d->head + BS + 32, 8);
  if (!backup) return loc(d, 2);
  memcpy(&lba, loc(d, alt) + 72, 8);
  return loc(d, lba);
}
static unsigned char *copy_header(disk_t *d, int backup)
{
  unsigned long long alt; memcpy(&alt, d->head + BS + 32, 8);
  return backup ? loc(d, alt) : loc(d, 1);
}
static int find_entry(const unsigned char *e, unsigned count, const char *name)
{
  unsigned i, k;
  for (i = 0; i < count; i++) {
    const unsigned char *x = e + i * 128 + 56;
    for (k = 0;; k++) {
      if (x[2 * k] != (unsigned char)name[k] || x[2 * k + 1]) break;
      if (!name[k]) return (int)i;
    }
  }
  return -1;
}
/* A/B flags as ABL sees them: primary if valid, else backup. no valid copy = -1 */
static int loader_copy(disk_t *d)
{
  int c;
  for (c = 0; c < 2; c++) {
    unsigned char h[92], *hp = copy_header(d, c), *ep = copy_entries(d, c);
    memcpy(h, hp, 92); wr32le(h + 16, 0);
    if (memcmp(hp, "EFI PART", 8) || ls_crc32(h, 92) != rd32le(hp + 16)) continue;
    if (ls_crc32(ep, rd32le(hp + 80) * 128) != rd32le(hp + 88)) continue;
    return c;
  }
  return -1;
}
static unsigned char get_flags(disk_t *d, const char *name)
{
  int c = loader_copy(d);
  unsigned char *e;
  if (c < 0) return 0xFF;
  e = copy_entries(d, c);
  return e[find_entry(e, rd32le(copy_header(d, c) + 80), name) * 128 + 54];
}
static void set_flags_both(disk_t *d, const char *name, unsigned char v)
{
  int c;
  for (c = 0; c < 2; c++) {
    unsigned char *e = copy_entries(d, c), *h = copy_header(d, c);
    e[find_entry(e, rd32le(h + 80), name) * 128 + 54] = v;
    fix_crc(h, e);
  }
}
/* boot_lun: 1 = xbl_a, 2 = xbl_b: state outside the GPT, set by the HAL and ABL */
static int g_boot_lun;
/* swap type GUIDs of every x_a / x_b pair, in both copies (ABL SwitchPtnSlots, HAL UPDATE_SLOT) */
static void swap_all_guids(disk_t *d)
{
  int c; unsigned i;
  for (c = 0; c < 2; c++) {
    unsigned char *e = copy_entries(d, c), *h = copy_header(d, c);
    unsigned n = rd32le(h + 80);
    for (i = 0; i < n; i++) {
      char nm[40]; unsigned k; int o;
      for (k = 0; k < 36; k++) nm[k] = (char)e[i * 128 + 56 + 2 * k];
      nm[36] = 0; k = (unsigned)strlen(nm);
      if (k < 3 || strcmp(nm + k - 2, "_a")) continue;
      nm[k - 1] = 'b';
      o = find_entry(e, n, nm);
      if (o >= 0) { unsigned char t[16]; memcpy(t, e + i * 128, 16); memcpy(e + i * 128, e + o * 128, 16); memcpy(e + o * 128, t, 16); }
    }
    fix_crc(h, e);
  }
}
/* HAL set_active_boot_slot [V boot_control.cpp]: 0x3F on the new slot, active bit cleared on the other */
static void hal_set_active(disk_t *d, int slot)
{
  const char *n = slot ? "boot_b" : "boot_a", *o = slot ? "boot_a" : "boot_b";
  int was = (get_flags(d, "boot_a") & LS_ACTIVE) ? 0 : 1;
  set_flags_both(d, o, (unsigned char)(get_flags(d, o) & ~LS_ACTIVE));
  set_flags_both(d, n, 0x3F);
  if (was != slot) swap_all_guids(d);
  g_boot_lun = slot ? 2 : 1;
}
/* boot result of ABL: slot 0/1, or -1 = no bootable slot (fastboot). Reboots inside fallback are followed. */
static int abl_boot(disk_t *d)
{
  int guard;
  for (guard = 0; guard < 4; guard++) {
    unsigned char a, b, f; int slot, active_prio_a, active_prio_b;
    if (loader_copy(d) < 0) return -1;
    a = get_flags(d, "boot_a"); b = get_flags(d, "boot_b");
    active_prio_a = (a & LS_ACTIVE) ? (a & LS_PRIO_MASK) : 0;
    active_prio_b = (b & LS_ACTIVE) ? (b & LS_PRIO_MASK) : 0;
    if (!active_prio_a && !active_prio_b) return -1;
    slot = active_prio_b > active_prio_a ? 1 : 0;
    f = slot ? b : a;
    if (!(f & LS_UNBOOTABLE) && (f & LS_SUCCESSFUL)) {
      /* boots */
    } else if (!(f & LS_UNBOOTABLE) && !(f & LS_SUCCESSFUL) && LS_RETRIES(f) > 0) {
      f = (unsigned char)((f & ~LS_RETRY_MASK) | ((LS_RETRIES(f) - 1) << LS_RETRY_SHIFT));
      set_flags_both(d, slot ? "boot_b" : "boot_a", f);
    } else {
      /* HandleActiveSlotUnbootable */
      int alt = -1;
      set_flags_both(d, slot ? "boot_b" : "boot_a", (unsigned char)(f | LS_UNBOOTABLE));
      a = get_flags(d, "boot_a"); b = get_flags(d, "boot_b");
      if (!(a & LS_UNBOOTABLE) && (a & LS_SUCCESSFUL) && (a & LS_PRIO_MASK)) alt = 0;
      if (!(b & LS_UNBOOTABLE) && (b & LS_SUCCESSFUL) && (b & LS_PRIO_MASK) > (alt == 0 ? (a & LS_PRIO_MASK) : 0)) alt = 1;
      if (alt < 0) return -1;
      /* SetActiveSlot (alt, FALSE) */
      {
        const char *n = alt ? "boot_b" : "boot_a", *o = alt ? "boot_a" : "boot_b";
        unsigned char nf = get_flags(d, n), of = get_flags(d, o);
        nf = (unsigned char)((nf | LS_PRIO_MASK | LS_ACTIVE | LS_RETRY_MASK) & ~LS_UNBOOTABLE);
        of = (unsigned char)((of & ~(LS_ACTIVE | LS_PRIO_MASK)) | 2);
        set_flags_both(d, n, nf); set_flags_both(d, o, of);
      }
      swap_all_guids(d);
      g_boot_lun = alt ? 2 : 1;
      continue; /* reset */
    }
    /* ValidateSlotGuids: boot_x and abl_x must differ in type GUID, boot LUN must match. */
    {
      unsigned char *e = copy_entries(d, loader_copy(d));
      unsigned n = rd32le(copy_header(d, loader_copy(d)) + 80);
      int ib = find_entry(e, n, slot ? "boot_b" : "boot_a"), il = find_entry(e, n, slot ? "abl_b" : "abl_a");
      if (ib < 0 || il < 0 || !memcmp(e + ib * 128, e + il * 128, 16)) return -2;
      if (g_boot_lun != (slot ? 2 : 1)) return -2;
    }
    return slot;
  }
  return -1;
}
/* bytes that differ between two snapshots, against an allow list */
static int differs_only_at(const unsigned char *x, const unsigned char *y, unsigned n, const unsigned *ok, unsigned nok)
{
  unsigned i, k;
  for (i = 0; i < n; i++) {
    if (x[i] == y[i]) continue;
    for (k = 0; k < nok; k++) if (ok[k] == i) break;
    if (k == nok) { printf("  byte %#x changed outside the allowed list\n", i); return 0; }
  }
  return 1;
}

static const char *g_dir;

/* the dump: the phone on slot a (phone state 2026-11-02 01:37) */
static void test_read_dump(void)
{
  static const char *luns[] = { "sda", "sdb", "sdc", "sdd", "sdf" };
  unsigned i; ls_table t;
  disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d);
  ls_status s = ls_load(&x, &t);
  CHECK(s == LS_OK, "sde: %s", ls_status_text(s));
  CHECK(t.index_a == 10 && t.index_b == 31, "indexes %u %u", t.index_a, t.index_b);
  CHECK(t.flags_a == 0x77 && t.flags_b == 0x7B, "flags %#x %#x", t.flags_a, t.flags_b);
  CHECK(t.backup_a == 0x77 && t.backup_b == 0x7B, "backup flags");
  CHECK(d->writes == 0, "load writes");
  printf("sde: boot_a #%u %#x, boot_b #%u %#x, %u entries, backup header LBA %llu\n", t.index_a, t.flags_a, t.index_b, t.flags_b, t.entry_count, (unsigned long long)t.alt_lba);
  free(d);
  for (i = 0; i < 5; i++) {
    d = new_disk(g_dir, luns[i]); x = io(d);
    s = ls_load(&x, &t);
    CHECK(s == LS_NOT_THIS_LUN, "%s: %s", luns[i], ls_status_text(s));
    CHECK(d->outside == 0 && d->writes == 0, "%s io", luns[i]);
    free(d);
  }
}

/* exact byte diff: only byte 6 of the two attributes + both CRC fields of each header */
static void test_byte_diff(void)
{
  disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d);
  ls_table t; int w; ls_status s; unsigned nok = 0, i; unsigned ok[32];
  unsigned long long blocks0 = d->blocks;
  hal_set_active(d, 1);              /* the state in iOS use */
  memcpy(g_clean[0], d->head, AREA); memcpy(g_clean[1], d->tail, AREA);
  s = ls_load(&x, &t); CHECK(s == LS_OK, "load %s", ls_status_text(s));
  CHECK(t.flags_b == 0x3F, "b %#x", t.flags_b);
  s = ls_commit(&x, 0x73, 0x07, &w);  /* some new flags */
  CHECK(s == LS_OK && w == 1, "commit %s", ls_status_text(s));
  CHECK(d->writes == 2, "2 write commands, got %d", d->writes);
  /* head area: LBA1 header crc fields, entries */
  ok[nok++] = BS + 16; ok[nok++] = BS + 17; ok[nok++] = BS + 18; ok[nok++] = BS + 19;
  ok[nok++] = BS + 88; ok[nok++] = BS + 89; ok[nok++] = BS + 90; ok[nok++] = BS + 91;
  ok[nok++] = 2 * BS + t.index_a * 128 + 54; ok[nok++] = 2 * BS + t.index_b * 128 + 54;
  CHECK(differs_only_at(g_clean[0], d->head, AREA, ok, nok), "head area");
  {
    unsigned tail_hdr = AREA - BS, tail_ent = AREA - BS - t.entries_blocks * BS; /* entries_blocks = the reserved run */
    nok = 0;
    for (i = 0; i < 4; i++) { ok[nok++] = tail_hdr + 16 + i; ok[nok++] = tail_hdr + 88 + i; }
    ok[nok++] = tail_ent + t.index_a * 128 + 54; ok[nok++] = tail_ent + t.index_b * 128 + 54;
    CHECK(differs_only_at(g_clean[1], d->tail, AREA, ok, nok), "tail area");
  }
  CHECK(d->outside == 0 && d->blocks == blocks0, "outside I/O");
  s = ls_load(&x, &t);
  CHECK(s == LS_OK && t.flags_a == 0x73 && t.flags_b == 0x07 && t.backup_a == 0x73 && t.backup_b == 0x07, "reload");
  /* same flags again: no write */
  d->writes = 0;
  s = ls_commit(&x, 0x73, 0x07, &w);
  CHECK(s == LS_OK && w == 0 && d->writes == 0, "second commit writes nothing");
  free(d);
}

static void damage_case(const char *what, void (*hurt)(disk_t *), ls_status want)
{
  disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t; int w = 9; ls_status s;
  unsigned char before_h[AREA], before_t[AREA];
  hal_set_active(d, 1);
  hurt(d);
  memcpy(before_h, d->head, AREA); memcpy(before_t, d->tail, AREA);
  d->writes = 0;
  s = ls_load(&x, &t);
  CHECK(s == want, "%s: load says '%s', want '%s'", what, ls_status_text(s), ls_status_text(want));
  s = ls_commit(&x, 0x77, 0x07, &w);
  CHECK(s == want && w == 0, "%s: commit says '%s'", what, ls_status_text(s));
  CHECK(d->writes == 0, "%s: %d writes on a damaged table", what, d->writes);
  CHECK(!memcmp(before_h, d->head, AREA) && !memcmp(before_t, d->tail, AREA), "%s: bytes changed", what);
  free(d);
}
static void h_sig(disk_t *d) { d->head[BS] ^= 1; }
static void h_rev(disk_t *d) { d->head[BS + 10] ^= 1; fix_crc(d->head + BS, d->head + 2 * BS); }
static void h_crc(disk_t *d) { d->head[BS + 16] ^= 1; }
static void h_alt(disk_t *d) { d->head[BS + 32] ^= 1; fix_crc(d->head + BS, d->head + 2 * BS); }
static void h_entry_byte(disk_t *d) { d->head[2 * BS + 100] ^= 1; }
static void h_entry_byte_tail(disk_t *d) { copy_entries(d, 1)[100] ^= 1; }
static void h_tail_hdr(disk_t *d) { copy_header(d, 1)[0] ^= 1; }
static void h_tail_crc(disk_t *d) { copy_header(d, 1)[16] ^= 1; }
static void h_count(disk_t *d) { wr32le(d->head + BS + 80, 100000); wr32le(d->head + BS + 16, 0); wr32le(d->head + BS + 16, ls_crc32(d->head + BS, 92)); }
static void h_entsz(disk_t *d) { wr32le(d->head + BS + 84, 256); wr32le(d->head + BS + 16, 0); wr32le(d->head + BS + 16, ls_crc32(d->head + BS, 92)); }
static void h_pe_lba(disk_t *d) { d->head[BS + 72] = 3; wr32le(d->head + BS + 16, 0); wr32le(d->head + BS + 16, ls_crc32(d->head + BS, 92)); }
/* valid copies that differ: name of another partition, GUID of boot_a, attribute byte 7, attribute of another entry */
static void diff_at(disk_t *d, unsigned off) { unsigned char *e = copy_entries(d, 1), *h = copy_header(d, 1); e[off] ^= 0x10; fix_crc(h, e); }
static void h_diff_guid(disk_t *d) { diff_at(d, 10 * 128 + 1); }
static void h_diff_name(disk_t *d) { diff_at(d, 3 * 128 + 56); }
static void h_diff_attr7(disk_t *d) { diff_at(d, 10 * 128 + 55); }
static void h_diff_attr_other(disk_t *d) { diff_at(d, 11 * 128 + 54); }
static void h_diff_lba(disk_t *d) { diff_at(d, 31 * 128 + 32); }
static void h_two_boot_a(disk_t *d)
{
  int c;
  for (c = 0; c < 2; c++) { unsigned char *e = copy_entries(d, c), *h = copy_header(d, c); memcpy(e + 11 * 128 + 56, e + 10 * 128 + 56, 72); fix_crc(h, e); }
}
static void h_no_boot_b(disk_t *d)
{
  int c;
  for (c = 0; c < 2; c++) { unsigned char *e = copy_entries(d, c), *h = copy_header(d, c); e[31 * 128 + 56] = 'x'; fix_crc(h, e); }
}
static void test_damage(void)
{
  damage_case("primary signature", h_sig, LS_ERR_HEADER);
  damage_case("primary revision (crc good)", h_rev, LS_ERR_HEADER);
  damage_case("primary header crc", h_crc, LS_ERR_HEADER);
  damage_case("primary alt LBA (crc good)", h_alt, LS_ERR_HEADER);
  damage_case("primary entry byte", h_entry_byte, LS_ERR_ENTRY_CRC);
  damage_case("backup entry byte", h_entry_byte_tail, LS_ERR_ENTRY_CRC);
  damage_case("backup signature", h_tail_hdr, LS_ERR_HEADER);
  damage_case("backup header crc", h_tail_crc, LS_ERR_HEADER);
  damage_case("entry count 100000", h_count, LS_ERR_LAYOUT);
  damage_case("entry size 256", h_entsz, LS_ERR_LAYOUT);
  damage_case("entries at LBA 3", h_pe_lba, LS_ERR_LAYOUT);
  damage_case("valid copies, GUID of boot_a differs", h_diff_guid, LS_ERR_COPIES_DIFFER);
  damage_case("valid copies, a name differs", h_diff_name, LS_ERR_COPIES_DIFFER);
  damage_case("valid copies, attribute byte 7 differs", h_diff_attr7, LS_ERR_COPIES_DIFFER);
  damage_case("valid copies, flags of another partition differ", h_diff_attr_other, LS_ERR_COPIES_DIFFER);
  damage_case("valid copies, first LBA of boot_b differs", h_diff_lba, LS_ERR_COPIES_DIFFER);
  damage_case("two boot_a", h_two_boot_a, LS_NOT_THIS_LUN);
  damage_case("no boot_b", h_no_boot_b, LS_NOT_THIS_LUN);
  /* wrong block size */
  {
    disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t;
    x.block_size = 1024;
    CHECK(ls_load(&x, &t) == LS_ERR_BLOCK_SIZE, "block size");
    free(d);
  }
  /* the LUN is shorter or longer than the table says */
  {
    disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t;
    x.last_lba += 1;
    CHECK(ls_load(&x, &t) == LS_ERR_HEADER, "LUN size");
    free(d);
  }
}

/* copies valid, differ only in the two flag bytes: state after a cut between the copies. Must load, commit must finish */
static void test_copies_flag_diff(void)
{
  disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t; int w; ls_status s;
  unsigned char *e, *h;
  hal_set_active(d, 1);
  e = copy_entries(d, 1); h = copy_header(d, 1);
  e[31 * 128 + 54] = 0x07; fix_crc(h, e);
  s = ls_load(&x, &t);
  CHECK(s == LS_OK && t.flags_b == 0x3F && t.backup_b == 0x07, "flag diff load: %s", ls_status_text(s));
  s = ls_commit(&x, t.flags_a, 0x07, &w);
  CHECK(s == LS_OK && w == 1, "flag diff commit: %s", ls_status_text(s));
  CHECK(d->writes == 1, "only the primary needs writing, got %d", d->writes);
  s = ls_load(&x, &t);
  CHECK(s == LS_OK && t.flags_b == 0x07 && t.backup_b == 0x07, "flag diff after");
  free(d);
}

/* plans */
static void test_plans(void)
{
  ls_u8 a, b; const char *why = "";
  CHECK(ls_plan_android(0x73, 0x3F, &a, &b, &why) == 0 && a == 0x73 && b == 0x07, "android normal: %#x %#x", a, b);
  CHECK(ls_plan_android(0x73, 0x7F, &a, &b, &why) == 0 && b == 0x07, "android clears successful of b");
  CHECK(ls_plan_android(0x83 | 0x38, 0x3F, &a, &b, &why) == 0 && a == (0x43 | 0x38), "android repairs a: %#x", a);
  CHECK(ls_plan_android(0x77, 0x7B, &a, &b, &why) != 0, "android: b not active");
  CHECK(ls_plan_android(0x77, 0x3F, &a, &b, &why) != 0, "android: both active");
  CHECK(ls_plan_android(0x70, 0x3F, &a, &b, &why) != 0, "android: a priority 0");
  /* refill: every value of retries */
  { unsigned r;
    for (r = 0; r <= 7; r++) {
      ls_u8 in = (ls_u8)(0x07 | (r << LS_RETRY_SHIFT));
      CHECK(ls_plan_refill(0x73, in, &a, &b, &why) == 0, "refill r=%u", r);
      CHECK(a == 0x73, "refill changes a");
      CHECK(LS_RETRIES(b) == (r <= LS_REFILL_AT ? 7u : r), "refill r=%u -> %u", r, LS_RETRIES(b));
      CHECK(!(b & LS_SUCCESSFUL), "refill never sets successful");
    }
  }
  CHECK(ls_plan_refill(0x73, 0x7F, &a, &b, &why) == 0 && b == 0x7F && a == 0x73, "refill: successful b stays");
  CHECK(ls_plan_refill(0x77, 0x7B, &a, &b, &why) != 0, "refill: b not active");
  CHECK(ls_plan_refill(0x33, 0x0F, &a, &b, &why) != 0, "refill: a not successful");
  CHECK(ls_plan_refill(0x73, 0x8F, &a, &b, &why) != 0, "refill: b unbootable");
}

/* the whole cycle on the model */
static void test_cycle(void)
{
  disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t; int w, i, r;
  ls_u8 a, b; const char *why;
  g_boot_lun = 1;
  CHECK(abl_boot(d) == 0, "dump state boots slot a");
  hal_set_active(d, 1);
  /* iOS in daily use: 100 boots, menu reached each time */
  for (i = 0; i < 100; i++) {
    r = abl_boot(d);
    CHECK(r == 1, "iOS boot %d went to slot %d", i, r);
    CHECK(ls_load(&x, &t) == LS_OK, "load");
    CHECK(ls_plan_refill(t.flags_a, t.flags_b, &a, &b, &why) == 0, "plan refill %s", why);
    CHECK(ls_commit(&x, a, b, &w) == LS_OK, "refill commit");
  }
  printf("100 iOS boots with the menu: %d write commands (2 per refill), slot b flags %#x\n", d->writes, get_flags(d, "boot_b"));
  CHECK(d->writes <= 2 * 100 / 4 + 2, "too many writes: %d", d->writes);
  /* Android from the menu */
  CHECK(ls_load(&x, &t) == LS_OK, "load");
  CHECK(ls_plan_android(t.flags_a, t.flags_b, &a, &b, &why) == 0, "plan android");
  CHECK(ls_commit(&x, a, b, &w) == LS_OK && w == 1, "android commit");
  r = abl_boot(d);
  CHECK(r == 0, "after the Android choice ABL boots slot %d", r);
  CHECK((get_flags(d, "boot_a") & LS_ACTIVE) && !(get_flags(d, "boot_b") & LS_ACTIVE), "a active");
  printf("after the choice + ABL fallback: boot_a %#x, boot_b %#x, boot LUN %d\n", get_flags(d, "boot_a"), get_flags(d, "boot_b"), g_boot_lun);
  CHECK(abl_boot(d) == 0, "Android boots again");
  /* Android -> iOS: HAL. Unbootable of b is cleared by 0x3F */
  hal_set_active(d, 1);
  CHECK(get_flags(d, "boot_b") == 0x3F, "HAL makes b %#x", get_flags(d, "boot_b"));
  CHECK(abl_boot(d) == 1, "iOS again");
  /* broken Mu: nothing refills */
  for (i = 0; i < 6; i++) CHECK(abl_boot(d) == 1, "broken Mu boot %d", i);
  r = abl_boot(d);
  CHECK(r == 0, "broken Mu: after the retries ABL boots slot %d, want a", r);
  printf("broken Mu: slot a after %d more boots\n", 6);
  /* attribute-only slot change (the first idea): the model of ValidateSlotGuids refuses it */
  hal_set_active(d, 1);
  CHECK(ls_load(&x, &t) == LS_OK, "load");
  CHECK(ls_commit(&x, 0x7F, (ls_u8)(t.flags_b & ~LS_ACTIVE), &w) == LS_OK, "commit");
  r = abl_boot(d);
  CHECK(r == -2, "attribute-only change: model says %d, want refused (-2)", r);
  free(d);
}

/* power cut at every block of every write, and every failed write. Each state boots. */
static void test_power_cut(void)
{
  long cut; int boots_a = 0, boots_b = 0;
  for (cut = 0; cut <= 11; cut++) {
    disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t; int w; ls_u8 a, b; const char *why; int r; ls_status s;
    g_boot_lun = 1;
    hal_set_active(d, 1);
    CHECK(ls_load(&x, &t) == LS_OK, "load");
    CHECK(ls_plan_android(t.flags_a, t.flags_b, &a, &b, &why) == 0, "plan");
    d->cut_after = cut;
    s = ls_commit(&x, a, b, &w);
    d->cut_after = -1; d->dead = 0;
    /* a torn state: read what a loader takes, after a heal of the bad copy (Mu PartitionDxe, Gpt.c) or none */
    CHECK(loader_copy(d) >= 0, "cut %ld: no valid copy", cut);
    r = abl_boot(d);
    CHECK(r == 0 || r == 1, "cut %ld: boot result %d (%s)", cut, r, ls_status_text(s));
    if (r == 0) boots_a++; else boots_b++;
    if (r == 1) {
      /* menu again: after PartitionDxe heals an invalid backup from the primary, choose again */
      int c = loader_copy(d);
      unsigned char *he = copy_header(d, c), *en = copy_entries(d, c), *ho = copy_header(d, !c), *eo = copy_entries(d, !c);
      unsigned n = rd32le(he + 80) * 128, crc_h[1];
      (void)crc_h;
      if (!(ls_load(&x, &t) == LS_OK)) {
        memcpy(eo, en, n);
        { unsigned long long my, alt; memcpy(&my, ho + 24, 8); memcpy(&alt, ho + 32, 8); (void)my; (void)alt; }
        memcpy(ho + 88, he + 88, 4);
        fix_crc(ho, eo);
      }
      s = ls_load(&x, &t);
      CHECK(s == LS_OK, "cut %ld: after heal: %s", cut, ls_status_text(s));
      CHECK(ls_plan_android(t.flags_a, t.flags_b, &a, &b, &why) == 0, "cut %ld: plan again: %s", cut, why);
      CHECK(ls_commit(&x, a, b, &w) == LS_OK, "cut %ld: second commit", cut);
      r = abl_boot(d);
      CHECK(r == 0, "cut %ld: second try boots %d", cut, r);
    }
    free(d);
  }
  printf("power cut at each block (12 points): first boot on slot a %d times, slot b (menu again) %d times, 0 lost\n", boots_a, boots_b);
  /* write errors */
  {
    int at;
    for (at = 1; at <= 2; at++) {
      disk_t *d = new_disk(g_dir, "sde"); ls_disk x = io(d); ls_table t; int w; ls_u8 a, b; const char *why; ls_status s; int r;
      unsigned char before[AREA];
      g_boot_lun = 1;
      hal_set_active(d, 1);
      memcpy(before, d->head, AREA);
      CHECK(ls_load(&x, &t) == LS_OK, "load");
      CHECK(ls_plan_android(t.flags_a, t.flags_b, &a, &b, &why) == 0, "plan");
      d->fail_write_at = at;
      s = ls_commit(&x, a, b, &w);
      CHECK(s == (at == 1 ? LS_ERR_WRITE_BACKUP : LS_ERR_WRITE_PRIMARY), "write fail %d: %s", at, ls_status_text(s));
      if (at == 1) CHECK(!memcmp(before, d->head, AREA), "backup failure: primary touched");
      d->fail_write_at = 0;
      r = abl_boot(d);
      CHECK(r == 1, "write fail %d boots %d", at, r);
      free(d);
    }
  }
}

int main(int argc, char **argv)
{
  if (argc != 2) { printf("usage: test_slot BACKUP_DIR\n"); return 2; }
  g_dir = argv[1];
  test_read_dump();
  test_byte_diff();
  test_damage();
  test_copies_flag_diff();
  test_plans();
  test_cycle();
  test_power_cut();
  printf("slot core: %d checks, %d failures\n", checks, failures);
  return failures ? 1 : 0;
}
