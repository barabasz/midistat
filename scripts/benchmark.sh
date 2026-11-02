#!/bin/bash
# Measures CPU and memory of the running MIDIstat while virtual MIDI devices
# (MIDIstatLoad) play, with different combinations of open windows.
# Windows are switched through the control API (`MIDIstat ctl`); their state,
# the event history and the notes count are restored afterwards where possible.
#
#   ./scripts/benchmark.sh            # all window sets x all loads, 10 s each
#   ./scripts/benchmark.sh --quick    # fewer combinations, 6 s each
#
# Environment:
#   MIDISTAT_BIN   the app binary (default: /Applications/MIDIstat.app/Contents/MacOS/MIDIstat)
#   RUN_SECONDS    seconds per measurement (default: 10, or 6 with --quick)
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C

BIN="${MIDISTAT_BIN:-/Applications/MIDIstat.app/Contents/MacOS/MIDIstat}"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1
RUN="${RUN_SECONDS:-$([[ $QUICK == 1 ]] && echo 6 || echo 10)}"

ctl() { "$BIN" ctl "$@"; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

ctl ver >/dev/null 2>&1 || { echo "MIDIstat is not running (or $BIN is not MIDIstat)." >&2; exit 2; }
echo "Building the load generator…"
swift build -c release --product MIDIstatLoad >/dev/null 2>&1
LOAD="$(swift build -c release --show-bin-path)/MIDIstatLoad"

STATUS="$(ctl status)"
PID="$(echo "$STATUS" | json 'd["status"]["app"]["pid"]')"
VERSION="$(echo "$STATUS" | json 'd["status"]["app"]["version"]')"
WAS_OPEN="$(echo "$STATUS" | json '" ".join(k for k, v in d["status"]["windows"].items() if v["open"])')"
STORED_BEFORE="$(echo "$STATUS" | json 'd["status"]["events"]["stored"]')"
NOTES_BEFORE="$(echo "$STATUS" | json 'd["status"]["stats"]["notesSinceReset"]')"

cpu_seconds() { ps -o time= -p "$PID" | awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else print $1 * 60 + $2 }'; }
memory() { top -l 1 -pid "$PID" -stats mem | tail -1 | tr -d ' +-'; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

windows() {  # windows <log|events|notes …>: exactly these open
    for w in log events notes stats; do
        if [[ " $* " == *" $w "* ]]; then ctl open "$w" >/dev/null; else ctl close "$w" >/dev/null; fi
    done
    sleep 1
}

measure() {  # measure <label> <MIDIstatLoad options…>
    local label="$1"; shift
    "$LOAD" --seconds "$((RUN + 2))" "$@" >/dev/null &
    local gen=$!
    sleep 1.5  # the generator connects during its first second
    local c0 w0 c1 w1
    c0="$(cpu_seconds)"; w0="$(now)"
    sleep "$RUN"
    c1="$(cpu_seconds)"; w1="$(now)"
    printf "  %-34s %6.2f %%   %s\n" "$label" "$(echo "($c1 - $c0) / ($w1 - $w0) * 100" | bc -l)" "$(memory)"
    wait "$gen"
}

loads() {
    measure "no MIDI"
    measure "6 notes/s" --notes 6
    measure "16 notes/s" --notes 16
    [[ $QUICK == 1 ]] && return
    measure "6 notes/s + 10 aftertouch/note" --notes 6 --aftertouch 10
    measure "MIDI Clock 120 BPM + Active Sensing" --clock 120 --sensing
}

echo "MIDIstat $VERSION (pid $PID), $RUN s per measurement. CPU: % of one core (average)."
echo
for set in "" "log" "events" "notes" "stats" "log events notes stats"; do
    [[ $QUICK == 1 && ( "$set" == "log" || "$set" == "events" || "$set" == "notes" || "$set" == "stats" ) ]] && continue
    echo "Windows: ${set:-none (menu bar icon only)}"
    printf "  %-34s %8s   %s\n" "load" "CPU" "memory"
    windows $set
    loads
    echo
done

# Restore: windows, and the history / notes count if they were empty before.
windows $WAS_OPEN
[[ "$STORED_BEFORE" == "0" ]] && ctl clear-log >/dev/null
[[ "$NOTES_BEFORE" == "0" ]] && ctl reset-stats >/dev/null
echo "Restored the windows that were open (${WAS_OPEN:-none})."
[[ "$STORED_BEFORE" != "0" ]] && echo "Note: the test events remain in the event history (it was not empty before)."
exit 0
