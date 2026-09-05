"""The animation vocabulary.

A word means the same thing in every animation in the book. A reader learns the
notation once, in the first figure they meet, and every figure after that reads
without a legend. New shapes and new colours are a change to the vocabulary and
get argued about as such, which is why they live here and not in a scene file.

The palette is Open Color, the same swatches the Excalidraw figures use. That is
not decoration. A lesson shows a still drawn in Excalidraw and a video rendered
by Manim on the same page, and if the two use different greens the reader spends
attention deciding whether the difference means something.

Colour says what a term costs, because that is the question the terms chapter is
about:

  blue    a header word, which is not a term at all
  green   a pointer, so there is heap at the other end
  orange  an immediate that spends four bits on its tag
  grape   an immediate that spends six
  grey    payload, the part of the word that carries the value
  amber   a mask, and in motion the mask being applied right now
"""

from __future__ import annotations

from manim import DOWN, LEFT, RIGHT, UP, Rectangle, Text, VGroup

# Open Color. Stroke first, then the pale fill that goes under it.
INK = "#1e1e1e"
PAPER = "#f8f9fa"
MUTED = "#868e96"
QUIET = "#adb5bd"

HEADER = "#1971c2"
HEADER_FILL = "#a5d8ff"
POINTER = "#2f9e44"
POINTER_FILL = "#b2f2bb"
IMMED1 = "#e8590c"
IMMED1_FILL = "#ffd8a8"
IMMED2 = "#9c36b5"
IMMED2_FILL = "#eebefa"
LOOK = "#f08c00"

# Pango resolves both of these on macOS and on Linux without either machine
# having to install a font first. Naming a real face here would render one way
# on the machine that drew the figure and another way in CI, and the difference
# would only ever be noticed by a reader.
MONO = "monospace"
SANS = "sans-serif"

CELL = 0.44
STROKE = 2.0

# Pango loses most of the width of a space when it lays out at a small point
# size, so "what is left" comes out as "whatisleft" and every caption in the
# book reads slightly wrong. Laying out at one large size and scaling the shape
# down afterwards keeps the spacing the font intended.
BASE = 48


def label(string: str, size: float, color: str, font: str = SANS) -> Text:
    return Text(string, font=font, font_size=BASE, color=color).scale(size / BASE)


def bit(value: str, stroke: str, fill: str) -> VGroup:
    """One bit of a tag: a small square with the digit in it."""
    box = Rectangle(width=CELL, height=CELL, stroke_color=stroke, stroke_width=STROKE)
    box.set_fill(fill, opacity=1.0)
    digit = label(value, 20, stroke, font=MONO).move_to(box)
    return VGroup(box, digit)


def tag(pattern: str, stroke: str, fill: str) -> VGroup:
    """A tag, most significant bit on the left, written the way a C header does."""
    cells = VGroup(*[bit(value, stroke, fill) for value in pattern])
    cells.arrange(RIGHT, buff=0.0)
    return cells


def payload(name: str, width: float) -> VGroup:
    """The part of the word that is not the tag."""
    box = Rectangle(width=width, height=CELL, stroke_color=QUIET, stroke_width=STROKE)
    box.set_fill(PAPER, opacity=1.0)
    text = label(name, 18, MUTED, font=MONO).move_to(box)
    return VGroup(box, text)


def word(name: str, pattern: str, stroke: str, fill: str, width: float = 6.4) -> VGroup:
    """One machine word: payload on the left, tag bits at the low end on the right.

    Low bits go on the right because that is where they are when the word is
    written down in hexadecimal, and a figure that reverses them to make the
    drawing easier costs the reader a translation on every glance.
    """
    body = payload(name, width)
    bits = tag(pattern, stroke, fill)
    group = VGroup(body, bits).arrange(RIGHT, buff=0.0)
    return group


def mono(text: str, size: float = 20, color: str = INK) -> Text:
    """Anything the reader could type or grep for: a mask, a tag name, a count."""
    return label(text, size, color, font=MONO)


def caption(text: str, size: int = 22, color: str = INK) -> Text:
    return label(text, size, color)


def note(text: str, size: int = 18) -> Text:
    return label(text, size, MUTED)


def door(name: str, pattern: str, stroke: str, fill: str) -> VGroup:
    """One arm of a branch: the bit pattern above, the name it means below.

    Drawn as a door because that is what the emulator does with it. Two bits
    open onto four of these, and one of the four opens onto four more.
    """
    bits = tag(pattern, stroke, fill)
    text = label(name, 17, stroke, font=MONO)
    return VGroup(bits, text).arrange(DOWN, buff=0.12)


def shut(group: VGroup) -> VGroup:
    """A door that was not taken. Still there, still readable, out of the way."""
    return group.set_opacity(0.28)


def stack(*rows: VGroup, buff: float = 0.34) -> VGroup:
    return VGroup(*rows).arrange(DOWN, buff=buff, aligned_edge=LEFT)


def titled(title: str, body: VGroup, buff: float = 0.5) -> VGroup:
    return VGroup(caption(title), body).arrange(DOWN, buff=buff)


__all__ = [
    "CELL",
    "HEADER",
    "HEADER_FILL",
    "IMMED1",
    "IMMED1_FILL",
    "IMMED2",
    "IMMED2_FILL",
    "INK",
    "LOOK",
    "MONO",
    "BASE",
    "MUTED",
    "SANS",
    "PAPER",
    "POINTER",
    "POINTER_FILL",
    "QUIET",
    "STROKE",
    "UP",
    "bit",
    "label",
    "mono",
    "caption",
    "door",
    "note",
    "payload",
    "shut",
    "stack",
    "tag",
    "titled",
    "word",
]
