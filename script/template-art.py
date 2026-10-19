#!/usr/bin/env python3
"""Draws the Share tab's template tiles as SVG image sets in the asset catalog.

Each tile is a small dark card, as every share image is dark, in the shape of a Portrait image
(4:5), with the template's layout in cream and gold: `template.<ShareTemplate raw value>`. The
books follow the workspace's realism rules: they stand on a ledge or lie flat, keep book
proportions, and never tilt in the card's plane unless they lie flat on the Desk's table.

Run it from the repository root after changing a drawing:

    python3 script/template-art.py
"""

import json
import math
import pathlib

W, H = 120, 150
CREAM = "#FAF2DE"
GOLD = "#E9B949"
INK = "#1E1611"
BOOKS = ["#8C3B2E", "#2F5D50", "#2E4A6E", "#B07A2A", "#6B3F6E", "#9A5B3A", "#3E6A7A"]
OUT = pathlib.Path(__file__).resolve().parent.parent / "Bookworms" / "Assets.xcassets"


def shade(color, factor):
    """`color` darkened (factor < 1) or lightened (factor > 1)."""
    r, g, b = (int(color[i : i + 2], 16) for i in (1, 3, 5))
    if factor < 1:
        r, g, b = (int(c * factor) for c in (r, g, b))
    else:
        r, g, b = (int(c + (255 - c) * (factor - 1)) for c in (r, g, b))
    return f"#{r:02X}{g:02X}{b:02X}"


def rect(x, y, w, h, fill, rx=0, opacity=1):
    return (
        f'<rect x="{x:g}" y="{y:g}" width="{w:g}" height="{h:g}" rx="{rx:g}" fill="{fill}"'
        f' fill-opacity="{opacity:g}"/>'
    )


def bar(x, y, w, h=3.5, fill=CREAM, opacity=1):
    """A line of lettering, drawn as a rounded bar."""
    return rect(x, y, w, h, fill, rx=h / 2, opacity=opacity)


def star(cx, cy, r, fill=GOLD, opacity=1):
    points = []
    for i in range(10):
        radius = r if i % 2 == 0 else r * 0.45
        angle = -math.pi / 2 + i * math.pi / 5
        points.append(f"{cx + radius * math.cos(angle):.2f},{cy + radius * math.sin(angle):.2f}")
    return f'<polygon points="{" ".join(points)}" fill="{fill}" fill-opacity="{opacity:g}"/>'


def stars(x, cy, r, count=5, filled=5, fill=GOLD):
    return "".join(
        star(x + r + i * r * 2.3, cy, r, fill, 1 if i < filled else 0.3) for i in range(count)
    )


def book(x, y, w, h, color):
    """An upright book turned a little so its spine shows on the left, its bottom at y + h."""
    spine = max(2.5, w * 0.2)
    return (
        f'<polygon points="{x:g},{y + 1:g} {x + spine:g},{y:g} {x + spine:g},{y + h:g}'
        f' {x:g},{y + h - 0.6:g}" fill="{shade(color, 0.62)}"/>'
        + rect(x + spine, y, w - spine, h, color, rx=0.8)
        + bar(x + spine + (w - spine) * 0.2, y + h * 0.2, (w - spine) * 0.6, 2, CREAM, 0.7)
    )


def heading(width, y=14):
    return bar((W - width) / 2, y, width, 5.5)


