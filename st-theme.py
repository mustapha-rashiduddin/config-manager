#!/usr/bin/env python3
"""Recolor every running st window to the given fg/bg via OSC 10/11/12.

st (>= 0.9) handles these dynamic-color OSC sequences natively and redraws
live. We deliver them by writing to each st shell's controlling pty on the
*output* path (the slave /dev/pts/N). Bytes written to the slave are parsed by
st as output and can never be read as input by whatever program is in the
foreground, so recoloring a window mid-app (nvim, litecli, erd, ...) is safe
and applies instantly to transparent-background apps.

Usage: st-theme.py <foreground hex> <background hex>
"""

import os
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


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: st-theme.py <fg> <bg>", file=sys.stderr)
        return 1
    fg, bg = sys.argv[1].lstrip("#"), sys.argv[2].lstrip("#")
    osc = ("\x1b]11;#%s\x07\x1b]10;#%s\x07\x1b]12;#%s\x07\x15" % (bg, fg, fg)).encode()

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