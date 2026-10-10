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

# Returns through $mode_out rather than stdout, and that detail is the whole
# point. This loop runs twice a second for as long as the session lasts, and
# `$(read_mode)` forks a subshell to capture stdout -- so making the body
# cheaper does nothing on its own. Measured in voluntary context switches:
#
#   grep | head | sed, captured via $( )      5.70 wakeups/sec  (492k/day)
#   fork-free body, still captured via $( )   6.00 wakeups/sec  (518k/day)
#   fork-free body, returned via $mode_out    2.00 wakeups/sec  (173k/day)
#   bare sleep 0.5, no read at all            2.00 wakeups/sec  (173k/day)
#
# The second row is the trap: same fork-free body, more wakeups than the
# pipeline, because the pipeline was never where the forks came from. The last
# row is the floor a 0.5s poll can reach, and this now sits on it, so the read
# costs nothing measurable and only the sleeps wake the CPU.
#
# On a laptop the wakeup count is the number that matters. 4.1 minutes of CPU a
# day is not worth optimising; half a million forced wakeups is what stops the
# machine settling into a deep idle state.
#
# kv.json is written atomically -- opencode writes a tmp file and renames it --
# so inotify would work here too and would cut this to zero. That needs a
# resident process (Python, or inotify-tools added to the system) to hold the
# watch, which is a worse trade than two wakeups a second for a few KB of shell.
mode_out=
read_mode() {
    mode_out=
    [ -r "$STATE" ] || return 0
    if [ -n "${BASH_VERSION:-}" ]; then
        # $(< file) is bash's fork-free whole-file read and =~ is a builtin, so
        # this is one syscall. It matches whether the value sits on its own line
        # or inside a single-line document.
        local content
        content=$(< "$STATE")
        if [[ $content =~ \"theme_mode\"[[:space:]]*:[[:space:]]*\"([a-z]+)\" ]]; then
            mode_out="${BASH_REMATCH[1]}"
        fi
        return 0
    fi
    # grep fallback, for the unlikely day /bin/sh is not bash.
    v=$(grep -o '"theme_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" 2>/dev/null | head -1)
    [ -n "$v" ] || return 0
    mode_out=$(printf '%s' "$v" | sed 's/.*"\([a-z]*\)"$/\1/')
}

read_desktop_theme() {
    cat "$CM/current-st-theme" 2>/dev/null
}

# Seed from whatever is already true, so starting up is never mistaken for a
# change. The config-manager dir may not exist on a fresh login.
read_mode
last=$mode_out
[ -n "$last" ] || last=$(read_desktop_theme)

while :; do
    read_mode
    cur=$mode_out
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
        last=$cur
        if [ "$cur" != "$(read_desktop_theme)" ]; then
            "$CM/theme.sh" "$cur" >/dev/null 2>&1 || true
        fi
    fi
    sleep 0.5
done
