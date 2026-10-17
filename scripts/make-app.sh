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

# Staged outside the repo on purpose. This project lives under ~/Documents, which iCloud syncs,
# and a bundle rewritten in place inside a synced folder gets conflict copies — `Chunks 2.app`,
# `Chunks 3.app` and so on. Each one is a real `.app` with `CFBundleIdentifier = app.chunks.mac`,
# so LaunchServices registers it, and seven copies of Chunks ended up in the app switcher next to
# the one installed app. `install.sh` reads the same path.
APP="${CHUNKS_STAGING_DIR:-$HOME/.chunks-build}/Chunks.app"

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

    <!-- Push-to-talk. macOS requires the app to be relaunched after the user
         grants this, which the UI states rather than pretending otherwise. -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>Chunks reads your screen only when you ask, so it can explain what you are looking at.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Chunks listens only while you hold the talk hotkey, so you can ask about your screen by voice. Transcription happens on your Mac.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Chunks transcribes your voice locally so you can ask about your screen by voice. Audio is not sent anywhere.</string>

    <!-- The push-to-talk shortcut is a system-wide event tap. Chunks installs a
         listen-only tap, so this is for seeing the key, never for altering what other
         apps receive. -->
    <key>NSInputMonitoringUsageDescription</key>
    <string>Chunks listens for the hold-to-talk shortcut while you work in other apps. It reads only that key and never records what you type.</string>

    <!-- Needed to read the Accessibility tree for computer-use actions (Phase 5). -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Chunks controls apps on your behalf, only after you confirm each action.</string>
</dict>
</plist>
PLIST

# Code signature. Ad-hoc (`-`) is fine for a throwaway run but is the reason Screen Recording
# grants keep appearing to "not stick": TCC identifies the app by its signature, and an ad-hoc
# signature is its cdhash — so every rebuild is, as far as Privacy settings is concerned, a
# brand-new app. The same rule is what makes the *Keychain* forget the API key: a generic
# password's ACL names the app that wrote it, so an ad-hoc build reads as a different app and
# the stored key becomes invisible to the next one. So the default is the local identity when
# it exists, and falling back to ad-hoc is opt-in (`CHUNKS_SIGN_IDENTITY=-`) rather than the
# accident that costs the user their grants and their key.
if [ -z "${CHUNKS_SIGN_IDENTITY:-}" ]; then
  # `find-identity -v` hides this identity because the self-signed certificate is not trusted
  # by any anchor (CSSMERR_TP_NOT_TRUSTED), and yet `codesign` uses it happily — which is what
  # a stable signature needs. So list *all* codesigning identities and match the name.
  if security find-identity -p codesigning 2>/dev/null | grep -q '"Chunks Local"'; then
    CHUNKS_SIGN_IDENTITY="Chunks Local"
  else
    CHUNKS_SIGN_IDENTITY="-"
  fi
fi
SIGN_IDENTITY="$CHUNKS_SIGN_IDENTITY"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "note: ad-hoc signing — a rebuild invalidates both Screen Recording grants and the stored API key" >&2
fi
# Strip Finder metadata before sealing. This project lives under ~/Documents, which iCloud syncs,
# and the file provider stamps `com.apple.FinderInfo` onto the bundle folder — a bundle carrying
# it fails to sign at all ("resource fork, Finder information, or similar detritus not allowed"),
# and an app that does not verify is an app TCC will not match to the grant the user already
# ticked. The stamp comes back within milliseconds, so one clear is a race: clear, seal, verify,
# and repeat. A build that never verifies is still installable — `install.sh` re-seals the copy it
# makes outside the synced folder — but it is the ad-hoc signature that costs the grants and the
# stored API key, so failing loudly here is the point.
SEALED=0
for _ in 1 2 3; do
  xattr -cr "$APP" 2>/dev/null || true
  if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 \
     && codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    SEALED=1
    break
  fi
done
if [ "$SEALED" != 1 ]; then
  echo "warning: could not seal $APP with '$SIGN_IDENTITY' (iCloud keeps stamping the bundle) — install.sh will try again at the destination" >&2
fi

echo "==> Built $APP"
echo
echo "    open $APP"
echo

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "  IMPORTANT - Screen Recording"
  echo "    macOS keys the Screen Recording grant to the app's CODE SIGNATURE."
  echo "    This build is ad-hoc, so its identity is its cdhash: a grant made"
  echo "    against the previous build stops applying, and the Keychain hides the"
  echo "    stored API key. Re-grant in System Settings > Privacy & Security >"
  echo "    Screen Recording, then QUIT AND REOPEN Chunks."
  echo
  echo "    If Chunks is listed but still cannot see your screen, remove it from"
  echo "    that list and add it again with +."
  echo
  echo "    To stop paying this cost every rebuild: create the \"Chunks Local\""
  echo "    self-signed code-signing certificate (see scripts/install.sh)."
else
  echo "  Screen Recording: this build is signed as \"$SIGN_IDENTITY\", so the grant the"
  echo "    user already ticked — and the API key already stored — apply to it by name"
  echo "    instead of by cdhash. Nothing needs re-granting after the next rebuild."
fi
echo
echo "    Chunks shows an orange triangle in the menu bar and an on-screen"
echo "    card explaining a missing grant."
echo
echo "    To check without the UI:  $APP/Contents/MacOS/Chunks --self-test"
