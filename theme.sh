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
                # Persist so new st windows start with this theme.
                printf '%s\n' "${ST_FG#\#}" > "$HOME/.config/config-manager/current-st-fg"
                printf '%s\n' "${ST_BG#\#}" > "$HOME/.config/config-manager/current-st-bg"
            fi
        fi

        # 3. Update Emacs theme, applied immediately if open
        case "$THEME" in
            light) EMACS_THEME="ef-day" ;;
            dark)  EMACS_THEME="ef-cherie" ;;
        esac
        EMACS_DB="$HOME/emacs-speed-dial/speed-dial.sqlite"
        if [ -f "$EMACS_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$EMACS_DB" "INSERT OR REPLACE INTO state (key, value) VALUES ('ef_theme', '$EMACS_THEME');" 2>/dev/null
        fi
        if command -v emacsclient >/dev/null 2>&1; then
            emacsclient -e "(progn (mapc #'disable-theme custom-enabled-themes) (load-theme '$EMACS_THEME t))" >/dev/null 2>&1
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