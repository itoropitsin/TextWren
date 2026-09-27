#!/bin/zsh
set -euo pipefail

# `xcode-select` can point at Command Line Tools even when full Xcode is
# installed. The version check below needs xcodebuild from full Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d /tmp/TinyAI-build.XXXXXX)"
app_bundle="$build_root/TinyAI.app"
version="2.0.5"
build_number="99"
project_file="$project_root/TinyAI.xcodeproj/project.pbxproj"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
build_only="${1:-}"
team_identifier="Y29LYS5D8M"
local_identity_name="TinyAI Local Code Signing"
local_identity_sha1="75F9D22B6BECE37FC7059A195C35315EF84A5D96"
signing_identity="${TINYAI_SIGNING_IDENTITY:-}"
signing_mode=""
install_stage_root=""
backup_root=""

cleanup_temporary_files() {
  if [[ -n "$install_stage_root" && -d "$install_stage_root" ]]; then
    rm -rf -- "$install_stage_root"
  fi
  if [[ -d "$build_root" ]]; then
    rm -rf -- "$build_root"
  fi
}

trap cleanup_temporary_files EXIT

# The script keeps the release number next to the build command for a clear
# release record, and checks it against the app target in Xcode before doing
# any build or install work. This prevents the two version sources drifting.
project_build_settings="$(xcodebuild -project "$project_root/TinyAI.xcodeproj" -target TinyAI -configuration Release -showBuildSettings 2>/dev/null || true)"
project_version="$(printf '%s\n' "$project_build_settings" | awk -F ' = ' '$1 ~ /MARKETING_VERSION/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
project_build_number="$(printf '%s\n' "$project_build_settings" | awk -F ' = ' '$1 ~ /CURRENT_PROJECT_VERSION/ {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
if [[ -z "$project_version" || -z "$project_build_number" ]]; then
  echo "Не удалось прочитать версию TinyAI из настроек Xcode: $project_file." >&2
  exit 1
fi
if [[ "$project_version" != "$version" || "$project_build_number" != "$build_number" ]]; then
  echo "Версия в установщике ($version/$build_number) не совпадает с Xcode ($project_version/$project_build_number)." >&2
  exit 1
fi
identity_listing="$(security find-identity -v -p codesigning 2>/dev/null || true)"
# `find-identity` confirms that the certificate has a usable private key.  Its
# output does not include the Team ID, so that part is read from the
# certificate subject below.

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

compare_releases() {
  # Print -1, 0, or 1 for candidate versus installed release. A malformed
  # plist is an error rather than a reason to overwrite an unknown app.
  awk -F '[.]' -v candidate_version="$1" -v candidate_build="$2" \
    -v installed_version="$3" -v installed_build="$4" \
    -f "$project_root/scripts/compare_releases.awk"
}

if [[ -z "$signing_identity" ]] && printf '%s\n' "$identity_listing" \
    | awk -v sha="$local_identity_sha1" -F'"' '$1 ~ sha && $2 == "TinyAI Local Code Signing" {found=1} END {exit(found ? 0 : 1)}'; then
  signing_identity="$local_identity_sha1"
fi

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
  echo "Не найден действительный сертификат TinyAI Local Code Signing или Apple Development для команды $team_identifier."
  echo "Установите сертификат с приватным ключом или используйте --build-only для неподписанной проверки."
  exit 1
fi

if [[ -n "$signing_identity" ]]; then
  if [[ "$signing_identity" == "$local_identity_name" || "$signing_identity" == "$local_identity_sha1" ]]; then
    if ! printf '%s\n' "$identity_listing" \
        | awk -F'"' -v sha="$local_identity_sha1" -v name="$local_identity_name" \
          '$1 ~ sha && $2 == name {found=1} END {exit(found ? 0 : 1)}'; then
      echo "Локальный сертификат TinyAI не найден среди действительных identities."
      exit 1
    fi
    signing_identity="$local_identity_sha1"
    signing_mode="local"
  else
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
    signing_mode="apple_development"
  fi
