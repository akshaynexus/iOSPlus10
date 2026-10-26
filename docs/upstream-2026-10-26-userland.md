# Upstream check 2026-10-26: the userland submodules

Scope: the three userland submodules we consume or fork: `external/metal2vulkan`, `external/ios-flame`,
`external/hackios-xnu-userland`. What upstream gained since our pin, whether our patches still apply, and what to do.
Research only. No submodule changed. No pin changed. Nothing ran on the phone.

Marks: **[V]** read in the source, log or command output named. **[I]** inference.

Scratch copy used: `out/src/m2v-next` (a clone of the submodule at `origin/master` f6a96b7d; git-ignored; delete it when done).

| Submodule | Our pin | Upstream head (fetched 2026-10-26) | Distance | Verdict |
|---|---|---|---|---|
| `external/metal2vulkan` (steelbrain/metal2vulkan) | 720ef1ce = v0.1.0-169 (2026-10-14) | `origin/master` f6a96b7d = v0.1.0-857 (2026-10-26 13:19 +0200) | 688 commits ahead, pin is an ancestor [V `git merge-base --is-ancestor`] | **Stay.** Bump later, after a rebase of 3 bridge patches we do not own + our 3 (section A.5) |
| `external/ios-flame` (NWylynko/ios-flame; upstream dipa-studio/ios-sweet) | 745c4341 | `origin/main` = 745c434 (same); `upstream/main` 45263be | 1 commit, `site/` only | **Nothing to merge** |
| `external/hackios-xnu-userland` (oosexgang) | a79ff077 (2026-10-22) | `origin/main` 2573c4a "Moved into the main HakiOS repository" | 2 commits on a new root; the tree is one README | **Stay on the pin; do not follow `main`.** The content moved into `oosexgang/hackios-xnu-kernel` `userland/` + `tools/`, renamed `redwood_*` -> `hakios_*`; 2 of our 4 Mesa patches are not there (section C) |

## A. metal2vulkan

### A.1 How we consume it

- Pin: the submodule gitlink 720ef1ce. `scripts/metal/env.sh:11-12` reads `M2V_COMMIT` from the gitlink (fallback 720ef1ce).
  `docs/metal-design.md:174-178` "Versions" table carries the same pin [V].
- `scripts/metal/fetch-sources.sh:14-18` exports the pinned tree to `out/metal/src/metal2vulkan`, then applies in this order [V]:
  1. ios-flame's bridge patches `external/ios-flame/phone/metal2/bridge/patches/0001-0005, 0100, 0101` (`0006` skipped,
     `fetch-sources.sh:29-33`).
  2. our `userland/metal/patches/m2v/0001-0003` (`fetch-sources.sh:35-38`).
- `scripts/metal/build-bridge.sh:19-36` writes a Cargo manifest with `metal2vulkan = { path = "$M2V/crates/metal2vulkan",
  features = ["ash"] }` and `metal2vulkan-runtime = { path = ... }`, lib = `$FLAME_SRC/phone/metal2/bridge/NativeMetalBridge.rs`,
  Rust 1.98.0 (`env.sh:14`). The bridge is built from source every time; there is no crates.io pin in ios-flame
  (no `Cargo.toml` under `external/ios-flame/phone/metal2` [V `find`]).
- `scripts/metal/host-translate.sh:21` builds the `metal2vulkan` CLI with `--features cli` from the same tree.

### A.2 What upstream gained since 720ef1ce (688 commits; the full list is `git -C external/metal2vulkan log --oneline 720ef1ce..origin/master`)

Commit cadence [V `git log --date=short | uniq -c`]: 4 on 10-16, 6 on 10-17, 56 on 10-19, **622 on 10-26, every one stamped
13:19:22 +0200**: a replayed series ("Content: the tree of `development` at 2023604104, unchanged" in 0f374bc9). `origin/master`
== `origin/development` (0 commits apart). `origin/development-untested` is 1 old commit (79d15c97, 2026-10-19). Diff size
pin -> master: 4069 files, +1 991 500 / -59 356 lines (mostly fixtures and measurements); a new crate `metal2vulkan-conformance`.

Topics that matter to us (grep of the 688 subjects; counts are commit subjects that match):

