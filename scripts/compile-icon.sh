#!/usr/bin/env bash
#
# compile-icon.sh
#
# DEVELOPER TOOL. Compiles the Liquid Glass app icon (Icon.icon) together with
# the asset catalog into prebuilt-icon/Assets.car (+ Icon.icns) using actool.
#
# This must run on a Mac with an Xcode new enough to compile .icon bundles.
# The CI runner's actool can crash on .icon, so we commit the prebuilt output
# and let the workflow inject it into the built app instead of recompiling.
#
# Re-run this whenever Icon.icon or Assets.xcassets changes, then commit
# prebuilt-icon/.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ASSETS="$ROOT/zot sidekick/Assets.xcassets"
ICON="$ROOT/zot sidekick/Icon.icon"
OUT="$ROOT/prebuilt-icon"

rm -rf "$OUT"
mkdir -p "$OUT"

actool "$ASSETS" "$ICON" --compile "$OUT" \
  --output-format human-readable-text --notices --warnings \
  --output-partial-info-plist "$OUT/info.plist" \
  --app-icon Icon --include-all-app-icons \
  --accent-color AccentColor \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --platform macosx

rm -f "$OUT/info.plist"
echo "Wrote:"
ls -la "$OUT"
