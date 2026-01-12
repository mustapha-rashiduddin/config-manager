#!/bin/sh

THEME=$1

if [ -z "$THEME" ]; then
    echo "Usage: theme [light|dark]"
    exit 1
fi

# 1. Update Neovim
echo 'return "'$THEME'"' > ~/.config/nvim/theme.lua

# 2. Update Ghostty Config
# Uses --follow-symlinks so it doesn't break your Stow setup
sed --follow-symlinks -i "s|^config-file = theme_colors_.*|config-file = theme_colors_$THEME|" ~/.config/ghostty/theme_colors

# 3. Force Ghostty Reload (Ctrl + Shift + ,)
#echo "Reloading Ghostty..."

if command -v wtype >/dev/null 2>&1; then
    # Wayland Method
    # Press modifiers -> Press comma -> Release modifiers
    wtype -M ctrl -M shift -k comma -m ctrl -m shift
elif command -v xdotool >/dev/null 2>&1; then
    # X11 Method
    xdotool key ctrl+shift+comma
else
    echo "Warning: Could not reload Ghostty. Install 'wtype' (Wayland) or 'xdotool' (X11)."
fi

# echo "Switched System to $THEME"
