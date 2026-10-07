#!/bin/sh

THEME=$1

case "$THEME" in
    light|dark)
        # 1. Update Neovim
        echo 'return "'$THEME'"' > ~/.config/nvim/theme.lua

        # 1b. Update Helix. Helix has no include directive, so rewrite the
        # top-level theme line in config.toml. acme is light, amberwood dark.
        HX_THEME=amberwood
        [ "$THEME" = light ] && HX_THEME=acme
        HX_CONFIG="$HOME/.config/helix/config.toml"
        if [ -f "$HX_CONFIG" ]; then
            sed --follow-symlinks -i \
                "s|^theme *= *\"[^\"]*\"|theme = \"$HX_THEME\"|" "$HX_CONFIG"
        fi
        # Repaint every running Helix immediately. SIGUSR1 makes Helix re-read
        # config.toml and apply the new theme live (book/src/configuration.md).
        # This is why no remote-control channel is needed: the file we just
        # rewrote above is the single source of truth, and the signal tells
        # each running instance to reload it.
        pkill -USR1 -x hx 2>/dev/null && echo "hx: signalled to reload theme" || true

        # 2. Update every running st window. st-theme.py emits OSC 4 for the
        # full ANSI palette plus OSC 10/11/12 for fg/bg/cursor.
        ST_THEME="$HOME/.config/config-manager/st_colors_$THEME"
        if [ -f "$ST_THEME" ]; then
            ST_FG=$(sed -n 's/^foreground *= *//p' "$ST_THEME" | tail -1)
            ST_BG=$(sed -n 's/^background *= *//p' "$ST_THEME" | tail -1)
            if [ -n "$ST_FG" ] && [ -n "$ST_BG" ]; then
                python3 "$HOME/.config/config-manager/st-theme.py" "$ST_THEME"
                # Persist so new st windows start with this theme.
                printf '%s\n' "$THEME" > "$HOME/.config/config-manager/current-st-theme"
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
        if [ "${EMACS_APPLY:-1}" != "0" ] && command -v emacsclient >/dev/null 2>&1; then
            emacsclient -e "(progn (mapc #'disable-theme custom-enabled-themes) (load-theme '$EMACS_THEME t))" >/dev/null 2>&1
        fi

        # 4. Update Dark Reader in any running loadout Chrome profiles.
        if [ -x "$HOME/.config/i3/loadout.py" ]; then
            "$HOME/.config/i3/loadout.py" chrome-theme "$THEME"
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
