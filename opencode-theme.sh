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
# How we drive it: one keystroke. config-manager/opencode/tui.json binds
# theme_switch_mode to ctrl+alt+m, which flips light <-> dark. It defaults to
# "none", so the binding is free by definition and cannot collide with anything.
# ~/.config/opencode/tui.json is a symlink to it, because the two halves only
# work together: without the binding this sends a key nothing is listening for
# and quietly stops switching anything.
#
# ctrl+alt rather than ctrl+shift because that is the one chord that is actually
# reachable: opencode's defaults already use ctrl+alt for k/y/e/u/d/g/b/f and for
# the arrow and page keys, but nothing takes ctrl+alt+m. The layout here is plain
# "us" with no AltGr remapping, so there is no ctrl+alt chord to collide with
# either.
#
# That binding is the whole fix, and it is worth being explicit about why the
# version it replaced was broken. The old code opened the command palette
# (ctrl+p), typed the word "dark" into it, and pressed Return -- on the theory
# that the palette would mount fast enough to swallow all of it. It usually
# did. When it did not, "dark" went into the prompt instead of the palette box
# and Return submitted it, so the LLM got a prompt reading "dark". Rare enough
# to look like a ghost, frequent enough to keep happening: roughly 1 in 40.
#
# The shape of the bug is what makes it so unpleasant to fix in place. A single
# keystroke bound to a command cannot leak, because there is no text to leak --
# either it fires and the theme changes, or it does not and nothing at all
# happens. No window exists in which stray characters could land, no Return that
# could submit them, no Escape to send afterwards (which was itself risky, being
# "interrupt" in opencode whenever no palette was up). The prompt is not
# reachable from here at all, so the entire failure class is gone rather than
# made less likely.
#
# Keys go out as XSendEvent (xdotool --window), not XTEST. That distinction is
# the second half of the whole ballgame. XTEST injects at the X server and can
# only ever reach whatever holds focus, so switching a *background* opencode
# meant raising its window and taking the keyboard for a second -- and if you
# were typing at the time, the keystroke landed in your shell. XSendEvent
# carries a target window id, so st takes the KeyPress while sitting in the
# background, forwards it to its pty exactly as if it had been typed, and
# opencode cannot tell the difference. Nothing is raised and focus never moves.
#
# The toggle is verified, not assumed. opencode rewrites theme_mode in kv.json
# itself when the switch runs, so re-reading that file is opencode telling us it
# switched rather than us agreeing with ourselves. If the mode does not move the
# key was not received and we press again; if it moves to the *wrong* mode we
# press again to come back. Neither case can put anything in the prompt.

set -u

MODE=${1:-}
case "$MODE" in
    light|dark) ;;
    *) echo "usage: ${0##*/} light|dark" >&2; exit 1 ;;
esac

STATE="$HOME/.local/state/opencode/kv.json"
LOG="$HOME/.local/state/opencode/theme-switch.log"

# Pure bash, no forks. This runs inside the poll loop below, and it used to be
# a `grep | sed` pipeline: three processes per iteration, so 200 iterations cost
# around ten seconds of fork/exec rather than the two the comment claimed. On a
# miss that delay was most of the script's runtime, and it is why a single failed
# press took long enough to look like a hang.
#
# $(< file) is bash's fork-free whole-file read, and the regex is a builtin, so
# this costs a single syscall where the pipeline cost three processes. It also
# matches regardless of whether the value sits on its own line or inside a
# single-line document, which the earlier line-at-a-time attempt got wrong: that
# loop re-read the same line forever on a file with no match, hanging the script
# outright. grep is kept as a fallback so the script still runs if /bin/sh ever
# stops being bash.
read_mode() {
    [ -r "$STATE" ] || return 0
    if [ -n "${BASH_VERSION:-}" ]; then
        local content
        content=$(< "$STATE")
        if [[ $content =~ \"theme_mode\"[[:space:]]*:[[:space:]]*\"([a-z]+)\" ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
        fi
        return 0
    fi
    v=$(grep -o '"theme_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" 2>/dev/null | head -1)
    [ -n "$v" ] || return 0
    printf '%s' "$v" | sed 's/.*"\([a-z]*\)"$/\1/'
}

# Poll for opencode to report the new mode instead of sleeping a fixed guess.
# The switch itself lands in well under a tenth of a second, so a fixed wait was
# spending almost all of its time waiting for something that had already
# happened. Thirty rounds is about a second of real time and several times what a
# healthy switch needs.
wait_for_mode() {
    i=0
    while [ "$i" -lt 30 ]; do
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
START=$(date +%s%N)

log_run() {
    {
        printf '%s mode=%s before=%s after=%s via=%s windows=%s failed=%s ms=%s\n' \
            "$(date +%H:%M:%S.%N | cut -c1-12)" "$MODE" "$BEFORE" "$(read_mode)" \
            "${VIA:-?}" "${switched:-0}" "${failed:-0}" \
            "$(( ($(date +%s%N) - START) / 1000000 ))"
    } >> "$LOG" 2>/dev/null || true
}

# One line per press. `noreply` means the mode never moved, so the keystroke was
# not received and pressing again is free. `wrongway` means it was received and
# toggled, just not to the mode asked for. Both are recoverable; neither can
# have touched the prompt.
log_attempt() {
    {
        printf '  press=%s mode=%s before=%s after=%s result=%s ms=%s\n' \
            "$1" "$MODE" "$2" "$3" "$4" \
            "$(( ($(date +%s%N) - press_start) / 1000000 ))"
    } >> "$LOG" 2>/dev/null || true
}

if [ "$BEFORE" = "$MODE" ]; then
    VIA="noop"
    log_run
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
    #
    # One press should do it: BEFORE is known to differ from MODE and the
    # binding is a pure toggle. The loop exists only to cover a keystroke that
    # never arrived, which costs a re-press and nothing else.
    ok=""
    presses=0
    while [ "$presses" -lt 3 ]; do
        presses=$((presses + 1))
        press_start=$(date +%s%N)
        press_before=$(read_mode)

        "$XD" key --window "$wid" --clearmodifiers ctrl+alt+m

        if wait_for_mode "$MODE"; then
            VIA="toggle$presses"
            ok=1
            log_attempt "$presses" "$press_before" "$(read_mode)" switched
            break
        fi

        press_after=$(read_mode)
        if [ "$press_after" = "$press_before" ]; then
            VIA="toggle$presses-noreply"
        else
            VIA="toggle$presses-wrongway"
        fi
        log_attempt "$presses" "$press_before" "$press_after" \
            "$([ "$press_after" = "$press_before" ] && echo noreply || echo wrongway)"
    done

    if [ -n "$ok" ]; then
        switched=$((switched + 1))
    else
        failed=$((failed + 1))
    fi
    VIA="$VIA/$MODE"
    log_run
    VIA=
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
