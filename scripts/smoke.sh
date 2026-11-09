#!/bin/bash
# scripts/smoke.sh — does the installed app survive being used, and does anything it says stay true?
#
# Why this exists separately from `verify.sh`: the crash of 2026-11-03 (SIGSEGV in a routine-timer
# block) passed the whole gate. The gate runs probes that exit within a second each; the app died on a
# tick 60 seconds later, while it was running for real. **A check that finishes before the thing it is
# checking can fail is not a check.** So this one launches the installed bundle and leaves it alive
# longer than the routine tick — the scheduler's timer block runs every 60 s whether or not anything is
# due, which is the code that crashed — confirms the support folder the schedule lives in, walks every
# read-only probe against the *same process*, and then asks the two questions a user can ask:
# is it still running, and did macOS write a crash report.
#
# It does not arm a reminder or a routine: writing one would leave a real schedule behind in his app
# and speak a line at him mid-test, and the tick crash is in the timer block itself, which fires with
# an empty schedule too. An earlier header claimed it armed fixtures; it never did (AUDIT.md F-04).
#
# It also re-checks the claims that are cheap to lie about — that a probe which says it read nothing
# really changed nothing on disk — because those are the ones that rot quietly.
#
# Usage: ./scripts/smoke.sh [--quick]   (--quick skips the timer-length wait; it will not catch a
#                       tick crash, and it says so in its own output rather than passing anyway.)
set -uo pipefail

APP="${HOME}/Applications/Chunks.app"
BIN="$APP/Contents/MacOS/Chunks"
quick=0
[[ "${1:-}" == "--quick" ]] && quick=1

pass=0; fail=0; skip=0
declare -a failures=()

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); failures+=("$1"); }
note() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip + 1)); }
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [[ ! -x "$BIN" ]]; then
  printf 'smoke: no installed bundle at %s — run ./scripts/make-app.sh && ./scripts/install.sh\n' "$APP"
  exit 2
fi

crash_dir="$HOME/Library/Logs/DiagnosticReports"
crash_before=$(ls "$crash_dir" 2>/dev/null | grep -c '^Chunks-' || true)
nonce="SMOKE-$RANDOM-$(date +%s)"
say "smoke test — nonce $nonce"

# ---------------------------------------------------------------- the app, running
say "the installed app, left running"
pkill -x Chunks 2>/dev/null; sleep 1
open "$APP" --args --show-hud
sleep 4
pid=$(pgrep -x Chunks | head -1)
if [[ -z "$pid" ]]; then
  bad "the app did not start from the installed bundle"
  printf 'smoke: nothing to test — %s did not launch\n' "$APP"
  exit 1
fi
ok "started, pid $pid"

# Confirm the folder the schedule lives in exists. Nothing is armed here on purpose (see the header):
# the tick's timer block runs with an empty schedule too, and writing a fixture would leave a real
# reminder behind and speak a line at him mid-test.
arm_dir="$HOME/Library/Application Support/Chunks"
if [[ -d "$arm_dir" ]]; then
  ok "the app's own support folder is where the schedule lives"
else
  note "no support folder yet — the first turn creates it, so nothing was armed for the tick"
fi

# The tick is 60 s. Waiting past it is the entire point of this script: every probe below would pass
# against a process that dies at 01:00, and the crash of 2026-11-03 was a process that died at 01:00.
if [[ $quick -eq 1 ]]; then
  note "--quick: not waiting out the routine tick — this run cannot catch a timer crash, and says so"
else
  printf '  …  waiting 75 s so the routine scheduler ticks at least once while the app is running\n'
  sleep 75
  if pgrep -x Chunks >/dev/null; then
    ok "still alive 75 s in, past a scheduler tick"
  else
    bad "the app DIED while idle — this is the class of failure the gate cannot see"
  fi
fi

# ---------------------------------------------------------------- the read-only probes, on that process
say "every read-only probe, against the installed bundle"
run_probe() {
  local label="$1"; shift
  local out status
  out=$("$@" 2>&1); status=$?
  if pgrep -x Chunks >/dev/null; then
    :
  else
    bad "$label killed the running app"
    return
  fi
  if [[ $status -eq 0 ]]; then
    ok "$label"
  elif [[ $status -eq 3 ]]; then
    note "$label — declined to run (asleep, locked, or the fixture is not present)"
  else
    bad "$label (exit $status)"
    printf '        %s\n' "$(printf '%s' "$out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fi
}

