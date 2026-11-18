#!/bin/zsh
# Builds Hephaestus.app (no Xcode needed, just Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Hephaestus.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Hephaestus "$APP/Contents/MacOS/Hephaestus"
cp .build/release/hephaestus-cli "$APP/Contents/MacOS/hephaestus-cli"
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/HephaestusIPC/Version.swift)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hephaestus</string>
  <key>CFBundleIdentifier</key><string>dev.rsdf.hephaestus</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Hephaestus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
if security find-identity -p codesigning | grep -q "Hephaestus Dev"; then
  codesign --force --sign "Hephaestus Dev" "$APP/Contents/MacOS/hephaestus-cli"
  codesign --force --sign "Hephaestus Dev" "$APP"
else
  echo "WARNING: ad-hoc signing; Accessibility permission will reset on every rebuild. Run ./setup-signing.sh once."
  codesign --force --sign - "$APP/Contents/MacOS/hephaestus-cli"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
