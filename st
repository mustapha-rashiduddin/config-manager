#!/bin/sh
# st wrapper: launch the real st, then apply the persisted theme once the
# new window's shell is idle (so st-theme.py can flush the OSC reliably).
REAL_ST=$(command -v st)
FFG="$HOME/.config/config-manager/current-st-fg"
FBG="$HOME/.config/config-manager/current-st-bg"

"$REAL_ST" "$@" &
ST_PID=$!

if [ -s "$FFG" ] && [ -s "$FBG" ]; then
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
        python3 "$HOME/.config/config-manager/st-theme.py" "$(cat "$FFG")" "$(cat "$FBG")"
    ) &
fi

wait "$ST_PID"