| Topic | Count | Commits worth reading | Relevance to NegroniMetal |
|---|---|---|---|
| Argument buffers | 10 | b3cd6073 (member address space from its holding field), 6f69538e (layout, offset composition, nesting vs Metal), 265230b7 (argument encoder layout vs Metal), cb72ae8d (retain an argument table's object once per encoder), 123a9919 (argument samplers at each batch's submission; resource-id takeover retired) | Correctness of UIKit/CA shaders that use argument buffers. Medium. |
| Indirect command buffers | 10 | 3306a909 (ICB compute + render run on the GPU vs Metal), f8f58013 (ICB inheritance, reset, pass state), 98bc475e (reset/copy ICB words as Metal), 651dcbd8, f6442761, 13e63981 | Low for a compositor. |
| Events / shared events | 7 | 0f374bc9 (hold a shared event's wait instead of a VkQueue), 8e4f8471 (scheduler/completion wake only the sleeping thread; wait for event values on the GPU), fdf3f414, ec890f72 | High for frame pacing: fewer cross-thread wakes on commit and completion. |
| Heaps | 27 | f7d857ec / 8574c662 (heap and heap-texture footprints = Metal's numbers), 25653b5b, 2afa7970 (heap shadow of depth/stencil), 437e37cb (HeapCompressionPolicy) | Medium (CA uses heaps on real Metal; our frontend's use is unknown [I]). |
| MSL | 1 | 6ea26165 (MSL for pixel-sampler test lanes) | None (tests). |
| Turnip / Adreno / freedreno / Qualcomm | **0** | - | No upstream knowledge of Turnip. `DriverId::MESA_TURNIP` is referenced nowhere in master's `device/driver_facts.rs` [V grep]; our 0003 still adds the first Turnip row. |
| Host imports (no-copy buffers, pointer imports, host pages) | 19 | **a97f7c27** (no posted deallocator, no shadow copy back over CPU bytes: Metal's contract kept), **3bb4722d** (idle pointer imports released where `DriverFact::PointerImportsFollowTheirAddress` holds; deallocator timing across rebinds/detaches; fewer PROCMAP_QUERY kernel calls), 7db879f2 (same on RADV), e35bf78b (shadow every padded texture over a buffer and every texture over host pages), 33b282bf (buffer over read-only host pages) | **High**: this is the IOSurface path (`docs/metal-design.md:122`). 3bb4722d changes when an import is freed and re-imported; our 0001 invalidates "each whole import its commands used" at completion, so the rebased 0001 must follow the new import lifetime [I]. |
| Cache maintenance (`invalidate`, `flush`) | 0 | - | Upstream still calls no `vkInvalidateMappedMemoryRanges` in `command_buffer/mod.rs` [V grep on master]; `memory.rs` still has `host_incoherent()`/`host_cached()` only as type classifiers (master `memory.rs:184-200`). Our 0001 stays necessary. |
| Color writes / compositor policy | 0 | - | No `ColorWritesPolicy` upstream [V grep]. Our 0003 stays necessary. |
| Driver facts / profiles | 7 (+1963 lines in `driver_facts.rs`) | 4348323b (profile fingerprint derived once), 242d0171, e841dd6b (Radeon 780M profile), 07d517d7 | Our 0003 adds a `DEVIATIONS` row and a `ProfileFields` member; both tables moved (`DEVIATIONS` now at master `driver_facts.rs:509`, `ProfileFields` at `profile.rs:507`). |
| Scheduler / waits / fences | 24 | 8e4f8471, 0f374bc9, 077709c8 (MoltenVK fence) | High for latency; interacts with our kernel 0289 GPU-fence wait only through the bridge's `wait_until_completed` [I]. |
| MoltenVK / RADV / ANV / lavapipe measurements | 14 | - | None directly; they are the measured drivers. Turnip is still unmeasured upstream. |
| IOSurface | 3 | 3817c5dd, 2dd3557a (an IOSurface plane whose GPU rows overlap is held as a shadow), 18a61c82 (Metal side: a texture over an IOSurface) | Medium: `new_texture_with_iosurface_plane` behaviour on overlapping rows changed. |

Build-side changes [V `git diff 720ef1ce origin/master -- Cargo.toml crates/*/Cargo.toml`]: workspace `rust-version = "1.98"`
unchanged (our toolchain 1.98.0 still fits); `sha2` 0.10 -> 0.11 with `default-features = false` (our bridge manifest pins its own
`sha2 = "0.10"` with `asm`; Cargo keeps both, no change needed [I]); `[profile.release] incremental = true` removed, a `debugger`
profile added; `examples/host_ab` (macOS-only dev-dependencies `objc2-metal` etc., not pulled by a consumer). The `ash` and `cli`
features still exist (`crates/metal2vulkan/Cargo.toml:65-74`). Both fixture files `build-bridge.sh:17-18` assembles still exist on
master [V `ls`].

### A.3 Do the patches still apply on origin/master? No.

Dry run in `out/src/m2v-next` at f6a96b7d, `git apply --check --whitespace=nowarn` [V]:

| Patch | Owner | `git apply --check` | `patch -p1 --dry-run -F3` (fuzz) |
|---|---|---|---|
| flame 0001-optional-constant-output-members | UniXNU | applies | applies |
| flame 0002-resource-wait-storage-dependencies | UniXNU | applies | applies |
| flame 0003-cache-device-entry-point-priming | UniXNU | **fails** (`runtime/src/device/mod.rs:971`, `device/prime.rs:52`) | 1/2 + 1/9 hunks fail |
| flame 0004-fold-constant-global-field-loads | UniXNU | **fails** (`air/src/canon/mod.rs:583`) | applies with fuzz |
| flame 0005-keep-module-decodes-and-profile-fingerprints | UniXNU | **fails** (`device/profile.rs:342`, `pipeline/compile.rs:1803`) | 1/2 hunks fail in `compile.rs` |
| flame 0006 (not applied by us) | UniXNU | fails | 1/1 fails |
| flame 0100-sweet-8mb-memory-blocks | ios-flame | **fails** (`memory.rs:48`) | applies with fuzz |
| flame 0101-sweet-padded-writers-alias | ios-flame | **fails** (`linear_plan.rs:822`) | 1/1 fails |
| m2v/0001-negroni-host-import-noncoherent | ours | **fails** (`buffer.rs:507`, `command_buffer/mod.rs:1247`, `memory.rs:983`) | only `buffer.rs` 1/1 fails; the other 2 files apply with offset/fuzz |
| m2v/0002-negroni-host-invalidate-stats | ours | **fails** (`command_buffer/mod.rs:1281`) | 1/2 fails (the file-end static + C symbol hunk) |
| m2v/0003-negroni-compositor-policy | ours | **fails** (`derive.rs:329`, `driver_facts.rs:680`, `device/mod.rs:66`, ...) | 4 hunks fail: `derive.rs` 1/1, `device/mod.rs` 1/1, `profile.rs` 1/1, `tests/fast_paths.rs` 1/3; `driver_facts.rs`, `policy.rs`, `color_writes.rs` apply with fuzz |

On the pin all 10 apply (`docs/metal-design.md:160` "done [V: all 7 patches apply]" + our 3) [V].

Anchors on master for our failed hunks (so the rebase is mechanical) [V grep]:
- 0001 `buffer.rs`: `HostPages::type_index` is now at `crates/metal2vulkan-runtime/src/buffer.rs:709`, `over_dma_buf` at :714; add `import_range` after :712.
- 0001/0002 `command_buffer/mod.rs`: `fn complete(self: &Arc<Self>, ...)` is at :4207 (was :2621); `used_resources`, `host_pages`
  (:3231), `over_dma_buf` (:3294), `memory.type_flags` (`memory.rs:1656`) all still exist with the same names.
- 0003 `derive.rs`: the field list now has `texel_conversion: policy.texel_conversion` at :344 (`framebuffer_fetch` line moved); insert `color_writes` there.
- 0003 `device/mod.rs`: the `pub use` line of policies is at :73 (was :66).
- 0003 `profile.rs`: `pub struct ProfileFields` at :507 (was :394).
- 0003 `driver_facts.rs`: `DEVIATIONS` at :509 (was :670); `DriverId::MESA_TURNIP` and `QUALCOMM_VENDOR_ID` are still absent, so our
  constant and row still carry them.
- 0003 `color_writes.rs`: `exact_writes` and `ChannelWrite` unchanged in name (:69-83).

### A.4 ios-flame bridge against master's crate API

The bridge (`external/ios-flame/phone/metal2/bridge/NativeMetalBridge.rs`, 363 lines; `NativeMetalObjects.rs`, 2047 lines) imports
58 names from `metal2vulkan_runtime` (`NativeMetalObjects.rs:19-24`, `NativeMetalBridge.rs:16-19`) and 30 from `metal2vulkan::{metal,
pipeline, bind, library}` (`NativeMetalObjects.rs:7-18`). Checks on `out/src/m2v-next` [V]:
- every imported runtime name is still exported by master's `crates/metal2vulkan-runtime/src/lib.rs` (0 missing of 58, incl.
  `IoSurfacePlane`, `PrivateProperties`, `ShaderCacheOptions`, `RuntimeGap`, `FormatCapabilities`);
- all 65 distinct methods the bridge calls (`new_*`, `set_*`, `add_*`, `wait_until_*`, `pixel_format_capabilities`, `in_directory`,
  `from_air`) exist on master, and their full signatures (from `pub fn name(` to `{`, compared text to text between the pin and
  master in `crates/metal2vulkan-runtime/src`, `metal2vulkan/src/{library,pipeline}`) are **unchanged** (0 differences);
- limits of the check: same-named methods on different types are compared as a set; struct fields the bridge fills by name
  (`DeviceOptions`, `PipelineOptions`, `TextureDescriptor`, `HostMemory`, ...) were not diffed field by field [I: likely
  compatible, a `cargo build` is the real test].

So the API the bridge uses is stable; the blockers for a bump are patch rebases, not the bridge. Our telemetry symbol
`m2v_negroni_host_invalidate_stat` (m2v/0002) is a C symbol with no bridge ABI change, so flame/0006 needs nothing.

### A.5 Recommendation: stay now; bump after a rebase

Reasons to stay today [V]:
1. 8 of 10 patches fail `git apply --check`, 3 of them (flame 0003, 0005, 0101) are not ours and fail even with fuzz; UniXNU/ios-flame
   have not rebased them (ios-flame upstream's only new commit is `site/`).
2. 622 of the 688 commits landed today as one replayed series. Wait for the tree to settle (a second replay could move the base).
3. Turnip is still unmeasured upstream: nothing in the 688 commits targets our GPU; the gains are generic (events, host imports, heaps).
4. The phone has not yet drawn a frame through the current pin + patches on A730 (`docs/metal-plan.md`); a bump adds a second
   variable before the first.

Reasons to bump later: 3bb4722d/a97f7c27 (host-import lifetime and deallocator timing), 8e4f8471/0f374bc9 (event waits and fewer wakes),
the argument-buffer fixes, and 2dd3557a (IOSurface overlapping rows).

Rebase plan (when the pin + patches draw on the phone, or when UniXNU/ios-flame publish rebased bridge patches):

```sh
# 1. scratch tree at the target (already made for this report; recreate after a fetch)
git -C external/metal2vulkan fetch origin
git clone --no-hardlinks external/metal2vulkan out/src/m2v-next && git -C out/src/m2v-next checkout origin/master
# 2. bridge patches (UniXNU/ios-flame): apply with fuzz, fix the failed hunks by hand, keep as rebased copies in
#    userland/metal/patches/flame-bridge/ (new dir; fetch-sources.sh:29-33 then reads ours instead of the flame copies)
cd out/src/m2v-next
for p in ../../../external/ios-flame/phone/metal2/bridge/patches/000[1-5]-*.patch ../../../external/ios-flame/phone/metal2/bridge/patches/010[01]-*.patch; do
  patch -p1 -F3 --no-backup-if-mismatch < "$p" || echo "FIX BY HAND: $p"; done
#    hand fixes: flame 0003 (runtime/src/device/mod.rs, device/prime.rs), 0005 (pipeline/compile.rs), 0101 (linear_plan.rs)
# 3. our 3 patches, same way; hand fixes listed in A.3 "Anchors"
for p in ../../../userland/metal/patches/m2v/000[1-3]-*.patch; do patch -p1 -F3 --no-backup-if-mismatch < "$p" || echo "FIX BY HAND: $p"; done
# 4. re-read 0001 against 3bb4722d: an idle pointer import may be released and re-imported between commit and completion;
#    invalidate_host_imports must take the import that is live at completion (used_resources holds it) [I]
# 5. regenerate the 3 patches: git add -A && git diff --cached > ../../../userland/metal/patches/m2v/000N-....patch (one per patch,
#    commit between them), keep the header text
# 6. compile both targets in tmux
scripts/bg.sh m2v-next-bridge env M2V=$PWD/out/src/m2v-next scripts/metal/build-bridge.sh ios
scripts/bg.sh m2v-next-cli    env M2V=$PWD/out/src/m2v-next scripts/metal/host-translate.sh
#    (build-bridge.sh and host-translate.sh read M2V from env.sh; export M2V before them or add an override there)
# 7. bump: git -C external/metal2vulkan checkout f6a96b7d; update docs/metal-design.md:174-178 and scripts/metal/env.sh:12 fallback;
#    then scripts/metal/fetch-sources.sh + build, and the on-phone test plan docs/metal-management.md section 4
```

Effort estimate [I]: our 3 patches ~1 h (7 failed hunks, all context moves); the 3 foreign patches 1-3 h (flame 0003 and 0005 touch
`device/prime.rs` and `pipeline/compile.rs`, which upstream rewrote); plus one full bridge compile (~10-20 min) and the phone test.

## B. ios-flame

- Submodule pin 745c4341 = `origin/main` (NWylynko/ios-flame) [V `git log HEAD..origin/main` empty].
- `upstream/main` (dipa-studio/ios-sweet) = 45263be "update website", 2026-10-23, 9 files all under `site/` (+469/-223) [V `git show --stat`].
  Nothing under `phone/`, `bridge/`, or the patches. **Nothing to merge.** `scripts/setup/get-references.sh:15-16` already pins
  `ios-sweet` and `ios-sweet-upstream` at 45263bee [V].

## C. hackios-xnu-userland

### C.1 What happened upstream

- `origin/main` of `oosexgang/hackios-xnu-userland` is now 2573c4a (2026-10-25 14:41 -0700) on a **new root** (1422925 "init" ->
  2573c4a "Moved into the main HakiOS repository"); the tree is one file [V `git ls-tree -r origin/main`]. `README.md` says:
  "The HakiOS user space now lives in the main repository together with the kernel: https://github.com/oosexgang/hakios-os
  (until it is renamed: https://github.com/oosexgang/hackios-xnu-kernel). Everything that was here is in `userland/` there."
- `gh api repos/oosexgang/hakios-os` -> 404; `git ls-remote https://github.com/oosexgang/hakios-os.git` -> "Repository not found"
  [V 2026-10-26]. The rename has not happened yet. `gh api repos/oosexgang/hackios-xnu-userland` shows no redirect (`full_name`
  unchanged, `archived: false`, `pushed_at` 2026-10-25T16:44:44Z).
- The live home is **`oosexgang/hackios-xnu-kernel`** (`main`, HEAD 88513176 2026-10-26T10:14Z) [V `gh api`]. It has `userland/`
  (same file set as our pin, `com.hakios.*.plist` instead of `com.redwood.*.plist`, plus `hakios.{audio,camera,gl,input}.h`),
  `tools/mesa/` and `prebuilt/`.
- The old objects are still served: `git fetch --depth 1 <pointer repo> a79ff0772a3454fd1ef127e181e5b3bce6c9ce18` succeeds [V]. The
  pointer repo keeps `refs/pull/3..8/head` but no branch reaches a79ff077, so GitHub may drop the objects at a later gc [I].
  A fresh `git submodule update --init` works today and may stop working later.
- The kernel repo's history was rewritten: `gh api .../compare/d82c64a3...main` -> "No common ancestor" [V]. Our reference pin
  `scripts/setup/get-references.sh:22` (d82c64a3, 2026-10-23) is on the old history. Out of this report's scope, but the same
  "fetch by sha" risk applies.

### C.2 What the moved copy contains that we use

| We use | From the pin (a79ff077 / b4c5513e) | In `hackios-xnu-kernel` `main` | Status |
|---|---|---|---|
| `tools/mesa/freedreno-darwin.patch` | `scripts/gpu/env.sh:12-13` `HACKIOS_COMMIT=b4c5513e`, `HACKIOS_PATCHES`; `scripts/gpu/mesa-fetch.sh:43-47` reads them from the submodule objects | present, 11994 B vs ours 11999 B; the only diff is the rename `redwood_drm_*` -> `hakios_drm_*`, `src/redwood-drm` -> `src/hakios-drm`, `redwood_drm.c` -> `hakios.drm.c` [V diff] | equivalent; ours pairs with `tools/mesa/redwood-drm`, theirs with `tools/mesa/hakios-drm` |
| `tools/mesa/ir3-round-default.patch` | same | present, identical blob 58faacd5 [V] | same |
| `tools/mesa/ir3-shift-split.patch` | same | **absent** [V listing; `commits?path=` empty; code search `ir3_nir_lower_io_offsets` 0 hits] | only in our pin |
| `tools/mesa/ir3-ssbo-subdword.patch` | same | **absent** [V] | only in our pin |
| `userland/src/audio_plugin.c` | model of `userland/audio/NegroniAudio.c:5-6` (commit a79ff07, MIT) | present, renamed identifiers, 41502 B vs 41555 B; last content commits 2026-10-16 (mic), 2026-10-25 (rename) [V] | no new behaviour since our pin [I: the only later commit is the rename] |
| `userland/src/redwood_audio.h` | model of `userland/audio/negroni_audio.h:6` | `userland/src/hakios.audio.h` 4961 B vs 5005 B | renamed |
| `userland/src/eagl.c` | `docs/audit/2026-10-26-metal-gl.md:110` (`RedwoodWaitsForGPU` contract, `eagl.c:4036-4045`) | present, 168776 B vs 168874 B | renamed |
| `userland/`, `tools/air`, `tools/mk-mesa.sh` | docs only (`docs/external-repos.md:25`, `docs/metal-design.md:36`, `docs/gpu-userland.md:13`) | present | - |

`redwood_sound.c` is a kernel file (`hackios-xnu-kernel` `bsd/dev/`), referenced by `patches/xnu/0243:155,911` and `0240:58`; it is
not in the userland submodule and is not part of this check. The two ir3 patches came into the userland repo with its open-source
release c5c92f6 (2026-10-22, OOSEX GANG) [V `git log -- tools/mesa/ir3-*.patch`]; the kernel repo never had them. Whether they were
dropped on purpose (folded into Mesa upstream, or wrong) is unknown [I]. We keep applying them from our pinned objects.

### C.3 Recommendation

Keep the gitlink a79ff077 and `HACKIOS_COMMIT=b4c5513e`. Do **not** point the submodule at `hackios-xnu-kernel`: that repo is
5-6x larger, carries the APSL kernel beside the MIT userland, lacks 2 of our 4 Mesa patches, renamed every identifier our
docs cite, and is on a rewritten history. Protect the pinned objects instead:

1. Fork the pointer repo under akshaynexus with the old history (the owner's pattern for slop, Mu-Silicium-negroni, UniXNU):
   ```sh
   gh repo create akshaynexus/hackios-xnu-userland --private --disable-wiki -d "mirror of oosexgang/hackios-xnu-userland at a79ff077 (pre-move history)"
   git -C external/hackios-xnu-userland push https://github.com/akshaynexus/hackios-xnu-userland.git a79ff0772a3454fd1ef127e181e5b3bce6c9ce18:refs/heads/main
   ```
   (`gh api repos/akshaynexus/hackios-xnu-userland` is 404 today [V]; a private mirror of MIT code is allowed with the notice,
   `THIRD_PARTY_NOTICES.md:136`.)
2. Then change `.gitmodules` (lines 17-20; do not change it in this session):
   ```
   [submodule "external/hackios-xnu-userland"]
   	path = external/hackios-xnu-userland
   	url = https://github.com/akshaynexus/hackios-xnu-userland.git
   	branch = main
   ```
   followed by `git submodule sync external/hackios-xnu-userland` and `git -C external/hackios-xnu-userland remote set-url origin
   https://github.com/akshaynexus/hackios-xnu-userland.git`. The gitlink stays a79ff077.
3. Add one line to `docs/external-repos.md:25` and `README.md:68`: upstream moved to `oosexgang/hackios-xnu-kernel` `userland/`
   on 2026-10-25 (rename `redwood` -> `hakios`); our pin is the last pre-move commit.
4. If the owner prefers no fork: keep the URL, and note in `docs/notes.md` that `git submodule update --init` depends on GitHub
   serving an unreferenced sha (works 2026-10-26 [V]).

## Commands used (for the main session to repeat)

```sh
git -C external/metal2vulkan log --oneline 720ef1ce..origin/master | wc -l                     # 688
git -C external/metal2vulkan diff --stat 720ef1ce origin/master -- crates/metal2vulkan-runtime/src/{buffer.rs,memory.rs,command_buffer/mod.rs} crates/metal2vulkan/src/device/{derive,driver_facts,mod,policy,profile}.rs crates/metal2vulkan/src/pipeline/color_writes.rs
git clone --no-hardlinks external/metal2vulkan out/src/m2v-next && git -C out/src/m2v-next checkout f6a96b7d
cd out/src/m2v-next && for p in ../../../external/ios-flame/phone/metal2/bridge/patches/*.patch ../../../userland/metal/patches/m2v/*.patch; do echo "$p"; git apply --check --whitespace=nowarn "$p"; done
git -C external/ios-flame fetch --all && git -C external/ios-flame show --stat 45263be
git -C external/hackios-xnu-userland fetch origin && git -C external/hackios-xnu-userland show origin/main:README.md
gh api repos/oosexgang/hackios-xnu-kernel/contents/tools/mesa --jq '.[] | "\(.sha) \(.size) \(.name)"'
rm -rf out/src/m2v-next                                                                          # when done
```
