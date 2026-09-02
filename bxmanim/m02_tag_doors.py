"""m02, the tag taxonomy: how many bits a term spends saying what it is.

The lesson prints the three C headers and says "read the shape rather than the
hex". This is the shape. Two bits decide first, one of the four answers opens
onto four more, and one of those four opens onto four more again, so the width
of a tag is the number of doors the emulator had to walk through to reach it.

That nesting is the reason this figure is an animation and not only a still. A
still can show that an atom spends six bits. It cannot show the six arriving two
at a time, which is the part that explains why a small integer keeps sixty and
an atom does not.

The still is the last scene in this file, built out of the same vocabulary calls
as the moving one, so the two cannot drift apart into different notations.

Render:
  just anim m02_tag_doors        the video and the still
  just anim-still m02_tag_doors  the still on its own, which is quick
"""

from __future__ import annotations

from manim import (
    DOWN,
    RIGHT,
    UP,
    Brace,
    Create,
    FadeIn,
    FadeOut,
    Scene,
    Transform,
    VGroup,
    Write,
    config,
)

from bxmanim.vocabulary import (
    HEADER,
    HEADER_FILL,
    IMMED1,
    IMMED1_FILL,
    IMMED2,
    IMMED2_FILL,
    INK,
    LOOK,
    MUTED,
    PAPER,
    POINTER,
    POINTER_FILL,
    caption,
    door,
    label,
    mono,
    note,
    shut,
    tag,
    word,
)

config.background_color = PAPER

# Where the still belongs once it is rendered. Declared here rather than passed
# on the command line so that a test can check the file is actually there, and
# so that moving the lesson moves the figure with it.
STILL = "lessons/02-terms/m02/files/tag-doors.png"

# erts/emulator/beam/erl_term.h:70-75, :79-84, :86-90 at OTP-29.0.5. The three
# doors, in the order the emulator opens them, each arm carrying the colour the
# vocabulary gives it. HEADER is blue because it is not a term, LIST and BOXED
# are green because there is heap at the other end, and IMMED2 is grape rather
# than orange because it is not a kind of term at all, it is the door into the
# six bit ones.
PRIMARY = [
    ("HEADER", "00", HEADER, HEADER_FILL),
    ("LIST", "01", POINTER, POINTER_FILL),
    ("BOXED", "10", POINTER, POINTER_FILL),
    ("IMMED1", "11", IMMED1, IMMED1_FILL),
]
FOUR_BIT = [
    ("PID", "0011", IMMED1, IMMED1_FILL),
    ("PORT", "0111", IMMED1, IMMED1_FILL),
    ("IMMED2", "1011", IMMED2, IMMED2_FILL),
    ("SMALL", "1111", IMMED1, IMMED1_FILL),
]
SIX_BIT = [
    ("ATOM", "001011", IMMED2, IMMED2_FILL),
    ("CATCH", "011011", IMMED2, IMMED2_FILL),
    ("NIL", "111011", IMMED2, IMMED2_FILL),
]


def doors(rows, taken):
    """A row of branch arms with the one that was taken left bright."""
    group = VGroup(*[door(name, pattern, stroke, fill) for name, pattern, stroke, fill in rows])
    group.arrange(RIGHT, buff=0.55)
    for arm, row in zip(group, rows, strict=True):
        if row[0] != taken:
            shut(arm)
    return group


