#!/bin/zsh
set -euo pipefail

app_bundle="${1:?Usage: scripts/sign_release_ad_hoc.sh /path/to/TinyAI.app}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
framework="$app_bundle/Contents/Frameworks/CTranscribe.framework"

test -d "$app_bundle"
test -d "$framework"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" = "IT.TinyAI"

# The vendored framework may have a seal for headers that Xcode does not copy
# into the app. Re-sign it after embedding, then seal the complete app bundle.
codesign --force --sign - "$framework"
codesign --force --sign - --identifier IT.TinyAI \
  --entitlements "$project_root/TinyAI/TinyAI.entitlements" "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
