#!/bin/zsh
set -euo pipefail

app_bundle="${1:?Usage: scripts/sign_release_ad_hoc.sh /path/to/TinyAI.app}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
frameworks=(
  "$app_bundle/Contents/Frameworks/CTranscribe.framework"
  "$app_bundle/Contents/Frameworks/llama.framework"
)

test -d "$app_bundle"
for framework in "${frameworks[@]}"; do
  test -d "$framework"
done
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" = "IT.TinyAI"

# The vendored frameworks may have a seal for headers that Xcode does not copy
# into the app. Re-sign them after embedding, then seal the complete app bundle.
for framework in "${frameworks[@]}"; do
  codesign --force --sign - "$framework"
done
codesign --force --sign - --identifier IT.TinyAI \
  --entitlements "$project_root/TinyAI/TinyAI.entitlements" "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
