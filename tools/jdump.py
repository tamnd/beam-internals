"""Read a native code tape and print what the JIT emitted.

The tape comes from `erl +JDdump true', which makes the JIT write out the
native code it generated for every module it loads. The interesting part is
that the assembler is asked to log the name of the BEAM instruction before
emitting the code for it, so the file arrives already grouped by BEAM
instruction and the grouping is the emulator's own.

Two views. The listing is one module, and it is where you go to see how many
native instructions a BEAM instruction turned into. The comparison is two
tapes of the same module from two architectures side by side, and it is where
the argument lives: same release, same beam file, and the two machines do not
even agree on which BEAM instructions to run.

Run: python3 -m tools.jdump corpora/jdump/l1-x86_64.tape.gz
     python3 -m tools.jdump --compare corpora/jdump/l1-*.tape.gz
"""

from __future__ import annotations

import gzip
import sys
from dataclasses import dataclass, field
from pathlib import Path

from tools import erlterm


class Unreadable(ValueError):
    """The file is not a native code tape."""


@dataclass(frozen=True)
class Row:
    kind: str
    text: str
    size: int = 0


@dataclass
class Group:
    index: int
    function: int
    op: str
    natives: int
    rows: list[Row] = field(default_factory=list)


@dataclass(frozen=True)
class Function:
    index: int
    name: str
    arity: int
    opcodes: int
    natives: int

    @property
    def signature(self) -> str:
        return f"{self.name}/{self.arity}"


