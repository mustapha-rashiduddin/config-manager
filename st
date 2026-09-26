#!/bin/sh
# st wrapper: launch the real st, then apply the persisted theme once the
# new window's shell is idle (so st-theme.py can flush the OSC reliably).
# The palette lives in st_colors_<theme>; OSC 4 swaps the ANSI colors and
# OSC 10/11/12 swap fg/bg/cursor.
REAL_ST=$(command -v st)
CM="$HOME/.config/config-manager"
FTHEME="$CM/current-st-theme"

"$REAL_ST" "$@" &
ST_PID=$!

PALETTE=""
if [ -s "$FTHEME" ]; then
    theme=$(cat "$FTHEME" 2>/dev/null)
    case "$theme" in
        light|dark) [ -f "$CM/st_colors_$theme" ] && PALETTE="$CM/st_colors_$theme" ;;
    esac
fi

if [ -n "$PALETTE" ]; then
    (
        i=0
        while [ "$i" -lt 60 ]; do
            sleep 0.1
            shl=$(pgrep -P "$ST_PID" 2>/dev/null | head -1)
            if [ -n "$shl" ]; then
                tpgid=$(ps -o tpgid= -p "$shl" | tr -d ' ')
                pgrp=$(ps -o pgrp= -p "$shl" | tr -d ' ')
                [ "$tpgid" = "$pgrp" ] && break
            fi
            i=$((i + 1))
        done
        python3 "$CM/st-theme.py" "$PALETTE"
    ) &
fi

wait "$ST_PID"
