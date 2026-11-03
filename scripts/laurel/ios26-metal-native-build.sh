#!/bin/bash
# The native Metal stack for the Mi A3 on iOS 26.5.2 23F84: the third option of NegroniMetal.bundle. No Vulkan, no Turnip, no metal2vulkan runtime in this image. Docs: docs/laurel_sprout/ios26-native-metal.md.
#   scripts/bg.sh ios26-metal-native scripts/laurel/ios26-metal-native-build.sh
# Inputs: scripts/laurel/ios26-metal-build.sh fetch + turnip (the patched Mesa built for iOS: its static libraries and headers), the frontend tree out/ios26/metal/src.
# Output: out/ios26/metal-native/NegroniMetal (class NegroniMTLDeviceImpl), for options/native in scripts/laurel/ios26-metal-options.sh. Checks: abi-check, 0 instructions newer than ARMv8.0, imports against the 23F84 cache.
# It builds nothing of the default or hot stacks.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
export METAL_OUT=$REPO/out/ios26/metal GPU_OUT=$REPO/out/ios26/gpu METAL_EXPORTS_CACHE=$REPO/out/ios26/metal-spi/exports
. "$HERE/metal-env.sh"
laurel_metal_tools
. "$REPO/scripts/metal/env.sh"
N=$REPO/userland/laurel/metal-native
W=$REPO/out/ios26/metal-native
B=$GPU_OUT/turnip/build-ios
S=$GPU_OUT/turnip/mesa-25.0.7
FRONT=$MOUT/src/flame/phone/metal2
mkdir -p "$W"
PROFILE=$REPO/out/metal/profiles/a610-turnip-est.json
[ -f "$PROFILE" ] || { mkdir -p "$(dirname "$PROFILE")"; python3 -I "$REPO/scripts/laurel/a610-profile.py" "$M2V/crates/metal2vulkan-validation/profiles/vk12-floor.json" "$PROFILE"; }
[ -f "$B/compile_commands.json" ] || { echo "no $B: scripts/laurel/ios26-metal-build.sh turnip" >&2; exit 1; }
python3 -I - "$B/compile_commands.json" > "$W/flags.rsp" <<'PY'
import json,shlex,sys,os
c=json.load(open(sys.argv[1]))
e=[x for x in c if x['file'].endswith('ir3_nir.c')][0]
a=shlex.split(e['command'])
out=[x for x in a if x.startswith('-D')]
for x in a:
    if x.startswith('-I'):
        p=x[2:]
        out.append('-I'+(p if os.path.isabs(p) else os.path.normpath(os.path.join(e['directory'],p))))
for x in out:
    print('"'+x.replace('\\','\\\\').replace('"','\\"')+'"')