fi

verify_signature() {
  local bundle="$1"
  local details
  local requirement
  local entitlements
  codesign --verify --deep --strict "$bundle" || return 1
  details="$(codesign -dv --verbose=4 "$bundle" 2>&1)" || return 1
  if [[ "$details" == *"Signature=adhoc"* ]]; then
    echo "Сборка подписана ad-hoc, установка запрещена: $bundle" >&2
    return 1
  fi
  if [[ "$signing_mode" == "local" ]]; then
    [[ "$details" == *"Authority=$local_identity_name"* ]] || return 1
    codesign -v -R="identifier \"IT.TinyAI\" and certificate leaf = H\"$local_identity_sha1\"" "$bundle" || return 1
    requirement="$(codesign -d -r- "$bundle" 2>&1)" || return 1
    if [[ "$requirement" == *"cdhash"* ]]; then
      echo "Требование подписи привязано к хешу конкретной сборки: $bundle" >&2
      return 1
    fi
    entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)" || return 1
    if [[ "$entitlements" != *"com.apple.security.cs.disable-library-validation"* ]]; then
      echo "Локальная сборка не может загрузить CTranscribe и llama без исключения Library Validation: $bundle" >&2
      return 1
    fi
  else
    [[ "$details" == *"TeamIdentifier=$team_identifier"* ]] || return 1
  fi
}

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"

# The local speech and text engines ship as prebuilt frameworks; fetch the
# pinned releases once and embed them next to the executable.
"$project_root/scripts/fetch_transcribe_cpp.sh"
"$project_root/scripts/fetch_llama_cpp.sh"
transcribe_framework_dir="$project_root/Vendor/TranscribeCpp.xcframework/macos-arm64_x86_64"
ditto "$transcribe_framework_dir/CTranscribe.framework" "$app_bundle/Contents/Frameworks/CTranscribe.framework"
llama_framework_dir="$project_root/Vendor/llama.xcframework/macos-arm64_x86_64"
ditto "$llama_framework_dir/llama.framework" "$app_bundle/Contents/Frameworks/llama.framework"

