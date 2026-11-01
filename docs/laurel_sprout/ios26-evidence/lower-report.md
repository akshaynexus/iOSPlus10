# a64-lower report

Rules: Rules { pac: true, rcpc: true, lse: true, sysreg: true, slide: true }. Page shift: 12 (0 = keep). Dead images: ["ANECompiler.framework/ANECompiler", "VisualGeneration.framework/VisualGeneration"].

## Cache `~/op10-apple/ios26/23F84-n104ap/tree/cache/dyld_shared_cache_arm64e`

| What | Count |
|---|---:|
| left for the kernel: LDAPUR/STLUR with offset or sign extension | 1 |
| left for the kernel: lse uses x30 | 10 |
| left, not proven code: blraa | 144 |
| left, not proven code: braa | 301 |
| left, not proven code: braaz | 22 |
| left, not proven code: ldraa | 8 |
| left, not proven code: ldrab | 3 |
| left, not proven code: lse | 81 |
| left, not proven code: retab | 207 |
| left, not proven code: stlur | 1 |
| left, not proven code: stlurh | 5 |
| one-word autda | 4864851 |
| one-word autdb | 15524 |
| one-word autdza | 28769 |
| one-word autia | 19611 |
| one-word autib | 6930 |
| one-word autiza | 382 |
| one-word blraa | 6443802 |
| one-word blraaz | 239971 |
| one-word blrab | 224 |
| one-word braa | 4013417 |
| one-word braaz | 12563 |
| one-word brab | 109 |
| one-word ldapr | 121995 |
| one-word ldraa | 1649 |
| one-word mrs-dit | 87 |
| one-word msr-dit-imm | 96 |
| one-word pacda | 2646246 |
| one-word pacdb | 420593 |
| one-word pacdza | 850 |
| one-word pacga | 687 |
| one-word pacia | 2812203 |
| one-word pacib | 2314 |
| one-word paciza | 856155 |
| one-word retab | 5501721 |
| one-word sb | 6 |
| one-word xpacd | 1407043 |
| one-word xpaci | 33676 |
| LSE sites: bl to a shared trampoline | 626471 |
| LSE sites: b to a stub that saves x30 | 173890 |
| LSE sites: no free space in reach (left for the kernel) | 0 |
| trampolines placed / unique LSE words | 16327 / 6150 |
| bytes used: trampolines + stubs | 841212 + 2782240 |
| free r-x bytes offered (zero runs of 64 bytes or more outside sections, plus dead images) | 36360036 |
| slide info v5 auth rebases rewritten to plain | 10069319 |
| FIPS HMAC resealed | /usr/lib/system/libcorecrypto.dylib |

## Mach-O files

Files 3451; arm64e slices lowered 3413.

| What | Count |
|---|---:|
| left for the kernel: LDAPUR/STLUR with offset or sign extension | 1 |
| left for the kernel: lse uses x30 | 2 |
| left, not proven code: blraa | 144 |
| left, not proven code: braa | 286 |
| left, not proven code: braaz | 6 |
| left, not proven code: lse | 3 |
| left, not proven code: retab | 55 |
| one-word autda | 1558336 |
| one-word autdb | 1952 |
| one-word autdza | 11073 |
| one-word autia | 2346 |
| one-word autib | 2116 |
| one-word autiza | 161 |
| one-word blraa | 2285384 |
| one-word blraaz | 31689 |
| one-word braa | 1706581 |
| one-word braaz | 5145 |
| one-word ldapr | 16521 |
| one-word mrs-dit | 6 |
| one-word msr-dit-imm | 12 |
| one-word pacda | 817346 |
| one-word pacdb | 199071 |
| one-word pacdza | 2 |
| one-word pacia | 793647 |
| one-word pacib | 8 |
| one-word paciza | 307658 |
| one-word retab | 1588536 |
| one-word sb | 4 |
| one-word xpacd | 552474 |
| one-word xpaci | 3362 |
| LSE sites: bl / stub | 57511 / 5011 |
| LSE sites left, no free space in the file's __TEXT (for the kernel) | 5460 in 16 files |
| trampoline + stub bytes / free __TEXT bytes | 232408 / 30273744 |