PY
TARGET="-target arm64-apple-ios16.0 -isysroot $SDK $LAUREL_CPU_FLAGS -fno-strict-aliasing -O2 -g"
INC="@$W/flags.rsp -I$S/src/freedreno -I$S/include -I$B/src/compiler -I$S/src/compiler -I$S/src/freedreno/fdl -I$N/winsys -I$N/pm4 -I$B/src/freedreno/registers/adreno -I$B/src/freedreno/registers"
pids=()
CACHE_ID=$("$REPO/scripts/laurel/native/cache-id.sh" "$REPO" "$M2V" "$S")
clang -std=gnu11 $TARGET -DNMN_CACHE_ID="\"$CACHE_ID\"" $INC -c "$N/shader/nmn_shader.c" -o "$W/nmn_shader.o" & pids+=($!)
clang -std=gnu11 $TARGET $INC -c "$N/winsys/nw.c" -o "$W/nw.o" & pids+=($!)
clang -std=gnu11 $TARGET $INC -c "$N/winsys/nw_check.c" -o "$W/nw_check.o" & pids+=($!)
clang -std=gnu11 $TARGET $INC -c "$N/winsys/winsys_iokit.c" -o "$W/winsys_iokit.o" & pids+=($!)
clang++ -std=c++17 -fno-exceptions -fno-rtti $TARGET -Wno-c99-designator -Wno-c++11-narrowing -Wno-missing-field-initializers -Wno-deprecated-declarations $INC -c "$N/pm4/nmn_pm4.cc" -o "$W/nmn_pm4.o" & pids+=($!)
for p in "${pids[@]}"; do wait "$p"; done
cat > "$W/Cargo.toml" <<TOML
[package]
name = "native-metal-native"
version = "0.1.0"
edition = "2024"
rust-version = "1.98"
[workspace]
[lib]
crate-type = ["staticlib"]
name = "native_metal_native"
path = "$N/bridge/src/lib.rs"
[dependencies]
metal2vulkan = { path = "$M2V/crates/metal2vulkan" }
libc = "0.2"
[profile.release]
panic = "unwind"
debug = 1
TOML
python3 -I "$REPO/scripts/laurel/native/profile.py" "$PROFILE" "$W/profile.json"
export NMN_PROFILE=$W/profile.json SDKROOT=$SDK IPHONEOS_DEPLOYMENT_TARGET=16.0
cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$W/Cargo.toml" --target aarch64-apple-ios --target-dir "$W/target" -j "$NPROC"
RLIB=$W/target/aarch64-apple-ios/release/libnative_metal_native.a
LIBS="$B/src/compiler/spirv/libvtn.a $B/src/compiler/nir/libnir.a $B/src/compiler/libcompiler.a $B/src/freedreno/ir3/libfreedreno_ir3.a $B/src/freedreno/isa/libir3decode.a $B/src/freedreno/isa/libir3encode.a $B/src/compiler/isaspec/libisaspec.a $B/src/freedreno/common/libfreedreno_common.a $B/src/freedreno/fdl/libfreedreno_layout.a $B/src/util/libmesa_util.a $B/src/util/blake3/libblake3.a $B/src/c11/impl/libmesa_util_c11.a"
OBJ=$W/NegroniMetal
clang++ -std=c++17 -fobjc-arc $TARGET -Wno-deprecated-declarations -DNMTL_IOS26=1 -DNMTL_NATIVE=1 -DNMTL_CLASS=NegroniMTLDeviceImpl -I"$FRONT" -I"$REPO/userland/metal/plugin" -I"$REPO/userland/laurel/metal/option" -c "$REPO/userland/metal/plugin/NegroniMetal.mm" -o "$W/plugin.o" &
clang++ -std=c++17 -fobjc-arc $TARGET -Wno-deprecated-declarations -DNMTL_IOS26=1 -I"$FRONT" -I"$REPO/userland/metal/plugin" -c "$FRONT/NativeBridgeMetalFrontend.mm" -o "$W/frontend.o" &
wait
clang++ -target arm64-apple-ios16.0 -isysroot "$SDK" -fuse-ld=lld -bundle -Wl,-dead_strip -Wl,-exported_symbol,_OBJC_CLASS_\$_NegroniMTLDeviceImpl -Wl,-exported_symbol,_OBJC_METACLASS_\$_NegroniMTLDeviceImpl \
  "$W/plugin.o" "$W/frontend.o" "$W/nmn_shader.o" "$W/nw.o" "$W/nw_check.o" "$W/winsys_iokit.o" "$W/nmn_pm4.o" "$RLIB" $LIBS -lz -lc++ -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation -framework Security -o "$OBJ.unstripped"
cp "$OBJ.unstripped" "$OBJ"
llvm-strip -x "$OBJ"
ldid -S "$OBJ"
ls -la "$OBJ"
# the first phone test: the fixed scene as a tool, no Metal.framework, no compositor. It draws into its own memory and prints pixels. Docs: section 8.
clang -target arm64-apple-ios16.0 -isysroot "$SDK" $LAUREL_CPU_FLAGS -O2 -c -I"$FRONT/bridge" "$N/tests/scene.c" -o "$W/scene.o"
clang -target arm64-apple-ios16.0 -isysroot "$SDK" $LAUREL_CPU_FLAGS -O2 -c "$N/tests/scene_surface_ios.c" -o "$W/scene_surface.o"
clang++ -target arm64-apple-ios16.0 -isysroot "$SDK" -fuse-ld=lld -Wl,-dead_strip "$W/scene.o" "$W/scene_surface.o" "$W/nmn_shader.o" "$W/nw.o" "$W/nw_check.o" "$W/winsys_iokit.o" "$W/nmn_pm4.o" "$RLIB" $LIBS -lz -lc++ -framework Foundation -framework IOKit -framework IOSurface -framework CoreFoundation -framework Security -o "$W/nmn-scene"
llvm-strip -x "$W/nmn-scene"
ldid -S "$W/nmn-scene"
# the selector of the bundle, with the option's lines: it must build against the same SDK
clang -target arm64-apple-ios16.0 -isysroot "$SDK" $LAUREL_CPU_FLAGS -fuse-ld=lld -O2 -fobjc-arc -bundle -Wall -Wextra -I"$REPO/userland/laurel/metal/option" -framework Foundation -framework Metal -o "$W/selector-test" "$REPO/userland/laurel/metal/option/option_select.m"
ldid -S "$W/selector-test"
C=$W/check; rm -rf "$C"; mkdir -p "$C"; cp "$OBJ" "$W/nmn-scene" "$W/selector-test" "$C/"
python3 -I "$REPO/scripts/ios26/abi-check.py" "$C" 2>&1 | tail -5
for f in "$OBJ" "$W/nmn-scene" "$W/selector-test"; do python3 -I "$REPO/scripts/laurel/armv80-check.py" "$f" 2>&1 | tail -1; done
IOS_DSC=${IOS_DSC:-$HOME/op10-apple/ios26/23F84-n104ap/tree/cache/dyld_shared_cache_arm64e}
python3 "$REPO/scripts/metal/check-imports.py" "$IOS_DSC" "$OBJ" "$W/nmn-scene" "$W/selector-test" 2>&1 | tail -2
ls -la "$OBJ" "$W/nmn-scene"
