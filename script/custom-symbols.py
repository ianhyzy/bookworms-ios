#!/usr/bin/env python3
"""Draws the app's custom symbols as SF Symbols variable templates in the asset catalog.

Each symbol is built from rounded rectangles and circles, drawn at three weights (Ultralight,
Regular, and Black, at the small scale) with the same path commands, so the system interpolates
every other weight and scale. Run it from the repository root after changing a shape:
`python3 script/custom-symbols.py`. Open a symbol in the SF Symbols app to refine it by hand.
"""
import json
import math
from pathlib import Path

ASSETS = Path("Bookworms/Assets.xcassets")
K = 0.5523  # Cubic Bézier handle length for a quarter circle.
# Stroke widths at each weight, in template units (cap height 70.459).
WEIGHTS = {"Ultralight": 2.4, "Regular": 6.0, "Black": 11.0}
COLUMNS = {"Ultralight": 559.711, "Regular": 1449.84, "Black": 2933.4}
BASELINE = 696


class Path2D:
    def __init__(self):
        self.parts = []

    def move(self, p):
        self.parts.append(("M", [p]))

    def line(self, p):
        self.parts.append(("L", [p]))

    def curve(self, a, b, p):
        self.parts.append(("C", [a, b, p]))

    def close(self):
        self.parts.append(("Z", []))

    def transformed(self, f):
        out = Path2D()
        out.parts = [(c, [f(p) for p in ps]) for c, ps in self.parts]
        return out

    def reversed(self):
        """The same closed outline, traced the other way, for a hole in a filled shape."""
        points = [self.parts[0][1][0]]
        for command, ps in self.parts[1:]:
            if ps:
                points.append(ps[-1])
        out = Path2D()
        out.move(points[-1])
        segments = [(c, ps) for c, ps in self.parts[1:] if ps]
        for index in range(len(segments) - 1, -1, -1):
            command, ps = segments[index]
            back = points[index]
            if command == "L":
                out.line(back)
            else:
                out.curve(ps[1], ps[0], back)
        out.close()
        return out

    def svg(self):
        def n(v):
            text = f"{v:.4f}".rstrip("0").rstrip(".")
            return "0" if text in ("-0", "") else text
        return "".join(c + " ".join(f"{n(x)} {n(y)}" for x, y in ps) for c, ps in self.parts)


def rrect(x, y, w, h, r, reverse=False):
    """A rounded rectangle from its top-left corner, clockwise on screen, or counterclockwise."""
    r = max(0.01, min(r, w / 2, h / 2))
    corners = [  # (start of corner arc, handle 1, handle 2, end), clockwise from the top edge.
        ((x + w - r, y), (x + w - r + K * r, y), (x + w, y + r - K * r), (x + w, y + r)),
        ((x + w, y + h - r), (x + w, y + h - r + K * r), (x + w - r + K * r, y + h), (x + w - r, y + h)),
        ((x + r, y + h), (x + r - K * r, y + h), (x, y + h - r + K * r), (x, y + h - r)),
        ((x, y + r), (x, y + r - K * r), (x + r - K * r, y), (x + r, y)),
    ]
    p = Path2D()
    p.move(corners[3][3])
    for start, a, b, end in corners:
        p.line(start)
        p.curve(a, b, end)
    p.close()
    return p.reversed() if reverse else p


def ring(x, y, w, h, r, stroke):
    """A rounded rectangle's outline, `stroke` wide, inside the rectangle."""
    return [rrect(x, y, w, h, r), rrect(x + stroke, y + stroke, w - 2 * stroke, h - 2 * stroke,
                                        max(0.5, r - stroke), reverse=True)]


def circle(cx, cy, r, reverse=False):
    return rrect(cx - r, cy - r, 2 * r, 2 * r, r, reverse)


def rotated(paths, angle, pivot):
    c, s = math.cos(angle), math.sin(angle)

    def f(p):
        x, y = p[0] - pivot[0], p[1] - pivot[1]
        return (pivot[0] + x * c - y * s, pivot[1] + x * s + y * c)
    return [p.transformed(f) for p in paths]


def star(cx, cy, r, waist):
    """A four-pointed sparkle, like a foil stamp's glint."""
    p = Path2D()
    p.move((cx, cy - r))
    for (tx, ty), (hx, hy) in [((cx + r, cy), (cx + waist, cy - waist)),
                               ((cx, cy + r), (cx + waist, cy + waist)),
                               ((cx - r, cy), (cx - waist, cy + waist)),
                               ((cx, cy - r), (cx - waist, cy - waist))]:
        p.curve((hx, hy), (hx, hy), (tx, ty))
    p.close()
    return p


# Shapes in template units: y runs down from the cap line (-70.459) to the baseline (0).
def share_card(w, filled=False):
    """The Share tab: a keepsake card that shows a small stack of books over a caption line.
    Filled, the card is solid and the books and caption are cut out of it."""
    width = 54 + w
    paths = [rrect(0, -76, width, 82, 10)] if filled else ring(0, -76, width, 82, 10, w)
    bar = 5 + w * 0.45
    inside = width - 2 * w
    # Three books lying flat on each other, each shifted a little left or right.
    top = -76 + w + 9
    for left, length in [(0.2, 0.62), (0.13, 0.7), (0.24, 0.58)]:
        paths.append(rrect(w + inside * left, top, inside * length, bar, bar * 0.3, filled))
        top += bar + 1.6
    paths.append(rrect(w + inside * 0.18, 6 - w - 9 - max(2.2, w * 0.5), inside * 0.64,
                       max(2.2, w * 0.5), 1.1, filled))
    return paths, width