@dataclass(frozen=True)
class Tape:
    header: dict
    source: str
    functions: list[Function]
    groups: list[Group]

    @property
    def native(self) -> str:
        return text(self.header["native"])

    def of(self, function: Function) -> list[Group]:
        return [one for one in self.groups if one.function == function.index]

    def census(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for one in self.groups:
            counts[one.op] = counts.get(one.op, 0) + 1
        return counts


def text(value) -> str:
    """A field off a tape, which is a binary for anything a person wrote."""
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


def read(path: Path) -> Tape:
    header = None
    source = ""
    functions: list[Function] = []
    groups: list[Group] = []
    by_index: dict[int, Group] = {}

    with gzip.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("%%"):
                continue
            term = erlterm.parse(stripped)
            if header is None:
                if not isinstance(term, dict):
                    raise Unreadable(f"{path}: the first term is not a header")
                header = term
                if text(header.get("kind")) != "jdump":
                    raise Unreadable(f"{path}: this is a {text(header.get('kind'))} tape, not a jdump tape")
                continue
            if not isinstance(term, tuple) or not term:
                continue
            tag = term[0]
            if tag == "source":
                source = text(term[2])
            elif tag == "function":
                functions.append(Function(term[1], text(term[2]), term[3], term[4], term[5]))
            elif tag == "group":
                group = Group(term[1], term[2], text(term[3]), term[4])
                groups.append(group)
                by_index[group.index] = group
            elif tag in ("native", "note", "label", "section"):
                at = by_index.get(term[1])
                if at is not None:
                    at.rows.append(Row(tag, text(term[2])))
            elif tag == "align":
                at = by_index.get(term[1])
                if at is not None:
                    at.rows.append(Row("align", "align", term[2]))
            elif tag == "data":
                at = by_index.get(term[1])
                if at is not None:
                    at.rows.append(Row("data", text(term[2]), term[3]))

    if header is None:
        raise Unreadable(f"{path}: there is nothing in it")
    return Tape(header, source, functions, groups)


def summary(tape: Tape) -> list[str]:
    header = tape.header
    return [
        f"{text(header['source'])}  module {text(header['module'])}",
        f"recorded {text(header['recorded'])} by {text(header['by_whom'])}",
        (
            f"OTP {text(header['otp'])} erts {text(header['erts'])}, "
            f"{text(header['arch'])}, {text(header['flavor'])} flavor, "
            f"{tape.native} native code"
        ),
        (
            f"{header['functions']} functions, {header['opcodes']} BEAM instructions, "
            f"{header['natives']} native instructions"
        ),
        f"booting this node compiled {header['modules_jitted']} modules to native code",
    ]


def show(row: Row) -> str:
    """One line under a BEAM instruction.

    A note is the emitter talking to whoever reads the dump, so it keeps its
    hash. A run of bytes is shown as a size, because what is in it is the
    module's own metadata and none of it survives being moved to another
    machine. A section marker sits at the outdent a label sits at, without the
    colon, because it is not somewhere anything jumps to.
    """
    if row.kind == "native":
        return f"      {row.text}"
    if row.kind == "note":
        return f"      # {row.text}"
    if row.kind == "label":
        return f"    {row.text}:"
    if row.kind == "section":
        return f"  {row.text}"
    if row.kind == "align":
        return f"      pad to a {row.size} byte boundary"
    return f"      {row.text}  {row.size} byte{'' if row.size == 1 else 's'} of data"


def listing(tape: Tape) -> list[str]:
    lines: list[str] = []
    for function in tape.functions:
        lines.append("")
        lines.append(f"{function.signature}  {function.opcodes} BEAM instructions, {function.natives} native")
        for group in tape.of(function):
            lines.append(f"  {group.op}")
            lines.extend(show(row) for row in group.rows)
    return lines


def cost(tape: Tape) -> list[str]:
    """How many native instructions each BEAM instruction cost, worst first.

    The census is the point of the tape. A BEAM instruction is one entry in a
    table on the interpreter and a stretch of inline machine code here, and the
    stretch is nothing like the same length for all of them.
    """
    worst: dict[str, int] = {}
    for group in tape.groups:
        worst[group.op] = max(worst.get(group.op, 0), group.natives)
    width = max((len(op) for op in worst), default=0)
    order = sorted(worst.items(), key=lambda pair: (-pair[1], pair[0]))
    return [f"  {op.ljust(width)}  {n}" for op, n in order]


def render(tape: Tape) -> str:
    return "\n".join(
        summary(tape) + listing(tape) + ["", "native instructions per BEAM instruction"] + cost(tape)
    )


def compare(tapes: list[Tape]) -> str:
    """Two or more tapes of the same module, side by side.

    A dot rather than a zero for an instruction one side never emitted, because
    zero would read as a count and this is an absence.
    """
    names = [one.native for one in tapes]
    if len({text(one.header["module"]) for one in tapes}) != 1:
        raise Unreadable("these tapes are not all of the same module")

    lines = [f"module {text(tapes[0].header['module'])}, {len(tapes)} architectures", ""]
    facts = [
        ("BEAM instructions", "opcodes"),
        ("distinct BEAM instructions", "distinct_opcodes"),
        ("native instructions", "natives"),
        ("modules compiled at boot", "modules_jitted"),
    ]
    label = max(len(name) for name, _ in facts)
    columns = max(8, max(len(name) for name in names) + 2)
    lines.append(" " * label + "".join(name.rjust(columns) for name in names))
    for name, key in facts:
        row = "".join(str(one.header[key]).rjust(columns) for one in tapes)
        lines.append(name.ljust(label) + row)

    lines.append("")
    censuses = [one.census() for one in tapes]
    every = sorted({op for census in censuses for op in census})
    width = max(len(op) for op in every)
    lines.append("BEAM instruction".ljust(width) + "".join(name.rjust(columns) for name in names))
    for op in every:
        cells = "".join(str(census.get(op, ".")).rjust(columns) for census in censuses)
        lines.append(op.ljust(width) + cells)
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--compare":
        rest = argv[1:]
        if len(rest) < 2:
            print("usage: python3 -m tools.jdump --compare ONE.tape.gz ANOTHER.tape.gz")
            return 2
        try:
            print(compare([read(Path(name)) for name in rest]))
        except (OSError, Unreadable, erlterm.TermError) as problem:
            print(problem)
            return 1
        return 0
    if not argv:
        print("usage: python3 -m tools.jdump corpora/jdump/l1-x86_64.tape.gz")
        return 2
    for name in argv:
        try:
            print(render(read(Path(name))))
        except (OSError, Unreadable, erlterm.TermError) as problem:
            print(problem)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
