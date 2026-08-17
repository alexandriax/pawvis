#!/usr/bin/env python3
"""Draws the gesture guide's hand glyphs into docs/assets/gestures/*.svg.

One hand, posed. Every glyph is the same palm-forward hand with the fingers
the gesture actually moves folded down and an arrow through the column they
vacated, so the picture says which finger to move rather than gesturing at
"input" in the abstract. That is the whole point of generating them: the poses
have to agree with each other and with the engine (an index dip is the click,
a pinky dip is the right click, middle + ring fold in to scroll), and eight
hand-drawn files drift apart the first time a knuckle line moves.

The same files are used twice: the site inlines them as <img> in the gestures
grid, and scripts/make_app.sh copies them into the app bundle, where the
Gesture Guide draws them as template images. Template rendering keys off alpha
alone, so the app ignores the colors baked in here and tints the whole glyph
with the menu accent; the colors below are the site's own (violet-300 for the
hand, sky-300 for whatever is moving), matching `.glyph` in site.css.

Run it by hand after changing a pose, like scripts/make_banner.sh:

    python3 scripts/make_gesture_glyphs.py
"""
import os

HAND = "#C4B5FD"    # violet-300, site.css --purple-light
ACCENT = "#7DD3FC"  # sky-300, site.css --blue-light

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "docs", "assets", "gestures")

# --- the hand -------------------------------------------------------------
# Palm-forward right hand, fingers up, in a 48x48 box: each finger is a
# stroked line from the knuckle line to its tip, the palm is a U (two sides
# and the wrist), and the thumb curls off the left edge. Stroke width 2 with
# round caps, so the whole set matches the site's other glyphs.
FINGERS = {
    "index":  dict(x=19.0, base=25.5, tip=11.0),
    "middle": dict(x=23.5, base=25.0, tip=8.5),
    "ring":   dict(x=28.0, base=25.5, tip=10.5),
    "little": dict(x=32.0, base=26.5, tip=15.0),
}
PALM = "M17.5 25.5 V33 C17.5 37.5 20 40 25 40 C30 40 33.5 37.5 33.5 33 V25.5"
THUMB = "M17.5 30 C14.5 30.5 11.5 29 10 26"

# How far a dipped finger still rises above its knuckle before hooking
# forward. Short on purpose: the gap it leaves is what makes the dip readable
# at the 44 px the guide and the site both draw these at, and it is where the
# motion arrow goes.
DIP_RISE = 4.5


def finger(name, dipped=False):
    f = FINGERS[name]
    if not dipped:
        return f'M{f["x"]} {f["base"]} V{f["tip"]}'
    return f'M{f["x"]} {f["base"]} V{f["base"] - DIP_RISE} q0 3 2.4 3.6'


def hand(dipped=(), extra="", thumb=THUMB, accent_dipped=True):
    """The hand with `dipped` fingers folded. Folded fingers and the arrows
    take the accent color: on the site they are the thing to look at, and in
    the app they flatten into the tint with everything else. The thumbs-up
    pair passes `accent_dipped=False` (and its own `thumb`): there the thumb
    is the story, so the folded fingers stay quiet."""
    parts = [path(PALM), path(thumb, accent=thumb != THUMB)]
    for name in FINGERS:
        down = name in dipped
        parts.append(path(finger(name, down), accent=down and accent_dipped))
    return "\n  ".join(parts) + (("\n  " + extra) if extra else "")


def path(d, accent=False):
    attrs = f' class="accent" stroke="{ACCENT}"' if accent else ''
    return f'<path{attrs} d="{d}"/>'


# --- motion ---------------------------------------------------------------

def tap_arrow(name, doubled=False):
    """The dip's arrow, dropping through the column the folded finger left
    empty: it reads as "this finger came down from up there"."""
    x = FINGERS[name]["x"]
    bottom = FINGERS[name]["base"] - DIP_RISE - 5.0
    heads = [bottom] + ([bottom - 3.6] if doubled else [])
    d = f'M{x} {bottom - (9.0 if doubled else 5.5)} V{bottom}'
    for y in heads:
        d += f' M{x - 1.8} {y - 2} L{x} {y} L{x + 1.8} {y - 2}'
    return path(d, accent=True)


