#!/usr/bin/env python3
"""Draws the gesture hand glyphs into docs/assets/gestures/*.svg.

Two sets from one drawing kit, so the poses can never disagree:

- The 48x48 *icons* (`click.svg`, `wiggle-pointed.svg`, ...): one posed hand
  per gesture, used by the Settings rows and the site's gestures grid.
- The 104x48 *guide panels* (`full-*.svg`): the whole gesture, not just its
  end pose — the before-and-after of a click, the gather-then-fling of a
  grab, the drumming fingers of a wiggle — drawn as one or two panels with
  motion arrows. The Gesture Guide leads every row with one of these.

Every glyph is built from the same palm-forward hand (or the side-view hand
for the pointed wiggle) with the fingers the gesture actually moves folded
down and an arrow through the column they vacated, so the picture says which
finger to move rather than gesturing at "input" in the abstract. That is the
whole point of generating them: the poses have to agree with each other and
with the engine (an index dip is the click, a pinky dip is the right click,
middle + ring fold in to scroll), and dozens of hand-drawn files drift apart
the first time a knuckle line moves.

The same files are used twice: the site inlines icons as <img> in the
gestures grid, and scripts/make_app.sh copies everything into the app bundle,
where Settings and the Gesture Guide draw them as template images. Template
rendering keys off alpha alone, so the app ignores the colors baked in here
and tints the whole glyph with the menu accent; the colors below are the
site's own (violet-300 for the hand, sky-300 for whatever is moving),
matching `.glyph` in site.css.

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


SPLAYED_FINGERS = [((19, 25.5), (13.5, 11)), ((23.5, 25), (22, 8.5)),
                   ((28, 25.5), (31.5, 10.5)), ((32, 26.5), (37.5, 15))]


def big_splayed_curled(extra=""):
    """The splayed hand mid-wiggle: every finger at half reach, hooking
    toward the palm — the guide's second wiggle frame."""
    parts = [path(PALM), path(THUMB)]
    for (bx, by), (tx, ty) in SPLAYED_FINGERS:
        dx, dy = tx - bx, ty - by
        length = (dx * dx + dy * dy) ** 0.5
        ux, uy = dx / length, dy / length
        mx, my = bx + 0.58 * dx, by + 0.58 * dy
        # Perpendicular chosen to point back toward the palm center.
        px, py = -uy, ux
        if px * (25.5 - mx) + py * (31 - my) < 0:
            px, py = -px, -py
        cx, cy = mx + ux * 3.2, my + uy * 3.2
        ex, ey = mx + ux * 1.6 + px * 4.6, my + uy * 1.6 + py * 4.6
        parts.append(path(
            f'M{bx} {by} L{round(mx, 1)} {round(my, 1)} '
            f'Q{round(cx, 1)} {round(cy, 1)} {round(ex, 1)} {round(ey, 1)}'))
    return "\n  ".join(parts) + (("\n  " + extra) if extra else "")


def pointed_profile(extra=""):
    """The pointed wiggle's hand, seen from the side: flat, palm down,
    fingers toward the screen (drawn pointing right). The one glyph not
    built on the palm-forward hand — a hand pointed at the camera projects
    to nothing, so the guide shows the pose the way the *user* sees it."""
    parts = [path(d) for d in [
        'M7 25.5 C12 22.5 18 21.5 24.5 21.8',      # back of the hand
        'M7 25.5 V33.5',                           # wrist
        'M7 33.5 C12 35 17 34.8 21.5 33.8',        # underside
        'M21.5 33.8 C23.5 35.8 26 36.5 28.5 36',   # thumb, tucked below
        'M24.5 21.8 C30.5 21.4 35.5 22.2 40 24.2',  # fingers, staggered
        'M25 25.2 C31 25.1 36 26 40.8 28',
        'M24 28.6 C30 29.1 34.5 30 38 31.6',
    ]]
    return "\n  ".join(parts) + (("\n  " + extra) if extra else "")


# --- guide panels ---------------------------------------------------------
# The `full-*` set: the whole gesture in a 104x48 strip, one or two panels.

def group(body, tx=0.0, ty=0.0, s=1.0):
    """Place a 48-box drawing inside the wide strip. Stroke width is scaled
    back up so every panel keeps the same 2px line."""
    stroke = round(2 / s, 2)
    return (f'<g transform="translate({tx} {ty}) scale({s})" stroke-width="{stroke}">'
            f'\n  {body}\n  </g>')