class TagDoors(Scene):
    """Walk one word down the tag tree, then two more that stop early."""

    def construct(self):
        self.opening()
        self.walk_the_atom()
        self.walk_the_small()
        self.walk_the_cons()
        self.closing()

    def opening(self):
        title = caption("Two bits decide first", size=34).to_edge(UP, buff=0.8)
        under = note("every term in the system is one machine word").next_to(title, DOWN, buff=0.25)
        self.play(Write(title), run_time=1.2)
        self.play(FadeIn(under, shift=UP * 0.2), run_time=0.8)
        self.wait(1.0)
        self.play(FadeOut(title), FadeOut(under), run_time=0.6)
        self.title_slot = None

    # The long walk. An atom is the term that goes furthest, so it is the one
    # worth watching all the way down.

    def walk_the_atom(self):
        header = caption("an atom", size=28).to_edge(UP, buff=0.7)
        self.play(Write(header), run_time=0.7)

        the_word = word("58 bits, an index into the atom table", "001011", IMMED2, IMMED2_FILL)
        the_word.shift(UP * 1.5)
        self.play(Create(the_word), run_time=1.2)
        self.wait(0.6)

        bits = the_word[1]

        self.step(bits, 2, "word & 0x3", PRIMARY, "IMMED1", "the value is right here")
        self.step(bits, 4, "word & 0xF", FOUR_BIT, "IMMED2", "one of the four is another door")
        self.step(bits, 6, "word & 0x3F", SIX_BIT, "ATOM", "six bits spent, and done")

        self.play(FadeOut(the_word), FadeOut(header), run_time=0.6)

    def step(self, bits, width, mask_text, rows, taken, line):
        """Widen the mask by one door and show which arm it selected."""
        looked = bits[-width:]
        brace = Brace(looked, DOWN, color=LOOK)
        mask = mono(mask_text, 22, LOOK).next_to(brace, DOWN, buff=0.15)

        arms = doors(rows, taken).shift(DOWN * 1.0)
        says = note(line).next_to(arms, DOWN, buff=0.5)

        if hasattr(self, "brace") and self.brace is not None:
            self.play(
                Transform(self.brace, brace),
                Transform(self.mask, mask),
                FadeOut(self.arms),
                FadeOut(self.says),
                run_time=0.8,
            )
            self.play(FadeIn(arms), FadeIn(says), run_time=0.7)
        else:
            self.play(Create(brace), Write(mask), run_time=0.8)
            self.play(FadeIn(arms), FadeIn(says), run_time=0.7)
            self.brace = brace
            self.mask = mask

        self.arms = arms
        self.says = says
        self.wait(1.4)
        if width == 6:
            self.play(FadeOut(self.brace), FadeOut(self.mask), FadeOut(arms), FadeOut(says), run_time=0.6)
            self.brace = None

    # The two short walks. The point of showing them after the long one is that
    # the reader already knows what the doors look like, so the only new
    # information is where each term stops.

    def walk_the_small(self):
        self.short_walk(
            "a small integer",
            word("60 bits of value, signed", "1111", IMMED1, IMMED1_FILL),
            [(2, "word & 0x3", PRIMARY, "IMMED1"), (4, "word & 0xF", FOUR_BIT, "SMALL")],
            "four bits, and the number is the term",
        )

    def walk_the_cons(self):
        self.short_walk(
            "a pointer to a cons cell",
            word("62 bits, the address of two words", "01", POINTER, POINTER_FILL),
            [(2, "word & 0x3", PRIMARY, "LIST")],
            "two bits, and the head and tail live on a heap",
        )

    def short_walk(self, name, the_word, steps, ending):
        header = caption(name, size=28).to_edge(UP, buff=0.7)
        the_word.shift(UP * 1.5)
        self.play(Write(header), Create(the_word), run_time=0.9)

        bits = the_word[1]

        # One step is fully off the screen before the next one arrives. Playing
        # the fade out and the fade in together saves half a second and puts two
        # rows of doors on top of each other while it does, which is exactly the
        # frame somebody screenshots.
        showing = None
        for width, mask_text, rows, taken in steps:
            brace = Brace(bits[-width:], DOWN, color=LOOK)
            mask = mono(mask_text, 22, LOOK).next_to(brace, DOWN, buff=0.15)
            arms = doors(rows, taken).shift(DOWN * 1.0)
            step = VGroup(brace, mask, arms)
            if showing is not None:
                self.play(FadeOut(showing), run_time=0.4)
            self.play(FadeIn(step), run_time=0.7)
            self.wait(1.2)
            showing = step

        stops = note(ending).shift(DOWN * 2.4)
        self.play(FadeIn(stops), run_time=0.6)
        self.wait(1.4)
        self.play(FadeOut(VGroup(header, the_word, stops, showing)), run_time=0.6)

    def closing(self):
        rows = ledger_rows()
        rows.shift(UP * 0.4)
        self.play(FadeIn(rows), run_time=1.0)
        self.wait(1.0)
        line = note("you only pay for more bits when the extra bits buy you something", size=22)
        line.next_to(rows, DOWN, buff=0.8)
        self.play(Write(line), run_time=1.4)
        self.wait(2.5)


