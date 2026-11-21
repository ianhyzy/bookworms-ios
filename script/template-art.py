#!/usr/bin/env python3
"""Draws the Share tab's template tiles as SVG image sets in the asset catalog.

Each tile is a small dark card, as every share image is dark, in the shape of a Portrait image
(4:5), with the template's layout in cream and gold: `template.<ShareTemplate raw value>`.
Checkout Card's tile keeps the card stock and inks of its image (`Stationery`) instead, and
Dropped's books are gray, as its image letters them. The books keep book proportions and stand
upright or lie flat. They tilt in the card's plane only where the card tilts them: fanned like a
hand of cards in Top Five, lying turned on the Desk's table, or resting on Seesaw's tipped
plank.

Each tile is drawn on a 120-by-150 grid and sized to the 56 by 70 points that `ShareStudioView`
shows it at, without its vector data. The asset catalog then draws its bitmaps at build time,
and the app shows them at their own size instead of drawing the vector at run time.

Run it from the repository root after changing a drawing:

    python3 script/template-art.py
"""

import json
import math
import pathlib

W, H = 120, 150
# The tile's size in points, as `ShareStudioView.templateTile(_:)` frames it.
POINTS = 56, 70
CREAM = "#FAF2DE"
GOLD = "#E9B949"
INK = "#1E1611"
BOOKS = ["#8C3B2E", "#2F5D50", "#2E4A6E", "#B07A2A", "#6B3F6E", "#9A5B3A", "#3E6A7A"]
OUT = pathlib.Path(__file__).resolve().parent.parent / "Bookworms" / "Assets.xcassets"


def shade(color, factor):
    """`color` darkened to `factor` of its brightness."""
    r, g, b = (int(color[i : i + 2], 16) * factor for i in (1, 3, 5))
    return f"#{int(r):02X}{int(g):02X}{int(b):02X}"


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


# The gradients the tiles fill with: the warm glow behind a featured book and the lamp's pool
# on the Desk's table.
LIGHTS = f"""<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
<stop offset="0" stop-color="{GOLD}" stop-opacity="0.38"/>
<stop offset="1" stop-color="{GOLD}" stop-opacity="0"/>
</radialGradient>
<radialGradient id="lamp" cx="0.5" cy="0.35" r="0.7">
<stop offset="0" stop-color="#8A5F3C"/><stop offset="1" stop-color="#4A3020"/>
</radialGradient>"""
# The card's own outline, which clips a drawing that runs off its edge.
CLIP = f'<clipPath id="card"><rect x="0" y="0" width="{W}" height="{H}" rx="10"/></clipPath>'


def card(body, defs=LIGHTS):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{POINTS[0]}" height="{POINTS[1]}" viewBox="0 0 {W} {H}">
<defs>
<linearGradient id="ground" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#3A2A1F"/><stop offset="1" stop-color="{INK}"/>
</linearGradient>
{defs}
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
    # Five books fanned like a hand of cards, as the card fans them: the first-ranked in the
    # middle and in front, larger than the others, which turn further and sit lower on the arc
    # the further out they are.
    lead = 42
    colors = [BOOKS[0], BOOKS[2], BOOKS[1], BOOKS[3], BOOKS[4]]
    for rank in reversed(range(5)):
        slot = [0, -1, 1, -2, 2][rank]
        h = lead * (1 if rank == 0 else 0.82)
        w = h * 0.66
        cx = 60 + slot * 18.5
        cy = 48 + (slot * slot * 0.026 + (0 if rank == 0 else 0.06)) * lead
        turn = slot * 7.5
        parts.append(
            f'<g transform="rotate({turn:g} {cx:g} {cy:g})">'
            + rect(cx - w / 2 + 0.8, cy - h / 2 + 1.4, w, h, "#000000", 1, 0.35)
            + book(cx - w / 2, cy - h / 2, w, h, colors[rank])
            + "</g>"
        )
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