def chevron(x, y=24):
    """Panel separator: and-then."""
    return path(f'M{x - 1.5} {y - 4} L{x + 2.5} {y} L{x - 1.5} {y + 4}')


def accent_circle(cx, cy, r):
    return f'<circle class="accent" cx="{cx}" cy="{cy}" r="{r}" stroke="{ACCENT}" fill="none"/>'


def clock(cx, cy, r=4.4):
    """Hold it for a beat: a small clock face."""
    return (accent_circle(cx, cy, r) + "\n  " +
            path(f'M{cx} {round(cy - r + 1.6, 1)} V{cy} L{round(cx + r - 1.8, 1)} {round(cy + 1.2, 1)}',
                 accent=True))


def screen_edge(x=88):
    """The screen the pointed wiggle points at: a slim display on its stand."""
    return "\n  ".join([
        f'<rect x="{x}" y="7" width="9" height="31" rx="2.5"/>',
        path(f'M{x + 4.5} 38 V42 M{x + 1} 42 H{x + 8}'),
    ])


def rosette(cx, cy, inner=5.0, outer=10.0):
    """Four small arrows radiating from a dot — the this-way-or-that badge
    (the four thumb directions, the fling's edges and corners)."""
    parts = [f'<circle class="dot" cx="{cx}" cy="{cy}" r="1.5" fill="{HAND}" stroke="none"/>']
    for ux, uy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        parts.append(arrow(cx + ux * inner, cy + uy * inner,
                           cx + ux * outer, cy + uy * outer))
    return "\n  ".join(parts)


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

    # The raised finger wiggle: fanned fingers, the wiggle floating above.
    "wiggle": big_splayed(wiggle_marks([(13.5, 6.5), (22, 4.5), (31.5, 6)])),
    "wiggle-two": (splayed_hand(14.5) + "\n  " + splayed_hand(33.5, flip=True) + "\n  " +
                   wiggle_marks([(9, 7.5), (14.5, 6), (33.5, 6), (39, 7.5)])),

    # The pointed wiggle: the side-view hand, fingers drumming toward the
    # screen — the desk posture, not the raised palm.
    "wiggle-pointed": pointed_profile(
        wiggle_marks([(36, 13.5)]) + "\n  " + updown_arrow(44.5, 18, 33)),
    "wiggle-pointed-two": (
        group(pointed_profile(wiggle_marks([(36.5, 15.5)])), tx=2, ty=-7, s=0.68) + "\n  " +
        group(pointed_profile(wiggle_marks([(36.5, 15.5)])), tx=2, ty=15, s=0.68) + "\n  " +
        updown_arrow(37.5, 20, 30)),

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


# --- the guide panels -----------------------------------------------------
# One per Gesture Guide row: the whole gesture as one or two 48-box panels
# placed in a 104x48 strip, and-then chevrons between stages.

FIST = ("index", "middle", "ring", "little")

