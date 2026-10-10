#!/bin/sh
# st wrapper.
#
# It used to race st's startup and repaint the new window over OSC 4/10/11/12
# as soon as its pty turned up. That whole mechanism existed for one reason:
# st's colours were compiled into the binary, so a new window opened in
# whatever theme was baked in at build time and visibly flipped a moment later
# once the escape sequence landed.
#
# It is gone. st now reads the active palette itself, from ~/.config/st/palette
# (written by theme.sh), before it allocates its first pixel -- see
# st-palette.diff in /etc/nixos/users/saifr/. A new window is therefore born in
# the current theme, and there is nothing left for a wrapper to do.
#
# Repainting windows that are ALREADY open still goes through st-theme.py, which
# theme.sh calls on a theme switch. That has to stay OSC: a running st can only
# be recoloured by being sent escape sequences.
#
# Note ~/.config/config-manager is deliberately not on PATH. This file resolves
# the real st with `command -v`, so putting it on PATH ahead of the store
# binary would make it exec itself.
exec "$(command -v st)" "$@"
