"""Erase the parts of a cell's output that change from machine to machine.

A lot of what a running VM prints is true and useless. A pid is three numbers
that depend on how many processes started before yours. A duration is whatever
the machine felt like doing that second. A path is where somebody happened to
install the release. None of it is the answer to anything a lesson asks, and all
of it stops a recording from being compared.

So each filter here takes one shape of noise and replaces it with a placeholder,
and a lesson names the filters it wants per cell. Named per cell, never applied
to everything, because the same shape is noise in one lesson and the whole point
in another. `m55` builds a pid for the node `a@b` out of a binary literal and
prints the node name it decoded, so running the `nodes` filter over that cell
would erase exactly the thing the cell exists to show.

That is the rule every filter here is written against. Erase the noise, keep the
answer, and when the two are the same number, leave the cell alone and say so.

Each filter is deliberately narrow. It matches a shape with a delimiter or a
unit attached, never a bare number, because a bare number in a lesson about the
BEAM is nearly always a heap word count, a byte count or a reduction count, and
those are answers.
"""

from __future__ import annotations

import re
from dataclasses import dataclass


class Unknown(ValueError):
    pass


@dataclass(frozen=True)
class Filter:
    name: str
    erases: str
    keeps: str
    # The text a filter leaves behind when it fires. It is what lets a checker
    # ask whether a filter named for a cell did anything, without having to run
    # the cell again, because by the time anybody is reading a recording the
    # noise the filter erased is long gone.
    mark: str
    rules: tuple[tuple[re.Pattern[str], str], ...]

    def apply(self, text: str) -> str:
        for pattern, replacement in self.rules:
            text = pattern.sub(replacement, text)
        return text


def rule(pattern: str, replacement: str, flags: int = 0) -> tuple[re.Pattern[str], str]:
    return re.compile(pattern, flags), replacement


FILTERS: dict[str, Filter] = {
    "pids": Filter(
        name="pids",
        erases="the three numbers in a process identifier",
        keeps="that it is a pid at all, and the shape it is printed in",
        mark="<0.PID.0>",
        rules=(
            # Elixir first. Once `#PID<0.111.0>` has become `#PID<0.PID.0>` it no
            # longer looks like the Erlang shape, so the second rule cannot
            # reach inside it.
            rule(r"#PID<\d+\.\d+\.\d+>", "#PID<0.PID.0>"),
            rule(r"(?<![\w.])<\d+\.\d+\.\d+>", "<0.PID.0>"),
        ),
    ),
    "ports": Filter(
        name="ports",
        erases="the slot number of a port",
        keeps="that it is a port",
        mark="#Port<0.PORT>",
        rules=(rule(r"#Port<\d+\.\d+>", "#Port<0.PORT>"),),
    ),
    "refs": Filter(
        name="refs",
        erases="the words that make a reference unique",
        keeps="that it is a reference",
        mark="<REF>",
        rules=(
            rule(r"#Reference<[\d.]+>", "#Reference<REF>"),
            rule(r"#Ref<[\d.]+>", "#Ref<REF>"),
        ),
    ),
    "times": Filter(
        name="times",
        erases="a number that carries a time unit, and the column padding in front of it",
        keeps="the unit, so a cell that moves from microseconds to milliseconds is still caught",
        mark="<TIME>",
        rules=(
            # The unit has to be there. A bare number is not a duration, it is a
            # count of something, and counts are what the lessons are about.
            #
            # The padding goes with it. A cell that lines a duration up in a
            # column pads with spaces, so the width of the number leaks into the
            # width of the padding, and erasing one without the other leaves the
            # difference behind in whitespace.
            rule(r" *\b\d+(?:\.\d+)?[ ]?(ns|us|ms|s)\b", r" <TIME> \1"),
            rule(r" *\b\d+(?:\.\d+)?[ ]?(µs)\b", r" <TIME> \1"),
        ),
    ),
    "paths": Filter(
        name="paths",
        erases="an absolute filesystem path",
        keeps="everything relative, which is how this repository cites the OTP tree",
        mark="<PATH>",
        rules=(rule(r"(?<![\w/])/(?:[\w.@+-]+/)+[\w.@+-]*", "<PATH>"),),
    ),
    "nodes": Filter(
        name="nodes",
        erases="the host half of a node name",
        keeps="the name half, which is chosen rather than discovered",
        mark="@HOST",
        rules=(rule(r"\b([\w-]+)@[A-Za-z0-9][\w.-]*", r"\1@HOST"),),
    ),
    "addresses": Filter(
        name="addresses",
        erases="a hexadecimal address",
        keeps="short hex, which in this repository is nearly always a byte value from a wire format",
        mark="0xADDR",
        rules=(rule(r"\b0x[0-9a-fA-F]{6,}\b", "0xADDR"),),
    ),
    "build-flags": Filter(
        name="build-flags",
        erases="the bracketed flags the emulator prints after its version",
        keeps="the OTP release and the erts version, which are what the lesson is pinned to",
        mark="[...]",
        rules=(rule(r"^(Erlang/OTP \S+ \[erts-[\d.]+\]).*$", r"\1 [...]", re.MULTILINE),),
    ),
    "schedulers": Filter(
        name="schedulers",
        erases="how many schedulers this machine has",
        keeps="that the line is about schedulers",
        mark="<N>",
        rules=(
            rule(r"\b\d+ scheduler", "<N> scheduler"),
            rule(r"(schedulers online +)\d+", r"\1<N>"),
        ),
    ),
}


def normalise(text: str, names: list[str]) -> str:
    """Run the named filters over some output, in the order they are named."""
    for name in names:
        if name not in FILTERS:
            raise Unknown(f"no such filter: {name}. There are {', '.join(sorted(FILTERS))}")
        text = FILTERS[name].apply(text)
    return text


def describe() -> str:
    width = max(len(name) for name in FILTERS)
    lines = [f"{name.ljust(width)}  erases {FILTERS[name].erases}" for name in sorted(FILTERS)]
    return "\n".join(lines)


if __name__ == "__main__":
    print(describe())
