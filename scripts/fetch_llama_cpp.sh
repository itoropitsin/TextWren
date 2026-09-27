#!/bin/zsh
set -euo pipefail

# Downloads the pinned llama.cpp release (the engine behind TinyAI's on-device
# text model) into Vendor/. The archive is checked against its published
# SHA-256 before it is unpacked.

project_root="$(cd "$(dirname "$0")/.." && pwd)"
release="b11217"
archive_sha256="f8098cd59e0bc5a2829379ad94e82947c97585db795a9e73f632748b2e99c7f3"
archive_url="https://github.com/ggml-org/llama.cpp/releases/download/$release/llama-$release-xcframework.zip"
vendor_root="$project_root/Vendor"
framework_root="$vendor_root/llama.xcframework"
marker="$vendor_root/.llama-cpp-release"

if [[ -d "$framework_root" && -f "$marker" && "$(cat "$marker")" == "$release" ]]; then
  exit 0
fi

download_root="$(mktemp -d /tmp/TinyAI-llama.XXXXXX)"
trap 'rm -rf -- "$download_root"' EXIT

echo "Downloading llama.cpp $release…"
curl --fail --location --silent --show-error -o "$download_root/xcframework.zip" "$archive_url"
actual_sha256="$(shasum -a 256 "$download_root/xcframework.zip" | awk '{print $1}')"
if [[ "$actual_sha256" != "$archive_sha256" ]]; then
  echo "llama.cpp checksum mismatch: $actual_sha256" >&2
  exit 1
fi

ditto -x -k "$download_root/xcframework.zip" "$download_root/unpacked"
mkdir -p "$vendor_root"
rm -rf -- "$framework_root"
mv "$download_root/unpacked/build-apple/llama.xcframework" "$framework_root"
test -d "$framework_root/macos-arm64_x86_64/llama.framework"
printf '%s' "$release" > "$marker"
echo "llama.cpp $release: $framework_root"