echo "Собираю TinyAI $version ($build_number)…"
swiftc \
  -target arm64-apple-macosx14.6 \
  -sdk "$sdk_path" \
  -swift-version 5 \
  -parse-as-library \
  -default-isolation MainActor \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature MemberImportVisibility \
  -module-name TinyAI \
  -O \
  -o "$app_bundle/Contents/MacOS/TinyAI" \
  "$project_root"/TinyAI/*.swift \
  -F "$transcribe_framework_dir" \
  -framework CTranscribe \
  -F "$llama_framework_dir" \
  -framework llama \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework ApplicationServices \
  -framework Carbon \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework Foundation \
  -framework LocalAuthentication \
  -framework Security \
  -framework AVFoundation \
  -framework CryptoKit \
  -framework Network

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
  # The embedded frameworks arrive ad-hoc signed, so sign them before the app.
  # A local certificate has no Apple Team ID. The main executable therefore
  # needs the narrow Library Validation exception to load these frameworks.
  signing_entitlements="$project_root/TinyAI/TinyAI.entitlements"
  if [[ "$signing_mode" == "local" ]]; then
    signing_entitlements="$project_root/TinyAI/TinyAI.local.entitlements"
  fi
  codesign --force --options runtime --sign "$signing_identity" \
    "$app_bundle/Contents/Frameworks/CTranscribe.framework"
  codesign --force --options runtime --sign "$signing_identity" \
    "$app_bundle/Contents/Frameworks/llama.framework"
  codesign --force --options runtime --sign "$signing_identity" \
    --entitlements "$signing_entitlements" \
    "$app_bundle"
else
  echo "Подпись пропущена: режим --build-only."
fi

echo "Проверяю собранное приложение…"
test -x "$app_bundle/Contents/MacOS/TinyAI"
test -f "$app_bundle/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe"
test -f "$app_bundle/Contents/Frameworks/llama.framework/Versions/A/llama"
test -s "$app_bundle/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" = "IT.TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Contents/Info.plist")" = "TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app_bundle/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app_bundle/Contents/Info.plist")" = "AppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_bundle/Contents/Info.plist")" = "AppIcon"
if [[ -n "$signing_identity" ]]; then
  verify_signature "$app_bundle"
fi

if [[ "$build_only" == "--build-only" ]]; then
  echo "Сборка и проверка завершены; установка пропущена."
  exit 0
fi

# Copy into a temporary directory under /Applications and verify that copy
# before touching the installed bundle.  A failed copy or signature check
# therefore leaves the currently installed version in place.
install_stage_root="$(mktemp -d /Applications/.TinyAI-install.XXXXXX)"
install_stage_app="$install_stage_root/TinyAI.app"
ditto "$app_bundle" "$install_stage_app"
verify_signature "$install_stage_app"
test -x "$install_stage_app/Contents/MacOS/TinyAI"
test -s "$install_stage_app/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$install_stage_app/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$install_stage_app/Contents/Info.plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_stage_app/Contents/Info.plist")" = "IT.TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$install_stage_app/Contents/Info.plist")" = "TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$install_stage_app/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$install_stage_app/Contents/Info.plist")" = "AppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$install_stage_app/Contents/Info.plist")" = "AppIcon"

# Never replace an equal or newer installed release. This check is made only
# for a real install; --build-only remains safe for local build verification.
if [[ -d /Applications/TinyAI.app ]]; then
  installed_version_before="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/TinyAI.app/Contents/Info.plist 2>/dev/null || true)"
  installed_build_before="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/TinyAI.app/Contents/Info.plist 2>/dev/null || true)"
  if [[ -z "$installed_version_before" || -z "$installed_build_before" ]]; then
    echo "Не удалось определить версию уже установленного TinyAI; замена отменена." >&2
    exit 1
  fi
  release_comparison="$(compare_releases "$version" "$build_number" "$installed_version_before" "$installed_build_before")" || {
    echo "Некорректная версия уже установленного TinyAI ($installed_version_before/$installed_build_before); замена отменена." >&2
    exit 1
  }
  if [[ "$release_comparison" -le 0 ]]; then
    echo "Установка отменена: TinyAI $installed_version_before ($installed_build_before) уже установлен или новее." >&2
    exit 1
  fi
fi

# Ask the running app to quit before moving its bundle. If it does not leave
# in time, keep /Applications untouched so a live process cannot execute from
# a half-replaced package.
wait_for_tinyai_exit() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while pgrep -x TinyAI >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done
  return 0
}

if pgrep -x TinyAI >/dev/null 2>&1; then
  echo "Завершаю запущенный TinyAI перед заменой…"
  osascript -e 'tell application "TinyAI" to quit' >/dev/null 2>&1 || true
  if ! wait_for_tinyai_exit 8; then
    # A menu-bar app can ignore the Apple event while its Settings window is
    # open. Send a normal termination signal only to the process executing
    # the installed bundle, then wait again. Never use SIGKILL here.
    running_pid="$(pgrep -x TinyAI | head -n 1)"
    running_executable="$(lsof -p "$running_pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [[ "$running_executable" != "/Applications/TinyAI.app/Contents/MacOS/TinyAI" ]]; then
      echo "Неизвестный процесс TinyAI ($running_pid); текущая установка сохранена." >&2
      exit 1
    fi
    echo "Отправляю TinyAI SIGTERM…"
    kill -TERM "$running_pid"
    if ! wait_for_tinyai_exit 5; then
      echo "TinyAI не завершился вовремя; текущая установка сохранена." >&2
      exit 1
    fi
  fi
fi

if [[ -d /Applications/TinyAI.app ]]; then
  backup_root="$(mktemp -d /tmp/TinyAI.previous.XXXXXX)"
  # Move the old bundle out of the destination before copying.  `ditto` into
  # an existing app would leave stale sealed resources behind and invalidate
  # the new code signature.
  mv /Applications/TinyAI.app "$backup_root/TinyAI.app"
  echo "Резервная копия предыдущей версии: $backup_root/TinyAI.app"
fi

if ! mv "$install_stage_app" /Applications/TinyAI.app; then
  if [[ -n "$backup_root" && -d "$backup_root/TinyAI.app" && ! -e /Applications/TinyAI.app ]]; then
    mv "$backup_root/TinyAI.app" /Applications/TinyAI.app
    echo "Не удалось заменить приложение; резервная копия восстановлена." >&2
  fi
  exit 1
fi
validate_installed_app() {
  verify_signature /Applications/TinyAI.app || return 1
  test -x /Applications/TinyAI.app/Contents/MacOS/TinyAI || return 1
  test -s /Applications/TinyAI.app/Contents/Resources/AppIcon.icns || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/TinyAI.app/Contents/Info.plist)" = "IT.TinyAI" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' /Applications/TinyAI.app/Contents/Info.plist)" = "TinyAI" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' /Applications/TinyAI.app/Contents/Info.plist)" = "APPL" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' /Applications/TinyAI.app/Contents/Info.plist)" = "AppIcon" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' /Applications/TinyAI.app/Contents/Info.plist)" = "AppIcon" || return 1
}
if ! validate_installed_app; then
  echo "Новая установка не прошла проверку; восстанавливаю предыдущую версию." >&2
  mv /Applications/TinyAI.app "$install_stage_root/TinyAI.failed.app"
  if [[ -n "$backup_root" && -d "$backup_root/TinyAI.app" ]]; then
    mv "$backup_root/TinyAI.app" /Applications/TinyAI.app
  fi
  exit 1
fi

echo "Установлено: /Applications/TinyAI.app"
installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/TinyAI.app/Contents/Info.plist)"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/TinyAI.app/Contents/Info.plist)"
echo "Версия: $installed_version ($installed_build)"
open -a /Applications/TinyAI.app

wait_for_tinyai_start() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while ! pgrep -x TinyAI >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done
  return 0
}

restore_previous_install() {
  if [[ -z "$backup_root" || ! -d "$backup_root/TinyAI.app" ]]; then
    return 0
  fi
  if [[ -d /Applications/TinyAI.app ]]; then
    mv /Applications/TinyAI.app "$install_stage_root/TinyAI.failed.app" || return 1
  fi
  mv "$backup_root/TinyAI.app" /Applications/TinyAI.app || return 1
  echo "Предыдущая версия TinyAI восстановлена: /Applications/TinyAI.app" >&2
  open -a /Applications/TinyAI.app || true
}

if ! wait_for_tinyai_start 8; then
  echo "Новая сборка не запустилась; восстанавливаю предыдущую версию." >&2
  restore_previous_install
  exit 1
fi

tinyai_pid="$(pgrep -x TinyAI | head -n 1)"
sleep 3
if ! kill -0 "$tinyai_pid" 2>/dev/null; then
  echo "TinyAI завершился сразу после запуска; восстанавливаю предыдущую версию." >&2
  restore_previous_install
  exit 1
fi
tinyai_executable="$(lsof -p "$tinyai_pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
if [[ "$tinyai_executable" != "/Applications/TinyAI.app/Contents/MacOS/TinyAI" ]]; then
  echo "Запущен не новый пакет TinyAI: ${tinyai_executable:-путь не определён}. Восстанавливаю предыдущую версию." >&2
  restore_previous_install
  exit 1
fi
echo "Активный процесс: PID $tinyai_pid, $tinyai_executable"
if [[ -n "$backup_root" && -d "$backup_root" ]]; then
  # Keep the previous version until the newly signed app has launched from
  # /Applications; a startup failure then leaves a recoverable copy.
  rm -rf -- "$backup_root"
  backup_root=""
fi
