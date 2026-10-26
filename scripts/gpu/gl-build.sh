#!/bin/sh
# Build and stage the GL path for backboardd (CoreAnimation on Mesa freedreno through the EAGL shim,
# the ios-spes route; docs/gpu-userland.md "GL path (ported from ios-spes)"):
#   1. scripts/gpu/build.sh: Mesa freedreno A730 + negronigl.dylib + ngl_test + NegroniGL.bundle
#   2. out/gpu/stage/ in the layout scripts/gpu/phone-gl.sh pushes (single files, never an archive):
#        usr/lib/negronigl.dylib                 the EAGL shim + Mesa (install name /usr/lib/negronigl.dylib)
#        usr/local/bin/ngl_test                  self test from a shell on the phone
#        usr/libexec/backboardd                  Apple's backboardd + LC_LOAD_WEAK_DYLIB negronigl.dylib
#                                                (scripts/gpu/stage-backboardd-gl.py; needs the iOS root at
#                                                IOS_ROOT, default /private/tmp/iosroot-ro; skipped without it)
#        var/db/negronigl/clients                the gate (default: nobody; phone-gl.sh on adds backboardd)
#        System/Library/Extensions/NegroniGL.bundle/{NegroniGL,Info.plist,apps}
#                                                the GL driver for apps (libGFXShared loads it through the kernel's
#                                                IOGLESBundleName, patch 0205); BUNDLE/apps = the staged app gate
#                                                (nobody); phone-gl.sh apps on|off writes BUNDLE/apps.local and BUNDLE/off
#   3. scripts/metal/check-imports.py on our binaries against the 20H392 dyld cache (NO_IMPORT_CHECK=1 skips).
# Long: scripts/bg.sh gl-build scripts/gpu/gl-build.sh ; status: scripts/bg.sh -s gl-build
set -eu
. "$(cd "$(dirname "$0")" && pwd)/env.sh"

"$REPO/scripts/gpu/build.sh"

STAGE=$G/stage
IOS_ROOT=${IOS_ROOT:-/private/tmp/iosroot-ro}
rm -rf "$STAGE"
BSTAGE=$STAGE/System/Library/Extensions/NegroniGL.bundle
mkdir -p "$STAGE/usr/lib" "$STAGE/usr/local/bin" "$STAGE/var/db/negronigl" "$BSTAGE"
cp "$G/negronigl.dylib" "$STAGE/usr/lib/negronigl.dylib"
cp "$G/ngl_test" "$STAGE/usr/local/bin/ngl_test"
"$STRIP" -x "$STAGE/usr/lib/negronigl.dylib" "$STAGE/usr/local/bin/ngl_test"
codesign -s - -f "$STAGE/usr/lib/negronigl.dylib" "$STAGE/usr/local/bin/ngl_test" 2>/dev/null ||
	ldid -S "$STAGE/usr/lib/negronigl.dylib" "$STAGE/usr/local/bin/ngl_test"
cp "$G/NegroniGL.bundle/NegroniGL" "$G/NegroniGL.bundle/Info.plist" "$BSTAGE/"
"$STRIP" -x "$BSTAGE/NegroniGL"
codesign -s - -f "$BSTAGE/NegroniGL" 2>/dev/null || ldid -S "$BSTAGE/NegroniGL"
cat > "$BSTAGE/apps" <<'EOF'
# Processes in which NegroniGL.bundle gives EAGLContexts on Mesa (userland/negronigl/plugin/gld.c apps_gate).
# Names separated by blanks, "*" = all, "-NAME" = never NAME (wins over "*"). This staged file lists nobody;
# the owner's list is apps.local next to it (scripts/gpu/phone-gl.sh apps on|off). A file "off" here turns it off.
EOF
otool -D "$STAGE/usr/lib/negronigl.dylib" | grep -qx /usr/lib/negronigl.dylib ||
	{ echo "gl-build: install name is not /usr/lib/negronigl.dylib" >&2; exit 1; }

cat > "$STAGE/var/db/negronigl/clients" <<'EOF'
# Processes whose EAGLContext runs on Mesa freedreno (userland/negronigl/negronigl.c ngl_load).
# Names separated by blanks, "*" = all, "-NAME" = never NAME. No name = the shim stays off everywhere.
# scripts/gpu/phone-gl.sh on|off edits this file on the phone. A file "off" next to it turns the shim off.
EOF

if [ -f "$IOS_ROOT/usr/libexec/backboardd" ]; then
	rm -rf "$G/backboardd-gl"
	python3 -I "$REPO/scripts/gpu/stage-backboardd-gl.py" "$IOS_ROOT/usr/libexec/backboardd" "$G/backboardd-gl" > "$G/backboardd-gl.json"
	mkdir -p "$STAGE/usr/libexec"
	cp "$G/backboardd-gl/backboardd" "$STAGE/usr/libexec/backboardd"
	cp "$G/backboardd-gl/manifest.json" "$STAGE/usr/libexec/backboardd.negronigl.json"
	echo "gl-build: staged backboardd with LC_LOAD_WEAK_DYLIB /usr/lib/negronigl.dylib"
elif [ -f "$G/backboardd-gl/backboardd" ]; then
	# no root attached: the copy an earlier run made from the same 20H392 backboardd
	mkdir -p "$STAGE/usr/libexec"
	cp "$G/backboardd-gl/backboardd" "$STAGE/usr/libexec/backboardd"
	[ ! -f "$G/backboardd-gl/manifest.json" ] || cp "$G/backboardd-gl/manifest.json" "$STAGE/usr/libexec/backboardd.negronigl.json"
	echo "gl-build: no $IOS_ROOT: staged the earlier $G/backboardd-gl/backboardd"
else
	echo "gl-build: NOTE: no $IOS_ROOT/usr/libexec/backboardd: backboardd not staged (attach the root or set IOS_ROOT)" >&2
fi

(cd "$STAGE" && find . -type f | sort | xargs ls -la)
if [ "${NO_IMPORT_CHECK:-0}" != 1 ]; then
	IOS_DSC=${IOS_DSC:-$IOS_ROOT/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64}
	# no root attached: the 20H392 cache copy (docs/notes.md section 16)
	[ -f "$IOS_DSC" ] || IOS_DSC=$REPO/out/dsc/cache/dyld_shared_cache_arm64
	(cd "$STAGE" && python3 "$REPO/scripts/metal/check-imports.py" "$IOS_DSC" usr/lib/negronigl.dylib usr/local/bin/ngl_test \
		System/Library/Extensions/NegroniGL.bundle/NegroniGL) ||
		{ echo "check-imports: FAILED (missing imports or no cache: attach the root or set IOS_DSC)" >&2; exit 1; }
	echo "check-imports: PASS"
fi
(cd "$STAGE" && find . -type f | sort | xargs shasum -a 256) > "$G/stage.SHA256SUMS"
cat "$G/stage.SHA256SUMS"
