#!/bin/sh
# builds a release Counterparty.app next to this script
set -e
cd "$(dirname "$0")"

swift build -c release --product Counterparty
app=Counterparty.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Counterparty" "$app/Contents/MacOS/Counterparty"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Counterparty</string>
    <key>CFBundleDisplayName</key><string>Counterparty</string>
    <key>CFBundleIdentifier</key><string>com.raihanadf.counterparty</string>
    <key>CFBundleExecutable</key><string>Counterparty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$app"
echo "built $app"
