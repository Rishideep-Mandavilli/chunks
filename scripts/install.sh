#!/bin/bash
# Install Chunks.app to one fixed path, so a permission grant can actually stick.
#
# Why this script exists at all. macOS identifies an app in Privacy settings by its *code
# signature*, not its name, and SwiftPM leaves the bundle wherever the last build happened to
# put it — `.build/debug`, Xcode's DerivedData, a fresh checkout. Each of those is a different
# app to TCC, so the list fills with stale "Chunks" rows and the one you just ticked is not the
# one the running binary is checked against. Symptom: the grant is given, the app still says
# it is missing.
#
# Three things fix it, and this script does the first two:
#   1. one install path, forever          -> ~/Applications/Chunks.app (here)
#   2. one signature, forever             -> "Chunks Local", found automatically below
#   3. a relaunch after every grant       -> macOS never tells a running process
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SRC="build/Chunks.app"
APP_DEST="$HOME/Applications/Chunks.app"

if [ ! -d "$APP_SRC" ]; then
  echo "error: $APP_SRC not found — run 'swift build && ./scripts/make-app.sh' first" >&2
  exit 1
fi

# A running app cannot see a new grant, and two copies of Chunks fight over the same hotkey.
pkill -x Chunks 2>/dev/null || true

mkdir -p "$HOME/Applications"
if [ -e "$APP_DEST" ]; then
  # Move the previous install aside rather than deleting it: macOS may already trust that
  # exact signature, and it is cheaper to look it up again than to re-earn the grant.
  mv "$APP_DEST" "$APP_DEST.previous-$(date +%Y%m%d-%H%M%S)"
fi

ditto "$APP_SRC" "$APP_DEST"
# ditto preserves the source's extended attributes, and a bundle carrying Finder metadata fails
# `codesign --verify` — which is the difference between TCC seeing "the app you granted yesterday"
# and seeing an unknown app with an empty checkbox.
xattr -cr "$APP_DEST" 2>/dev/null || true

# Re-seal here if the source could not be sealed. This project lives under ~/Documents, which
# iCloud's file provider stamps with `com.apple.FinderInfo` the moment a bundle appears, and
# `codesign` refuses to sign a bundle with a resource fork — so `make-app.sh` can try three
# times and still leave an ad-hoc build. ~/Applications is not synced, so the same seal made
# *here* sticks, and this is the last place the signature can still be chosen.
if ! codesign --verify --deep --strict "$APP_DEST" >/dev/null 2>&1 \
   || codesign -d --verbose=2 "$APP_DEST" 2>&1 | grep -q "Signature=adhoc"; then
  IDENTITY="${CHUNKS_SIGN_IDENTITY:-}"
  if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Chunks Local"'; then
    IDENTITY="Chunks Local"
  fi
  if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    xattr -cr "$APP_DEST" 2>/dev/null || true
    if codesign --force --deep --sign "$IDENTITY" "$APP_DEST" >/dev/null 2>&1 \
       && codesign --verify --deep --strict "$APP_DEST" >/dev/null 2>&1; then
      echo "    re-sealed here as \"$IDENTITY\" (the repo is iCloud-synced and refuses the seal)"
    else
      echo "warning: could not seal the installed bundle with '$IDENTITY' — permissions will not stick" >&2
    fi
  else
    echo "warning: no signing identity available, so the installed bundle stays ad-hoc — permissions will not stick" >&2
  fi
fi

if ! codesign --verify --deep --strict "$APP_DEST" >/dev/null 2>&1; then
  echo "warning: the installed bundle does not verify — permissions will not stick" >&2
fi
echo "==> installed $APP_DEST"

# Judge the bundle on disk, not the environment: `make-app.sh` now finds "Chunks Local" by
# itself, so the honest statement about a build is the one read off its signature.
if codesign -d --verbose=2 "$APP_DEST" 2>&1 | grep -q "Signature=adhoc"; then
  cat <<'TXT'

  WARNING: this build is ad-hoc signed, so its identity is its cdhash and the next
  `make-app.sh` will produce a different app as far as Privacy settings is concerned —
  and the Keychain will stop showing the stored API key, whose ACL names the app that wrote it.
  To make grants survive rebuilds, create one local signing certificate and use it always:

    Keychain Access > Certificate Assistant > Create a Certificate
      Name: Chunks Local | Identity Type: Self Signed Root | Certificate Type: Code Signing
    then, for every build and install:
      ./scripts/make-app.sh && ./scripts/install.sh
    and once, to clear every stale row this project has left behind:
      tccutil reset ScreenCapture app.chunks.mac
      tccutil reset Accessibility app.chunks.mac

TXT
else
  # `codesign -d` exits non-zero while printing a perfectly good description, and this script
  # runs under `pipefail` — so without the `|| true` this line would abort the install halfway
  # and the advice below it would never be printed.
  # Two things go wrong on this line if it is not written carefully: `codesign -d` puts its
  # description on stderr and exits non-zero, and awk's `exit` closes the pipe early, which
  # makes codesign die of SIGPIPE. Under this script's `pipefail` either one would abort the
  # install mid-advice, so both are tolerated and the value is allowed to come out blank.
  AUTHORITY=$(codesign -d --verbose=2 "$APP_DEST" 2>&1 \
              | awk -F'=' '/^Authority/ {found=$2} END {print found}' || true)
  echo "    signed as \"${AUTHORITY:-a stable identity}\" — grants and the stored API key survive rebuilds"
fi

cat <<TXT
  Next:
    open "$APP_DEST"                          # normal run (needs the grants)
    pkill -x Chunks; open "$APP_DEST" --args --show-hud   # notch card, no permissions needed

  After ticking anything in System Settings > Privacy & Security, quit and reopen:
    pkill -x Chunks && open "$APP_DEST"
TXT
