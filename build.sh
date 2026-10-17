#!/bin/sh
# Builds Patchbay.app into ./build. With --install, copies it to ~/Applications and opens it.
set -e
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=build/Patchbay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Patchbay" "$APP/Contents/MacOS/"
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ ! -f build/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.patchbay.Patchbay</string>
    <key>CFBundleName</key><string>Patchbay</string>
    <key>CFBundleDisplayName</key><string>Patchbay</string>
    <key>CFBundleExecutable</key><string>Patchbay</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.patchbay.session</string>
            <key>UTTypeDescription</key><string>Patchbay Session</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    swift scripts/quit-app.swift
    rm -rf "$HOME/Applications/Patchbay.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/Patchbay.app"
    echo "Installed to ~/Applications/Patchbay.app"
fi