def updown_arrow(x, top, bottom):
    return path(f'M{x} {top} V{bottom} M{x - 2} {top + 2.2} L{x} {top} '
                f'L{x + 2} {top + 2.2} M{x - 2} {bottom - 2.2} L{x} {bottom} '
                f'L{x + 2} {bottom - 2.2}', accent=True)


def side_arrow(y, x0, x1):
    back = -2.2 if x1 < x0 else 2.2
    return path(f'M{x0} {y} H{x1} M{x1 - back} {y - 2.2} L{x1} {y} '
                f'L{x1 - back} {y + 2.2}', accent=True)


def cursor_dot(x, y):
    """The claw riding the palm: the cursor anchor, drawn where it really
    sits. Filled, so it survives being scaled down to a menu-sized glyph."""
    return f'<circle class="dot" cx="{x}" cy="{y}" r="1.9" fill="{HAND}" stroke="none"/>'


def arrow(x0, y0, x1, y1):
    """A single-headed arrow from (x0,y0) to (x1,y1), any direction — the
    custom gestures' travel (swipes and flings radiate all eight ways)."""
    import math
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    ux, uy = dx / length, dy / length
    head, spread = 3.2, math.radians(32)
    d = f'M{x0} {y0} L{x1} {y1}'
    for sgn in (1, -1):
        hx = x1 - head * (ux * math.cos(spread) - sgn * uy * math.sin(spread))
        hy = y1 - head * (uy * math.cos(spread) + sgn * ux * math.sin(spread))
        d += f' M{round(hx, 1)} {round(hy, 1)} L{x1} {y1}'
    return path(d, accent=True)


def wiggle_marks(points):
    """Little tildes floating over the fingertips: the wiggle itself."""
    return "\n  ".join(
        path(f'M{x - 2.6} {y} q1.3 -2.6 2.6 0 q1.3 2.6 2.6 0', accent=True)
        for x, y in points)


def big_splayed(extra=""):
    """The full-size open hand with the fingers fanned wide — the one-hand
    wiggle pose (the small `splayed_hand` pair stays for two-hand glyphs)."""
    parts = [path(PALM), path(THUMB),
             path('M19 25.5 L13.5 11'),
             path('M23.5 25 L22 8.5'),
             path('M28 25.5 L31.5 10.5'),
             path('M32 26.5 L37.5 15')]
    return "\n  ".join(parts) + (("\n  " + extra) if extra else "")


# --- the poses ------------------------------------------------------------

def splayed_hand(cx, flip=False):
    """Half of the criss-cross wave: an open hand with the fingers fanned,
    small enough that two fit side by side."""
    s = -1 if flip else 1

    def fx(dx):
        return round(cx + s * dx, 2)

    return "\n  ".join(path(d) for d in [
        f'M{fx(-6)} 23 V28 C{fx(-6)} 31.5 {fx(-4)} 33.5 {fx(0)} 33.5 '
        f'C{fx(4)} 33.5 {fx(6)} 31.5 {fx(6)} 28 V23',
        f'M{fx(-4.5)} 23 L{fx(-8)} 13',
        f'M{fx(-1.5)} 22.5 L{fx(-2.5)} 11.5',
        f'M{fx(1.5)} 22.5 L{fx(3)} 12',
        f'M{fx(4.5)} 23.5 L{fx(7.5)} 15',
        f'M{fx(-6)} 27 C{fx(-9.5)} 26.5 {fx(-11.5)} 24.5 {fx(-12)} 21.5',
    ])


