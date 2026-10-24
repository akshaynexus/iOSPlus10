# negroni-xnu

CI-only repository: builds the iOS 16 era XNU kernel (xnu-8796.141.3, `MACHINE_CONFIG=NEGRONI`) for
the OnePlus 10 Pro, on GitHub's `macos-14` runner (Xcode 15; newer Xcode breaks the xnu-8796 IORPC
code).

- Build recipe: [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) at a pinned commit.
- Port patches: fetched at build time from [MellysInformejtik/slop](https://github.com/MellysInformejtik/slop)
  (`negroni-ios/xnu/patches`) at the commit in `SLOP_SHA`. They are not copied into this repository.
- `patches/`: additional patches (0200-...), maintained in a separate private project and synced here.

Output: the `negroni-xnu-kernel` artifact (`kernel.development.negroni`, `SHA256SUMS`,
`patch-report.txt` listing every applied / skipped patch).