def seesaw():
    # The table from the plank's height down, the walnut fulcrum, and the oak plank tipped down
    # on the left, the reader's side, with a stack of books lying flat on each end.
    table = (
        f'<path d="M0 62 H{W} V{H - 10} Q{W} {H} {W - 10} {H} H10 Q0 {H} 0 {H - 10} Z"'
        ' fill="url(#lamp)"/>'
    )
    parts = [heading(36, 11), bar(38, 20, 44, 2.5, CREAM, 0.55), table]
    # The plank's lower end rests on the table at the fulcrum's foot: asin(10 / 52) is 11 degrees.
    parts.append('<polygon points="53,98 67,98 61,88 59,88" fill="#5A3A26"/>')
    stacks = []
    for x, colors in [(8, [0, 3, 1, 5, 2]), (82, [6, 4, 1])]:
        y = 0
        for color in colors:
            stacks.append(
                rect(x, -7.7 - y, 28, 4.2, BOOKS[color], 0.8)
                + bar(x + 4, -6.6 - y, 14, 1.6, CREAM, 0.7)
            )
            y += 4.6
    parts.append(
        '<g transform="translate(60 88) rotate(-11)">'
        + rect(-52, -3.5, 104, 3.5, "#E8C49A", 1)
        + "".join(f'<g transform="translate(-60 0)">{book}</g>' for book in stacks)
        + "</g>"
    )
    parts += [
        avatar(22, 124, 9, BOOKS[5]), bar(36, 120, 22, 3), bar(36, 127, 16, 2.5, CREAM, 0.6),
        avatar(98, 124, 9, BOOKS[6]), bar(62, 120, 22, 3), bar(68, 127, 16, 2.5, CREAM, 0.6),
    ]
    return parts


def checkout_card():
    # A checkout card lying on the desk: a heading filled in as a form is, the handwritten name,
    # the printed words, and the handwritten year, over a red rule, then ruled lines, each with a
    # violet date stamp and a handwritten title.
    stock, ink, red, stamp, pen = "#EFE3CC", "#2B2117", "#8E2B24", "#2E2A6B", "#1B2A55"
    parts = [
        rect(17.5, 12, 88, 130, "#000000", 3, 0.35),
        rect(16, 10, 88, 130, stock, 3),
        bar(22, 15, 22, 4.5, pen),
        bar(46, 17, 24, 2.4, ink, 0.75),
        bar(73, 15, 14, 4.5, pen),
        rect(16, 22, 88, 1.4, red),
        rect(44, 24, 1, 109, red),
    ]
    for row in range(10):
        y = 32 + row * 10.5
        parts.append(rect(16, y + 3, 88, 0.8, ink, 0, 0.25))
        if row < 7:
            parts += [
                bar(21, y - 1.5, 19, 2.6, stamp, 0.9),
                bar(49, y - 2.5, [44, 30, 50, 36, 26, 42, 34][row], 3, pen),
            ]
    return parts


def dropped():
    # Four books given up on, in gray, dropping into a pit drawn in perspective: its rim, its
    # shadowed shaft, and the shaft's grid.
    gray = ["#9A9A9A", "#5E5E5E", "#C8C8C8", "#7A7A7A"]
    parts = [
        heading(52, 13),
        bar(44, 23, 32, 2.5, CREAM, 0.55),
        '<g clip-path="url(#card)">',
        '<path d="M20 80 L100 80 L90 160 L30 160 Z" fill="#000000" fill-opacity="0.3"/>',
    ]
    for i, color in enumerate(gray):
        x, y = 30 + i * 18, 46 + i % 2 * 5
        parts.append(
            f'<rect x="{x}" y="{y}" width="17" height="40" rx="1" fill="{color}"/>'
            + bar(x + 3, y + 5, 11, 2, CREAM, 0.75)
        )
    parts.append('<g stroke="#B8B8B8" stroke-opacity="0.85" stroke-width="1.2">')
    # The floor runs from 20...100 at its edge, y = 80, to 30...90 at y = 160.
    for i in range(9):
        parts.append(f'<line x1="{20 + i * 10:.1f}" y1="80" x2="{30 + i * 7.5:.1f}" y2="160"/>')
    for y in (100, 120, 140):
        inset = 10 * (y - 80) / 80
        parts.append(f'<line x1="{20 + inset:.1f}" y1="{y}" x2="{100 - inset:.1f}" y2="{y}"/>')
    parts += [
        "</g>",
        '<ellipse cx="60" cy="80" rx="40" ry="3" fill="none" stroke="#D0D0D0" stroke-width="2"/>',
        "</g>",
    ]
    return parts


