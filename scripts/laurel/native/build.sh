#!/bin/bash
# The native Metal stack (docs/laurel_sprout/ios26-native-metal.md), for this host, for tests. No GPU.
#   scripts/bg.sh nmn-build scripts/laurel/native/build.sh host
# Inputs: scripts/laurel/native/mesa-host.sh (Mesa's static libraries and generated headers), out/ios26/metal/src (scripts/laurel/ios26-metal-build.sh fetch), the A610 profile (scripts/ios26/metal-corpus.sh or a610-profile.py).
# Output: out/ios26/native/host/{libnmn_c.a, libnative_metal_native.a}
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/metal-env.sh"
export METAL_OUT=$OUT/ios26/metal
. "$REPO/scripts/metal/env.sh"
what=${1:-host}
N=$REPO/userland/laurel/metal-native
W=$OUT/ios26/native/$what
mkdir -p "$W"
PROFILE=$OUT/metal/profiles/a610-turnip-est.json
[ -f "$PROFILE" ] || { mkdir -p "$(dirname "$PROFILE")"; python3 -I "$REPO/scripts/laurel/a610-profile.py" "$M2V/crates/metal2vulkan-validation/profiles/vk12-floor.json" "$PROFILE"; }
case $what in
host)
  S=$OUT/ios26/turnip-host/mesa
  B=$OUT/ios26/native/mesa-host
  CC_FLAGS="-O2 -g -fPIC -fno-strict-aliasing -Wall -Wno-unused-parameter"
  triple=$(rustc "+$RUST_TOOLCHAIN" -vV | sed -n 's/^host: //p')
  ;;
*) echo "build.sh: host" >&2; exit 2 ;;
esac
# Mesa's own defines and include paths for an ir3 file, from its compile database: the headers depend on them
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
INC="@$W/flags.rsp -I$S/src/freedreno -I$S/include -I$B/src/compiler -I$S/src/compiler"
DEFS=""
CACHE_ID=$("$REPO/scripts/laurel/native/cache-id.sh" "$REPO" "$M2V" "$S")
clang -std=gnu11 $CC_FLAGS $DEFS -DNMN_CACHE_ID="\"$CACHE_ID\"" $INC -c "$N/shader/nmn_shader.c" -o "$W/nmn_shader.o"
clang -std=gnu11 $CC_FLAGS $DEFS $INC -I"$N/winsys" -c "$N/winsys/nw.c" -o "$W/nw.o"
clang -std=gnu11 $CC_FLAGS $DEFS $INC -I"$N/winsys" -I"$B/src/freedreno/registers/adreno" -I"$B/src/freedreno/registers" -c "$N/winsys/nw_check.c" -o "$W/nw_check.o"
clang++ -std=c++17 -fno-exceptions -fno-rtti $CC_FLAGS -Wno-c99-designator -Wno-c++11-narrowing -Wno-missing-field-initializers -Wno-unused-function $DEFS $INC -I"$N/winsys" -I"$N/pm4" -I"$S/src/freedreno/fdl" -I"$B/src/freedreno/registers/adreno" -I"$B/src/freedreno/registers" -c "$N/pm4/nmn_pm4.cc" -o "$W/nmn_pm4.o"
rm -f "$W/libnmn_c.a"; ar rcs "$W/libnmn_c.a" "$W/nmn_shader.o" "$W/nw.o" "$W/nw_check.o" "$W/nmn_pm4.o"
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
export NMN_PROFILE=$W/profile.json
cargo "+$RUST_TOOLCHAIN" build --release --manifest-path "$W/Cargo.toml" --target "$triple" --target-dir "$W/target" -j "$NPROC"
cp "$W/target/$triple/release/libnative_metal_native.a" "$W/"
ls -la "$W"/*.a
