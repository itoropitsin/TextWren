#!/bin/zsh
set -euo pipefail

# `xcode-select` can point at Command Line Tools even when full Xcode is
# installed. The version check below needs xcodebuild from full Xcode.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$(mktemp -d /tmp/TextWren-build.XXXXXX)"
# The app was called TinyAI before 2.1.0. The bundle ID, Keychain service and
# model folder keep that name so settings, keys and permissions carry over.
app_name="TextWren"
legacy_app_name="TinyAI"
installed_app="/Applications/$app_name.app"
legacy_app="/Applications/$legacy_app_name.app"
app_bundle="$build_root/$app_name.app"
version="2.1.0"
build_number="104"
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
  echo "Could not read the TinyAI version from the Xcode settings: $project_file." >&2
  exit 1
fi
if [[ "$project_version" != "$version" || "$project_build_number" != "$build_number" ]]; then
  echo "The installer version ($version/$build_number) does not match Xcode ($project_version/$project_build_number)." >&2
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
  echo "No valid TinyAI Local Code Signing or Apple Development certificate found for team $team_identifier."
  echo "Install a certificate with its private key, or use --build-only for an unsigned check."
  exit 1
fi

if [[ -n "$signing_identity" ]]; then
  if [[ "$signing_identity" == "$local_identity_name" || "$signing_identity" == "$local_identity_sha1" ]]; then
    if ! printf '%s\n' "$identity_listing" \
        | awk -F'"' -v sha="$local_identity_sha1" -v name="$local_identity_name" \
          '$1 ~ sha && $2 == name {found=1} END {exit(found ? 0 : 1)}'; then
      echo "The local TinyAI certificate is not among the valid identities."
      exit 1
    fi
    signing_identity="$local_identity_sha1"
    signing_mode="local"
  else
    if ! printf '%s\n' "$identity_listing" \
        | awk -F'"' -v identity="$signing_identity" \
          '$2 == identity && $2 ~ /^Apple Development:/ {found=1} END {exit(found ? 0 : 1)}'; then
      echo "Certificate '$signing_identity' is not among the valid Apple Development identities."
      exit 1
    fi
    detected_team_identifier="$(identity_team_id "$signing_identity")"
    if [[ "$detected_team_identifier" != "$team_identifier" ]]; then
      echo "Certificate '$signing_identity' belongs to team '${detected_team_identifier:-unknown}', expected '$team_identifier'."
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
    echo "The build is ad-hoc signed; installing it is not allowed: $bundle" >&2
    return 1
  fi
  if [[ "$signing_mode" == "local" ]]; then
    [[ "$details" == *"Authority=$local_identity_name"* ]] || return 1
    codesign -v -R="identifier \"IT.TinyAI\" and certificate leaf = H\"$local_identity_sha1\"" "$bundle" || return 1
    requirement="$(codesign -d -r- "$bundle" 2>&1)" || return 1
    if [[ "$requirement" == *"cdhash"* ]]; then
      echo "The signing requirement is tied to the hash of one build: $bundle" >&2
      return 1
    fi
    entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)" || return 1
    if [[ "$entitlements" != *"com.apple.security.cs.disable-library-validation"* ]]; then
      echo "A local build cannot load CTranscribe and llama without the Library Validation exception: $bundle" >&2
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

echo "Building $app_name $version ($build_number)…"
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
  -o "$app_bundle/Contents/MacOS/$app_name" \
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
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $app_name" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 14.6" "$app_bundle/Contents/Info.plist"
printf 'APPL????' > "$app_bundle/Contents/PkgInfo"

if [[ -n "$signing_identity" ]]; then
  echo "Signing with certificate: $signing_identity"
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
  echo "Signing skipped: --build-only mode."
fi

echo "Checking the built app…"
test -x "$app_bundle/Contents/MacOS/$app_name"
test -f "$app_bundle/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe"
test -f "$app_bundle/Contents/Frameworks/llama.framework/Versions/A/llama"
test -s "$app_bundle/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" = "IT.TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Contents/Info.plist")" = "$app_name"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$app_bundle/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$app_bundle/Contents/Info.plist")" = "AppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app_bundle/Contents/Info.plist")" = "AppIcon"
if [[ -n "$signing_identity" ]]; then
  verify_signature "$app_bundle"
fi

if [[ "$build_only" == "--build-only" ]]; then
  echo "Build and checks finished; install skipped."
  exit 0
fi

# Copy into a temporary directory under /Applications and verify that copy
# before touching the installed bundle.  A failed copy or signature check
# therefore leaves the currently installed version in place.
install_stage_root="$(mktemp -d /Applications/.TextWren-install.XXXXXX)"
install_stage_app="$install_stage_root/$app_name.app"
ditto "$app_bundle" "$install_stage_app"
verify_signature "$install_stage_app"
test -x "$install_stage_app/Contents/MacOS/$app_name"
test -s "$install_stage_app/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$install_stage_app/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$install_stage_app/Contents/Info.plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_stage_app/Contents/Info.plist")" = "IT.TinyAI"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$install_stage_app/Contents/Info.plist")" = "$app_name"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$install_stage_app/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$install_stage_app/Contents/Info.plist")" = "AppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$install_stage_app/Contents/Info.plist")" = "AppIcon"

# Never replace an equal or newer installed release. This check is made only
# for a real install; --build-only remains safe for local build verification.
# The previous install is TextWren.app, or TinyAI.app from before the rename.
previous_app=""
if [[ -d "$installed_app" ]]; then
  previous_app="$installed_app"
elif [[ -d "$legacy_app" ]]; then
  previous_app="$legacy_app"
