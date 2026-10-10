#!/usr/bin/env python3
"""Recolor every running st window from a palette file via OSC 4/10/11/12.

st (>= 0.9) handles these dynamic-color OSC sequences natively and redraws
live. We deliver them by writing to each st shell's controlling pty on the
*output* path (the slave /dev/pts/N). Bytes written to the slave are parsed by
st as output and can never be read as input by whatever program is in the
foreground, so recoloring a window mid-app (nvim, litecli, erd, ...) is safe
and applies instantly to transparent-background apps.

This is only for windows that are ALREADY open. A newly opened window needs no
help: st reads the same palette file itself at startup, before it allocates its
first pixel (st-palette.diff, /etc/nixos/users/saifr/st.nix), so it is born in
the current theme. A running st can only be recoloured by being sent escape
sequences, which is what this does.

OSC 4 sets palette entries, so the whole ANSI color set switches at runtime.
OSC 10/11/12 then set foreground, background and cursor.

The palette file is the `key = #hex` format of st_colors_{dark,light}.

Usage: st-theme.py <palette file>
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path


def child_pids(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
    return [int(x) for x in out.stdout.split()]


def st_pids() -> list[int]:
    """Only the real st processes, not the config-manager wrapper around them.

    `pgrep -x st` also matches the wrapper, because a shell run as
    `.../config-manager/st` has argv[0]'s basename -- and therefore its comm --
    set to "st". For the wrapper, children[0] is the real st rather than the
    shell, so its fd 0 is the terminal that *launched* that window, not the
    window itself. Taking it at face value themes the wrong terminal, and
    themes each palette once per wrapper on top of once per window.
    """
    out = subprocess.run(["pgrep", "-x", "st"], capture_output=True, text=True)
    real = []
    for line in out.stdout.split():
        pid = int(line)
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
        except OSError:
            continue
        if Path(exe).name == "st":
            real.append(pid)
    return real


def recolor(tty: str, seq: bytes) -> None:
    """Push the escape sequence at st without touching the terminal's state.

    Writing to the pty *slave* is pure output: st reads it and renders it, and
    the line discipline never echoes output back. Muting ECHO therefore bought
    nothing -- all it did was bracket the write with two tcsetattr calls on a
    terminal the shell owns. The shell's line editor (mksh, readline) is
    constantly re-setting that same terminal as it draws a prompt and runs a
    completion, so a stale save/restore around a write lands in the middle of
    somebody's Tab and puts the terminal back into whatever mode it had before
    the shell changed it. That is the only thing here that mutates terminal
    state, and it is the only thing that can disturb an editor mid-completion.

    """
    fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY)
    try:
        view = memoryview(seq)
        while view:
            # os.write may be short on a pty; a partial write would leave st with
            # a half-applied palette and the untouched entries still dark.
            view = view[os.write(fd, view):]
    finally:
        os.close(fd)


def load_palette(path: str) -> tuple[dict[int, str], str, str, str]:
    """Parse a `key = #hex` palette file into (colors, foreground, background, cursor)."""
    colors: dict[int, str] = {}
    named: dict[str, str] = {}

    try:
        fh = open(path)
    except OSError as e:
        print(f"st-theme: cannot read palette {path}: {e}", file=sys.stderr)
        raise SystemExit(1) from None

    with fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().lstrip("#")
            if not re.fullmatch(r"[0-9a-fA-F]{6}", value):
                continue
            if key.startswith("color") and key[5:].isdigit():
                colors[int(key[5:])] = value.lower()
            else:
                named[key] = value.lower()

    if sorted(colors) != list(range(16)):
        print(f"st-theme: {path}: need color0..color15, got {len(colors)}", file=sys.stderr)
        raise SystemExit(1)

    missing = [k for k in ("foreground", "background", "cursor") if k not in named]
    if missing:
        print(f"st-theme: {path}: missing {', '.join(missing)}", file=sys.stderr)
        raise SystemExit(1)

    return colors, named["foreground"], named["background"], named["cursor"]


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if len(args) != 1:
        print("usage: st-theme.py <palette file>", file=sys.stderr)
        return 1

    colors, fg, bg, cursor = load_palette(args[0])

    # OSC 4 takes pairs: "4;index;spec". Specs are X color names, so #rrggbb.
    osc = "".join(f"\x1b]4;{i};#{value}\x07" for i, value in sorted(colors.items()))
    # OSC 10 fg, 11 bg, 12 cursor, then \x15 to repaint.
    osc += f"\x1b]11;#{bg}\x07\x1b]10;#{fg}\x07\x1b]12;#{cursor}\x07\x15"
    osc = osc.encode()

    # Cache the finished sequence, one line, next to the palette it came from.
    # The st wrapper opens a window by reading this back with `read` and a bare
    # printf redirect, so a new window costs no interpreter start -- which was
    # the larger half of the delay between a window appearing and it being the
    # right colour. Regenerated here, so it can never drift from the palette.
    seen: set[str] = set()
    targets: list[str] = []
    for stpid in st_pids():
        children = child_pids(stpid)
        if not children:
            continue
        shell = children[0]
        try:
            tty = os.readlink(f"/proc/{shell}/fd/0")
        except OSError:
            continue
        if tty.startswith("/dev/pts/") and tty not in seen:
            seen.add(tty)
            targets.append(tty)

    changed = 0
    for tty in targets:
        recolor(tty, osc)
        changed += 1
        time.sleep(0.03)

    if changed:
        print(f"st-theme: recolored {changed} st window(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())