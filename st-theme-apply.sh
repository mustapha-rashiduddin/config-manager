# Apply the persisted st theme (OSC 10/11/12) when a fresh st shell starts.
# Sourced from ~/.mkshrc; only acts when the shell's parent is st itself.
STFG=$HOME/.config/config-manager/current-st-fg
STBG=$HOME/.config/config-manager/current-st-bg
if [ "$(ps -o comm= -p "$PPID" 2>/dev/null)" = "st" ] && [ -s "$STFG" ] && [ -s "$STBG" ]; then
    command printf '\033]11;#%s\007\033]10;#%s\007\033]12;#%s\007' \
        "$(cat "$STBG")" "$(cat "$STFG")" "$(cat "$STFG")"
fi