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
# Keys go out as XSendEvent (xdotool --window), not XTEST. That distinction is
# the whole ballgame. XTEST injects at the X server and can only ever reach
# whatever holds focus, so switching a *background* opencode meant raising its
# window and taking the keyboard for a second -- and if you were typing at the
# time, the palette keystrokes landed in your shell. XSendEvent carries a target
# window id, so st takes the KeyPress while sitting in the background, forwards
# it to its pty exactly as if it had been typed, and opencode cannot tell the
# difference. Nothing is raised and focus never moves.
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
    # grep rather than python3: this is called on every poll below, and an
    # interpreter start is ~50-100ms, which used to cost more than the switch
    # itself. Tolerant of spacing and of the value sitting anywhere in the file.
    v=$(grep -o '"theme_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" 2>/dev/null | head -1)
    [ -n "$v" ] || return 0
    printf '%s' "$v" | sed 's/.*"\([a-z]*\)"$/\1/'
}

# Poll for opencode to report the new mode instead of sleeping a fixed guess.
# The switch itself lands in well under a tenth of a second, so a fixed wait was
# spending almost all of its time waiting for something that had already
# happened.
wait_for_mode() {
    i=0
    while [ "$i" -lt 200 ]; do
        [ "$(read_mode)" = "$1" ] && return 0
        sleep 0.01
        i=$((i + 1))
    done
    return 1
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

if [ "$BEFORE" = "$MODE" ]; then
    echo "opencode-theme: already $MODE." >&2
    exit 0
fi

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

    # Everything below is addressed to this window id; nothing here touches the
    # focus or the workspace the user is actually looking at.
    # Two attempts. ctrl+p reliably opens the palette when it is closed and is
    # harmless when it is already open, so a miss here is a transient one --
    # opencode mid-render, say -- and a second try costs almost nothing.
    ok=""
    for attempt in 1 2; do
        # 20ms was measured as enough for the palette to mount and take the
        # focus; the old 1s was a guess, and guessing high is what made this
        # look like it was waiting on a person. Sending faster than the palette
        # can mount is what puts text in the prompt, so this is the one delay
        # worth being careful with.
        "$XD" key --window "$wid" --clearmodifiers ctrl+p
        sleep 0.05
        # Clear whatever the palette was last filtered by, so our word is the
        # only one in the box.
        "$XD" key --window "$wid" --clearmodifiers ctrl+u
        sleep 0.03
        "$XD" type --window "$wid" --clearmodifiers --delay 0 "$MODE"
        sleep 0.05
        "$XD" key --window "$wid" --clearmodifiers Return

        # opencode rewrites theme_mode itself when the command runs, and nothing
        # else writes it during this loop -- so this reading is genuinely
        # opencode telling us it switched, not us agreeing with ourselves.
        if wait_for_mode "$MODE"; then
            ok=1
            break
        fi

        # It did not switch, so Return matched nothing: either the palette never
        # opened, or it opened already filtered to a mode that is not on offer.
        #
        # Escape is right here precisely because we know Return did not act --
        # if it had, we would be in the success branch. When no palette is up
        # Escape is "interrupt", which is the mild version of this failure.
        "$XD" key --window "$wid" --clearmodifiers Escape
        sleep 0.2

        # ...and if the palette had in fact never opened, those keystrokes went
        # into the prompt instead, where Return has already submitted them. There
        # is no way to tell the two cases apart from here, so clear the line
        # either way. This can wipe something the user typed in that window in
        # the same instant, which is a far smaller loss than the alternative --
        # a stray "light" or "dark" going to the model as a prompt.
        "$XD" key --window "$wid" --clearmodifiers ctrl+u
        sleep 0.15
    done

    if [ -n "$ok" ]; then
        switched=$((switched + 1))
    else
        failed=$((failed + 1))
    fi
done

if [ "$switched" -gt 0 ]; then
    echo "opencode-theme: switched $switched opencode window(s) to $MODE." >&2
fi
if [ "$switched" -eq 0 ] && [ "$failed" -eq 0 ]; then
    # Nothing was running to switch, so kv.json is all that is left to do.
    write_mode
    echo "opencode-theme: no running opencode; kv.json set to $MODE for the next one." >&2
fi
if [ "$failed" -gt 0 ]; then
    # Say plainly that the live switch did not happen. The theme change itself is
    # still correct for the next opencode, but claiming success here is what
    # let a failure look like a pass.
    write_mode
    echo "opencode-theme: FAILED to switch $failed window(s); they are still on $BEFORE." >&2
    echo "opencode-theme: kv.json set to $MODE, so the next opencode starts there." >&2
fi
