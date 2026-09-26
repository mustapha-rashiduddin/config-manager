#!/usr/bin/env python3
"""Recolor every running st window from a palette file via OSC 4/10/11/12.

st (>= 0.9) handles these dynamic-color OSC sequences natively and redraws
live. We deliver them by writing to each st shell's controlling pty on the
*output* path (the slave /dev/pts/N). Bytes written to the slave are parsed by
st as output and can never be read as input by whatever program is in the
foreground, so recoloring a window mid-app (nvim, litecli, erd, ...) is safe
and applies instantly to transparent-background apps.

OSC 4 sets palette entries, so the whole ANSI color set switches at runtime and
the compiled-in default in st.nix is only a fallback for a window that has
never been themed. OSC 10/11/12 then set foreground, background and cursor.

The palette file is the `key = #hex` format of st_colors_{dark,light}.

Usage: st-theme.py <palette file>
"""

import os
import re
import subprocess
import sys
import termios
import time


def child_pids(pid: int) -> list[int]:
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
    return [int(x) for x in out.stdout.split()]


def st_pids() -> list[int]:
    out = subprocess.run(["pgrep", "-x", "st"], capture_output=True, text=True)
    return [int(x) for x in out.stdout.split()]


def recolor(tty: str, seq: bytes) -> None:
    fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY)
    try:
        saved = termios.tcgetattr(fd)
        muted = list(saved)
        muted[3] &= ~(termios.ECHO | termios.ECHOE | termios.ECHOK | termios.ECHONL)
        termios.tcsetattr(fd, termios.TCSANOW, muted)
        os.write(fd, seq)
        termios.tcsetattr(fd, termios.TCSANOW, saved)
    finally:
        os.close(fd)


def load_palette(path: str) -> tuple[dict[int, str], str, str, str]:
    """Parse a `key = #hex` palette file into (colors, foreground, background, cursor)."""
    colors: dict[int, str] = {}
    named: dict[str, str] = {}

    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().lstrip("#")
            if not re.fullmatch(r"[0-9a-fA-F]{6}", value):
                continue
            if key.startswith("color"):
                colors[int(key[len("color"):])] = value.lower()
            else:
                named[key] = value.lower()

    if sorted(colors) != list(range(16)):
        print(f"st-theme: {path}: need color0..color15, got {len(colors)}", file=sys.stderr)
        raise SystemExit(1)

    return colors, named["foreground"], named["background"], named["cursor"]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: st-theme.py <palette file>", file=sys.stderr)
        return 1

    colors, fg, bg, cursor = load_palette(sys.argv[1])

    # OSC 4 takes pairs: "4;index;spec". Specs are X color names, so #rrggbb.
    osc = "".join(f"\x1b]4;{i};#{value}\x07" for i, value in sorted(colors.items()))
    # OSC 10 fg, 11 bg, 12 cursor, then \x15 to repaint.
    osc += f"\x1b]11;#{bg}\x07\x1b]10;#{fg}\x07\x1b]12;#{cursor}\x07\x15"
    seq = osc.encode()

    changed = 0
    for stpid in st_pids():
        children = child_pids(stpid)
        if not children:
            continue
        shell = children[0]
        try:
            tty = os.readlink(f"/proc/{shell}/fd/0")
        except OSError:
            continue
        if not tty.startswith("/dev/pts/"):
            continue
        recolor(tty, osc)
        changed += 1
        time.sleep(0.03)

    if changed:
        print(f"st-theme: recolored {changed} st window(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())