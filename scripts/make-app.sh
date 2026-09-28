#!/bin/bash
# Assemble Chunks.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary. A menu-bar app needs a bundle with an
# Info.plist (LSUIElement for no Dock tile, plus the usage descriptions macOS
# reads before it will prompt) and, for the capture and accessibility work, an
# ad-hoc signature.
#
# Usage:  swift build -c release && ./scripts/make-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Chunks.app"

if [ "$CONFIG" = "release" ]; then
  BIN_DIR=".build/release"
else
  BIN_DIR=".build/debug"
fi

if [ ! -f "$BIN_DIR/chunks" ]; then
  echo "error: $BIN_DIR/chunks not found — run 'swift build -c $CONFIG' first" >&2
  exit 1
fi

echo "==> Assembling $APP"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_DIR/chunks" "$APP/Contents/MacOS/Chunks"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Chunks</string>
    <key>CFBundleDisplayName</key>           <string>Chunks</string>
    <key>CFBundleExecutable</key>            <string>Chunks</string>
    <key>CFBundleIdentifier</key>            <string>app.chunks.mac</string>
    <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>LSMinimumSystemVersion</key>        <string>14.2</string>

    <!-- Menu-bar only: no Dock tile, no app switcher entry. -->
    <key>LSUIElement</key>                   <true/>

    <!-- Screen Recording. macOS requires the app to be relaunched after the user
         grants this, which the UI states rather than pretending otherwise. -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>Chunks reads your screen only when you ask, so it can explain what you are looking at.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Chunks listens only while you hold the talk hotkey, so you can ask about your screen by voice.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Chunks transcribes your voice locally so you can ask about your screen by voice.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Chunks reads a document you point it at, so it can explain the open file.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Chunks reads a document you point it at, so it can explain the open file.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Chunks reads a document you point it at, so it can explain the open file.</string>

    <!-- Needed to read the Accessibility tree for computer-use actions (Phase 5). -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Chunks controls apps on your behalf, only after you confirm each action.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough for local running; distribution would need a Developer ID
# plus notarisation, which is a Phase-6 concern.
codesign --force --deep --sign - "$APP" 2>/dev/null || {
  echo "warning: ad-hoc codesign failed; the app will still run locally" >&2
}

echo "==> Built $APP"
echo "    open $APP   # then grant Screen Recording + Accessibility when prompted"
