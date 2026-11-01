# a64-census

Decoder: `llvm-mc` (`llvm-mc --version` of this host), base `-mcpu=cortex-a73`.

- cache units 3827; root Mach-O files 0; root arm64e slices 0
- cache: words 556294250 (2122 MiB), proven 554899080 (99.75 %), undecodable 470908
- root: words 0 (0 MiB), proven 0 (0.00 %), undecodable 0
- unique words 38043180; invalid on Cortex-A73 45623; of those, decoded with all features 6217
- shared region start 0x180000000, size 0xf383c000, max slide 0x20000000; files 61; images 3793; executable mapping bytes 2881077248
- slide info v5: 0 mappings; pages 0 (0 with rebases); plain rebases 0 (0 with high8); **auth rebases 0** (IA 0, DA 0; addrDiv 0, zero diversity 0)
- LSE proven sites where x30 is dead (bl to a shared trampoline is enough): cache 732, root 0; with SP as base: cache 0, root 0

## Groups

| group | cache linear | cache proven | cache proven, A13 can run | cache units | root linear | root proven | root proven, A13 can run |
|---|---:|---:|---:|---:|---:|---:|---:|
| bf16 | 28 | 0 | 0 | 7 | 0 | 0 | 0 |
| bti-hint | 35 | 35 | 35 | 7 | 0 | 0 | 0 |
| complxnum | 8 | 0 | 0 | 8 | 0 | 0 | 0 |
| cssc | 30 | 0 | 0 | 8 | 0 | 0 | 0 |
| dotprod | 21 | 0 | 0 | 7 | 0 | 0 | 0 |
| faminmax | 7 | 0 | 0 | 7 | 0 | 0 | 0 |
| fp16 | 7612 | 6980 | 6980 | 15 | 0 | 0 | 0 |
| fp16fml | 44 | 0 | 0 | 8 | 0 | 0 | 0 |
| hbc | 838 | 0 | 0 | 8 | 0 | 0 | 0 |
| i8mm | 80 | 0 | 0 | 9 | 0 | 0 | 0 |
| lse | 1725 | 1182 | 1182 | 18 | 0 | 0 | 0 |
| lse128 | 30 | 0 | 0 | 8 | 0 | 0 | 0 |
| lut | 106 | 0 | 0 | 8 | 0 | 0 | 0 |
| mops | 52 | 0 | 0 | 8 | 0 | 0 | 0 |
| mte | 1009 | 1 | 0 | 15 | 0 | 0 | 0 |
| other | 16107 | 1 | 1 | 9 | 0 | 0 | 0 |
| pac-hint | 67 | 67 | 67 | 4 | 0 | 0 | 0 |
| pac-nonhint | 161 | 40 | 40 | 11 | 0 | 0 | 0 |
| rcpc-imm | 540 | 1 | 1 | 11 | 0 | 0 | 0 |
| rcpc-ldapr | 5 | 4 | 4 | 2 | 0 | 0 | 0 |
| rcpc3 | 72 | 0 | 0 | 9 | 0 | 0 | 0 |
| rdm | 63 | 0 | 0 | 7 | 0 | 0 | 0 |
| sha3 | 1286 | 1057 | 1057 | 17 | 0 | 0 | 0 |
| sm4 | 56 | 0 | 0 | 7 | 0 | 0 | 0 |
| sme | 881 | 6 | 0 | 14 | 0 | 0 | 0 |
| sme-f64f64 | 28 | 0 | 0 | 7 | 0 | 0 | 0 |
| sme-i16i64 | 129 | 0 | 0 | 8 | 0 | 0 | 0 |
| sme2 | 780 | 18 | 0 | 12 | 0 | 0 | 0 |
| sme2p1 | 107 | 0 | 0 | 8 | 0 | 0 | 0 |
| sve | 47848 | 83 | 0 | 23 | 0 | 0 | 0 |
| sve2 | 2072 | 8 | 0 | 13 | 0 | 0 | 0 |
| sve2-aes | 7 | 0 | 0 | 7 | 0 | 0 | 0 |
| sve2-bitperm | 14 | 0 | 0 | 7 | 0 | 0 | 0 |
| sve2-sm4 | 7 | 0 | 0 | 7 | 0 | 0 | 0 |
| system | 547 | 261 | 231 | 21 | 0 | 0 | 0 |
| the | 161 | 0 | 0 | 7 | 0 | 0 | 0 |
| AMX word shape `(insn & 0xfffffc00) == 0x00201000` (undecodable in LLVM; 'proven' = both neighbour words decode) | 0 | 0 | 0 | | 0 | | |

## LSE in the cache by size (linear)

| byte | half | word | double | CASP |
|---:|---:|---:|---:|---:|
| 273 | 199 | 564 | 680 | 9 |

## Named images (linear counts by group)

| image | bf16 | bti-hint | complxnum | cssc | dotprod | faminmax | fp16 | fp16fml | hbc | i8mm | lse | lse128 | lut | mops | mte | other | pac-hint | pac-nonhint | rcpc-imm | rcpc-ldapr | rcpc3 | rdm | sha3 | sm4 | sme | sme-f64f64 | sme-i16i64 | sme2 | sme2p1 | sve | sve2 | sve2-aes | sve2-bitperm | sve2-sm4 | system | the |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| vImage | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libBLAS.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| CoreFoundation | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| CoreGraphics | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Foundation | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| JavaScriptCore | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 28 | 28 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Metal | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| OpenGLES | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| QuartzCore | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| RenderBox | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| UIKitCore | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| dyld | 0 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 144 | 0 | 0 | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 0 | 8 | 0 |
| libc++.1.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libc++abi.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libobjc.A.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libswiftCore.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libdispatch.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 665 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libsystem_kernel.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 0 |
| libsystem_malloc.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 26 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libsystem_platform.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 83 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 18 | 0 | 75 | 5 | 0 | 0 | 0 | 20 | 0 |
| libsystem_pthread.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 84 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 | 0 |
| libxpc.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Details: classes.tsv (per mnemonic), slack.tsv (free r-x bytes and trampoline need per file), root-lse.tsv, lse-forms.tsv, images.tsv (per image), layout.tsv, slide.tsv, apple-opcodes.tsv, sysreg.tsv, undecodable.tsv, hot-*.tsv.
