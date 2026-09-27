#!/bin/zsh
set -euo pipefail

# Downloads the pinned transcribe.cpp release (the engine behind TinyAI's local
# speech models, the same one Handy uses) into Vendor/. The archive is checked
# against its published SHA-256 before it is unpacked.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
release="v0.2.4"
archive_sha256="243e96ea569583245c9732de3955111210d986c03a34b81424dacde169f9de6a"
archive_url="https://github.com/handy-computer/transcribe.cpp/releases/download/$release/TranscribeCpp.xcframework.zip"
vendor_root="$project_root/Vendor"
framework_root="$vendor_root/TranscribeCpp.xcframework"
marker="$vendor_root/.transcribe-cpp-release"

if [[ -d "$framework_root" && -f "$marker" && "$(cat "$marker")" == "$release" ]]; then
  exit 0
fi

download_root="$(mktemp -d /tmp/TinyAI-transcribe.XXXXXX)"
trap 'rm -rf -- "$download_root"' EXIT

echo "Downloading transcribe.cpp $release…"
curl --fail --location --silent --show-error -o "$download_root/xcframework.zip" "$archive_url"
actual_sha256="$(shasum -a 256 "$download_root/xcframework.zip" | awk '{print $1}')"
if [[ "$actual_sha256" != "$archive_sha256" ]]; then
  echo "transcribe.cpp checksum mismatch: $actual_sha256" >&2
  exit 1
fi

mkdir -p "$vendor_root"
rm -rf -- "$framework_root"
ditto -x -k "$download_root/xcframework.zip" "$vendor_root"
test -d "$framework_root/macos-arm64_x86_64/CTranscribe.framework"
printf '%s' "$release" > "$marker"
echo "transcribe.cpp $release: $framework_root"
