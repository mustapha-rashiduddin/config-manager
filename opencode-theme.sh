#!/bin/sh
# Put every running opencode into light or dark mode, live.
#
# Why this is UI automation instead of a config write: opencode has no hot
# reload. It reads theme state from ~/.local/state/opencode/kv.json (theme,
# theme_mode, theme_mode_lock) only at startup, so editing that file while an
# opencode is running does nothing -- verified three ways (atomic rename,
# in-place write, SIGWINCH). And unlike Helix, which re-reads config.toml on
# SIGUSR1, opencode has no signal that does the same. A config write can
# therefore only ever affect the *next* opencode.
#
# To change a *running* one you have to drive its TUI, and the only way to put
# keystrokes into another process here is XTEST (TIOCSTI is disabled on this
# box, so the usual ioctl trick is unavailable).
#
# What we drive: the command palette has a "Switch to dark mode" entry while
# opencode is light, and "Switch to light mode" while it is dark. Filtering the
# palette on the bare word "dark" or "light" leaves exactly that one entry,
# already highlighted, so Return is unambiguous -- nothing that breaks when the
# palette gains other commands.
#
# The cost is focus: XTEST only reaches the focused window, so each opencode is
# briefly raised and the previous focus is restored at the end. That is visible.
#
# Two things this has to get right, both learned the hard way:
#
#   * Only open the palette when the mode actually differs. The entry for the
#     mode you are already in does not exist, so Return would do nothing and
#     leave the palette sitting there, open, with your UI blocked behind it.
#
#   * Verify afterwards, and Escape if the switch did not take. Escape is
#     "interrupt" in opencode when no palette is open, so it must only ever be
#     sent while we are certain the palette is up. Re-reading kv.json tells us:
#     opencode rewrites theme_mode itself when the command runs, so if it did
#     not change, Return found nothing and the palette is still open.

set -u

MODE=${1:-}
case "$MODE" in
    light|dark) ;;
    *) echo "usage: ${0##*/} light|dark" >&2; exit 1 ;;
esac

STATE="$HOME/.local/state/opencode/kv.json"

read_mode() {
    python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("theme_mode", ""))
except Exception:
    print("")' "$STATE" 2>/dev/null
}

write_mode() {
    python3 -c 'import json, sys
path, mode = sys.argv[1], sys.argv[2]
try:
    kv = json.load(open(path))
except Exception:
    sys.exit(0)
kv["theme_mode"] = mode
# theme_mode_lock is what pins the mode against palette changes; it has to move
# with it or the next theme selection snaps back to the old mode.
kv["theme_mode_lock"] = mode
with open(path, "w") as fh:
    json.dump(kv, fh, indent=2)' "$STATE" "$MODE" 2>/dev/null || true
}

BEFORE=$(read_mode)

# Persist for the next opencode, whether or not one is running to switch now.
write_mode

# Locate xdotool. home.nix lists it, but this has to keep working between
# "home.nix edited" and "nixos-rebuild switch" -- and quietly doing only the
# kv.json write is the worst failure available here, because it looks like it
# half-worked: new opencode comes up right, running ones don't move.
XD=$(command -v xdotool 2>/dev/null)
if [ -z "$XD" ]; then
    for dir in "$HOME/.nix-profile/bin" /etc/profiles/per-user/"$(id -un)"/bin \
               /run/current-system/sw/bin; do
        [ -x "$dir/xdotool" ] && { XD="$dir/xdotool"; break; }
    done
fi
if [ -z "$XD" ]; then
    # Last resort on NixOS until the rebuild puts xdotool on PATH.
    XD=$(ls -t /nix/store/*xdotool*/bin/xdotool 2>/dev/null | head -1)
fi
if [ -z "$XD" ] || [ ! -x "$XD" ]; then
    echo "opencode-theme: xdotool not found; live switch skipped." >&2
    echo "opencode-theme: run 'sudo nixos-rebuild switch --flake .#saif-thinkpad'." >&2
    exit 1
fi

if [ "$BEFORE" = "$MODE" ]; then
    echo "opencode-theme: already $MODE." >&2
    exit 0
fi

PREV=$("$XD" getactivewindow 2>/dev/null || true)

switched=0
failed=0

for stpid in $(pgrep -x st 2>/dev/null); do
    exe=$(readlink "/proc/$stpid/exe" 2>/dev/null) || continue
    [ "${exe##*/}" = st ] || continue

    # Is opencode running under this st? It sits two levels down: st spawns the
    # shell, and the shell execs opencode. Matching on the window title instead
    # would break the moment a session is renamed.
    found=""
    for child in $(pgrep -P "$stpid" 2>/dev/null); do
        for cand in "$child" $(pgrep -P "$child" 2>/dev/null); do
            comm=$(cat "/proc/$cand/comm" 2>/dev/null) || continue
            case "$comm" in
                *opencode*) found=1 ;;
            esac
        done
    done
    [ -n "$found" ] || continue

    wid=$("$XD" search --pid "$stpid" 2>/dev/null | head -1)
    [ -n "$wid" ] || continue

    "$XD" windowactivate --sync "$wid" 2>/dev/null || continue
    sleep 0.4

    "$XD" key --clearmodifiers ctrl+p
    sleep 0.9
    # Clear whatever the palette was last filtered by, so our word is the only
    # one in the box.
    "$XD" key --clearmodifiers ctrl+u
    sleep 0.2
    "$XD" type --clearmodifiers --delay 60 "$MODE"
    sleep 0.9
    "$XD" key --clearmodifiers Return
    sleep 1.2

    # opencode rewrites theme_mode itself when the command runs. If it did not
    # change, Return matched nothing and the palette is still open -- which is
    # the one case where Escape is the right key rather than an interrupt.
    if [ "$(read_mode)" = "$MODE" ]; then
        switched=$((switched + 1))
    else
        "$XD" key --clearmodifiers Escape
        sleep 0.4
        write_mode
        failed=$((failed + 1))
    fi
done

if [ -n "$PREV" ]; then
    "$XD" windowactivate --sync "$PREV" 2>/dev/null || true
fi

if [ "$switched" -gt 0 ]; then
    echo "opencode-theme: switched $switched opencode window(s) to $MODE." >&2
fi
if [ "$failed" -gt 0 ]; then
    echo "opencode-theme: $failed opencode window(s) did not offer a switch to $MODE." >&2
fi
if [ "$switched" -eq 0 ] && [ "$failed" -eq 0 ]; then
    echo "opencode-theme: no running opencode; kv.json set to $MODE for the next one." >&2
fi
