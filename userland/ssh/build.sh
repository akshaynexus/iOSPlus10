#!/bin/sh
# Build the SSH userland for iOS 16 arm64 (docs/usb-network.md); scripts/net/root-add-ssh.sh then
# installs the result on macOS or Linux.
#   userland/ssh/fetch.sh && userland/ssh/build.sh
#   (in tmux: scripts/bg.sh ssh-build sh -c 'userland/ssh/fetch.sh && userland/ssh/build.sh')
# macOS: Xcode with the iPhoneOS SDK, GNU sed (brew install gnu-sed; toybox's scripts need it).
# Linux (x86_64): stock clang (any recent version) as the compiler, the theos toolchain for the Mach-O
#   tools (ld64, lipo, otool, nm, ldid; scripts/laurel/kernel-linux.sh installs it in out/laurel-kernel/theos,
#   or THEOS=DIR) and the iPhoneOS 16.5 SDK from theos/sdks (userland/ssh/fetch-sdk.sh -> out/ssh/sdk,
#   or IOS_SDK=DIR), as hackios-scion userland/build.sh does. Signing: ldid -S (XML + DER entitlements).
#   out/ssh/host then holds Linux builds (dropbearkey for the host key at install time).
# Output:
#   out/ssh/ios/   dropbearmulti (dropbear, dropbearkey, dbclient, scp), dash, toybox,
#                  usbnetcfg, laurelnet, usbreboot, oslogstream: arm64, minos 16.0, signed ad hoc with
#                  entitlements.plist (oslogstream: oslogstream.entitlements);
#                  toybox.applets (applet list); SHA256SUMS
#   out/ssh/host/  macOS builds of dropbearmulti and toybox (host keys at install time, tests)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=$REPO/out/ssh
DB=$W/src/dropbear/dropbear-2026.94
DASH=$W/src/dash/dash-0.5.13.5
TB=$W/src/toybox/toybox-0.8.15
MINOS=16.0
for d in "$DB" "$DASH" "$TB"; do [ -d "$d" ] || { echo "missing $d: run userland/ssh/fetch.sh" >&2; exit 1; }; done

case "$(uname -s)" in
Darwin)
  NPROC=$(sysctl -n hw.ncpu)
  GSED=$(command -v gsed || true)
  [ -n "$GSED" ] || { echo "GNU sed missing: brew install gnu-sed" >&2; exit 1; }
  SDK=$(xcrun -sdk iphoneos --show-sdk-path)
  ICC=$(xcrun -sdk iphoneos --find clang)
  IFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=$MINOS"
  LIPO=lipo; OTOOL=otool; NM=nm; HOSTCC=clang; ISTRIP=strip; IAR=ar; IRANLIB=ranlib
  sign() { codesign --force -s - --entitlements "$2" "$1" 2>/dev/null; }
  sha() { shasum -a 256 "$@"; }
  ;;
Linux)
  NPROC=$(nproc)
  GSED=$(command -v sed)
  THEOS=${THEOS:-$REPO/out/laurel-kernel/theos}
  TC=$THEOS/toolchain/linux/iphone/bin
  SDK=${IOS_SDK:-$W/sdk/iPhoneOS16.5.sdk}
  for t in ld lipo otool nm ldid strip llvm-ar llvm-ranlib; do
    [ -x "$TC/$t" ] || { echo "missing $TC/$t: run scripts/laurel/kernel-linux.sh once (installs theos) or set THEOS" >&2; exit 1; }
  done
  [ -d "$SDK/usr/include" ] || { echo "missing $SDK: run userland/ssh/fetch-sdk.sh or set IOS_SDK" >&2; exit 1; }
  command -v clang >/dev/null || { echo "missing clang" >&2; exit 1; }
  ICC=$(command -v clang)
  # stock clang: Mach-O for iOS by -target; ld64 from theos (--ld-path); quiet about the unused link flags
  IFLAGS="-target arm64-apple-ios$MINOS -arch arm64 -isysroot $SDK -mios-version-min=$MINOS --ld-path=$TC/ld -Wno-unused-command-line-argument"
  # archives for ld64: GNU ar writes a format ld64 ignores, and the cctools ar of theos calls a missing
  # aarch64-apple-darwin14-ranlib; theos' llvm-ar/llvm-ranlib write Darwin archives for Mach-O members
  LIPO=$TC/lipo; OTOOL=$TC/otool; NM=$TC/nm; HOSTCC=${HOSTCC:-cc}; ISTRIP=$TC/strip; IAR=$TC/llvm-ar; IRANLIB=$TC/llvm-ranlib
  sign() { "$TC/ldid" -S"$2" "$1"; }
  sha() { sha256sum "$@"; }
  ;;
