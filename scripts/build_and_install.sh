#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d /tmp/TinyAI-build.XXXXXX)"
app_bundle="$build_root/TinyAI.app"
version="1.58"
build_number="74"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"

echo "Собираю TinyAI $version ($build_number)…"
swiftc \
  -target arm64-apple-macosx14.6 \
  -sdk "$sdk_path" \
  -swift-version 5 \
  -parse-as-library \
  -module-name TinyAI \
  -O \
  -o "$app_bundle/Contents/MacOS/TinyAI" \
  "$project_root"/TinyAI/*.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework ApplicationServices \
  -framework Carbon \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework Foundation \
  -framework Security

iconset="$build_root/AppIcon.iconset"
mkdir -p "$iconset"
ditto "$project_root/TinyAI/Assets.xcassets/AppIcon.appiconset" "$iconset"
iconutil --convert icns --output "$app_bundle/Contents/Resources/AppIcon.icns" "$iconset"

cp "$project_root/TinyAI/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier IT.TinyAI" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable TinyAI" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName TinyAI" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.6" "$app_bundle/Contents/Info.plist"
printf 'APPL????' > "$app_bundle/Contents/PkgInfo"

codesign --force --deep --sign - \
  --entitlements "$project_root/TinyAI/TinyAI.entitlements" \
  "$app_bundle"

echo "Проверяю собранное приложение…"
test -x "$app_bundle/Contents/MacOS/TinyAI"
test -s "$app_bundle/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Contents/Info.plist")" = "TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app_bundle/Contents/Info.plist")" = "AppIcon"
codesign --verify --deep --strict "$app_bundle"

if [[ "${1:-}" == "--build-only" ]]; then
  echo "Готово: $app_bundle"
  exit 0
fi

backup_root=""
if [[ -d /Applications/TinyAI.app ]]; then
  backup_root="$(mktemp -d /tmp/TinyAI.previous.XXXXXX)"
  # Move the old bundle out of the destination before copying.  `ditto` into
  # an existing app would leave stale sealed resources behind and invalidate
  # the new code signature.
  mv /Applications/TinyAI.app "$backup_root/TinyAI.app"
  echo "Резервная копия предыдущей версии: $backup_root/TinyAI.app"
fi

ditto "$app_bundle" /Applications/TinyAI.app
codesign --verify --deep --strict /Applications/TinyAI.app

echo "Установлено: /Applications/TinyAI.app"
installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/TinyAI.app/Contents/Info.plist)"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/TinyAI.app/Contents/Info.plist)"
echo "Версия: $installed_version ($installed_build)"
if pgrep -x TinyAI >/dev/null 2>&1; then
  echo "TinyAI уже запущен; перезапустите его, чтобы загрузить новую сборку."
else
  open -a /Applications/TinyAI.app
fi
