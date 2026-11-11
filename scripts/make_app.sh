#!/bin/bash
# Builds Lazy Print in release mode and packages dist/Lazy Print.app
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building (release)…"
swift build -c release

APP="dist/Lazy Print.app"
BIN=".build/release/LazyPrint"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/LazyPrint"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>CFBundleName</key>              <string>Lazy Print</string>
    <key>CFBundleDisplayName</key>       <string>Lazy Print</string>
    <key>CFBundleIdentifier</key>        <string>local.lazyprint.app</string>
    <key>CFBundleExecutable</key>        <string>LazyPrint</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>NSApplicationSupportsSecureRestorableState</key> <true/>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Lazy Print's demo printer saves the pages it prints in your Documents folder.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Lazy Print looks for printers on your local network, so you can print to them, and receives files from your paired phone.</string>
    <key>NSBonjourServices</key>
    <array><string>_ipp._tcp</string><string>_ipps._tcp</string><string>_lazyprint._tcp</string></array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key> <true/>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>PDF document</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>    <array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>      <string>Picture</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>    <array><string>public.image</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>      <string>Text document</string>
            <key>CFBundleTypeRole</key>      <string>Viewer</string>
            <key>LSHandlerRank</key>         <string>Alternate</string>
            <key>LSItemContentTypes</key>    <array><string>public.plain-text</string></array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>Lazy Print</string>
            <key>CFBundleURLSchemes</key>    <array><string>lazyprint</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (optional — skipped if generation fails)
if [ ! -f dist/icon_1024.png ] || [ scripts/make_ios_icon.py -nt dist/icon_1024.png ]; then
  mkdir -p dist
  python3 scripts/make_ios_icon.py dist/icon_1024.png || true
fi
if [ -f dist/icon_1024.png ]; then
  echo "==> Building icon…"
  ICONSET=dist/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s dist/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d dist/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && rm -rf "$ICONSET"
fi

echo "==> Signing (ad-hoc)…"
codesign --force --deep -s - "$APP"

echo "==> Done: $APP"
echo "    Launch with:  open \"$APP\""
