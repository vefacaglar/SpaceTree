#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
app="build/SpaceTree.app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/SpaceTree" "$app/Contents/MacOS/SpaceTree"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SpaceTree</string>
<key>CFBundleDisplayName</key><string>SpaceTree</string>
<key>CFBundleIdentifier</key><string>local.spacetree.app</string>
<key>CFBundleExecutable</key><string>SpaceTree</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null
printf 'Built %s\n' "$PWD/$app"
