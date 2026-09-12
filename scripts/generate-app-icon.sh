#!/usr/bin/env bash
# Generates every macOS AppIcon asset-catalog representation from one square PNG.
# Usage: scripts/generate-app-icon.sh /path/to/app-icon.png

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/app-icon.png" >&2
  exit 64
fi

source_image=$1
if [[ ! -f "$source_image" ]]; then
  echo "Icon source does not exist: $source_image" >&2
  exit 66
fi

if ! command -v magick >/dev/null; then
  echo "ImageMagick (magick) is required. Install it with: brew install imagemagick" >&2
  exit 69
fi

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir="$root_dir/Maccy/Assets.xcassets/AppIcon.appiconset"
icon_composer_dir="$root_dir/Maccy/AppIcon.icon/Assets"

read -r width height < <(magick identify -format '%w %h\n' "$source_image")
if [[ "$width" != "$height" ]]; then
  echo "Icon source must be square; received ${width}x${height}." >&2
  exit 65
fi

generate() {
  local pixels=$1
  local filename=$2

  magick "$source_image" \
    -strip \
    -filter Lanczos \
    -resize "${pixels}x${pixels}!" \
    -define png:compression-level=9 \
    "$output_dir/$filename"
}

generate 16 'AppIcon (Big Sur)-16w.png'
generate 32 'AppIcon (Big Sur)-32w.png'
generate 32 'AppIcon (Big Sur)-32w-1.png'
generate 64 'AppIcon (Big Sur)-64w.png'
generate 128 'AppIcon (Big Sur)-128w.png'
generate 256 'AppIcon (Big Sur)-256w.png'
generate 256 'AppIcon (Big Sur)-256w-1.png'
generate 512 'AppIcon (Big Sur)-512w.png'
generate 512 'AppIcon (Big Sur)-512w-1.png'
generate 1024 'AppIcon (Big Sur)-1024w.png'

# Keep the Xcode Icon Composer source in sync with the catalog used by builds.
# Icon Composer stores layers as SVG, so embed the raster source in its top layer.
generate_composer_layer() {
  local encoded_png
  encoded_png=$(magick "$source_image" \
    -strip \
    -filter Lanczos \
    -resize '1024x1024!' \
    -define png:compression-level=9 \
    png:- | base64 | tr -d '\n')

  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<svg width="1024px" height="1024px" viewBox="0 0 1024 1024" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">' \
    '  <title>0 - Layer</title>' \
    "  <image x=\"0\" y=\"0\" width=\"1024\" height=\"1024\" preserveAspectRatio=\"none\" href=\"data:image/png;base64,${encoded_png}\"/>" \
    '</svg>' \
    > "$icon_composer_dir/0 - Layer.svg"
}

generate_composer_layer

echo "Generated macOS app-icon representations in $output_dir and updated $icon_composer_dir/0 - Layer.svg"
