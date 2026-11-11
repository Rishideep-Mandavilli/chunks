#!/bin/bash
# Registers the Chunks Chrome bridge: writes the native-messaging host manifest for the installed
# app and prints the one manual step (loading the unpacked extension). Local-only; no network.
set -euo pipefail

BIN="$HOME/Applications/Chunks.app/Contents/MacOS/Chunks"
if [[ ! -x "$BIN" ]]; then
  echo "Chunks is not installed at $BIN — run ./scripts/make-app.sh && ./scripts/install.sh first." >&2
  exit 1
fi

EXT_DIR="$(cd "$(dirname "$0")/../Extension" && pwd)"
KEY=$(python3 -c "import json,sys;print(json.load(open('$EXT_DIR/manifest.json'))['key'])")

# The extension id is the first 16 bytes of the SHA-256 of the DER public key, each hex nibble
# mapped 0-f -> a-p. Computing it here keeps allowed_origins in step with the manifest's fixed key.
ID=$(printf '%s' "$KEY" | base64 -d 2>/dev/null | openssl dgst -sha256 -binary | head -c 16 | od -An -tx1 | tr -d ' \n' | tr '0-9a-f' 'a-p')
ORIGIN="chrome-extension://$ID/"

write_host() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/com.chunks.bridge.json" <<EOF
{
  "name": "com.chunks.bridge",
  "description": "Chunks local web bridge",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["$ORIGIN"]
}
EOF
  echo "wrote $dir/com.chunks.bridge.json"
}

write_host "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
write_host "$HOME/Library/Application Support/Chromium/NativeMessagingHosts"
write_host "$HOME/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
write_host "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"

echo
echo "Extension id: $ID"
echo "Now load the extension (one time):"
echo "  1. Open chrome://extensions in Chrome."
echo "  2. Turn on 'Developer mode' (top right)."
echo "  3. Click 'Load unpacked' and choose: $EXT_DIR"
echo "  4. Keep Chrome open; the bridge connects automatically."
echo "Then ask Chunks a web task, e.g. 'open youtube, search comedy scenes, play the first video'."