#!/bin/bash
# Builds "Night Guard.app" (menu bar app). Needs Xcode Command Line Tools (swiftc).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-build}"
APP="$OUT/Night Guard.app"
command -v swiftc >/dev/null || { echo "swiftc не найден: xcode-select --install" >&2; exit 1; }
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/NightGuard" NightGuard.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Night Guard</string>
  <key>CFBundleDisplayName</key><string>Night Guard</string>
  <key>CFBundleIdentifier</key><string>app.nightguard.menubar</string>
  <key>CFBundleExecutable</key><string>NightGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
