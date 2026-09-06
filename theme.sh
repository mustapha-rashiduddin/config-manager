#!/bin/sh

THEME=$1

case "$THEME" in
    light|dark)
        # 1. Update Neovim
        echo 'return "'$THEME'"' > ~/.config/nvim/theme.lua

        # 2. Update every running st window (fg/bg/cursor via OSC 10/11/12)
        ST_THEME="$HOME/.config/config-manager/st_colors_$THEME"
        if [ -f "$ST_THEME" ]; then
            ST_FG=$(sed -n 's/^foreground *= *//p' "$ST_THEME" | tail -1)
            ST_BG=$(sed -n 's/^background *= *//p' "$ST_THEME" | tail -1)
            if [ -n "$ST_FG" ] && [ -n "$ST_BG" ]; then
                python3 "$HOME/.config/config-manager/st-theme.py" "$ST_FG" "$ST_BG"
            fi
        fi
        ;;

    clight|cdark)
        # Update Ghostty (cosmic) config
        # Uses --follow-symlinks so it doesn't break your Stow setup
        sed --follow-symlinks -i "s|^config-file = theme_colors_.*|config-file = theme_colors_$THEME|" ~/.config/ghostty/theme_colors
        ;;

    *)
        echo "Usage: theme [light|dark|clight|cdark]"
        exit 1
        ;;
esac