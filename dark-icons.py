#!/usr/bin/env python3
"""Generate an `AdwaitaDark` icon theme: Adwaita with lightness-scaled colours.

Why this exists
---------------
Nautilus 49 is libadwaita, which pins its icon theme internally. GTK4 exposes
no way to reach it -- `org.gnome.desktop.icons` is not in gsettings-desktop-
schemas, `gtk-icon-theme-name` in gtk-4.0/settings.ini is ignored, and a
`-gtk-icontheme` rule in gtk-4.0/gtk.css is ignored. The one key GTK4 does read
is `Net/IconThemeName` over XSettings, so selecting a *different theme* is the
only lever there is.

The obvious pick, `breeze-dark`, does not help: its folder body is byte-identical
to `breeze` (#3daee9), and Papirus-Dark's is identical to Papirus's (#5294e2).
Dark variants in every mainstream theme recolour only *symbolic* icons; the
coloured folder is deliberately shared. So the folder has to be darkened here.

What it does
------------
Copies Adwaita's `scalable/places` icons and rewrites every colour in HSL:
hue and saturation are preserved, lightness is scaled. That matters -- scaling
RGB toward black instead flattens these files, because #a4caee, #afd4ff and
#c0d5ea are all in the same narrow light band and converge into one grey. In
HSL the highlight at #afd4ff stays visibly lighter than the #a4caee face, so the
folder keeps its shape.

The output theme inherits `Adwaita`, so every icon we do not touch stays
byte-identical to what you have now; only folders, Home, Desktop, Trash and the
Documents/Music/Pictures/Downloads icons change.

Selection is `theme.sh`'s job -- it points `Net/IconThemeName` at this theme and
SIGHUPs xsettingsd. Regenerate after a GTK/Adwaita upgrade to pick up new art.

Usage: dark-icons.py [--factor FLOAT] [--subdir NAME]...
"""

from __future__ import annotations

import argparse
import colorsys
import os
import re
import sys

THEME_NAME = "AdwaitaDark"
BASE_THEME = "Adwaita"
DEFAULT_SUBDIRS = ["places"]

# The [scalable/places] directory stanza in Adwaita's index.theme. Copied
# verbatim: icon lookup matches Context=Places for folder.svg in Adwaita, so
# deviating here would make GTK skip our override and fall through to Adwaita.
DIR_STANZA = """[scalable/{subdir}]
Context={context}
Size=128
MinSize=8
MaxSize=512
Type=Scalable
"""

HEX = re.compile(r"#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b")


def find_base_theme() -> str:
    """Locate the bundled Adwaita icon theme via the normal XDG search path."""
    roots = [os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")]
    roots += os.environ.get("XDG_DATA_DIRS", "/usr/share").split(":")
    roots += ["/run/current-system/sw/share"]
    for root in roots:
        if not root:
            continue
        candidate = os.path.join(root, "icons", BASE_THEME)
        if os.path.isfile(os.path.join(candidate, "index.theme")):
            return candidate
    raise SystemExit(f"dark-icons: cannot find the {BASE_THEME} icon theme on XDG_DATA_DIRS")


def darken_hex(digits: str, factor: float) -> str:
    width = len(digits)
    r, g, b = (int(digits[i : i + 2], 16) for i in (0, 2, 4))
    a = int(digits[6:8], 16) if width == 8 else None

    h, s, lightness = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
    r, g, b = colorsys.hls_to_rgb(h, min(lightness * factor, 1.0), s)
    parts = [round(r * 255), round(g * 255), round(b * 255)]
    if a is not None:
        parts.append(a)
    return "#" + "".join(f"{min(255, max(0, c)):02x}" for c in parts)


def rewrite(text: str, factor: float) -> tuple[str, int]:
    changed = 0

    def sub(match: re.Match) -> str:
        nonlocal changed
        before = match.group(1)
        after = darken_hex(before, factor)
        if after != "#" + before.lower():
            changed += 1
        return after

    return HEX.sub(sub, text), changed


def main() -> int:
    parser = argparse.ArgumentParser(description=f"Generate the {THEME_NAME} icon theme.")
    parser.add_argument("--factor", type=float, default=0.62,
                        help="lightness multiplier for generated colours (default: 0.62)")
    parser.add_argument("--subdir", action="append", dest="subdirs",
                        help="Adwaita scalable/ subdirectory to darken (repeatable)")
    args = parser.parse_args()

    subdirs = args.subdirs or DEFAULT_SUBDIRS
    base = find_base_theme()
    dest_root = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    dest = os.path.join(dest_root, "icons", THEME_NAME)

    written = 0
    stanzas = []
    for subdir in subdirs:
        src_dir = os.path.join(base, "scalable", subdir)
        if not os.path.isdir(src_dir):
            print(f"dark-icons: no scalable/{subdir} in {base}", file=sys.stderr)
            continue
        out_dir = os.path.join(dest, "scalable", subdir)
        os.makedirs(out_dir, exist_ok=True)
        for name in sorted(os.listdir(src_dir)):
            if not name.endswith(".svg"):
                continue
            with open(os.path.join(src_dir, name)) as fh:
                text, _ = rewrite(fh.read(), args.factor)
            with open(os.path.join(out_dir, name), "w") as fh:
                fh.write(text)
            written += 1
        # Context comes from Adwaita's own directory stanza so we inherit its
        # icon-lookup behaviour rather than guessing.
        context = "Places"
        with open(os.path.join(base, "index.theme")) as fh:
            body = fh.read()
        match = re.search(rf"^\[scalable/{re.escape(subdir)}\]\s*$(.*?)(?=^\[|\Z)",
                          body, re.M | re.S)
        if match:
            found = re.search(r"^Context=(.+)$", match.group(1), re.M)
            if found:
                context = found.group(1).strip()
        stanzas.append(DIR_STANZA.format(subdir=subdir, context=context))

    if not written:
        print("dark-icons: nothing written", file=sys.stderr)
        return 1

    os.makedirs(dest, exist_ok=True)
    with open(os.path.join(dest, "index.theme"), "w") as fh:
        fh.write(f"[Icon Theme]\nName={THEME_NAME}\nComment=Adwaita with darkened "
                 f"colours, generated by dark-icons.py\nInherits={BASE_THEME}\n")
        fh.write("Directories=" + ",".join(f"scalable/{s}" for s in subdirs) + "\n")
        fh.write("\n".join(stanzas))

    print(f"dark-icons: wrote {written} icon(s) to {dest} "
          f"(factor {args.factor}, subdirs {','.join(subdirs)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())