GUIDE_GLYPHS = {
    # Take control: a parked fist, and then the open hand that arms it.
    "full-take-control": (
        group(hand(FIST, accent_dipped=False), tx=2, ty=4.3, s=0.82) + "\n  " +
        chevron(46) + "\n  " +
        group(hand(extra=(path('M7.5 21.5 A11 11 0 0 1 10 14', accent=True) +
                          path('M43.5 21.5 A11 11 0 0 0 41 14', accent=True))),
              tx=56, ty=4.3, s=0.82)),

    # Move: the open hand, the cursor riding the palm, travelling the strip.
    "full-move": (
        group(hand(extra=cursor_dot(25.5, 32)), tx=28, ty=1, s=0.95) + "\n  " +
        side_arrow(31.5, 22, 6) + "\n  " + side_arrow(31.5, 82, 98)),

    # Click: fingers up, and then the index dips.
    "full-click": (
        group(hand(), tx=2, ty=4.3, s=0.82) + "\n  " +
        chevron(46) + "\n  " +
        group(hand(("index",), tap_arrow("index")), tx=56, ty=4.3, s=0.82)),

    # Drag: the dip, and then travel while it holds.
    "full-drag": (
        group(hand(("index",), tap_arrow("index")), tx=2, ty=4.3, s=0.82) + "\n  " +
        chevron(46) + "\n  " +
        group(hand(("index",), cursor_dot(25.5, 32) + side_arrow(33, 36.5, 47)),
              tx=56, ty=4.3, s=0.82)),

    # Scroll: the fold-in pose, the parked cursor, the hand riding up and down.
    "full-scroll": (
        group(hand(("middle", "ring"), cursor_dot(25.5, 32)), tx=22, ty=1, s=0.95) + "\n  " +
        updown_arrow(78, 10, 38)),

    # Stop tracking: the double high-five trading sides, drawn big.
    "full-stop-tracking": group(
        splayed_hand(14.5) + "\n  " + splayed_hand(33.5, flip=True) + "\n  " +
        path('M11.5 39 C19 39 25 45.5 36 45.5 M33.5 43.5 L36 45.5 L33.5 47.5',
             accent=True) + "\n  " +
        path('M36.5 39 C29 39 23 45.5 12 45.5 M14.5 43.5 L12 45.5 L14.5 47.5',
             accent=True),
        tx=20.6, ty=-6.6, s=1.15),

    # Raised wiggle: fingers fanned and up, and then curling — back and forth.
    "full-wiggle": (
        group(big_splayed(wiggle_marks([(13.5, 6.5), (22, 4.5), (31.5, 6)])),
              tx=0, ty=2, s=0.9) + "\n  " +
        side_arrow(20, 45, 56) + "\n  " + side_arrow(27, 56, 45) + "\n  " +
        group(big_splayed_curled(wiggle_marks([(15, 10), (24, 8), (32.5, 9.5)])),
              tx=60, ty=2, s=0.9)),

    # Pointed wiggle: the side-view hand drumming its fingers at the screen.
    "full-wiggle-pointed": (
        group(pointed_profile(), tx=10, ty=-2, s=1.12) + "\n  " +
        wiggle_marks([(46, 14), (55, 18)]) + "\n  " +
        updown_arrow(66, 16, 34) + "\n  " + screen_edge(86)),

    # Thumb signals: the fist with the thumb out, held for a beat, any of
    # four ways.
    "full-thumbs": (
        group(hand(FIST, thumb='M17.5 28 C15.5 27.5 14 25.5 14 22 V15',
                   accent_dipped=False, extra=arrow(9.5, 21, 9.5, 12)),
              tx=8, ty=3, s=0.88) + "\n  " +
        clock(56, 12) + "\n  " + rosette(80, 27, inner=5, outer=12)),

    # Shaka: thumb and pinky out, held for a beat.
    "full-shaka": (
        group(hand(("index", "middle", "ring")), tx=22, ty=2, s=0.92) + "\n  " +
        clock(74, 13)),

    # Grab & fling: the open hand gathering onto the thumb (arrows in the
    # finger gaps converging on the bunch), and then the bunch flung toward
    # any edge or corner.
    "full-grab": (
        group(hand(extra=(arrow(20.8, 12.5, 22.6, 17.5) + "\n  " +
                          arrow(25.8, 11, 24.6, 16.5) + "\n  " +
                          arrow(30.2, 13, 26.4, 17.8) + "\n  " +
                          arrow(12, 24, 19.5, 21.8) + "\n  " +
                          cursor_dot(23.7, 20.8))),
              tx=2, ty=4.3, s=0.82) + "\n  " +
        chevron(46) + "\n  " +
        group(hand(FIST, accent_dipped=False), tx=52, ty=4.3, s=0.82) + "\n  " +
        rosette(91, 24, inner=5, outer=12)),
}

for finger_name in ("little", "ring", "middle"):
    GUIDE_GLYPHS[f"full-right-click-{finger_name}"] = (
        group(hand(), tx=2, ty=4.3, s=0.82) + "\n  " +
        chevron(46) + "\n  " +
        group(hand((finger_name,), tap_arrow(finger_name)), tx=56, ty=4.3, s=0.82))

TEMPLATE = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 48" width="{w}" height="48" role="img" aria-label="{label}" fill="none" stroke="{hand}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <!-- Generated by scripts/make_gesture_glyphs.py. Edit that, not this. -->
  {body}
</svg>
'''

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, body in sorted(GLYPHS.items()) + sorted(GUIDE_GLYPHS.items()):
        width = 104 if name.startswith("full-") else 48
        with open(os.path.join(OUT_DIR, name + ".svg"), "w") as fh:
            fh.write(TEMPLATE.format(label=name.replace("-", " "),
                                     hand=HAND, body=body, w=width))
    print(f"wrote {len(GLYPHS)} icons + {len(GUIDE_GLYPHS)} guide panels "
          "to docs/assets/gestures/")
