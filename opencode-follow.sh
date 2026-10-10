#!/bin/sh
# Mirror opencode's light/dark mode onto the rest of the desktop.
#
# theme.sh already drives opencode when you type `light` or `dark` in a
# terminal. This is the other direction: opencode's own command palette
# ("Switch to dark mode" / "Switch to light mode") changes kv.json, and this
# picks that up and runs the same theme switch for everything else.
#
# Polling, because opencode has no way to tell us: no signal, no socket, no
# hook. Half a second is well inside "instant" for a human and costs a grep.
#
# The loop guard is current-st-theme. theme.sh writes that *before* it touches
# opencode, so by the time kv.json changes as a result, the two already agree
# and this loop has nothing to do. It only acts when opencode moved on its own,
# which is exactly the case we want, and that is also what stops this feeding
# itself.
#
# Run by systemd as opencode-theme-follow.service.

CM="$HOME/.config/config-manager"
STATE="$HOME/.local/state/opencode/kv.json"

read_mode() {
    grep -o '"theme_mode"[[:space:]]*:[[:space:]]*"[a-z]*"' "$STATE" 2>/dev/null |
        head -1 | sed 's/.*"\([a-z]*\)"$/\1/'
}

read_desktop_theme() {
    cat "$CM/current-st-theme" 2>/dev/null
}

# Seed from whatever is already true, so starting up is never mistaken for a
# change. The config-manager dir may not exist on a fresh login.
last=$(read_mode)
[ -n "$last" ] || last=$(read_desktop_theme)

while :; do
    cur=$(read_mode)
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
        last=$cur
        if [ "$cur" != "$(read_desktop_theme)" ]; then
            "$CM/theme.sh" "$cur" >/dev/null 2>&1 || true
        fi
    fi
    sleep 0.5
done
