#!/usr/bin/env bash
#
# bundle-zot.sh
#
# DEVELOPER TOOL, not part of the running app. Seeds the binary that ships
# inside the app bundle (Resources/zot-bin + zot-version.txt). Run this once
# before archiving a release if you want to refresh the baked-in copy.
#
# At runtime, the app updates its own installed copy in Application Support
# entirely in Swift (see ZotUpdater.swift); this script does not affect that.
#
set -euo pipefail

REPO="patriceckhart/zot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$SCRIPT_DIR/../zot sidekick/Resources"

ARCH=$(uname -m)
case "$ARCH" in
  arm64)  ASSET="darwin_arm64" ;;
  x86_64) ASSET="darwin_amd64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

VER=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')

if [ -z "$VER" ]; then
  echo "Failed to determine latest version" >&2
  exit 1
fi

URL="https://github.com/$REPO/releases/download/v${VER}/zot_${VER}_${ASSET}.tar.gz"
echo "Downloading zot v$VER ($ASSET)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -sL "$URL" -o "$TMP/zot.tgz"
tar xzf "$TMP/zot.tgz" -C "$TMP"

mkdir -p "$RESOURCES_DIR"
cp "$TMP/zot" "$RESOURCES_DIR/zot-bin"
chmod +x "$RESOURCES_DIR/zot-bin"
printf '%s' "$VER" > "$RESOURCES_DIR/zot-version.txt"

echo "Bundled zot v$VER at $RESOURCES_DIR/zot-bin"
