#!/bin/sh

THEME=$1

case "$THEME" in
    light|dark)
        # 1. Update Neovim
        echo 'return "'$THEME'"' > ~/.config/nvim/theme.lua

        # 1b. Update Helix. Helix has no include directive, so rewrite the
        # top-level theme line in config.toml. modus_operandi is light,
        # amberwood dark.
        HX_THEME=amberwood
        [ "$THEME" = light ] && HX_THEME=modus_operandi
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

                # 2c. Publish the palette where st reads it for itself at
                # startup (st-palette.diff, /etc/nixos/users/saifr/). This is
                # what actually fixes a freshly opened window: st allocates
                # its first pixel from this file, so it is born in the current
                # theme rather than flashing from the compiled-in colours
                # before the OSC repaint above can reach it. Written via a
                # temp file in the same directory so a terminal opening at
                # this instant cannot read a half-written palette.
                ST_PALETTE_DIR="$HOME/.config/st"
                mkdir -p "$ST_PALETTE_DIR"
                cp "$ST_THEME" "$ST_PALETTE_DIR/.palette.tmp"
                mv "$ST_PALETTE_DIR/.palette.tmp" "$ST_PALETTE_DIR/palette"
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

        # 5. Nautilus, and every other libadwaita app.
        #
        # Unlike st there is nothing to inject and no wrapper to install. The
        # theme is just the desktop color scheme, which splits persistence and
        # live-update for free: dconf keeps the value, so a window opened later
        # already inherits it, and libadwaita watches the key, so windows
        # already running repaint on their own. That is why this step has no
        # sidecar script and no current-nautilus-theme file -- gsettings is both
        # the knob and the record of what it was last set to.
        #
        # Verified against Nautilus 49.4 (GTK4/libadwaita): the repaint lands in
        # about a second, in both directions, with no restart.
        case "$THEME" in
            dark)  SCHEME='prefer-dark' ;;
            light) SCHEME='prefer-light' ;;
        esac
        if command -v gsettings >/dev/null 2>&1; then
            if gsettings set org.gnome.desktop.interface color-scheme "$SCHEME"; then
                echo "nautilus: color-scheme -> $SCHEME"
            fi
        fi

        # 6. Icon theme, for the icons color-scheme cannot reach.
        #
        # GTK4 picks the icon theme from Net/IconThemeName over XSettings and
        # from nowhere else -- org.gnome.desktop.icons is not in
        # gsettings-desktop-schemas, and gtk-4.0/settings.ini plus a
        # -gtk-icontheme rule are both ignored. So xsettingsd has to be running
        # (i3 autostarts it against this very file), and flipping the theme is
        # a config rewrite plus SIGHUP: the same shape as the Helix step above.
        #
        # There is no stock dark folder to switch to. breeze-dark's folder is
        # byte-identical to breeze's (#3daee9) and Papirus-Dark's to Papirus's
        # (#5294e2); dark variants only recolour symbolic icons, which GTK
        # already adapts by itself. So `dark` selects AdwaitaDark, a generated
        # theme that keeps Adwaita everywhere and darkens the coloured icons
        # under scalable/places. `light` goes back to stock Adwaita.
        CM="$HOME/.config/config-manager"
        if [ "$THEME" = dark ]; then
            DARK_THEME=AdwaitaDark
            # Regenerate when missing, or when a GTK/Adwaita upgrade has moved
            # the source art on, so we never sit on icons that no longer exist.
            GEN="$CM/dark-icons.py"
            # Must match where dark-icons.py writes, which prefers
            # XDG_DATA_HOME over ~/.local/share.
            DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
            OUT="$DATA_HOME/icons/AdwaitaDark/index.theme"
            SRC=$(ls -d /run/current-system/sw/share/icons/Adwaita/index.theme 2>/dev/null)
            if [ -f "$GEN" ] && { [ ! -f "$OUT" ] ||
                { [ -n "$SRC" ] && [ "$SRC" -nt "$OUT" ]; }; }; then
                python3 "$GEN" || true
            fi
        else
            DARK_THEME=Adwaita
        fi

        XS="$CM/xsettingsd.conf"
        mkdir -p "$CM"
        printf 'Net/IconThemeName "%s"\n' "$DARK_THEME" > "$XS"
        if pgrep -x xsettingsd >/dev/null 2>&1; then
            pkill -HUP -x xsettingsd 2>/dev/null \
                && echo "nautilus: icon theme -> $DARK_THEME (xsettingsd signalled)"
        else
            echo "nautilus: icon theme -> $DARK_THEME written to $XS, but xsettingsd is not running (reboot or start it by hand)" >&2
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