fi
if [[ -n "$previous_app" ]]; then
  installed_version_before="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$previous_app/Contents/Info.plist" 2>/dev/null || true)"
  installed_build_before="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$previous_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "$installed_version_before" || -z "$installed_build_before" ]]; then
    echo "Could not read the version of $previous_app; replacement cancelled." >&2
    exit 1
  fi
  release_comparison="$(compare_releases "$version" "$build_number" "$installed_version_before" "$installed_build_before")" || {
    echo "$previous_app has an invalid version ($installed_version_before/$installed_build_before); replacement cancelled." >&2
    exit 1
  }
  if [[ "$release_comparison" -le 0 ]]; then
    echo "Install cancelled: version $installed_version_before ($installed_build_before) is already installed or newer." >&2
    exit 1
  fi
fi

# Either name may be running: TextWren, or TinyAI before the rename.
running_app_pid() {
  pgrep -x "$app_name|$legacy_app_name" | head -n 1
}

# Ask the running app to quit before moving its bundle. If it does not leave
# in time, keep /Applications untouched so a live process cannot execute from
# a half-replaced package.
wait_for_app_exit() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [[ -n "$(running_app_pid)" ]]; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done
  return 0
}

if [[ -n "$(running_app_pid)" ]]; then
  echo "Quitting the running app before replacing it…"
  osascript -e 'tell application id "IT.TinyAI" to quit' >/dev/null 2>&1 || true
  if ! wait_for_app_exit 8; then
    # A menu-bar app can ignore the Apple event while its Settings window is
    # open. Send a normal termination signal only to the process executing
    # the installed bundle, then wait again. Never use SIGKILL here.
    running_pid="$(running_app_pid)"
    running_executable="$(lsof -p "$running_pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    if [[ "$running_executable" != "$installed_app/Contents/MacOS/$app_name" \
       && "$running_executable" != "$legacy_app/Contents/MacOS/$legacy_app_name" ]]; then
      echo "Unknown app process ($running_pid); the current install is kept." >&2
      exit 1
    fi
    echo "Sending SIGTERM to $running_pid…"
    kill -TERM "$running_pid"
    if ! wait_for_app_exit 5; then
      echo "The app did not quit in time; the current install is kept." >&2
      exit 1
    fi
  fi
fi

backup_app=""
if [[ -n "$previous_app" ]]; then
  backup_root="$(mktemp -d /tmp/TextWren.previous.XXXXXX)"
  backup_app="$backup_root/$(basename "$previous_app")"
  # Move the old bundle out of the destination before copying.  `ditto` into
  # an existing app would leave stale sealed resources behind and invalidate
  # the new code signature.
  mv "$previous_app" "$backup_app"
  echo "Backup of the previous version: $backup_app"
fi
# A TinyAI.app left next to TextWren.app would be a second copy with the same
# bundle ID; keep it with the backup instead.
if [[ -d "$legacy_app" && "$previous_app" != "$legacy_app" ]]; then
  [[ -n "$backup_root" ]] || backup_root="$(mktemp -d /tmp/TextWren.previous.XXXXXX)"
  mv "$legacy_app" "$backup_root/$legacy_app_name.app"
fi

restore_previous_install() {
  if [[ -z "$backup_app" || ! -d "$backup_app" ]]; then
    return 0
  fi
  if [[ -d "$installed_app" ]]; then
    mv "$installed_app" "$install_stage_root/$app_name.failed.app" || return 1
  fi
  mv "$backup_app" "$previous_app" || return 1
  echo "The previous version was restored: $previous_app" >&2
  open -a "$previous_app" || true
}

if ! mv "$install_stage_app" "$installed_app"; then
  restore_previous_install
  echo "Could not install the app; the backup was restored." >&2
  exit 1
fi
validate_installed_app() {
  verify_signature "$installed_app" || return 1
  test -x "$installed_app/Contents/MacOS/$app_name" || return 1
  test -s "$installed_app/Contents/Resources/AppIcon.icns" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")" = "IT.TinyAI" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$installed_app/Contents/Info.plist")" = "$app_name" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$installed_app/Contents/Info.plist")" = "APPL" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$installed_app/Contents/Info.plist")" = "AppIcon" || return 1
  test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$installed_app/Contents/Info.plist")" = "AppIcon" || return 1
}
if ! validate_installed_app; then
  echo "The new install failed its check; restoring the previous version." >&2
  restore_previous_install
  exit 1
fi

echo "Installed: $installed_app"
installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed_app/Contents/Info.plist")"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_app/Contents/Info.plist")"
echo "Version: $installed_version ($installed_build)"
open -a "$installed_app"

wait_for_app_start() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while ! pgrep -x "$app_name" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 0.2
  done
  return 0
}

if ! wait_for_app_start 8; then
  echo "The new build did not start; restoring the previous version." >&2
  restore_previous_install
  exit 1
fi

app_pid="$(pgrep -x "$app_name" | head -n 1)"
sleep 3
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "$app_name quit right after launch; restoring the previous version." >&2
  restore_previous_install
  exit 1
fi
app_executable="$(lsof -p "$app_pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
if [[ "$app_executable" != "$installed_app/Contents/MacOS/$app_name" ]]; then
  echo "The running $app_name is not the new bundle: ${app_executable:-unknown path}. Restoring the previous version." >&2
  restore_previous_install
  exit 1
fi
echo "Running process: PID $app_pid, $app_executable"
if [[ -n "$backup_root" && -d "$backup_root" ]]; then
  # Keep the previous version until the newly signed app has launched from
  # /Applications; a startup failure then leaves a recoverable copy.
  rm -rf -- "$backup_root"
  backup_root=""
fi
