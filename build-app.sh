#!/bin/sh
# Builds "Olaz Rebuild.app" (release, ad-hoc signed) next to this script.
set -eu
root="$(cd "$(dirname "$0")" && pwd)"
cd "$root/OlazRebuild"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="$root/Olaz Rebuild.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/OlazRebuild" "$app/Contents/MacOS/OlazRebuild"
cp -R "$bin/OlazRebuild_OlazRebuild.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.nih.olazrebuild</string>
    <key>CFBundleName</key><string>Olaz Rebuild</string>
    <key>CFBundleExecutable</key><string>OlazRebuild</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"
