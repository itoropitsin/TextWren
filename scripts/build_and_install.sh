#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d /tmp/TinyAI-build.XXXXXX)"
app_bundle="$build_root/TinyAI.app"
version="${TINYAI_VERSION:-1.59}"
build_number="${TINYAI_BUILD_NUMBER:-75}"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
build_only="${1:-}"
team_identifier="Y29LYS5D8M"
signing_identity="${TINYAI_SIGNING_IDENTITY:-}"
identity_listing="$(security find-identity -v -p codesigning 2>/dev/null || true)"

identity_team_id() {
  local identity="$1"
  local certificate_details
  certificate_details="$(security find-certificate -a -c "$identity" -p 2>/dev/null \
    | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
    | openssl pkcs7 -print_certs -text -noout 2>/dev/null || true)"
  printf '%s\n' "$certificate_details" \
    | sed -n 's/.*Subject:.*OU=\([^,]*\).*/\1/p' \
    | head -n 1
}

if [[ -z "$signing_identity" ]]; then
  while IFS= read -r candidate_identity; do
    [[ -n "$candidate_identity" ]] || continue
    if [[ "$(identity_team_id "$candidate_identity")" == "$team_identifier" ]]; then
      signing_identity="$candidate_identity"
      break
    fi
  done < <(printf '%s\n' "$identity_listing" \
    | awk -F'"' '$2 ~ /^Apple Development:/ {print $2}')
fi

if [[ "$build_only" != "--build-only" && -z "$signing_identity" ]]; then
  echo "Не найден сертификат Apple Development для команды $team_identifier."
  echo "Установите сертификат с приватным ключом или используйте --build-only для проверки без установки."
  exit 1
fi

if [[ -n "$signing_identity" ]]; then
  if ! printf '%s\n' "$identity_listing" \
      | awk -F'"' -v identity="$signing_identity" \
        '$2 == identity && $2 ~ /^Apple Development:/ {found=1} END {exit(found ? 0 : 1)}'; then
    echo "Сертификат '$signing_identity' не найден среди действительных Apple Development identities."
    exit 1
  fi
  detected_team_identifier="$(identity_team_id "$signing_identity")"
  if [[ "$detected_team_identifier" != "$team_identifier" ]]; then
    echo "Сертификат '$signing_identity' принадлежит команде '${detected_team_identifier:-неизвестная}', ожидалась '$team_identifier'."
    exit 1
  fi
fi

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

if [[ -n "$signing_identity" ]]; then
  echo "Подписываю сертификатом: $signing_identity"
  codesign --force --deep --options runtime --sign "$signing_identity" \
    --entitlements "$project_root/TinyAI/TinyAI.entitlements" \
    "$app_bundle"
else
  echo "Подпись пропущена: режим --build-only."
fi

echo "Проверяю собранное приложение…"
test -x "$app_bundle/Contents/MacOS/TinyAI"
test -s "$app_bundle/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Contents/Info.plist")" = "TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app_bundle/Contents/Info.plist")" = "AppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" = "IT.TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app_bundle/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_bundle/Contents/Info.plist")" = "AppIcon"
if [[ -n "$signing_identity" ]]; then
  codesign --verify --deep --strict "$app_bundle"
  signature_details="$(codesign -dv --verbose=4 "$app_bundle" 2>&1)"
  echo "$signature_details" | grep -F "TeamIdentifier=$team_identifier" >/dev/null
  if echo "$signature_details" | grep -F "Signature=adhoc" >/dev/null; then
    echo "Сборка подписана ad-hoc, установка запрещена."
    exit 1
  fi
fi

if [[ "${1:-}" == "--build-only" ]]; then
  echo "Готово: $app_bundle"
  exit 0
fi

install_stage_root="$(mktemp -d /Applications/.TinyAI-install.XXXXXX)"
install_stage_app="$install_stage_root/TinyAI.app"
trap 'rm -rf -- "$install_stage_root"' EXIT
ditto "$app_bundle" "$install_stage_app"
codesign --verify --deep --strict "$install_stage_app"
staged_signature_details="$(codesign -dv --verbose=4 "$install_stage_app" 2>&1)"
echo "$staged_signature_details" | grep -F "TeamIdentifier=$team_identifier" >/dev/null
if echo "$staged_signature_details" | grep -F "Signature=adhoc" >/dev/null; then
  echo "Подготовленная к установке сборка подписана ad-hoc, установка запрещена."
  exit 1
fi

backup_root=""
if [[ -d /Applications/TinyAI.app ]]; then
  backup_root="$(mktemp -d /tmp/TinyAI.previous.XXXXXX)"
  mv /Applications/TinyAI.app "$backup_root/TinyAI.app"
  echo "Резервная копия предыдущей версии: $backup_root/TinyAI.app"
fi

restore_previous_version() {
  if [[ -n "$backup_root" && -d "$backup_root/TinyAI.app" && ! -e /Applications/TinyAI.app ]]; then
    mv "$backup_root/TinyAI.app" /Applications/TinyAI.app
    echo "Резервная копия предыдущей версии восстановлена." >&2
  fi
}

if ! mv "$install_stage_app" /Applications/TinyAI.app; then
  restore_previous_version
  echo "Не удалось заменить приложение." >&2
  exit 1
fi

if ! codesign --verify --deep --strict /Applications/TinyAI.app; then
  echo "Проверка подписи установленного приложения не прошла." >&2
  rm -rf -- /Applications/TinyAI.app
  restore_previous_version
  exit 1
fi
if ! installed_signature_details="$(codesign -dv --verbose=4 /Applications/TinyAI.app 2>&1)"; then
  echo "Не удалось прочитать подпись установленного приложения." >&2
  rm -rf -- /Applications/TinyAI.app
  restore_previous_version
  exit 1
fi
if ! echo "$installed_signature_details" | grep -F "TeamIdentifier=$team_identifier" >/dev/null \
   || echo "$installed_signature_details" | grep -F "Signature=adhoc" >/dev/null; then
  echo "Подпись установленного приложения не соответствует команде $team_identifier." >&2
  rm -rf -- /Applications/TinyAI.app
  restore_previous_version
  exit 1
fi

echo "Установлено: /Applications/TinyAI.app"
installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/TinyAI.app/Contents/Info.plist)"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/TinyAI.app/Contents/Info.plist)"
echo "Версия: $installed_version ($installed_build)"
if pgrep -x TinyAI >/dev/null 2>&1; then
  echo "TinyAI уже запущен; перезапустите его, чтобы загрузить новую сборку."
else
  open -a /Applications/TinyAI.app
fi