def card(body):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs>
<linearGradient id="ground" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#3A2A1F"/><stop offset="1" stop-color="{INK}"/>
</linearGradient>
<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
<stop offset="0" stop-color="{GOLD}" stop-opacity="0.38"/>
<stop offset="1" stop-color="{GOLD}" stop-opacity="0"/>
</radialGradient>
<radialGradient id="lamp" cx="0.5" cy="0.35" r="0.7">
<stop offset="0" stop-color="#8A5F3C"/><stop offset="1" stop-color="#4A3020"/>
</radialGradient>
</defs>
<rect x="0" y="0" width="{W}" height="{H}" rx="10" fill="url(#ground)"/>
{body}
<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="9.5" fill="none" stroke="{CREAM}" stroke-opacity="0.22"/>
</svg>
"""


def year_in_books():
    parts = [heading(58)]
    for i in range(3):
        x = 10 + i * 34
        parts += [rect(x, 27, 30, 19, CREAM, 3, 0.1), bar(x + 4, 31, 14, 4.5, GOLD), bar(x + 4, 39, 20, 2.5, CREAM, 0.6)]
    # Stacks of spines lying flat on a board, each a little off true, as a real stack is.
    counts = [3, 6, 4, 8, 2, 5, 7]
    for column, count in enumerate(counts):
        x = 14 + column * 13.3
        for level in range(count):
            nudge = [0, 0.8, -0.6, 0.5, -0.8, 0.3][(column + level) % 6]
            color = BOOKS[(column * 3 + level) % len(BOOKS)]
            # Each spine rests on the one below it, 11 wide and 3.6 thick.
            parts.append(rect(x + nudge, 112 - (level + 1) * 3.6, 11, 3.6, color, 0.5))
        parts.append(bar(x + 2.5, 119, 6, 2, CREAM, 0.4))
    parts += [rect(10, 112, 100, 2.5, "#6A4A33"), bar(10, 129, 46, 3, CREAM, 0.55), bar(10, 137, 30, 3, CREAM, 0.55)]
    return parts


def top_five():
    parts = [heading(64)]
    # Five books standing side by side on a ledge, the first-ranked in the middle.
    sizes = [(17, 31), (19, 35), (22, 41), (19, 34), (17, 30)]
    colors = [BOOKS[3], BOOKS[2], BOOKS[0], BOOKS[1], BOOKS[4]]
    x = 9
    for (w, h), color in zip(sizes, colors):
        parts.append(book(x, 73 - h, w, h, color))
        x += w + 2
    parts += [rect(7, 73, 106, 2.5, "#8E6342"), rect(7, 75.5, 106, 2.5, "#5A3B26")]
    for rank in range(5):
        y = 86 + rank * 11.5
        parts += [
            bar(10, y, 4, 5, GOLD),
            bar(18, y, [46, 40, 50, 36, 42][rank], 3.5),
            bar(18, y + 5, 22, 2.2, CREAM, 0.5),
            stars(84, y + 2, 2, filled=[5, 4, 4, 4, 3][rank]),
        ]
    return parts


def hot_takes():
    parts = [heading(52)]
    for row in range(3):
        y = 27 + row * 40
        parts += [
            book(10, y, 24, 34, BOOKS[[5, 2, 1][row]]),
            bar(40, y + 3, 42, 3.5),
            stars(40, y + 14, 2.4, filled=[5, 2, 4][row]),
            stars(40, y + 23, 2.4, filled=[3, 4, 2][row], fill=CREAM),
            rect(92, y + 13, 18, 9, GOLD, 4.5),
            bar(96, y + 16.5, 10, 2, INK),
        ]
    return parts


def pile():
    # The table, its bottom corners rounded with the card's.
    table = (
        f'<path d="M0 30 H{W} V{H - 10} Q{W} {H} {W - 10} {H} H10 Q0 {H} 0 {H - 10} Z"'
        ' fill="url(#lamp)"/>'
    )
    parts = [heading(36, 11), bar(50, 20, 20, 2.5, CREAM, 0.55), table]
    # Books lying front cover up, turned a little on the table, in loose rows.
    layout = [
        (12, 40, -6, 0), (40, 37, 4, 1), (68, 41, -3, 2), (94, 38, 7, 3),
        (18, 76, 5, 4), (46, 79, -5, 5), (74, 75, 3, 6),
        (10, 112, -4, 2), (38, 110, 6, 0), (66, 114, -7, 1), (92, 111, 2, 4),
    ]
    for x, y, turn, color in layout:
        cx, cy = x + 10, y + 13.5
        transform = f'transform="rotate({turn} {cx:g} {cy:g})"'
        parts.append(
            f"<g {transform}>"
            + rect(x + 0.8, y + 1.4, 20, 27, "#000000", 1, 0.35)
            + rect(x, y, 20, 27, BOOKS[color], 1)
            + rect(x + 19, y + 0.5, 1, 26, CREAM, 0, 0.6)
            + bar(x + 4, y + 6, 12, 2, CREAM, 0.7)
            + "</g>"
        )
    return parts


def just_finished():
    return [
        '<circle cx="60" cy="56" r="50" fill="url(#glow)"/>',
        book(40, 24, 40, 58, BOOKS[1]),
        heading(58, 94),
        bar(43, 104, 34, 3, CREAM, 0.6),
        stars(45, 115, 2.7),
        bar(26, 126, 68, 2.5, CREAM, 0.5),
    ]


def review():
    parts = [
        book(10, 14, 28, 40, BOOKS[0]),
        bar(46, 20, 52, 5),
        bar(46, 30, 30, 3, CREAM, 0.6),
        stars(46, 41, 2.5, filled=4),
        # A hanging quotation mark.
        f'<circle cx="16" cy="70" r="4" fill="{GOLD}"/><path d="M19.6 70 Q19 77 13 79 Q16.5 75.5 15.5 72 Z" fill="{GOLD}"/>',
        f'<circle cx="27" cy="70" r="4" fill="{GOLD}"/><path d="M30.6 70 Q30 77 24 79 Q27.5 75.5 26.5 72 Z" fill="{GOLD}"/>',
    ]
    for line in range(6):
        parts.append(bar(12, 86 + line * 9, 96 if line < 5 else 58, 3, CREAM, 0.75))
    return parts


def currently_reading():
    return [
        bar(32, 13, 56, 4, GOLD),
        book(40, 24, 40, 58, BOOKS[2]),
        heading(58, 92),
        bar(44, 102, 32, 3, CREAM, 0.6),
        rect(20, 116, 62, 5, CREAM, 2.5, 0.2),
        rect(20, 116, 38, 5, GOLD, 2.5),
        rect(88, 114.5, 14, 8, CREAM, 2, 0.9),
        bar(38, 131, 44, 2.5, CREAM, 0.5),
    ]


def avatar(cx, cy, r, color):
    return (
        f'<circle cx="{cx:g}" cy="{cy:g}" r="{r:g}" fill="{color}" stroke="{CREAM}"'
        f' stroke-width="1.5"/>'
        + f'<circle cx="{cx:g}" cy="{cy - r * 0.2:g}" r="{r * 0.36:g}" fill="{CREAM}" fill-opacity="0.75"/>'
    )


def taste_match():
    parts = [avatar(48, 28, 13, BOOKS[5]), avatar(72, 28, 13, BOOKS[6]), rect(36, 48, 48, 15, GOLD, 4), bar(35, 68, 50, 3, CREAM, 0.6)]
    for i, color in enumerate([BOOKS[1], BOOKS[0], BOOKS[3]]):
        x = 22 + i * 28
        parts += [book(x, 79, 20, 28, color), stars(x + 1, 113, 1.6, count=4, filled=4)]
    parts += [bar(12, 124, 52, 3), stars(72, 125.5, 1.9, filled=5), stars(72, 133, 1.9, filled=1, fill=CREAM)]
    return parts


def book_swap():
    arrows = (
        f'<path d="M45 18 H73 M69 14.5 L73 18 L69 21.5" stroke="{GOLD}" stroke-width="2"'
        ' fill="none" stroke-linecap="round" stroke-linejoin="round"/>'
        f'<path d="M75 28 H47 M51 24.5 L47 28 L51 31.5" stroke="{GOLD}" stroke-width="2"'
        ' fill="none" stroke-linecap="round" stroke-linejoin="round"/>'
    )
    parts = [avatar(28, 23, 11, BOOKS[5]), avatar(92, 23, 11, BOOKS[6]), arrows]
    for side, x in enumerate([10, 64]):
        for row in range(3):
            y = 44 + row * 34
            parts += [
                book(x, y, 18, 26, BOOKS[(side * 3 + row * 2) % len(BOOKS)]),
                bar(x + 22, y + 5, 22, 3),
                stars(x + 22, y + 14, 1.8, count=5, filled=5 - row % 2),
            ]
    return parts


TEMPLATES = {
    "yearInBooks": year_in_books,
    "topFive": top_five,
    "hotTakes": hot_takes,
    "pile": pile,
    "justFinished": just_finished,
    "review": review,
    "currentlyReading": currently_reading,
    "tasteMatch": taste_match,
    "bookSwap": book_swap,
}

for name, draw in TEMPLATES.items():
    folder = OUT / f"template.{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"template.{name}.svg").write_text(card("\n".join(draw())))
    contents = {
        "images": [{"filename": f"template.{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
print(f"Wrote {len(TEMPLATES)} template tiles to {OUT}")
