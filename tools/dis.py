"""Read a disassembly tape and print what the loader left in memory.

This exists because almost nobody can produce the thing it prints. A
disassembly tape comes off an emulator configured `--disable-jit', a stock
release is the JIT, and `erts_debug:disassemble/1' returns false on the JIT. So
the tape is recorded once, committed to `corpora/dis/', and read from here.

The listing is a memory layout rather than an assembly listing, and the columns
say so: where each instruction starts inside its function, how many bytes it
takes, and how many machine words that is. The word column is the point. Every
instruction begins with one word holding the address of the C code that runs
it, and everything after that word is operands sitting inline in the code, so a
three word instruction is one dispatch and two operands. That is what threaded
code means, and it is easier to see in a column of small numbers than to read
about.

Run: python3 -m tools.dis corpora/dis/l1.tape.gz
"""

from __future__ import annotations

import gzip
import sys
from dataclasses import dataclass
from pathlib import Path

from tools import erlterm


class Unreadable(ValueError):
    """The file is not a disassembly tape."""


@dataclass(frozen=True)
class Instruction:
    index: int
    function: int
    offset: int
    size: int
    op: str
    args: str


@dataclass(frozen=True)
class Function:
    index: int
    name: str
    arity: int
    instructions: int
    size: int

    @property
    def signature(self) -> str:
        return f"{self.name}/{self.arity}"


@dataclass(frozen=True)
class Tape:
    header: dict
    source: str
    functions: list[Function]
    instructions: list[Instruction]

    @property
    def word(self) -> int:
        return self.header["wordsize"] // 8

    def of(self, function: Function) -> list[Instruction]:
        return [one for one in self.instructions if one.function == function.index]


def text(value) -> str:
    """A field off a tape, which is a binary for anything a person wrote."""
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


def read(path: Path) -> Tape:
    header = None
    source = ""
    functions: list[Function] = []
    instructions: list[Instruction] = []

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
                if text(header.get("kind")) != "dis":
                    raise Unreadable(f"{path}: this is a {text(header.get('kind'))} tape, not a dis tape")
                continue
            if not isinstance(term, tuple) or not term:
                continue
            tag = term[0]
            if tag == "source":
                source = text(term[2])
            elif tag == "function":
                functions.append(Function(term[1], text(term[2]), term[3], term[4], term[5]))
            elif tag == "instruction":
                instructions.append(
                    Instruction(term[1], term[2], term[3], term[4], text(term[5]), text(term[6]))
                )

    if header is None:
        raise Unreadable(f"{path}: there is nothing in it")
    return Tape(header, source, functions, instructions)


def summary(tape: Tape) -> list[str]:
    header = tape.header
    return [
        f"{text(header['source'])}  module {text(header['module'])}",
        f"recorded {text(header['recorded'])} by {text(header['by_whom'])}",
        (
            f"OTP {text(header['otp'])} erts {text(header['erts'])}, "
            f"{text(header['arch'])}, {text(header['flavor'])} flavor"
        ),
        (
            f"{header['functions']} functions, {header['instructions']} instructions, "
            f"{header['opcodes']} distinct opcodes, {header['code_bytes']} bytes"
        ),
        f"the interpreter loop that runs all of it is {header['interpreter_bytes']} bytes",
    ]


def listing(tape: Tape) -> list[str]:
    """One block per function, laid out the way the code is laid out.

    The three number columns are the offset from the start of the function, the
    size in bytes and the size in machine words, and they are printed for every
    instruction rather than only where they change, because the question a
    reader has here is arithmetic.
    """
    lines: list[str] = []
    for function in tape.functions:
        lines.append("")
        lines.append(f"{function.signature}  {function.size} bytes, {function.instructions} instructions")
        lines.append(f"  {'at':>5}  {'bytes':>5}  {'words':>5}  instruction")
        for one in tape.of(function):
            words = one.size // tape.word
            body = f"{one.op} {one.args}".rstrip()
            lines.append(f"  {one.offset:>5}  {one.size:>5}  {words:>5}  {body}")
    return lines


def opcodes(tape: Tape) -> list[str]:
    """Every opcode on the tape and how often it is used.

    Worth its own view because the names are the finding. Not one of them is
    emitted by the compiler: `i_plus_xxjd` is what became of `gc_bif2`, and the
    `xxjd` on the end is the loader saying it has already worked out that both
    operands are x registers and the result goes in one.
    """
    counts: dict[str, int] = {}
    for one in tape.instructions:
        counts[one.op] = counts.get(one.op, 0) + 1
    width = max(len(op) for op in counts) if counts else 0
    return [f"  {op.ljust(width)}  {count}" for op, count in sorted(counts.items())]


def render(tape: Tape) -> str:
    return "\n".join(summary(tape) + listing(tape) + ["", "opcodes"] + opcodes(tape))


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: python3 -m tools.dis corpora/dis/l1.tape.gz")
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