def ledger_rows() -> VGroup:
    """The three walks side by side, which is the thing worth remembering."""
    spec = [
        ("a pointer to a cons cell", "01", POINTER, POINTER_FILL, "2 bits spent, 62 kept"),
        ("a small integer", "1111", IMMED1, IMMED1_FILL, "4 bits spent, 60 kept"),
        ("an atom", "001011", IMMED2, IMMED2_FILL, "6 bits spent, 58 kept"),
    ]
    rows = VGroup()
    for name, pattern, stroke, fill, cost in spec:
        name_text = label(name, 19, INK)
        name_text.set_width(min(name_text.width, 3.4))
        bits = tag(pattern, stroke, fill)
        price = mono(cost, 18, MUTED)
        row = VGroup(name_text, bits, price)
        row.arrange(RIGHT, buff=0.5)
        rows.add(row)
    rows.arrange(DOWN, buff=0.55, aligned_edge=RIGHT)
    return rows


class TagDoorsStill(Scene):
    """The still, for print, for a slow connection, and for anybody who cannot
    watch a moving image.

    It is not a frame grabbed out of the video. It is built from the same
    vocabulary calls, and it says every mask the animation applies, because a
    still that only shows the answer has dropped the half of the figure that
    was worth the reader's time.
    """

    def construct(self):
        title = caption("How many bits a term spends saying what it is", size=28)
        title.to_edge(UP, buff=0.55)
        subtitle = note("the emulator masks the low bits, and only the immediate branch reads further")
        subtitle.next_to(title, DOWN, buff=0.22)

        heads = VGroup(
            label("term", 17, MUTED),
            mono("& 0x3", 17, LOOK),
            mono("& 0xF", 17, LOOK),
            mono("& 0x3F", 17, LOOK),
            label("what is left of the word", 17, MUTED),
        )

        spec = [
            (
                "a pointer to a cons cell",
                POINTER,
                POINTER_FILL,
                ["01 LIST", "", ""],
                "62 bits, the address of two words",
            ),
            (
                "a small integer",
                IMMED1,
                IMMED1_FILL,
                ["11 IMMED1", "1111 SMALL", ""],
                "60 bits of value, signed",
            ),
            (
                "an atom",
                IMMED2,
                IMMED2_FILL,
                ["11 IMMED1", "1011 IMMED2", "001011 ATOM"],
                "58 bits, an index into the atom table",
            ),
        ]

        table = VGroup(heads)
        for name, stroke, _fill, cells, left in spec:
            row = VGroup(label(name, 18, INK))
            for cell in cells:
                colour = stroke if cell else MUTED
                row.add(mono(cell or "stop", 17, colour))
            row.add(label(left, 17, MUTED))
            table.add(row)

        columns = [3.4, 1.9, 2.3, 2.9, 3.9]
        for row in table:
            for cell, width in zip(row, columns, strict=True):
                if cell.width > width - 0.25:
                    cell.set_width(width - 0.25)
            row.arrange(RIGHT, buff=0.0)
            offset = -sum(columns) / 2
            for cell, width in zip(row, columns, strict=True):
                cell.move_to([offset + width / 2, 0, 0])
                offset += width
        table.arrange(DOWN, buff=0.42)
        table.next_to(subtitle, DOWN, buff=0.55)

        summary = ledger_rows().scale(0.9)
        summary.next_to(table, DOWN, buff=0.7)

        closing = note("you only pay for more bits when the extra bits buy you something", size=19)
        closing.next_to(summary, DOWN, buff=0.5)

        everything = VGroup(title, subtitle, table, summary, closing)
        everything.move_to([0, 0, 0])

        # Fit to whichever edge it hits first. Without the width check the left
        # hand column walks off the side of the frame, and the way you find out
        # is that a reader tells you the first row has no label.
        if everything.width > config.frame_width - 0.8:
            everything.set_width(config.frame_width - 0.8)
        if everything.height > config.frame_height - 0.6:
            everything.set_height(config.frame_height - 0.6)

        self.add(everything)


__all__ = ["STILL", "TagDoors", "TagDoorsStill"]
