#!/usr/bin/env bash
# Builds build/LocalServer.app (release). Signed with a fixed Apple Development certificate when present, otherwise ad-hoc.
# Double-click in Finder or run from Terminal. LOCALSERVER_APP_DIR builds elsewhere (release.command uses a temp folder).
set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$OUT_DIR/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="${LOCALSERVER_APP_DIR:-$OUT_DIR}/LocalServer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LocalServer" "$APP/Contents/MacOS/LocalServer"

# App icon: the Deuce game icon (Resources/AppIcon.png).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    # The source is 512px: skip 512@2x rather than upscale it.
    [ $size -lt 512 ] && sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Local Server</string>
    <key>CFBundleDisplayName</key><string>Local Server</string>
    <key>CFBundleIdentifier</key><string>asia.catgaming.deuegambit.localserver</string>
    <key>CFBundleExecutable</key><string>LocalServer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>Serves CLR and Addressables files to test devices on your Wi-Fi.</string>
</dict>
</plist>
PLIST

# Version: VERSION (CFBundleShortVersionString), commit count (CFBundleVersion; no git → 1).
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# Default: the same Apple Development certificate as My Connector (by SHA-1). A fixed Team ID keeps macOS
# from asking for Local Network permission again after every build. Override with LOCALSERVER_SIGN_IDENTITY.
SIGN_IDENTITY="${LOCALSERVER_SIGN_IDENTITY:-E154544B45E03CE74ADB793B98E77AF31F9BDC60}"
if security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
    codesign --force --deep --options runtime --timestamp=none -s "$SIGN_IDENTITY" "$APP"
else
    echo "Signing ad-hoc: macOS may ask for Local Network permission again after each build. Set LOCALSERVER_SIGN_IDENTITY to a codesigning identity." >&2
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Authority|Signature)' || true
echo "Built $APP ($VERSION build $BUILD_NUMBER)"