*) echo "build.sh: macOS or Linux" >&2; exit 1 ;;
esac
B=$W/build
rm -rf "$B" "$W/ios" "$W/host"
mkdir -p "$B" "$W/ios" "$W/host"

# A one-word compiler for build systems that split $CC badly (toybox).
cat > "$B/ios-cc" <<EOS
#!/bin/sh
exec "$ICC" $IFLAGS -I"$HERE/compat" "\$@"
EOS
chmod +x "$B/ios-cc"
mkdir -p "$B/gnubin" && ln -sf "$GSED" "$B/gnubin/sed"

# ---- dropbear: one multi-call binary --------------------------------------------------------
# --disable-* : no utmp/wtmp/lastlog bookkeeping (iOS has none), no zlib, no PAM.
build_dropbear() { # TARGET(ios|host)
  d=$B/dropbear-$1; mkdir -p "$d"; cp "$HERE/localoptions.h" "$d/"
  if [ "$1" = ios ]; then hostarg=--host=aarch64-apple-darwin; cc=$B/ios-cc; ar=$IAR; rl=$IRANLIB; else hostarg=; cc=$HOSTCC; ar=ar; rl=ranlib; fi
  (cd "$d" && CC="$cc" AR="$ar" RANLIB="$rl" "$DB/configure" $hostarg --disable-zlib --disable-lastlog --disable-utmp --disable-utmpx \
      --disable-wtmp --disable-wtmpx --disable-pututline --disable-pututxline --disable-pam \
      --enable-bundled-libtom CFLAGS=-O2 > configure.log 2>&1 &&
   make AR="$ar" RANLIB="$rl" PROGRAMS="dropbear dropbearkey dbclient scp" MULTI=1 -j"$NPROC" > make.log 2>&1) ||
   { echo "dropbear $1 failed, see $d/configure.log / make.log" >&2; tail -20 "$d/make.log" >&2 || true; exit 1; }
}

# ---- dash: /bin/sh ----------------------------------------------------------------------------
# The iOS 27 SDK declares strchrnul() (iOS 18.4+). ac_cv_func_strchrnul=no makes dash use its
# own copy, so there is no weak import of a symbol iOS 16 lacks (checked below).
build_dash() {
  d=$B/dash-$1; mkdir -p "$d"
  if [ "$1" = ios ]; then
    (cd "$d" && CC="$B/ios-cc" CC_FOR_BUILD=$HOSTCC ac_cv_func_strchrnul=no "$DASH/configure" \
        --host=aarch64-apple-darwin --without-libedit CFLAGS=-O2 > configure.log 2>&1 &&
     make -j"$NPROC" > make.log 2>&1)
  else
    (cd "$d" && CC=$HOSTCC "$DASH/configure" --without-libedit CFLAGS=-O2 > configure.log 2>&1 &&
     make -j"$NPROC" > make.log 2>&1)
  fi || { echo "dash $1 failed, see $d/*.log" >&2; tail -20 "$d/make.log" >&2 || true; exit 1; }
}

# ---- toybox: coreutils-style applets ----------------------------------------------------------
# toybox's macOS miniconfig plus dd, diff, tr, gzip, gunzip, sync; minus readahead (needs
# posix_fadvise). ps/top/pgrep need Linux /proc and are not in the macOS config: iOS has /bin/ps.
build_toybox() {
  d=$B/toybox-$1; cp -R "$TB" "$d"
  { grep -v '^CONFIG_READAHEAD=' "$TB/scripts/macos_miniconfig"
    printf 'CONFIG_DD=y\nCONFIG_DIFF=y\nCONFIG_TR=y\nCONFIG_GZIP=y\nCONFIG_GUNZIP=y\nCONFIG_SYNC=y\n'; } > "$d/iosplus10.miniconfig"
  # toybox picks its link/strip flags by the build host's uname: the iOS target needs the Mach-O ones
  # (on a Linux host it would pass --gc-sections to ld64)
  if [ "$1" = ios ]; then cc=$B/ios-cc; tbenv="LDOPTIMIZE=-Wl,-dead_strip STRIP=$ISTRIP"; else cc=$HOSTCC; tbenv=; fi
  (cd "$d" && PATH="$B/gnubin:$PATH" && { [ -z "$tbenv" ] || export $tbenv; } &&
   KCONFIG_ALLCONFIG=iosplus10.miniconfig HOSTCC=$HOSTCC scripts/genconfig.sh -n > config.log 2>&1 &&
   CC="$cc" HOSTCC=$HOSTCC SED="$GSED" make -j"$NPROC" toybox > make.log 2>&1) ||
   { echo "toybox $1 failed, see $d/*.log" >&2; tail -20 "$d/make.log" >&2 || true; exit 1; }
}

