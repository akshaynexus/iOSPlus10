#!/bin/sh
# Build the Android side of the boot menu: tools/laurel-switcher -> out/laurel/switcher/laurel-switcher.apk (Quick Settings tile "Boot iOS").
#   scripts/bg.sh switcher scripts/laurel/switcher-build.sh
# Needs the Android SDK (build-tools + platform 36): $ANDROID_SDK, else ~/Android/Sdk, ~/Library/Android/sdk. The signing key is made once in out/ (git-ignored); only updates need the same key.
set -eu
. "$(dirname "$0")/../lib/env.sh"
SDK=${ANDROID_SDK:-}
for s in "$SDK" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" "${ANDROID_HOME:-}"; do
  if [ -n "$s" ] && [ -d "$s/build-tools" ] && [ -f "$s/platforms/android-36/android.jar" ]; then SDK=$s; break; fi
done
[ -f "$SDK/platforms/android-36/android.jar" ] || { echo "switcher-build: no Android SDK with platform android-36" >&2; exit 1; }
BT=$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)
[ -x "$BT/apksigner" ] && [ -x "$BT/d8" ] && [ -x "$BT/aapt2" ] || { echo "switcher-build: build-tools incomplete: $BT" >&2; exit 1; }
JAR=$SDK/platforms/android-36/android.jar
S=$REPO/tools/laurel-switcher
O=$OUT/laurel/switcher
rm -rf "$O/obj"; mkdir -p "$O/obj/classes" "$O/obj/dex"
"$REPO/scripts/laurel/switcher-asset.sh" "$O/obj/assets"
"$BT/aapt2" compile --dir "$S/res" -o "$O/obj/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest "$S/AndroidManifest.xml" -A "$O/obj/assets" --min-sdk-version 34 --target-sdk-version 36 -o "$O/obj/base.apk" "$O/obj/res.zip"
javac -nowarn --release 17 -cp "$JAR" -d "$O/obj/classes" "$S"/src/org/iosplus10/laurelswitcher/*.java
"$BT/d8" --release --min-api 34 --lib "$JAR" --output "$O/obj/dex" $(find "$O/obj/classes" -name '*.class')
cp "$O/obj/base.apk" "$O/obj/unsigned.apk"
( cd "$O/obj/dex" && zip -q -j "$O/obj/unsigned.apk" classes.dex )
"$BT/zipalign" -f -p 4 "$O/obj/unsigned.apk" "$O/obj/aligned.apk"
KS=$O/sign.p12
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storetype PKCS12 -storepass laurelsw -keypass laurelsw -alias laurel -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=laurel-switcher" >/dev/null 2>&1
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:laurelsw --out "$O/laurel-switcher.apk" "$O/obj/aligned.apk"
"$BT/apksigner" verify --print-certs "$O/laurel-switcher.apk" | head -1
"$BT/aapt2" dump badging "$O/laurel-switcher.apk" | sed -n '1p;/sdkVersion/p;/targetSdk/p'
ls -l "$O/laurel-switcher.apk"
