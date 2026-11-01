# a64-census

Decoder: `llvm-mc` (`llvm-mc --version` of this host), base `-mcpu=cortex-a73`.

- cache units 2734; root Mach-O files 0; root arm64e slices 0
- cache: words 389486316 (1485 MiB), proven 386672938 (99.28 %), undecodable 283559
- root: words 0 (0 MiB), proven 0 (0.00 %), undecodable 0
- unique words 30027396; invalid on Cortex-A73 59870; of those, decoded with all features 7088
- shared region start 0x180000000, size 0xaade8000, max slide 0x55214000; files 43; images 2710; executable mapping bytes 2091597824
- slide info v5: 0 mappings; pages 0 (0 with rebases); plain rebases 0 (0 with high8); **auth rebases 0** (IA 0, DA 0; addrDiv 0, zero diversity 0)
- LSE proven sites where x30 is dead (bl to a shared trampoline is enough): cache 464, root 0; with SP as base: cache 0, root 0

## Groups

| group | cache linear | cache proven | cache proven, A13 can run | cache units | root linear | root proven | root proven, A13 can run |
|---|---:|---:|---:|---:|---:|---:|---:|
| bf16 | 11 | 0 | 0 | 6 | 0 | 0 | 0 |
| bti-hint | 24 | 24 | 24 | 3 | 0 | 0 | 0 |
| complxnum | 17 | 0 | 0 | 7 | 0 | 0 | 0 |
| cssc | 41 | 0 | 0 | 11 | 0 | 0 | 0 |
| dotprod | 24 | 0 | 0 | 9 | 0 | 0 | 0 |
| faminmax | 6 | 0 | 0 | 1 | 0 | 0 | 0 |
| flagm | 1 | 0 | 0 | 1 | 0 | 0 | 0 |
| fp16 | 3085 | 2712 | 2712 | 37 | 0 | 0 | 0 |
| fp16fml | 36 | 2 | 2 | 11 | 0 | 0 | 0 |
| fp8 | 7 | 0 | 0 | 4 | 0 | 0 | 0 |
| hbc | 473 | 2 | 0 | 16 | 0 | 0 | 0 |
| i8mm | 22 | 0 | 0 | 9 | 0 | 0 | 0 |
| lse | 1183 | 888 | 888 | 18 | 0 | 0 | 0 |
| lse128 | 2 | 0 | 0 | 1 | 0 | 0 | 0 |
| lut | 43 | 0 | 0 | 7 | 0 | 0 | 0 |
| mops | 52 | 0 | 0 | 7 | 0 | 0 | 0 |
| mte | 918 | 35 | 0 | 42 | 0 | 0 | 0 |
| other | 8294 | 10 | 10 | 33 | 0 | 0 | 0 |
| pac-hint | 78 | 78 | 78 | 1 | 0 | 0 | 0 |
| pac-nonhint | 204 | 7 | 7 | 32 | 0 | 0 | 0 |
| rcpc-imm | 163 | 4 | 4 | 12 | 0 | 0 | 0 |
| rcpc-ldapr | 3 | 0 | 0 | 2 | 0 | 0 | 0 |
| rcpc3 | 124 | 0 | 0 | 9 | 0 | 0 | 0 |
| rdm | 20 | 0 | 0 | 7 | 0 | 0 | 0 |
| sha3 | 1221 | 994 | 994 | 18 | 0 | 0 | 0 |
| sm4 | 26 | 0 | 0 | 6 | 0 | 0 | 0 |
| sme | 601 | 7 | 0 | 38 | 0 | 0 | 0 |
| sme-f64f64 | 25 | 0 | 0 | 6 | 0 | 0 | 0 |
| sme-i16i64 | 189 | 19 | 0 | 31 | 0 | 0 | 0 |
| sme2 | 777 | 6 | 0 | 38 | 0 | 0 | 0 |
| sme2p1 | 74 | 0 | 0 | 9 | 0 | 0 | 0 |
| sve | 24345 | 20 | 0 | 53 | 0 | 0 | 0 |
| sve2 | 1204 | 15 | 0 | 39 | 0 | 0 | 0 |
| sve2-bitperm | 5 | 0 | 0 | 5 | 0 | 0 | 0 |
| sve2-sm4 | 6 | 0 | 0 | 6 | 0 | 0 | 0 |
| system | 3821 | 3676 | 3672 | 21 | 0 | 0 | 0 |
| the | 29 | 0 | 0 | 9 | 0 | 0 | 0 |
| AMX word shape `(insn & 0xfffffc00) == 0x00201000` (undecodable in LLVM; 'proven' = both neighbour words decode) | 0 | 0 | 0 | | 0 | | |

## LSE in the cache by size (linear)

| byte | half | word | double | CASP |
|---:|---:|---:|---:|---:|
| 45 | 121 | 556 | 452 | 9 |

## Named images (linear counts by group)

| image | bf16 | bti-hint | complxnum | cssc | dotprod | faminmax | flagm | fp16 | fp16fml | fp8 | hbc | i8mm | lse | lse128 | lut | mops | mte | other | pac-hint | pac-nonhint | rcpc-imm | rcpc-ldapr | rcpc3 | rdm | sha3 | sm4 | sme | sme-f64f64 | sme-i16i64 | sme2 | sme2p1 | sve | sve2 | sve2-bitperm | sve2-sm4 | system | the |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| vImage | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libBLAS.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| CoreFoundation | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| CoreGraphics | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| Foundation | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| JavaScriptCore | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 280 | 0 |
| Metal | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| OpenGLES | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| QuartzCore | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| RenderBox | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| UIKitCore | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| dyld | 0 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 144 | 0 | 0 | 0 | 0 | 0 | 0 | 5 | 0 | 0 | 0 | 115 | 0 |
| libc++.1.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libc++abi.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libobjc.A.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libswiftCore.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libdispatch.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 697 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libsystem_kernel.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 4 | 0 |
| libsystem_malloc.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 20 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libsystem_platform.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 81 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libsystem_pthread.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 86 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| libxpc.dylib | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Details: classes.tsv (per mnemonic), slack.tsv (free r-x bytes and trampoline need per file), root-lse.tsv, lse-forms.tsv, images.tsv (per image), layout.tsv, slide.tsv, apple-opcodes.tsv, sysreg.tsv, undecodable.tsv, hot-*.tsv.
