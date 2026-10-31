#!/bin/sh
# Install Google's latest Android platform-tools (adb, fastboot) next to the system ones, without sudo.
#   scripts/setup/platform-tools.sh          (run in tmux: scripts/bg.sh platform-tools scripts/setup/platform-tools.sh)
# Target: ~/.local/share/platform-tools, links in ~/.local/bin (put ~/.local/bin first in PATH).
# The links are made only when Google's version is newer than the one on PATH, so a newer distro
# package is never shadowed by an older zip. macOS and Linux.
set -eu
DEST=${PT_DEST:-$HOME/.local/share/platform-tools}
BIN=${PT_BIN:-$HOME/.local/bin}
case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
URL=https://dl.google.com/android/repository/platform-tools-latest-$os.zip

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 5 -o "$tmp/pt.zip" "$URL"
(cd "$tmp" && unzip -q pt.zip)
[ -x "$tmp/platform-tools/fastboot" ] && [ -x "$tmp/platform-tools/adb" ] || { echo "platform-tools: zip has no adb/fastboot" >&2; exit 1; }
new=$(sed -n 's/^Pkg.Revision=//p' "$tmp/platform-tools/source.properties")
echo "platform-tools: Google $new: $("$tmp/platform-tools/fastboot" --version | head -1)"

# version on PATH (system package), e.g. "fastboot version 37.0.0p1-android-tools" -> 37.0.0
cur=$(fastboot --version 2>/dev/null | head -1 | sed -n 's/^fastboot version \([0-9][0-9.]*\).*/\1/p')
echo "platform-tools: on PATH ${cur:-none}: $(command -v fastboot || echo -)"
newest=$(printf '%s\n%s\n' "${cur:-0}" "$new" | sort -V | tail -1)

rm -rf "$DEST.new"; mkdir -p "$(dirname "$DEST")"
mv "$tmp/platform-tools" "$DEST.new"
rm -rf "$DEST"; mv "$DEST.new" "$DEST"
if [ "$newest" = "$new" ] && [ "$new" != "${cur:-}" ]; then
  mkdir -p "$BIN"
  for t in adb fastboot; do ln -sfn "$DEST/$t" "$BIN/$t"; done
  echo "platform-tools: linked $BIN/adb and $BIN/fastboot -> $DEST ($new)"
  case ":$PATH:" in *":$BIN:"*) ;; *) echo "platform-tools: add $BIN to the front of PATH" ;; esac
else
  echo "platform-tools: the tools on PATH ($cur) are as new or newer; $DEST kept, no links changed"
fi