GLYPHS = {
    # Control trigger: the open hand, presented to the camera.
    "take-control": hand(extra=(
        path('M7.5 21.5 A11 11 0 0 1 10 14', accent=True) +
        path('M43.5 21.5 A11 11 0 0 0 41 14', accent=True))),

    # Move: the same open hand, the cursor riding the palm, travelling.
    "move": hand(extra=(cursor_dot(25.5, 32) +
                        side_arrow(35, 14.5, 6.5) + side_arrow(35, 36.5, 44.5))),

    # Click: the index dips, everything else stays up.
    "click": hand(("index",), tap_arrow("index")),

    # Double click: the same dip, twice, in the same place.
    "double-click": hand(("index",), tap_arrow("index", doubled=True)),

    # Drag: the index stays down while the hand travels.
    "drag": hand(("index",), tap_arrow("index") + cursor_dot(25.5, 32) +
                 side_arrow(33, 36.5, 45)),

    # Scroll: middle and ring fold in, index and little stay up, and the
    # whole hand travels up and down.
    "scroll": hand(("middle", "ring"), updown_arrow(41.5, 13, 33)),

    # Stop tracking: both hands splayed, waved across each other.
    "stop-tracking": (
        splayed_hand(14.5) + "\n  " + splayed_hand(33.5, flip=True) + "\n  " +
        path('M11.5 39 C19 39 25 45.5 36 45.5 M33.5 43.5 L36 45.5 L33.5 47.5',
             accent=True) + "\n  " +
        path('M36.5 39 C29 39 23 45.5 12 45.5 M14.5 43.5 L12 45.5 L14.5 47.5',
             accent=True)),

    # ---- Custom gestures (Settings → Custom; none bound by default) ----

    # The finger wiggle: fanned fingers with the wiggle floating above them.
    "wiggle": big_splayed(wiggle_marks([(13.5, 6.5), (22, 4.5), (31.5, 6)])),
    "wiggle-two": (splayed_hand(14.5) + "\n  " + splayed_hand(33.5, flip=True) + "\n  " +
                   wiggle_marks([(9, 7.5), (14.5, 6), (33.5, 6), (39, 7.5)])),

    # Thumb signals: the fist stays quiet, the thumb (and its direction)
    # carries the accent.
    "thumbs-up": hand(("index", "middle", "ring", "little"),
                      thumb='M17.5 28 C15.5 27.5 14 25.5 14 22 V15',
                      accent_dipped=False,
                      extra=arrow(9.5, 21, 9.5, 12)),
    "thumbs-down": hand(("index", "middle", "ring", "little"),
                        thumb='M17.5 32 C15.5 32.5 14 34.5 14 38 V45',
                        accent_dipped=False,
                        extra=arrow(9.5, 39, 9.5, 47)),

    "thumbs-left": hand(("index", "middle", "ring", "little"),
                        thumb='M17.5 29.5 C15.5 29.5 13 29.5 9.5 29.5',
                        accent_dipped=False,
                        extra=arrow(13, 23.5, 4.5, 23.5)),
    "thumbs-right": hand(("index", "middle", "ring", "little"),
                         thumb='M33.5 29.5 C35.5 29.5 38 29.5 41.5 29.5',
                         accent_dipped=False,
                         extra=arrow(38, 23.5, 46.5, 23.5)),

    # Shaka: thumb and pinky out, middle three folded in.
    "shaka": hand(("index", "middle", "ring")),

    # Grab & fling: the gathered hand, flung toward an edge or corner.
    "grab-left": hand(("index", "middle", "ring", "little"),
                      extra=arrow(14, 33, 4, 33)),
    "grab-right": hand(("index", "middle", "ring", "little"),
                       extra=arrow(36, 33, 46, 33)),
    "grab-up": hand(("index", "middle", "ring", "little"),
                    extra=arrow(41.5, 30, 41.5, 12)),
    "grab-down": hand(("index", "middle", "ring", "little"),
                      extra=arrow(41.5, 32, 41.5, 46)),
    "grab-up-left": hand(("index", "middle", "ring", "little"),
                         extra=arrow(14, 24, 5, 13)),
    "grab-up-right": hand(("index", "middle", "ring", "little"),
                          extra=arrow(36, 24, 45, 13)),
    "grab-down-left": hand(("index", "middle", "ring", "little"),
                           extra=arrow(14, 38, 5, 46)),
    "grab-down-right": hand(("index", "middle", "ring", "little"),
                            extra=arrow(36, 38, 45, 46)),
}

# Right-click follows the setting, so every finger the picker offers gets its
# own glyph and the guide shows the one that is actually configured.
for finger_name in ("little", "ring", "middle"):
    GLYPHS[f"right-click-{finger_name}"] = hand((finger_name,),
                                                tap_arrow(finger_name))

TEMPLATE = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48" role="img" aria-label="{label}" fill="none" stroke="{hand}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <!-- Generated by scripts/make_gesture_glyphs.py. Edit that, not this. -->
  {body}
</svg>
'''

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, body in sorted(GLYPHS.items()):
        with open(os.path.join(OUT_DIR, name + ".svg"), "w") as fh:
            fh.write(TEMPLATE.format(label=name.replace("-", " "),
                                     hand=HAND, body=body))
    print(f"wrote {len(GLYPHS)} glyphs to docs/assets/gestures/")