run_probe "geometry: where a move would land"        "$BIN" --probe-geometry "Qoder|Qoder|left"
run_probe "windows: enumeration and the verb cards"  "$BIN" --probe-windows
run_probe "reveal: a folder resolves, a secret does not" "$BIN" --probe-reveal "$PWD"
run_probe "open a file: the five answers apart"      "$BIN" --probe-open "TextEdit|no-such-file-xyz.md"
run_probe "voice answers: yes, no, and neither"      "$BIN" --probe-voice-answer
run_probe "notebook: the tier's rules on a copy"     "$BIN" --probe-notebook "the landlord"
run_probe "reply audit: the fixture table"           "$BIN" --probe-reply
run_probe "find: a sentence names a file"            "$BIN" --probe-find "read the invoice pdf"
run_probe "mic: what opening the input costs"        "$BIN" --probe-mic
run_probe "awake: the sleep policy's verdict"        "$BIN" --probe-awake
run_probe "caption: drawn offscreen"                 "$BIN" --render-caption /tmp/smoke-caption.png

# ---------------------------------------------------------------- the claims that are cheap to fake
say "the claims a probe could quietly stop honouring"
# A probe that reads must not write. Measured twice now: once when `--probe-local` switched the brain,
# and once when a probe's own output was trusted without checking. Both are the same failure.
settings_hash_before=$(md5 -q "$HOME/Library/Preferences/app.chunks.mac.plist" 2>/dev/null || echo none)
"$BIN" --probe-windows >/dev/null 2>&1
"$BIN" --probe-mic >/dev/null 2>&1
settings_hash_after=$(md5 -q "$HOME/Library/Preferences/app.chunks.mac.plist" 2>/dev/null || echo none)
if [[ "$settings_hash_before" == "$settings_hash_after" ]]; then
  ok "two read-only probes left his settings byte-identical"
else
  bad "a read-only probe WROTE his settings — the 2026-11-02 bug is back"
fi

# A caption render that draws nothing is the failure this script was written the day after: a plausible
# file with no picture in it. Size alone is not evidence, but a blank canvas is a specific size band.
cap_bytes=$(stat -f%z /tmp/smoke-caption.png 2>/dev/null || echo 0)
if [[ $cap_bytes -gt 150000 ]]; then
  ok "the caption render has content in it ($((cap_bytes / 1024)) KB)"
elif [[ $cap_bytes -gt 0 ]]; then
  bad "the caption rendered near-empty ($cap_bytes bytes) — a byte count is not a picture"
else
  note "no caption file to measure"
fi

# ---------------------------------------------------------------- the crash question, asked last
say "did macOS write a crash report?"
sleep 2
crash_after=$(ls "$crash_dir" 2>/dev/null | grep -c '^Chunks-' || true)
new_crashes=$((crash_after - crash_before))
if [[ $new_crashes -gt 0 ]]; then
  newest=$(ls -t "$crash_dir"/Chunks-*.ips 2>/dev/null | head -1)
  bad "$new_crashes new crash report(s) — newest: $(basename "$newest")"
  printf '        %s\n' "$(grep -o '"signal":"[^"]*"' "$newest" 2>/dev/null | head -1)"
else
  ok "no new crash report since the run started ($crash_before total, unchanged)"
fi

if pgrep -x Chunks >/dev/null; then
  ok "the app is still running at the end of the script — it can be tested by hand next"
else
  bad "the app was gone by the end of the run"
fi

printf '\n----------------------------------------\n'
if [[ $fail -eq 0 ]]; then
  printf 'smoke: %d passed, %d skipped, nothing failed (nonce %s)\n' "$pass" "$skip" "$nonce"
  exit 0
fi
printf 'smoke: %d passed, %d FAILED, %d skipped (nonce %s)\n' "$pass" "$fail" "$skip" "$nonce"
for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
exit 1