def tower():
    # The headline, left-aligned on two lines, the height in gold, and the count under it.
    parts = [bar(10, 12, 50, 5.5), bar(10, 21, 22, 5.5, GOLD), bar(35, 21, 18, 5.5), bar(10, 31, 30, 2.5, CREAM, 0.55)]
    parts.append(f'<ellipse cx="45" cy="{H - 14}" rx="44" ry="7" fill="url(#lamp)"/>')
    # Spines lying flat on one another, each a little off true, as a real stack is.
    top = H - 14
    for level in range(22):
        nudge = [0, 1.2, -0.9, 0.6, -1.3, 0.4, 1.0, -0.5][level % 8]
        width = 30 + [0, 4, -3, 2, 5, -2, 1][level % 7]
        thickness = 3.2 + [0, 1.2, 0.4, 1.8, 0.6][level % 5]
        top -= thickness
        if top < 44:
            break
        color = BOOKS[(level * 3) % len(BOOKS)]
        parts.append(rect(30 + nudge, top, width, thickness, color, 0.5))
        parts.append(bar(30 + nudge + 4, top + thickness / 2 - 0.6, width * 0.5, 1.2, CREAM, 0.6))
    # The tape hangs plumb beside the tower from its hook to its case on the desk.
    parts += [rect(22, top, 3.5, H - 14 - top - 7, GOLD), rect(22, top - 1, 12, 1.8, "#C79E52"),
              rect(16, H - 22, 11, 9, GOLD, 2), rect(16, H - 18, 11, 2, INK, 0, 0.6)]
    # The worm sits at the base: its coil lies flat, and its front rises to the head.
    pink = "#F08FA6"
    parts += [f'<ellipse cx="80" cy="{H - 15}" rx="11" ry="4" fill="{shade(pink, 0.8)}"/>',
              rect(74, H - 40, 11, 26, pink, 5.5),
              f'<circle cx="77.5" cy="{H - 34}" r="2.4" fill="{CREAM}"/>',
              f'<circle cx="81.5" cy="{H - 34}" r="2.4" fill="{CREAM}"/>',
              f'<circle cx="77.5" cy="{H - 33.4}" r="1" fill="{INK}"/>',
              f'<circle cx="81.5" cy="{H - 33.4}" r="1" fill="{INK}"/>']
    # The loupe magnifies the newest books, with a line to the top of the tower.
    parts += [f'<line x1="62" y1="{top + 1}" x2="82" y2="62" stroke="{CREAM}" stroke-opacity="0.6" stroke-width="1"/>',
              '<circle cx="96" cy="62" r="17" fill="#4A3020"/>']
    for row in range(4):
        parts.append(rect(84 + row % 2, 51 + row * 6, 26, 5, BOOKS[(row * 2 + 1) % len(BOOKS)], 0.6))
        parts.append(bar(87 + row % 2, 52.8 + row * 6, 14, 1.4, CREAM, 0.75))
    parts.append(f'<circle cx="96" cy="62" r="17" fill="none" stroke="{CREAM}" stroke-width="2.2"/>')
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
    "seesaw": seesaw,
    "checkoutCard": checkout_card,
    "dropped": dropped,
    "tower": tower,
}
# Tiles that draw without the light gradients.
DEFS = {"dropped": CLIP}

for name, draw in TEMPLATES.items():
    folder = OUT / f"template.{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"template.{name}.svg").write_text(card("\n".join(draw()), DEFS.get(name, LIGHTS)))
    contents = {
        "images": [{"filename": f"template.{name}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
print(f"Wrote {len(TEMPLATES)} template tiles to {OUT}")
