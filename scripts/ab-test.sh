#!/bin/bash
# scripts/ab-test.sh — the same questions, asked to both brains, and the difference measured.
#
# Why this is a script and not a conversation: he asked whether the offline tier can carry medium and
# high-complexity work the way the cloud chain does. That is a question with a number in it, and the
# only honest way to answer it is to run both sides on the same input in the same minute, because the
# cloud side's latency is dominated by contention that changes hour to hour. Measured 2026-11-03, a
# turn that took 7.2 s took 30 s forty minutes later on the same key.
#
# What is identical between the two sides, and what is not, is printed rather than assumed:
#   - IDENTICAL: the production prompt, the screenshot, the five questions, the tag families asserted,
#     the parser, and the machine.
#   - NOT IDENTICAL: the model, and therefore the token budget. The local tier is a 2B model on CPU;
#     asking it the same sentence the cloud is asked is the honest test of *capability*, not of tuning.
#
# It never writes his settings: both sides run through `BrainSettings.processOverride`, and the gate
# check that enforces that (`no probe writes the settings it only means to read`) is what makes this
# safe to run twice in a row.
set -uo pipefail

APP="${HOME}/Applications/Chunks.app"
BIN="$APP/Contents/MacOS/Chunks"
nonce="AB-$RANDOM-$(date +%s)"

if [[ ! -x "$BIN" ]]; then
  printf 'ab-test: no installed bundle — run ./scripts/make-app.sh && ./scripts/install.sh\n'
  exit 2
fi

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
row() { printf '  %-26s %s\n' "$1" "$2"; }

say "A/B — cloud chain vs the offline tier, nonce $nonce"

# Both sides run against a live screen: a probe that measures a model while the display is asleep
# reports refusals as though they were capability, which is the mistake `--probe-protocol` already
# refuses to make (it exits 3 and says so).

say "side A — the production chain (his key, five fixed turns)"
a_out=$("$BIN" --probe-protocol 2>&1); a_status=$?
a_served=$(printf '%s' "$a_out" | grep -c "turn: served by" || true)
# Counted from the probe's own SKIP lines, not from a word like "lost": the first version of this
# grepped for "lost|MALFORMED|FAIL" and reported 6 lost families on a run where one turn had simply
# timed out — it was counting the prose in the log echo, which is the same mistake as measuring a
# thing that is not there.
a_skipped=$(printf '%s' "$a_out" | grep -c "SKIPPED" || true)
a_time=$(printf '%s' "$a_out" | grep -oE 'served by [a-z0-9.-]+ in [0-9]+\.[0-9]+s' \
        | grep -oE '[0-9]+\.[0-9]+s$' | tr -dc '0-9. \n' | awk '{ s += $1 } END { printf "%.1f", s }')
row "exit" "$a_status (0 = every family still arrives)"
row "turns served" "$a_served"
row "turns skipped (no answer)" "$a_skipped"
row "seconds, served turns only" "${a_time:-n/a}"
printf '%s\n' "$a_out" | grep -E "in [0-9.]+s|refused|SKIP" | head -8 | sed 's/^/        /'

say "side B — the offline tier (same prompt, local model, same five questions)"
b_out=$("$BIN" --probe-reply --local 2>&1); b_status=$?
b_malformed=$(printf '%s' "$b_out" | grep -c "MALFORMED" || true)
b_swallowed=$(printf '%s' "$b_out" | grep -c "swallowed" || true)
b_time=$(printf '%s' "$b_out" | grep -oE 'served locally by [a-z0-9:._-]+ in [0-9]+\.[0-9]+s' \
        | grep -oE '[0-9]+\.[0-9]+s$' | tr -dc '0-9. \n' | awk '{ s += $1 } END { printf "%.1f", s }')
row "exit" "$b_status"
row "malformed tags in its reply" "$b_malformed"
row "tags swallowed by the parser" "$b_swallowed"
row "seconds, served turns only" "${b_time:-n/a}"
printf '%s\n' "$b_out" | grep -E "MALFORMED|swallowed|served|FAIL|verdict" | head -8 | sed 's/^/        /'

say "the difference, stated"
if [[ $a_status -eq 0 && $b_status -eq 0 ]]; then
  row "both tiers" "every tag family survived on both sides"
elif [[ $a_status -eq 0 ]]; then
  row "cloud only" "the offline tier lost at least one family — see side B above"
else
  row "cloud lost too" "side A did not pass; contention or a locked screen, not capability"
fi
if [[ $b_swallowed -gt 0 ]]; then
  printf '  \033[31mNOTE\033[0m  a tag was SWALLOWED on the local side: the parser ate a malformed tag\n'
  printf '        rather than showing it. That is the invisible failure class, not a model problem.\n'
fi
printf '\nab-test: A exit %s, B exit %s, nonce %s\n' "$a_status" "$b_status" "$nonce"
printf 'Compare the two "seconds, summed" rows only on the same machine, awake, in the same minute.\n'
