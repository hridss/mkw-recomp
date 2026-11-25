#!/usr/bin/env bash
# Follows a game run's log and prints its lines that match PATTERN (plus FATAL and guard stops), then exits when the
# run ends: the Monitor of a run, without a `tail -F` left behind (09/11/2026: two monitors kept their tail after the
# run ended and the hooks had to name the shells to kill).
# Usage: tools/run/watch.sh NAME [PATTERN]   (log build/run/NAME.log; the run is its job-NAME.service or mkw)
# Without PATTERN only failures and the end come through: every printed line wakes the agent for a whole turn that
# rereads its context, and the old default (every `seq: enter`) gave 4 to 43 events per run (09-16/11/2026, 13 % of
# the week's tokens). Ask only for the line that changes the plan; phases are read from the log afterwards.
set -euo pipefail
cd "$(dirname "$0")/../.."
n=${1:?usage: tools/run/watch.sh NAME [PATTERN]}
pat="FATAL|GPU_GUARD:.*destroyed|device fault${2:+|$2}"
log=build/run/$n.log
for _ in $(seq 120); do [ -f "$log" ] && break; sleep 1; done
[ -f "$log" ] || { echo "watch: no $log after 2 min"; exit 1; }
alive() { systemctl --user is-active -q "job-$n.service" 2>/dev/null || pgrep -x mkw >/dev/null; }
# Freeze check: every 15 s the frame through the control FIFO (answered off the game thread); the same frame above 0
# for 60 s prints one STALLED line and saves the threads' stacks (gdb needs the run started with MKW_ALLOW_PTRACE=1).
# A frozen game shows a black window: it is caught here, not by someone looking at it (mir2, 24/11/2026).
last=-1 same=0 stalled=0 tick=0
stall_check() {
    [ "$stalled" = 0 ] && [ -p "build/run/$n.ctl" ] && grep -q "ctl: reading" "$log" || return 0
    local f; f=$(timeout 10 tools/run/ctl.sh "$n" frame 2>/dev/null | grep -o '[0-9]*$' | tail -1) || true
    if [ -n "$f" ] && [ "$f" = "$last" ] && [ "$f" -gt 0 ]; then same=$((same + 1)); else same=0; fi
    last=${f:-$last}
    [ "$same" -ge 4 ] || return 0
    stalled=1
    timeout 120 uv run tools/run/stacks.py --host --save "build/run/$n-stall.txt" > "build/run/$n-stall-stacks.txt" 2>&1 || true
    echo "watch: $n STALLED at frame $f for 60 s (stacks: build/run/$n-stall-stacks.txt, raw build/run/$n-stall.txt)"
}
# Black check (WATCH_BLACK=0: off): every 30 s the window's image (ctl screen: the swapchain, after frame generation,
# which our mkw.ini has on); brightest pixel at most 10 in 4 in a row while the frame moves on prints one BLACK line,
# with the game's own image (ctl shot) to tell whether the game or the presentation (framegen, HUD, upscale) is black.
black=0 blacked=0
black_check() {
    [ "${WATCH_BLACK:-1}" = 1 ] && [ "$blacked" = 0 ] && [ "$stalled" = 0 ] && [ "$same" = 0 ] && [ "$last" -gt 0 ] || return 0
    local png="$PWD/build/run/$n-watch.png" shot="$PWD/build/run/$n-watch-game.png" l g=?
    rm -f "$png" "$shot" "${shot%.png}-s.png"
    timeout 20 tools/run/ctl.sh "$n" screen "$png" > /dev/null 2>&1 || return 0
    for _ in $(seq 10); do [ -s "$png" ] && break; sleep 1; done   # written at the next present
    l=$(uv run -q tools/imagen/maxlum.py "$png" 2>/dev/null) || return 0
    if [ "$l" -le 10 ]; then black=$((black + 1)); else black=0; fi
    [ "$black" -ge 4 ] || return 0
    blacked=1
    timeout 20 tools/run/ctl.sh "$n" shot "$shot" > /dev/null 2>&1 && g=$(uv run -q tools/imagen/maxlum.py "$shot" 2>/dev/null)
    echo "watch: $n BLACK at frame $last: the window has stayed black for 2 min while frames advance; game image max $g of 255 ($png, $shot)"
}
pos=0
while :; do
    tick=$((tick + 1)); [ $((tick % 8)) -ne 0 ] || stall_check; [ $((tick % 15)) -ne 0 ] || black_check
    size=$(stat -c %s "$log")
    if [ "$size" -gt "$pos" ]; then
        tail -c +$((pos + 1)) "$log" | head -c $((size - pos)) | grep -E --line-buffered "$pat" || true
        pos=$size
    fi
    alive || { sleep 2; tail -c +$((pos + 1)) "$log" | grep -E "$pat" || true; echo "watch: $n ended"; exit 0; }
    sleep 2
done
