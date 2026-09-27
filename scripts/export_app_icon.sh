#!/bin/zsh
set -euo pipefail

# Renders design/textwren-icon.svg into the app icon set and the README
# header image. Needs rsvg-convert (brew install librsvg).

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_svg="$project_root/design/textwren-icon.svg"
iconset="$project_root/TinyAI/Assets.xcassets/AppIcon.appiconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert is missing. Install it with: brew install librsvg" >&2
  exit 1
fi

render() {
  rsvg-convert --width "$1" --height "$1" --output "$2" "$source_svg"
}

for size in 16 32 128 256 512; do
  render "$size" "$iconset/icon_${size}x${size}.png"
  render "$((size * 2))" "$iconset/icon_${size}x${size}@2x.png"
done
render 256 "$project_root/docs/icon.png"

echo "Exported the app icon to $iconset and docs/icon.png."
