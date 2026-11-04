#!/bin/bash
# Every check Chunks can make without a human at the keyboard.
#
# This exists because a feature was once added that made the rest of the app unusable and the unit
# suite stayed green — the tests covered the arithmetic, not the wiring. So this runs the suite AND
# every read-only probe against the real machine AND re-renders every surface, and it fails loudly
# when any of them stops working. Run it before declaring anything done.
#
# The probes are the developer's harness, not the user's workflow: nothing here presses anything,
# sends a request, or needs a permission the shell does not already have.
set -u
cd "$(dirname "$0")/.."

# The signed bundle, not `.build/debug`: macOS grants Screen Recording and the Keychain by
# signature, so a probe run from the bare binary reports a machine that is not this machine.
APP="${CHUNKS_BINARY:-$HOME/Applications/Chunks.app/Contents/MacOS/Chunks}"
if [[ ! -x "$APP" || "$APP" != *.app/Contents/MacOS/* ]]; then
  printf 'error: install the signed app with ./scripts/make-app.sh && ./scripts/install.sh first\n' >&2
  exit 1
fi
BIN="$APP"
# The crash probe deliberately faults, so it runs against the debug binary rather than $BIN.
DEV_BIN=".build/debug/chunks"
export CHUNKS_DEV=1
RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chunks-verify.XXXXXX")" || exit 1
printf 'render artifacts: %s\n' "$RENDER_DIR"

pass=0; fail=0; skip=0
declare -a failures=()

# check <label> <command…> — a step passes when it exits 0 and wrote something to stdout.
# Exit 3 means "this machine is fine, the service is not" — the self-test uses it when the free
# tier is refusing requests. Counted as a skip, because a red line for something nobody changed
# teaches everyone to ignore the red lines.
check() {
  local label="$1"; shift
  local out status
  out="$( { "$@" ; } 2>&1 )"; status=$?
  if [[ $status -eq 0 && -n "$out" ]]; then
    printf '  \033[32mPASS\033[0m  %s\n' "$label"
    pass=$((pass + 1))
  elif [[ $status -eq 3 ]]; then
    printf '  \033[33mSKIP\033[0m  %s  — %s\n' "$label" \
      "$(printf '%s' "$out" | grep -o 'SKIP:.*' | head -1 | cut -c7-)"
    skip=$((skip + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s  (exit %d)\n' "$label" "$status"
    printf '        %s\n' "$(printf '%s' "$out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
    fail=$((fail + 1)); failures+=("$label")
  fi
}

# file <label> <path> — a render passes when the PNG exists and is big enough to hold real content.
file_check() {
  local label="$1" path="$2" minimum="${3:-20000}"
  if [[ -f "$path" ]] && [[ $(stat -f%z "$path") -ge $minimum ]]; then
    printf '  \033[32mPASS\033[0m  %s  (%s KB)\n' "$label" "$(( $(stat -f%z "$path") / 1024 ))"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s  — missing or empty: %s\n' "$label" "$path"
    fail=$((fail + 1)); failures+=("$label")
  fi
}

echo "Chunks — full verification"
echo "binary: $BIN"
echo

echo "build"
check "swift build is clean" swift build
expected_fingerprint="$(python3 scripts/build-fingerprint.py)" || exit 1
installed_fingerprint=""
IFS= read -r installed_fingerprint < "$(dirname "$BIN")/../Resources/BuildInputs.sha256" || true
if [[ "$installed_fingerprint" != "$expected_fingerprint" ]]; then
  printf 'error: the installed app does not match the source; run ./scripts/make-app.sh && ./scripts/install.sh\n' >&2
  exit 1
fi
echo

echo "unit tests"
out="$(swift run chunks-test 2>&1)"; status=$?
line="$(printf '%s' "$out" | grep -E '^[0-9]+/[0-9]+ passed' | tail -1)"
if [[ $status -eq 0 && -n "$line" ]]; then
  printf '  \033[32mPASS\033[0m  %s\n' "$line"
  printf '%s\n' "$out" | grep '⊘' || true
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "${line:-the suite failed}"
  printf '%s\n' "$out" | grep '✗' | head -10 | sed 's/^/        /'
  fail=$((fail + 1)); failures+=("unit tests")
fi
echo

echo "the real machine, read-only"
check "self-test: what this build can see"           "$BIN" --self-test
check "hit test: a point resolves to a control"      "$BIN" --probe-ax 900,120
check "hit test: the name fallback finds it too"     "$BIN" --probe-ax 900,120 --named "address bar"
# The draw-and-speak crop aim, checked as arithmetic on the real binary: the region's own rect is
# flipped into AppKit space, the aim is mapped inside it, and the result is flipped back — so the
# centre of a region at (0,0 1200x700) must land at (600, 350) whatever the display's height. This
# is the wiring the unit tests cannot see: a crop aimed as a fraction of the whole display would
# still print a plausible point, and press something else.
crop_out="$("$BIN" --probe-crop '0,0,1200,700|500,500' 2>&1)"
if printf '%s' "$crop_out" | grep -q "→ (600.0, 350.0)" \
   && printf '%s' "$crop_out" | grep -q "probe-ax: point="; then
  printf '  \033[32mPASS\033[0m  crop aim: a region maps back to its own place\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  crop aim: the region did not map to its centre\n'
  printf '        %s\n' "$(printf '%s' "$crop_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("crop aim mapping")
fi
check "semantic aim: a named control, no pixel"      "$BIN" --probe-semantic 'app=Finder name="Macintosh HD"'
# The ranking route, which exists because a name search reads what a control publishes about itself
# and most web controls publish nothing. Which controls are on screen depends on what he has open, so
# this asserts the two halves that must always hold: a name that cannot exist is refused out loud
# rather than answered with the nearest thing, and a name that does exist reaches a card sentence
# through the same door a press goes through. A browser has to be open for it to mean anything, and
# when none is the run says SKIP rather than agreeing that the route works.
browser=""
for candidate_app in "Google Chrome" Safari Firefox "Mozilla Firefox" Microsoft\ Edge Arc Brave; do
  if pgrep -x "$candidate_app" >/dev/null 2>&1; then browser="$candidate_app"; break; fi
done
if [ -n "$browser" ]; then
  # The name is read out of what the app publishes right now rather than typed into this script, for
  # the standing reason: a check that names `Reload` passed all afternoon and then failed when the
  # window moved down the screen and the walk found no pressable control to aim at at all.
  ctrl_out="$("$BIN" --probe-controls "$browser" 2>&1)"
  target_name="$(printf '%s' "$ctrl_out" \
    | grep -vE "AXMenuBarItem|AXMenuItem" \
    | grep -oE 'title="[^"]{4,40}"' | head -1 | sed 's/^title="//; s/"$//')"
  nonsense_out="$("$BIN" --probe-candidates "app=$browser name=zzqxvt" 2>&1)"
  # How many things the ranking could see at all, read out of the same walk the press uses. When it is
  # zero the check below proves nothing about web content, and saying "published no named control"
  # would blame the app for what is actually the window walk reaching nothing inside the veto — the
  # measured case on 2026-10-31: `--probe-controls` printed 198 pressable controls for Chrome and the
  # ranking collected 0 inside `(0.0, 156.0, 1710.0, 951.0)`, with the budget spent on browser chrome.
  ranked_count="$(printf '%s' "$nonsense_out" | grep -oE ': [0-9]+ pressable control' | grep -oE '[0-9]+' | head -1)"
  if [ -z "$target_name" ]; then
    printf '  \033[33mSKIP\033[0m  candidates: %s published no named control inside the window the ' \
           "$browser"
    printf 'ranking can reach (it saw %s pressable candidate(s))\n' "${ranked_count:-0}"
    skip=$((skip + 1))
  elif printf '%s' "$nonsense_out" | grep -q "refused —" \
     && "$BIN" --probe-candidates "app=$browser name=$target_name" 2>&1 \
        | grep -q "card would ask \"Press"; then
    printf '  \033[32mPASS\033[0m  candidates: a guess is asked about, a near miss is refused\n'
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  candidates: "%s" was not resolved, or an impossible name was not refused\n' "$target_name"
    printf '        %s\n' "$(printf '%s' "$nonsense_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
    fail=$((fail + 1)); failures+=("candidate ranking in $browser")
  fi
else
  printf '  \033[33mSKIP\033[0m  candidates: no browser open, so no web content to rank\n'
  skip=$((skip + 1))
fi
# The reveal tool's two halves: a name resolves to one real folder on this disk, and a credential
# folder is refused before a card is ever built. The second is a contract, not a behaviour test —
# showing `~/.ssh` on screen is a leak even when nothing is read from it.
reveal_out="$("$BIN" --probe-reveal "$PWD" 2>&1)"
secret_out="$("$BIN" --probe-reveal '~/.ssh' 2>&1)"
if printf '%s' "$reveal_out" | grep -q "one match" \
   && printf '%s' "$secret_out" | grep -q "refused — secret"; then
  printf '  \033[32mPASS\033[0m  reveal: a folder resolves, a credential store is refused\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  reveal: the name search or the credential refusal changed\n'
  printf '        %s\n' "$(printf '%s\n%s' "$reveal_out" "$secret_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("reveal tool")
fi
check "fields: what an app publishes to the typist"  "$BIN" --probe-fields Finder

# Answering the card by voice. The fixture table is the check, and the interesting rows are the ones
# that must NOT answer: "yes and close the other tab" is a new request with an old card hanging off it,
# and reading it as consent is the false yes this feature's whole design exists to avoid.
check "voice answers the card: yes, no, and a sentence that is neither" "$BIN" --probe-voice-answer

# Opening a file in a named app: five answers, and the gate asserts all five stay distinguishable.
# This verb puts a document on screen inside another application, so "that file holds credentials" is a
# security rule while "there is no file called X" is his own typo — and a card that says the second
# about the first sends him re-typing a path he already wrote correctly. The app is chosen by asking
# the probe which names resolve on *this* machine, never typed here, because three of his apps contain
# "code" and `open_file_with:Code|…` is honestly ambiguous.
open_app=""
for candidate in TextEdit Safari Music; do
  if "$BIN" --probe-open "$candidate|$PWD/AGENTS.md" 2>&1 | grep -q "installed=true"; then
    open_app="$candidate"; break
  fi
done
if [[ -z "$open_app" ]]; then
  printf '  \033[33mSKIP\033[0m  open a file: no app on this machine answers to a unique name\n'
  skip=$((skip + 1))
else
  open_out="$("$BIN" --probe-open "$open_app|$PWD/AGENTS.md" 2>&1)"
  secret_out="$("$BIN" --probe-open "$open_app|~/.ssh/id_rsa" 2>&1)"
  outside_out="$("$BIN" --probe-open "$open_app|/etc/hosts" 2>&1)"
  missing_out="$("$BIN" --probe-open "$open_app|no-such-file-here-xyz.md" 2>&1)"
  noapp_out="$("$BIN" --probe-open "NoSuchAppHere|$PWD/AGENTS.md" 2>&1)"
  parse_out="$("$BIN" --probe-open "$open_app|" 2>&1)"; parse_status=$?
  if printf '%s' "$open_out" | grep -q "one match" \
     && printf '%s' "$open_out" | grep -q "the card would ask" \
     && printf '%s' "$open_out" | grep -q "asks even with the switch off? no" \
     && printf '%s' "$secret_out" | grep -q "refused — That file holds credentials" \
     && printf '%s' "$outside_out" | grep -q "refused — That path is outside the folders" \
     && printf '%s' "$missing_out" | grep -q "refused — There is no file called no-such-file-here-xyz" \
     && printf '%s' "$noapp_out" | grep -q "refused — NoSuchAppHere is not installed" \
     && [[ $parse_status -eq 1 ]] && printf '%s' "$parse_out" | grep -q "refused at parse"; then
    printf '  \033[32mPASS\033[0m  open a file: one card, and four refusals that each name their own reason\n'
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  open a file: the five verdicts are no longer distinguishable\n'
    printf '        %s\n' "$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$open_out" "$secret_out" \
        "$outside_out" "$missing_out" "$noapp_out" "$parse_out" | grep -v 'roots:' | grep -vE '^\s*$' | tail -4 | tr '\n' '|')"
    fail=$((fail + 1)); failures+=("open a file policy")
  fi
fi

# The window verbs, read-only: enumeration, the card's wording for each, and the contract that closing
# and quitting stay asked about even with asking switched off. It performs nothing — the verbs are
# printed as questions — so this can run against his real screen.
check "windows: what Chunks can see, and what each verb would ask" "$BIN" --probe-windows

# Geometry, read-only. Moving a window is the one act in this app that writes a rectangle, and every
# coordinate bug this repo has hit produced a plausible number rather than an error — so the check asks
# the probe for a rectangle on his real display and asserts three things it can actually fail: the frame
# lands inside the usable area, a coordinate is refused at parse (never clamped), and a display that is
# not plugged in is refused rather than rounded to the one that is. The window is taken from the
# enumeration above rather than typed, so the check cannot pass because a fixture happened to exist.
# The desktop is enumerated as a window and is not one, so it is filtered before the pick: taking the
# first line blindly meant this check skipped whenever the desktop happened to be the only thing the
# frontmost-app enumeration published.
#
# And a window Chunks cannot reach is filtered too, because a move genuinely refuses it — that is the
# correct answer, not a failure. The first version of this check picked the first line of the listing,
# landed on an app on another Space, and reported the product as broken for behaving as designed. A
# check that fails when the code is right is worse than no check: it teaches whoever reads it next to
# distrust the gate.
first_window="$("$BIN" --probe-windows 2>&1 | grep -E '^  [A-Za-z]' | grep '"' \
  | grep -v '"desktop"' | grep -v 'out of reach' | head -1)"
# The app name is padded with spaces and may itself contain spaces ("Google Chrome"), so it is cut by
# the position of the first quote rather than by whitespace.
geom_app="$(printf '%s' "$first_window" \
  | awk '{i=index($0,"\""); s=substr($0,3,i-3); sub(/[ ]+$/,"",s); print s}')"
geom_title="$(printf '%s' "$first_window" | sed -E 's/.*"([^"]*)".*/\1/')"
if [[ -z "$geom_app" || -z "$geom_title" || "$geom_title" == "desktop" ]]; then
  printf '  \033[33mSKIP\033[0m  geometry: no real window on screen to place (the desktop is not one)\n'
  skip=$((skip + 1))
else
  geom_out="$("$BIN" --probe-geometry "$geom_app|$geom_title|left" 2>&1)"
  pixel_out="$("$BIN" --probe-geometry "$geom_app|$geom_title|400,220" 2>&1)"; pixel_status=$?
  # `display=3` is inside the grammar's cap and outside this Mac's one screen, so it reaches the runtime
  # answer. `display=9` is past the cap and is refused at parse — two different doors, and a check that
  # only walked one would not notice the other closing.
  nodisplay_out="$("$BIN" --probe-geometry "$geom_app|$geom_title|display=3" 2>&1)"
  overcap_out="$("$BIN" --probe-geometry "$geom_app|$geom_title|display=9" 2>&1)"; overcap_status=$?
  if printf '%s' "$geom_out" | grep -q "would write" \
     && printf '%s' "$geom_out" | grep -q "geometry: PASS" \
     && [[ $pixel_status -eq 1 ]] && printf '%s' "$pixel_out" | grep -q "refused at parse" \
     && [[ $overcap_status -eq 1 ]] && printf '%s' "$overcap_out" | grep -q "refused at parse" \
     && printf '%s' "$nodisplay_out" | grep -q "There is no display 3"; then
    printf '  \033[32mPASS\033[0m  geometry: a named place lands inside the display, a pixel never parses\n'
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  geometry: the rectangle, the pixel refusal or the missing display changed\n'
    printf '        %s\n' "$(printf '%s\n%s\n%s\n%s' "$geom_out" "$pixel_out" "$nodisplay_out" \
        "$overcap_out" | grep -vE '^\s*$|Built-in Retina|display\(s\)' | tail -4 | tr '\n' '|')"
    fail=$((fail + 1)); failures+=("window geometry")
  fi
fi
# The command tool's executor, run with two fixed programs the harness chooses — never an argument,
# because a flag that ran whatever it was handed is the door the parser exists to close.
cmd_out="$("$BIN" --probe-command 2>&1)"
# Three states, and the third is the one that matters: `caffeinate -u -t 5` is *meant* to still be
# running when Chunks stops watching, and until 2026-10-31 the probe reported it as "finished" — the
# same word `date` gets. A check that asserted only the first two lines let a card tell the user his
# six-hour sleep hold had already ended.
if printf '%s' "$cmd_out" | grep -q "date — finished · [1-9]" \
   && printf '%s' "$cmd_out" | grep -q "true — finished · 0 chars" \
   && printf '%s' "$cmd_out" | grep -q "caffeinate -u -t 5 — still running" \
   && printf '%s' "$cmd_out" | grep -q "ToolRunner.run(.runCommand) — executed"; then
  printf '  \033[32mPASS\033[0m  command tool: runs a program, collects output, and knows a hold from a finish\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  command tool: the executor did not report all three outcomes\n'
  printf '        %s\n' "$(printf '%s' "$cmd_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("command tool")
fi
# The reminder tool, against this Mac's actual clock. A unit case checks `at 21:00` against a fixed
# calendar; only this run checks it against the hour the machine is really at, which is where the
# first version was wrong (a 40-minute reminder reported itself as "in 39 min"). The spoken form
# is matched as either shape on purpose: armed at 23:30, "in 40 min" *is* "tomorrow at 00:10", and
# a check that only passes before midnight is a fixture bug, not a regression — learned at 23:57
# on 2026-10-28 when this line went red for no other reason than the hour.
remind_out="$("$BIN" --probe-remind 'remind:stretch|40 min' 2>&1)"
remind_seconds="$("$BIN" --probe-remind 'remind:buy milk|in 30 seconds' 2>&1)"
if printf '%s' "$remind_out" | grep -qF 'Remind "stretch" in 40 min?' \
   && printf '%s' "$remind_out" | grep -qE '· (in [0-9]+ min|tomorrow at [0-9]{2}:[0-9]{2})' \
   && printf '%s' "$remind_out" | grep -q "nothing was armed" \
   && printf '%s' "$remind_seconds" | grep -q "refused at parse"; then
  printf '  \033[32mPASS\033[0m  reminders: the tag parses, the clock agrees, seconds are refused\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  reminders: the tool did not describe its own card\n'
  printf '        %s\n' "$(printf '%s\n%s' "$remind_out" "$remind_seconds" | grep -vE '^\s*$' | tail -3 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("reminder tool")
fi
# The power hold. The decision is a unit case; whether *this* machine takes an `IOPMAssertion` is not,
# and the panel row has to be able to tell "on" from "holding" — so the probe asks, reads the answer
# and releases it in the same breath.
awake_out="$("$BIN" --probe-awake 2>&1)"
if printf '%s' "$awake_out" | grep -q "took the request and it has been released"; then
  printf '  \033[32mPASS\033[0m  power hold: the machine takes the request, and the probe let go of it\n'
  pass=$((pass + 1))
elif printf '%s' "$awake_out" | grep -q "refused (status"; then
  printf '  \033[33mSKIP\033[0m  power hold: this machine refused the assertion — the row must say so\n'
  skip=$((skip + 1))
else
  printf '  \033[31mFAIL\033[0m  power hold: the probe never reported a verdict\n'
  printf '        %s\n' "$(printf '%s' "$awake_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("power hold")
fi
# The two tags a reply can only work with if the model knows them. `--probe-prompt` prints the whole
# instruction the live request carries, so this is the same text, not a copy of it: a prompt edit that
# drops `<DRAFT>` leaves the code intact and the feature dead, which no unit case can see.
prompt_out="$("$BIN" --probe-prompt 'write him a reply' 2>&1)"
if printf '%s' "$prompt_out" | grep -q "<DRAFT>" \
   && printf '%s' "$prompt_out" | grep -q "\[DO:remind:" \
   && printf '%s' "$prompt_out" | grep -q "caffeinate -di" \
   && ! printf '%s' "$prompt_out" | grep -q "caffeinate -u" \
   && ! printf '%s' "$prompt_out" | grep -q "there is no tool yet"; then
  printf '  \033[32mPASS\033[0m  prompt: draft and reminder tags explained, sleep flags are the ones that hold\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  prompt: a supported tag is missing, or the sleep example is back on `-u`\n'
  fail=$((fail + 1)); failures+=("prompt teaches the new tags")
fi
# The whole keyboard (TASKS.md 3.10), and where one key would land. The probe posts nothing: it reads
# the table, the classification and the live focus. This is the only door that can answer that
# question at all, because a keystroke is the one act in this app that leaves no pointer, no control
# name and no pixel behind — an Electron editor publishes no tree to quote, so the target is an app
# plus whatever holds its caret, and he has to be able to see that before he says yes.
check "keyboard: the vocabulary classifies, the refusals hold, the focus is named" \
  "$BIN" --probe-keys Terminal
# The live prompt must carry the keyboard sentence belonging to the switch this machine is *actually*
# under. Both branches are asserted by `--probe-keys`, which reads the function; this reads the spliced
# request, so a prompt built with the wrong half — or with the acting rules dropped — still fails here.
keyboard_line="the whole keyboard is available too"
if printf '%s' "$prompt_out" | grep -q "the user has switched asking off"; then
  keyboard_line="keyboard is NOT available"
fi
if printf '%s' "$prompt_out" | grep -q "$keyboard_line"; then
  printf '  \033[32mPASS\033[0m  prompt: the keyboard sentence matches the asking switch on this machine\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  prompt: missing "%s" for the switch this machine is under\n' "$keyboard_line"
  fail=$((fail + 1)); failures+=("prompt matches the asking switch")
fi
# The memory trust rule, driven through his real `memory.md` in a temporary copy. Both halves must
# hold: an inference may not retire something he said, and his own correction must be able to — the
# second one matters because the file is capped, so a replacement that cannot land makes a full file
# permanently wrong.
memory_out="$("$BIN" --probe-memory 2>&1)"; memory_status=$?
if [[ $memory_status -eq 3 ]]; then
  printf '  \033[33mSKIP\033[0m  memory: %s\n' \
    "$(printf '%s' "$memory_out" | grep -o 'SKIP:.*' | head -1 | cut -c7-)"
  skip=$((skip + 1))
elif printf '%s' "$memory_out" | grep -q "refused, as it must be" \
   && printf '%s' "$memory_out" | grep -q "said by him → replaced"; then
  printf '  \033[32mPASS\033[0m  memory: a guess cannot overwrite what he said, and his own word can\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  memory: the replacement rule did not behave on his real file\n'
  printf '        %s\n' "$(printf '%s' "$memory_out" | grep -vE '^\s*$' | tail -3 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("memory trust rule")
fi
# The named aim must find the app the user is looking at, not a helper whose name merely starts with
# the same word — the ShortcutsViewService refusal of 2026-10-27 that said "no control called
# stop sleep" about a tile on screen. Asserted only when Shortcuts has a *window* open: the process
# keeps running after the window closes, and then there is genuinely nothing to aim at, so a refusal
# would be correct and the check would be lying about a regression.
if pgrep -x Shortcuts >/dev/null 2>&1 \
   && "$BIN" --probe-controls Shortcuts 2>&1 | grep -q "AXButton"; then
  sc_out="$("$BIN" --probe-semantic 'app=Shortcuts name="stop sleep"' 2>&1)"
  if printf '%s' "$sc_out" | grep -q "AXButton/stop sleep"; then
    printf '  \033[32mPASS\033[0m  named aim: the app with the window, not the helper beside it\n'
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  named aim: a visible shortcut could not be resolved\n'
    printf '        %s\n' "$(printf '%s' "$sc_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
    fail=$((fail + 1)); failures+=("named aim picks the right process")
  fi
else
  printf '  \033[33mSKIP\033[0m  named aim: no Shortcuts window open to aim at\n'
  skip=$((skip + 1))
fi
check "desktop: the icon tree is still published"    "$BIN" --probe-desktop
check "voices: at least one is offered to the app"   "$BIN" --probe-voice
# The microphone itself. Every other check in this file reads the screen or the disk; none of them
# could see the failure that made the notch appear and vanish, because that one lives in CoreAudio.
# This opens the input ten times and prints what each path cost, so "voice is dead" is a red line
# here rather than a message from him.
mic_out="$("$BIN" --probe-mic 2>&1)"; mic_status=$?
if [[ $mic_status -eq 3 ]]; then
  printf '  \033[33mSKIP\033[0m  microphone: %s\n' \
    "$(printf '%s' "$mic_out" | grep -o 'SKIP:.*' | head -1 | cut -c7-)"
  skip=$((skip + 1))
elif printf '%s' "$mic_out" | grep -q "reuse the same engine.*5/5 opened" \
   && printf '%s' "$mic_out" | grep -q "start a fresh engine.*5/5 opened"; then
  printf '  \033[32mPASS\033[0m  microphone: opens on reuse and on a fresh engine  (%s)\n' \
    "$(printf '%s' "$mic_out" | grep -o 'median [0-9]*ms' | head -2 | tr '\n' ' ' | sed 's/median //g')"
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  microphone: this build could not open an input that was there\n'
  printf '        %s\n' "$(printf '%s' "$mic_out" | grep -vE '^\s*$' | tail -3 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("microphone opens")
fi
# The local brain check: if Ollama is running on localhost:11434, verify local discovery and Gemma 4.
# Brought back on 2026-11-02 at his request — the offline tier is a product (4.3), and a check that is
# off by default is a check that rots. What stays fixed is the bug this probe had: it used to choose a
# model by writing the app's real settings, so one gate run left his stored brain on Ollama. Probes now
# use `BrainSettings.processOverride`, and the contract check further down fails if that ever returns.
if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
  check "local brain: Ollama discovery and Gemma 4 vision/text probe" "$BIN" --probe-local
else
  printf '  \033[33mSKIP\033[0m  local brain: Ollama not running on localhost:11434\n'
  skip=$((skip + 1))
fi

# The reply audit. Deterministic: five reply shapes a model has actually been photographed writing,
# run through the live parser. Three separate things have to be true, because exit 0 on its own would
# also be returned by a probe that had stopped measuring anything:
#   - `[ACT:DO:open_app:Chrome]` is still named MALFORMED. If the parser ever swallows that shape
#     quietly, the tag stops reaching the card, the line disappears, and this check goes red — which
#     is the point, because the swallowing would be invisible to every unit test that builds its own
#     tags by hand.
#   - a launch in front of a pixel still reports the steps it holds for a fresh capture.
#   - the fixture run asserts a non-zero number of things and fails none of them.
reply_out="$("$BIN" --probe-reply 2>&1)"; reply_status=$?
if [[ $reply_status -eq 0 ]] \
   && printf '%s' "$reply_out" | grep -q '\[ACT:DO:open_app:Chrome\].*MALFORMED' \
   && printf '%s' "$reply_out" | grep -q 'held for a fresh capture' \
   && printf '%s' "$reply_out" | grep -qE '[1-9][0-9]* assertion\(s\), 0 failure\(s\)'; then
  printf '  \033[32mPASS\033[0m  reply audit: %s\n' \
    "$(printf '%s' "$reply_out" | grep -E 'assertion\(s\), 0 failure' | head -1)"
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  reply audit  (exit %d)\n' "$reply_status"
  printf '        %s\n' "$(printf '%s' "$reply_out" | grep -vE '^\s*$' | tail -3 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("reply audit")
fi
# The live half of the same probe: the local model's own reply, tag by tag, with nothing pressed.
if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
  check "reply audit: the local model's real reply" "$BIN" --probe-reply --local
else
  printf '  \033[33mSKIP\033[0m  reply audit (live): Ollama not running on localhost:11434\n'
  skip=$((skip + 1))
fi

# The notebook tier, on a copy of his file plus the tier's own rules. The probe exits non-zero if a
# credential lands, if an over-long note is clipped instead of refused, if a whole-word delete takes
# "number 30" with "number 3", if a capped block claims nothing was left out, or if the live
# instruction stopped teaching <NOTE> and [NOTES:] — which is the regression that would make the
# tier unread and unwritten while every unit test stayed green.
check "notebook: keeps, refuses, ranks and caps as the rules say" "$BIN" --probe-notebook
echo

echo "file reading, end to end"
# Fixtures are *discovered*, never invented: a path typed into this script is a test that passes on
# the day it is written and fails for a reason that has nothing to do with the app the day after.
TEXT_FIXTURE="$PWD/AGENTS.md"
PDF_FIXTURE="$(ls -1t "$HOME"/Downloads/*.pdf 2>/dev/null | head -1 || true)"
DOC_FIXTURE="$(ls -1t "$HOME"/Downloads/*.docx 2>/dev/null | head -1 || true)"
IMG_FIXTURE="$(ls -1t "$HOME"/Downloads/*.png "$HOME"/Downloads/*.jpg "$HOME"/Downloads/*.jpeg 2>/dev/null | head -1 || true)"

check "find: a sentence names one file"              "$BIN" --probe-find 'read the resume in my downloads'
check "find: a sentence about the screen finds none" "$BIN" --probe-find 'why is the certificate warning showing'
check "read: a text file"                            "$BIN" --probe-read "$TEXT_FIXTURE|what invariants exist"
if [[ -n "$PDF_FIXTURE" ]]; then
  check "read: a PDF's pages ($(basename "$PDF_FIXTURE" | cut -c1-24))" "$BIN" --probe-read "$PDF_FIXTURE|the total"
else
  printf '  SKIP    read: a PDF — none in ~/Downloads to try\n'; skip=$((skip + 1))
fi
if [[ -n "$DOC_FIXTURE" ]]; then
  check "read: a Word file ($(basename "$DOC_FIXTURE" | cut -c1-24))" "$BIN" --probe-read "$DOC_FIXTURE|the summary"
else
  printf '  SKIP    read: a Word file — none in ~/Downloads to try\n'; skip=$((skip + 1))
fi
if [[ -n "$IMG_FIXTURE" ]]; then
  check "read: a picture, as pixels ($(basename "$IMG_FIXTURE" | cut -c1-20))" "$BIN" --probe-read "$IMG_FIXTURE"
else
  printf '  SKIP    read: a picture — none in ~/Downloads to try\n'; skip=$((skip + 1))
fi
check "prompt: what the model is actually told"      "$BIN" --probe-prompt 'the receipt'
echo

echo "surfaces, rendered afresh with successful exit required"
check "render: notch states and draft Copy bounds" "$BIN" --render-ui "$RENDER_DIR/card.png"
check "render: window" "$BIN" --render-window "$RENDER_DIR/window.png"
check "render: panel" "$BIN" --render-panel "$RENDER_DIR/panel.png"
check "render: setup steps and their plan rules" "$BIN" --render-setup "$RENDER_DIR/setup.png"
file_check "the notch card, all states"    "$RENDER_DIR/card.png"   120000
file_check "the window, full and empty"    "$RENDER_DIR/window.png" 80000
file_check "the menu-bar panel"            "$RENDER_DIR/panel.png"  40000
file_check "the first-run flow, all three steps" "$RENDER_DIR/setup.png" 60000
echo

echo "the safety contract, asserted not assumed"
# Every Accessibility call the shell makes must run off the main thread. The crash of 2026-11-04 was
# SwiftUI's own `MainActor.assumeIsolated` faulting on a main thread the act path had just blocked, and
# that call site is not ours to grep — so what is grepped is the *state*: a driver call outside a
# `driver { }` hop is a 150 ms wait on the main thread again, which is the ground a later callback
# crashes on. The type names and the pure helpers are listed because they read nothing from another
# process; `fieldLabel` and `isTrusted` are one attribute each and stay where they are.
ax_unhopped="$(grep -n 'AXTDriver\.' Sources/Chunks/Clicky/CompanionManager.swift \
  | grep -v 'driver({' \
  | grep -vE 'AXTDriver\.(PressResult|TypeResult|ScrollResult|SemanticMiss|RankedPress|PressTarget|TypeTarget|ScrollTarget|PressSnapshot|isTrusted|fieldLabel|appNamesMatch|isAmbiguousFailure|waitForLanding)' \
  | grep -vE ':[[:space:]]*(///|//)' || true)"
if [[ -z "$ax_unhopped" ]]; then
  printf '  \033[32mPASS\033[0m  no Accessibility call runs on the main thread\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  Accessibility work is back on the main thread — it blocks the loop a\n'
  printf '        SwiftUI callback then assumes the main actor on, and that is the crash of 2026-11-04:\n'
  printf '%s\n' "$ax_unhopped" | head -6 | sed 's/^/        /'
  fail=$((fail + 1)); failures+=("main-thread act path")
fi
check "main thread: a blocked loop is measurable, and the act path does not block it" \
  "$BIN" --probe-mainthread
check "bundle: universal, matching deployment target, hardened with exact entitlements" \
  python3 - "$BIN" "$PWD/scripts/Chunks.entitlements" <<'PY'
import json, pathlib, plistlib, re, subprocess, sys
binary = pathlib.Path(sys.argv[1])
manifest = json.loads(subprocess.check_output(['swift', 'package', 'dump-package']))
minimum = next(p['version'] for p in manifest['platforms'] if p['platformName'] == 'macos')
with (binary.parent.parent / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['LSMinimumSystemVersion'] == minimum, 'bundle and package deployment targets disagree'
arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
assert set(arches) == {'arm64', 'x86_64'}, f'not universal: {arches}'
with open(sys.argv[2], 'rb') as stream:
    expected = plistlib.load(stream)
assert expected == {'com.apple.security.device.audio-input': True}, 'unexpected entitlement expansion'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(binary.parent.parent.parent)], check=True)
for arch in arches:
    load_commands = subprocess.check_output(['xcrun', 'vtool', '-show-build', '-arch', arch, str(binary)], text=True)
    assert re.search(r'\bminos\s+' + re.escape(minimum) + r'\s', load_commands), f'{arch}: executable deployment target disagrees'
    details = subprocess.check_output(['codesign', '-d', '--arch', arch, '--verbose=4', str(binary)], stderr=subprocess.STDOUT, text=True)
    assert re.search(r'flags=.*\bruntime\b', details), f'{arch}: hardened runtime missing'
    assert 'Signature=adhoc' not in details and 'Authority=' in details, f'{arch}: stable signing identity missing'
    entitlements = subprocess.check_output(['codesign', '-d', '--arch', arch, '--entitlements', ':-', str(binary)], stderr=subprocess.DEVNULL)
    assert plistlib.loads(entitlements) == expected, f'{arch}: signed entitlements disagree'
print(f'arm64 + x86_64; minimum macOS {minimum}; hardened runtime; microphone entitlement only')
PY
# The overlay that locked his Mac is the one regression that must never come back: a full-screen
# surface that takes the mouse without a way out.
# `NSApp.activate` is allowed to appear in that file's *comments* — it explains why the call is
# absent — so the check looks for a call site, not the string.
if grep -q "_setPreventsActivation" Sources/Chunks/Annotate/AnnotationOverlay.swift \
   && ! grep -vE '^\s*//' Sources/Chunks/Annotate/AnnotationOverlay.swift | grep -q "NSApp\.activate("; then
  printf '  \033[32mPASS\033[0m  the annotation overlay still never activates the app\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  the overlay activation contract changed — see the 2026-10-11 lockup\n'
  fail=$((fail + 1)); failures+=("overlay activation contract")
fi
# The caption is a second surface that sits over his work, and it has to be strictly *less* intrusive
# than the overlay: the overlay needs clicks, the caption must need none. Four properties, each one a
# way this could take something from the app he is in — focus, a click, the menu bar, or his screen
# real estate after the voice has stopped.
if grep -q 'ignoresMouseEvents = true' Sources/Chunks/HUD/CaptionPanelManager.swift \
   && grep -q 'panel.perform(preventsActivation' Sources/Chunks/HUD/CaptionPanelManager.swift \
   && ! grep -vE '^\s*//' Sources/Chunks/HUD/CaptionPanelManager.swift | grep -q 'setValue(true, forKey: "_setPreventsActivation")' \
   && grep -q 'canBecomeKey: Bool { false }' Sources/Chunks/HUD/CaptionPanelManager.swift \
   && ! grep -q 'NSApp\.activate(' Sources/Chunks/HUD/CaptionPanelManager.swift; then
  printf '  \033[32mPASS\033[0m  the caption takes nothing: no focus, no clicks, no activation\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  the caption contract changed — it must be read, not interacted with\n'
  fail=$((fail + 1)); failures+=("caption contract")
fi
# The caption's own words: a cut that lands inside a word is a different sentence about an act on his
# machine, and the render is the only place that is visible without a microphone.
cap_out="$("$BIN" --render-caption /tmp/chunks-caption.png 2>&1)"; cap_status=$?
cap_bytes=$(stat -f%z /tmp/chunks-caption.png 2>/dev/null || echo 0)
if [[ $cap_status -eq 0 ]] && printf '%s' "$cap_out" | grep -q "wrote 3 caption rows" \
   && printf '%s' "$cap_out" | grep -q "caption-contract PASS" \
   && [[ $cap_bytes -gt 60000 ]]; then
  printf '  \033[32mPASS\033[0m  render: caption rows, cut at a word boundary  (%s KB)\n' \
    "$((cap_bytes / 1024))"
  printf '        %s\n' "$(printf '%s' "$cap_out" | grep 'contract measured')"
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  render: the caption did not draw or its contract was not measured (%s bytes, exit %s)\n' \
    "$cap_bytes" "$cap_status"
  printf '        %s\n' "$(printf '%s' "$cap_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("caption render")
fi
if grep -q '"store": false' Sources/ChunksKit/Brain/GeminiTransport.swift \
   && grep -q '"store": false' Sources/Chunks/BrainGateway.swift; then
  printf '  \033[32mPASS\033[0m  the Gemini request still asks for no server-side storage\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  store:false has gone missing from the request builder\n'
  fail=$((fail + 1)); failures+=("store:false")
fi
# The crash contract. Measured 2026-11-03: `MainActor.assumeIsolated` inside a `Timer` block is a
# SIGSEGV one frame below it — the app quit twice in two minutes on a routine tick, mid-turn, having
# promised the user it would act. The assertion is undefined behaviour when the caller is on the main
# *thread* but not inside the main actor's executor, which is exactly what a run-loop timer is. Every
# callback this app does not own must hop with `Task { @MainActor in … }` instead. Probe files are
# exempt: they run before any run loop exists and exit without returning.
if awk '
  /^[[:space:]]*(\/\/|\*)/ { next }   # comments describe the rule; they are not instances of it
  /Timer\(timeInterval|addObserver\(forName|scheduledTimer\(/ { watching = 4 }
  watching > 0 && /MainActor\.assumeIsolated/ {
    print FILENAME ":" FNR ": " $0; bad++
  }
  watching > 0 { watching-- }
  END { exit (bad ? 1 : 0) }
' $(find Sources/Chunks Sources/ChunksKit -name '*.swift' ! -name '*Probe*') 2>/dev/null; then
  printf '  \033[32mPASS\033[0m  no timer or observer asserts the main actor — they hop it\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  a callback asserts MainActor isolation; that is the 22:02 crash\n'
  fail=$((fail + 1)); failures+=("main-actor assertion in a callback")
fi
# A probe may decide what *it* asks; it may not decide what his next turn asks. Measured 2026-11-02:
# `--probe-local` answered "which brain is on this Mac?" by writing the app's real settings, so one
# gate run left his stored brain on Ollama and `--probe-protocol` then graded the production prompt
# against a 2B model and reported three tag families lost. The probes use `BrainSettings
# .processOverride` now, and this check fails if anyone puts the persistence back.
if ! grep -qE 'UserDefaults\.standard\.(set|removeObject)' Sources/Chunks/*Probe*.swift \
   && grep -q 'processOverride' Sources/Chunks/LocalBrainProbe.swift; then
  printf '  \033[32mPASS\033[0m  no probe writes the settings it only means to read\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  a probe writes UserDefaults again — running it would switch his app\n'
  fail=$((fail + 1)); failures+=("probe must not persist settings")
fi
# The keyboard is tied to the asking switch — his decision — and the tie has to survive someone
# editing either door. `toolRefusal` stops a key act before a card exists; `runTool`, the only place
# a tool executes, stops it again, because a plan may lead with a tool and run straight through when
# asking is off. Both read the request's own flag instead of a `case .key` written twice, so the unit
# cases about `requiresAskingEnabled` are cases about the live path and not about a dead property.
if grep -q 'request\.requiresAskingEnabled && !askBeforeActing' Sources/Chunks/Clicky/CompanionManager.swift \
   && [[ $(grep -c 'requiresAskingEnabled' Sources/Chunks/Clicky/CompanionManager.swift) -ge 2 ]]; then
  printf '  \033[32mPASS\033[0m  keyboard: the switch is read at the card door *and* the execution point\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  keyboard: a key act could reach the driver with asking switched off\n'
  fail=$((fail + 1)); failures+=("keyboard is gated by the asking switch")
fi
# A crash that says nothing is a crash that teaches nothing. Four reports in eighteen hours all
# faulted inside SwiftUI's event dispatch and none of them named the surface or the event, because a
# fault does not flush the log — so the app installs a signal handler that writes one line first, and
# this check requires both halves: that the process dies on the signal it means to die on, and that
# the sentence arrives before it does. Exit 139 is SIGSEGV; anything else means the probe stopped
# faulting and the check would otherwise pass on silence.
# Run it against the debug binary, not the installed bundle: this probe exists to die, and dying in
# `/Applications` files a production crash report on every gate run and takes his running app down
# with it. The 30-second bound is load-bearing: a binary that does not know the flag launches the
# full app inside this capture and the gate never returns — a hang this repo has already caused once.
"$DEV_BIN" --probe-crash > "$RENDER_DIR/crash.txt" 2>&1 &
crash_pid=$!
crash_wait=0
while kill -0 "$crash_pid" 2>/dev/null && [[ $crash_wait -lt 30 ]]; do
  sleep 1; crash_wait=$((crash_wait + 1))
done
if kill -0 "$crash_pid" 2>/dev/null; then
  kill -9 "$crash_pid" 2>/dev/null
  crash_status=99
  printf '        the crash probe did not exit within %ss — killed\n' "$crash_wait"
else
  wait "$crash_pid"; crash_status=$?
fi
crash_out="$(cat "$RENDER_DIR/crash.txt")"
if [[ $crash_status -eq 139 ]] && printf '%s' "$crash_out" | grep -q "chunks faulted on SIGSEGV"; then
  printf '  \033[32mPASS\033[0m  a fault names the last mouse event and the surface it landed on\n'
  pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  the crash breadcrumb did not speak (exit %s, wanted 139 + the sentence)\n' \
    "$crash_status"
  printf '        %s\n' "$(printf '%s' "$crash_out" | grep -vE '^\s*$' | tail -2 | tr '\n' '|')"
  fail=$((fail + 1)); failures+=("crash breadcrumb")
fi
echo

printf '%s\n' "----------------------------------------"
if [[ $fail -eq 0 ]]; then
  printf '\033[32mall %d checks passed\033[0m' "$pass"
[[ $skip -gt 0 ]] && printf ' (%d skipped — read the SKIP lines above for the reason)' "$skip"
printf '\n'
  exit 0
fi
printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
exit 1