def spine_foil(w, filled=False):
    """The Spines tab: an upright book spine with bands and a foil stamp, and a glint. Filled,
    the spine is solid and the bands and stamp are cut out of it."""
    width = 22 + 1.4 * w
    paths = [rrect(0, -76, width, 82, 4.5)] if filled else ring(0, -76, width, 82, 4.5, w)
    band = max(2, w * 0.5)
    inset = w + 3
    paths.append(rrect(inset, -76 + w + 7, width - 2 * inset, band, band / 2, filled))
    paths.append(rrect(inset, 6 - w - 7 - band, width - 2 * inset, band, band / 2, filled))
    stamp = star(width / 2, -35, (width - 2 * inset) / 2 + 1.5, 1 + w * 0.12)
    paths.append(stamp.reversed() if filled else stamp)
    paths.append(star(width + 15, -66, 8 + w * 0.3, 1.3 + w * 0.1))
    return paths, width + 23 + w * 0.3


def dominoes(w):
    """Dominoes: books standing on end on a floor, the first toppling against the second."""
    thick = 9 + w * 0.6
    height = 64
    floor = max(2.4, w * 0.6)
    gap = 14
    first = 20  # The first book's leading face, where it pivots, before it tips.
    stand = -floor + 0.4  # The books' bottoms overlap the floor a little, so they stand on it.
    paths = []
    for index in (1, 2):
        paths.append(rrect(first + index * (thick + gap), stand - height, thick, height, 2.5))
    # The first book pivots on its leading bottom corner and leans on the second's face; the
    # slight overlap closes the gap its rounded corner would leave.
    face = first + thick + gap
    tilt = math.asin((face - first + 0.8) / height)
    book = [rrect(first - thick, stand - height, thick, height, 2.5)]
    paths += rotated(book, tilt, (first, stand))
    right = first + 2 * (thick + gap) + thick + 6
    paths.append(rrect(0, -floor, right, floor, floor / 2))
    return paths, right


def bookworm(w):
    """The menu bar: a bookworm lying on top of an upright book."""
    paths = ring(4, -58, 40, 64, 6, w)
    paths.append(rrect(4 + w + 4, -58 + w + 2, max(2, w * 0.6), 64 - 2 * w - 4, 1))
    # The worm: two body segments and a head with an eye, resting on the book's top edge.
    seg = 6.5 + w * 0.25
    rest = -58 + 0.4
    paths.append(circle(13, rest - seg, seg))
    paths.append(circle(13 + 2 * seg - 1, rest - seg, seg))
    head_r = seg + 2.5
    head_x, head_y = 13 + 4 * seg, rest - head_r - 3
    paths.append(circle(head_x, head_y, head_r))
    paths.append(circle(head_x + head_r * 0.3, head_y - head_r * 0.2, max(1.4, head_r * 0.27),
                        reverse=True))
    return paths, max(48, head_x + head_r + 2)


# Named for where the app uses them.
# A tab bar shows a tab's symbol filled when a ".fill" variant exists.
SYMBOLS = {
    "tab.share": share_card,
    "tab.share.fill": lambda w: share_card(w, filled=True),
    "tab.spines": spine_foil,
    "tab.spines.fill": lambda w: spine_foil(w, filled=True),
    "desk.dominoes": dominoes,
    "menubar.bookworm": bookworm,
}

HEADER = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg
PUBLIC "-//W3C//DTD SVG 1.1//EN"
       "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--glyph: "", point size: 100.0, font version: "", template writer version: "101"-->
 <style>.monochrome-0 {fill:#000000}
.multicolor-0:tintColor {fill:#007AFF}
.hierarchical-0:primary {fill:#212121}
</style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.4.0</text>
 </g>
 <g id="Guides">
"""
GUIDE = '  <line id="{id}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{y}" y2="{y}"/>\n'
MARGIN = '  <line id="{id}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{x:.3f}" x2="{x:.3f}" y1="600.785" y2="720.121"/>\n'
SIDE_BEARING = 4


def svg(draw):
    out = HEADER
    for scale, base in (("S", 696), ("M", 1126), ("L", 1556)):
        out += GUIDE.format(id=f"Baseline-{scale}", y=base)
        out += GUIDE.format(id=f"Capline-{scale}", y=f"{base - 70.459:.3f}".rstrip("0"))
    glyphs = {}
    for weight, stroke in WEIGHTS.items():
        paths, width = draw(stroke)
        advance = width + 2 * SIDE_BEARING
        left = COLUMNS[weight] - advance / 2
        glyphs[weight] = (paths, left)
        out += MARGIN.format(id=f"left-margin-{weight}-S", x=left)
        out += MARGIN.format(id=f"right-margin-{weight}-S", x=left + advance)
    out += " </g>\n <g id=\"Symbols\">\n"
    for weight in ("Black", "Regular", "Ultralight"):
        paths, left = glyphs[weight]
        d = "".join(p.svg() for p in paths)
        out += f'  <g id="{weight}-S" transform="matrix(1 0 0 1 {left + SIDE_BEARING:.3f} {BASELINE})">\n'
        out += f'   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreviewWireframe" d="{d}"/>\n'
        out += "  </g>\n"
    return out + " </g>\n</svg>\n"


for name, draw in SYMBOLS.items():
    folder = ASSETS / f"{name}.symbolset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.svg").write_text(svg(draw))
    contents = {"info": {"author": "xcode", "version": 1},
                "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