# Both targets of each tool in parallel.
pids=
for t in ios host; do
  build_dropbear $t & pids="$pids $!"
  build_dash $t & pids="$pids $!"
  build_toybox $t & pids="$pids $!"
done
rc=0; for p in $pids; do wait "$p" || rc=1; done
[ $rc = 0 ] || exit 1

# ---- our tools --------------------------------------------------------------------------------
"$ICC" $IFLAGS -O2 -Wall -Wno-unguarded-availability-new -framework CoreFoundation \
  "$HERE/usbnetcfg.c" -o "$W/ios/usbnetcfg"
"$ICC" $IFLAGS -O2 -Wall -Wno-unguarded-availability-new -framework CoreFoundation \
  "$HERE/laurelnet.c" -o "$W/ios/laurelnet"
"$ICC" $IFLAGS -O2 -Wall -Wno-deprecated-declarations "$HERE/usbreboot.c" -o "$W/ios/usbreboot"
"$ICC" $IFLAGS -O2 -Wall -fobjc-arc -framework Foundation "$HERE/oslogstream.m" -o "$W/ios/oslogstream"

cp "$B/dropbear-ios/dropbearmulti" "$W/ios/dropbearmulti"
cp "$B/dash-ios/src/dash" "$W/ios/dash"
cp "$B/toybox-ios/toybox" "$W/ios/toybox"
cp "$B/dropbear-host/dropbearmulti" "$W/host/dropbearmulti"
cp "$B/dash-host/src/dash" "$W/host/dash"
cp "$B/toybox-host/toybox" "$W/host/toybox"
"$W/host/toybox" | tr ' ' '\n' | grep -v '^$' > "$W/ios/toybox.applets"
chmod 755 "$W"/ios/* "$W"/host/*; chmod 644 "$W/ios/toybox.applets"

# ---- checks + signing -------------------------------------------------------------------------
fail=0
for f in dropbearmulti dash toybox usbnetcfg laurelnet usbreboot oslogstream; do
  b=$W/ios/$f
  $LIPO -archs "$b" | grep -qx arm64 || { echo "$f: not arm64-only" >&2; fail=1; }
  minos=$($OTOOL -l "$b" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
  [ "$minos" = "$MINOS" ] || { echo "$f: minos $minos, expected $MINOS" >&2; fail=1; }
  # weak imports = symbols the SDK knows but iOS 16 may not have (they resolve to NULL there)
  weak=$($NM -m "$b" | grep 'weak external' || true)
  [ -z "$weak" ] || { echo "$f: weak imports (symbols newer than iOS $MINOS?):" >&2; echo "$weak" >&2; fail=1; }
  ents=$HERE/entitlements.plist; [ ! -f "$HERE/$f.entitlements" ] || ents=$HERE/$f.entitlements
  sign "$b" "$ents"
done
# The negroni AMFI stand-in reads the XML entitlements blob (DER-only signatures get none):
# check that each signature has one (magic 0xfade7171).
python3 -I - "$W"/ios/dropbearmulti "$W"/ios/dash "$W"/ios/toybox "$W"/ios/usbnetcfg "$W"/ios/laurelnet "$W"/ios/usbreboot "$W"/ios/oslogstream <<'EOF' || fail=1
import struct, sys
bad = 0
for p in sys.argv[1:]:
    d = open(p, 'rb').read()
    ncmds = struct.unpack_from('<I', d, 16)[0]; off = 32; cs = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x1d: cs = struct.unpack_from('<II', d, off + 8)
        off += size
    if cs is None: print(p, 'no code signature'); bad = 1; continue
    o = cs[0]; n = struct.unpack_from('>I', d, o + 8)[0]
    kinds = [struct.unpack_from('>II', d, o + 12 + 8 * i) for i in range(n)]
    magics = {struct.unpack_from('>I', d, o + bo)[0] for _, bo in kinds}
    if 0xfade7171 not in magics: print(p, 'no XML entitlements blob'); bad = 1
sys.exit(bad)
EOF
[ $fail = 0 ] || { echo "checks failed" >&2; exit 1; }

(cd "$W/ios" && sha dropbearmulti dash toybox usbnetcfg laurelnet usbreboot oslogstream > SHA256SUMS)
echo "iOS builds (arm64, minos $MINOS, ad hoc signed, XML entitlements present):"
cat "$W/ios/SHA256SUMS"
echo "toybox applets: $(wc -l < "$W/ios/toybox.applets")"
