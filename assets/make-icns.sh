#!/bin/zsh
# Regenerates assets/AppIcon.icns from assets/logo.svg (needs rsvg-convert: brew install librsvg).
set -euo pipefail
cd "$(dirname "$0")"
S=$(mktemp -d)/AppIcon.iconset; mkdir -p "$S"
for sz in 16 32 128 256 512; do
  rsvg-convert -w $sz -h $sz logo.svg -o "$S/icon_${sz}x${sz}.png"
  rsvg-convert -w $((sz*2)) -h $((sz*2)) logo.svg -o "$S/icon_${sz}x${sz}@2x.png"
done
iconutil -c icns "$S" -o AppIcon.icns
rsvg-convert -w 512 -h 512 logo.svg -o logo.png
echo "Wrote assets/AppIcon.icns and assets/logo.png"
