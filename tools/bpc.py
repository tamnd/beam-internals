"""Blueprint regions generated from the VM's own tables.

Some of a blueprint is prose that a person has to write. Some of it is a table
that already exists in the emulator source, and copying that table by hand means
it is wrong from the day upstream changes it. Nobody notices, because a table
looks equally plausible whether or not it is current.

So those tables are marked as regions and this generates them:

    <!-- bpc: primary-tags -->
    | Name | Value | ... |
    <!-- bpc: end primary-tags -->

Run with no arguments to rewrite every region in place. Run with --check to
compare instead and print a diff of what moved, which is what CI does. A region
somebody edited by hand fails --check, and that is the whole point: the numbers
in a blueprint either come from the source or they are a copy that will rot.

Reading a C header means expanding its macros, and the evaluator here handles
integer arithmetic and nothing else. It is not a C preprocessor and does not try
to be. When a table stops being readable this way, the answer is to fix the
generator rather than to paste the numbers in.

Without the submodule checked out there is nothing to read, so the regions are
left alone and the run says it was skipped, the same bargain `refcheck` makes.
Pass --strict to turn that into a failure.

Run: python3 -m tools.bpc [--check] [--strict] [path ...]
"""

from __future__ import annotations

import ast
import difflib
import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(".")
SKIP_DIRS = {".git", ".venv", "node_modules", "_build", "site", "otp", "__pycache__"}

BEGIN = re.compile(r"^<!--\s*bpc:\s*(?!end\b)([\w-]+)\s*-->$")
END = re.compile(r"^<!--\s*bpc:\s*end\s+([\w-]+)\s*-->$")


class Unreadable(Exception):
    """A table stopped parsing the way the generator expected."""


@dataclass
class Region:
    name: str
    first: int  # index of the line after the begin marker
    last: int  # index of the end marker
    body: list[str]


def load_pin(root: Path) -> dict:
    with (root / "refcheck.toml").open("rb") as handle:
        return tomllib.load(handle)["pin"]


# ---------------------------------------------------------------------------
# Reading integer constants out of a C header
# ---------------------------------------------------------------------------

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT = re.compile(r"//[^\n]*")
OBJECT_DEFINE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+(\w+)[ \t]+(.+)$", re.MULTILINE)
FUNCTION_DEFINE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+(\w+)\(([\w, ]*)\)[ \t]+(.+)$", re.MULTILINE)
IDENTIFIER = re.compile(r"\b[A-Za-z_]\w*\b")

# Every operator the tag headers actually use. Anything else is a table this
# was not written to read, and raising beats guessing.
BINARY = {
    ast.LShift: lambda a, b: a << b,
    ast.RShift: lambda a, b: a >> b,
    ast.BitOr: lambda a, b: a | b,
    ast.BitAnd: lambda a, b: a & b,
    ast.BitXor: lambda a, b: a ^ b,
    ast.Add: lambda a, b: a + b,
    ast.Sub: lambda a, b: a - b,
    ast.Mult: lambda a, b: a * b,
    ast.FloorDiv: lambda a, b: a // b,
}


CONTINUATION = re.compile(r"\\\n[ \t]*")


def strip_comments(text: str) -> str:
    return LINE_COMMENT.sub("", BLOCK_COMMENT.sub(" ", text))


def join_continuations(text: str) -> str:
    """Put a `#define` that was wrapped with a backslash back on one line.

    The define patterns are anchored to a line, so a macro whose body starts on
    the next line reads as a body of one backslash. That fails later with a
    parse error naming an expression the header does not contain, which is a
    long way from the cause.
    """
    return CONTINUATION.sub(" ", text)


@dataclass
class Macros:
    """The `#define`s of one header, ready to be evaluated."""

    plain: dict[str, str]
    functions: dict[str, tuple[list[str], str]]

    @classmethod
    def read(cls, path: Path) -> Macros:
        text = strip_comments(join_continuations(path.read_text(encoding="utf-8", errors="replace")))
        functions = {}
        for name, params, body in FUNCTION_DEFINE.findall(text):
            functions[name] = ([p.strip() for p in params.split(",") if p.strip()], body.strip())
        plain = {}
        for name, body in OBJECT_DEFINE.findall(text):
            if name in functions:
                continue
            plain[name] = body.strip()
        return cls(plain, functions)

    def names_matching(self, pattern: str) -> list[str]:
        rx = re.compile(pattern)
        return [name for name in self.plain if rx.fullmatch(name)]

    def value(self, name: str) -> int:
        if name not in self.plain:
            raise Unreadable(f"{name} is not defined in the header this generator reads")
        return evaluate(self.expand(self.plain[name]))

    def expand(self, expression: str, budget: int = 64) -> str:
        """Substitute macro bodies until only literals and operators are left.

        Function-like macros are expanded with a regex, so an argument list
        containing its own parentheses is not handled. None of the tag headers
        has one, and a generator that silently mis-expands is worse than one
        that stops.
        """
        for _ in range(budget):
            before = expression
            for name, (params, body) in self.functions.items():
                pattern = re.compile(rf"\b{re.escape(name)}\s*\(([^()]*)\)")

                # The three defaults bind this iteration's macro. Without them
                # every substitution would use whichever macro the loop ended
                # on, which is a wrong number rather than an error.
                def apply(
                    match: re.Match[str],
                    name: str = name,
                    params: list[str] = params,
                    body: str = body,
                ) -> str:
                    args = [a.strip() for a in match.group(1).split(",")]
                    if len(args) != len(params):
                        raise Unreadable(f"{name} takes {len(params)} arguments, called with {len(args)}")
                    out = body
                    for param, arg in zip(params, args, strict=True):
                        out = re.sub(rf"\b{re.escape(param)}\b", f"({arg})", out)
                    return f"({out})"

                expression = pattern.sub(apply, expression)

            expression = IDENTIFIER.sub(
                lambda m: f"({self.plain[m.group(0)]})" if m.group(0) in self.plain else m.group(0),
                expression,
            )
            if expression == before:
                return expression
        raise Unreadable(f"macro expansion did not settle: {expression[:80]}")


def evaluate(expression: str) -> int:
    """Evaluate a C integer expression.

    C and Python agree on the precedence and the meaning of every operator used
    here except division, which is integer division in C, so it is rewritten
    before parsing. The tree is then walked by hand rather than handed to
    `eval`, because the input is a file from another project and an evaluator
    that can only add and shift cannot do anything else.
    """
    leftover = IDENTIFIER.search(expression)
    if leftover:
        raise Unreadable(f"{leftover.group(0)} did not expand to a number")
    rewritten = re.sub(r"(?<![/])/(?![/])", "//", expression)
    try:
        tree = ast.parse(rewritten, mode="eval")
    except SyntaxError as exc:
        raise Unreadable(f"cannot parse {expression[:80]!r}") from exc
    return walk(tree.body)


def walk(node: ast.expr) -> int:
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in BINARY:
        return BINARY[type(node.op)](walk(node.left), walk(node.right))
    if isinstance(node, ast.UnaryOp):
        if isinstance(node.op, ast.Invert):
            return ~walk(node.operand)
        if isinstance(node.op, ast.USub):
            return -walk(node.operand)
        if isinstance(node.op, ast.UAdd):
            return walk(node.operand)
    raise Unreadable(f"{type(node).__name__} is not integer arithmetic")


def bits(value: int, width: int) -> str:
    return format(value & ((1 << width) - 1), f"0{width}b")


def table(header: list[str], rows: list[list[str]]) -> list[str]:
    return [
        "| " + " | ".join(header) + " |",
        "| " + " | ".join("---" for _ in header) + " |",
        *["| " + " | ".join(row) + " |" for row in rows],
    ]


# ---------------------------------------------------------------------------
# The generators
# ---------------------------------------------------------------------------

TERM_H = "erts/emulator/beam/erl_term.h"
INIT_C = "erts/emulator/beam/erl_init.c"
VM_H = "erts/emulator/beam/erl_vm.h"

# What each tag is for. The numbers come from the header and cannot drift. The
# sentences do not exist in the header, so they live here, which means editing
# one in a blueprint fails --check the same way editing a number does.
PRIMARY_MEANING = {
    "HEADER": "The word is the first word of a boxed object and says what follows it.",
    "LIST": "The rest of the word is the address of a two word cons cell.",
    "BOXED": "The rest of the word is the address of a header word.",
    "IMMED1": "The value is in the word itself. Four more bits say which kind.",
}

IMMED1_MEANING = {
    "PID": "A local process identifier.",
    "PORT": "A local port identifier.",
    "IMMED2": "Not a value. Two more bits say which kind.",
    "SMALL": "A signed integer that fits in the remaining bits.",
}

IMMED2_MEANING = {
    "ATOM": "An index into the atom table.",
    "CATCH": "A catch frame marker, only ever found on a stack.",
    "NIL": "The empty list, one value with a tag to itself.",
}

SUBTAG_MEANING = {
    "ARITYVAL": "A tuple. The arity is in the rest of the header word.",
    "POS_BIG": "A bignum, positive.",
    "NEG_BIG": "A bignum, negative.",
    "REF": "A local reference.",
    "FUN": "A fun, with its environment following the header.",
    "FLOAT": "A double, in the words after the header.",
    "RECORD": "A record.",
    "HEAP_BITS": "A bitstring whose bytes are on the process heap.",
    "SUB_BITS": "A slice of another bitstring, held as an offset and a length.",
    "BIN_REF": "A reference to bytes held off heap.",
    "MAP": "A map, either flat or a hash array mapped trie.",
    "EXTERNAL_PID": "A process identifier belonging to another node.",
    "EXTERNAL_PORT": "A port identifier belonging to another node.",
    "EXTERNAL_REF": "A reference belonging to another node.",
}


def primary_tags(tree: Path) -> list[str]:
    """The two bit tag every word carries."""
    macros = Macros.read(tree / TERM_H)
    size = macros.value("_TAG_PRIMARY_SIZE")
    rows = []
    for short, meaning in PRIMARY_MEANING.items():
        value = macros.value(f"TAG_PRIMARY_{short}")
        rows.append([f"`TAG_PRIMARY_{short}`", f"`0b{bits(value, size)}`", str(value), meaning])
    return [
        f"Two bits, mask `0x{macros.value('_TAG_PRIMARY_MASK'):X}`, on every `Eterm`.",
        "",
        *table(["Name", "Bits", "Value", "What it means"], rows),
    ]


def immediate_tags(tree: Path) -> list[str]:
    """The two levels of tag inside a word that holds its own value."""
    macros = Macros.read(tree / TERM_H)
    one, two = macros.value("_TAG_IMMED1_SIZE"), macros.value("_TAG_IMMED2_SIZE")
    first = [
        [f"`_TAG_IMMED1_{s}`", f"`0b{bits(macros.value(f'_TAG_IMMED1_{s}'), one)}`", m]
        for s, m in IMMED1_MEANING.items()
    ]
    second = [
        [f"`_TAG_IMMED2_{s}`", f"`0b{bits(macros.value(f'_TAG_IMMED2_{s}'), two)}`", m]
        for s, m in IMMED2_MEANING.items()
    ]
    return [
        f"{one} bits, mask `0x{macros.value('_TAG_IMMED1_MASK'):X}`, the low two of them "
        f"`TAG_PRIMARY_IMMED1`.",
        "",
        *table(["Name", "Bits", "What it means"], first),
        "",
        f"When those four bits are `_TAG_IMMED1_IMMED2`, two more make {two}, "
        f"mask `0x{macros.value('_TAG_IMMED2_MASK'):X}`.",
        "",
        *table(["Name", "Bits", "What it means"], second),
    ]


def header_subtags(tree: Path) -> list[str]:
    """What the first word of a boxed object says the object is."""
    macros = Macros.read(tree / TERM_H)
    width = 6
    found = {name[: -len("_SUBTAG")] for name in macros.names_matching(r"\w+_SUBTAG")}
    unknown = found - set(SUBTAG_MEANING)
    missing = set(SUBTAG_MEANING) - found
    if unknown or missing:
        raise Unreadable(
            f"the subtag list moved: added {sorted(unknown)}, gone {sorted(missing)}. "
            "Update SUBTAG_MEANING in tools/bpc.py rather than the blueprint."
        )
    rows = []
    for short, meaning in SUBTAG_MEANING.items():
        value = macros.value(f"_TAG_HEADER_{short}")
        rows.append([f"`_TAG_HEADER_{short}`", f"`0b{bits(value, width)}`", f"`0x{value:02X}`", meaning])
    return [
        f"{width} bits, mask `0x{macros.value('_TAG_HEADER_MASK'):X}`, the low two of them "
        f"`TAG_PRIMARY_HEADER`. The arity or size lives above them, from bit "
        f"{macros.value('_HEADER_ARITY_OFFS')} up.",
        "",
        *table(["Name", "Bits", "Value", "What it holds"], rows),
    ]


TIMINGS = re.compile(r"ErtsModifiedTimings\s+erts_modified_timings\[\]\s*=\s*\{(.*?)\n\}", re.DOTALL)
TIMING_ROW = re.compile(r"\{\s*make_small\((\d+)\)\s*,\s*([^}]+?)\s*\}")


def modified_timings(tree: Path) -> list[str]:
    """The slice each `+T Level` hands out instead of the usual one."""
    macros = Macros.read(tree / VM_H)
    full = macros.value("CONTEXT_REDS")
    source = strip_comments((tree / INIT_C).read_text(encoding="utf-8", errors="replace"))
    body = TIMINGS.search(source)
    if not body:
        raise Unreadable("erts_modified_timings[] is not where this generator looked for it")
    rows = []
    for level, (delay, reds) in enumerate(TIMING_ROW.findall(body.group(1))):
        slice_size = evaluate(re.sub(r"\bCONTEXT_REDS\b", str(full), reds))
        share = f"{slice_size / full:.3f}".rstrip("0").rstrip(".")
        # The second field is a timeout handed to `erlang:delay_trap/2`, which
        # does `receive after Timeout`, so it is milliseconds. Zero is not a
        # zero length sleep, it is a different branch that yields instead, and
        # writing "0 ms" in a normative document would hide that.
        held = "yields instead of sleeping" if delay == "0" else f"{delay} ms"
        rows.append([str(level), str(slice_size), share, held])
    if not rows:
        raise Unreadable("erts_modified_timings[] parsed to no rows")
    return [
        f"`+T Level` replaces the slice with the value on its row. The default, with no "
        f"`+T` at all, is `CONTEXT_REDS`, which is {full}. The last column is a separate "
        f"effect of the same option: `spawn`, `link`, `monitor` and their neighbours trap "
        f"through `erlang:delay_trap/2` on the way out.",
        "",
        *table(["Level", "Slice", "Share of a full slice", "Delay after spawn and friends"], rows),
    ]


# ---------------------------------------------------------------------------
# Reading the wire format out of its own standard
# ---------------------------------------------------------------------------
#
# The three generators above read a C header, because the thing they describe
# only exists in a C header. The external term format is different: it has a
# published standard in the OTP tree that other implementations are written
# from, and that document, not the emulator, is the thing a reimplementation
# has to agree with. So the tag table is read out of the standard and then
# checked against the emulator's own defines, and a disagreement between the
# two fails the build rather than being quietly resolved in favour of either.

EXT_DIST_MD = "erts/doc/guides/erl_ext_dist.md"
EXTERNAL_H = "erts/emulator/beam/external.h"

# A heading in the standard that names a tag. The parenthetical, when there is
# one, is the tag's status and the document has no other place that states it.
TAG_HEADING = re.compile(r"^## ([A-Z][A-Z0-9_]*)(?: \((deprecated|removed)\))?$")
TABLE_ROW = re.compile(r"^\|(.*)\|$")
SEPARATOR_ROW = re.compile(r"^\|[\s|:-]+\|$")
BACKTICKED_NUMBER = re.compile(r"^`(\d+)`$")
CHAR_DEFINE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+(\w+)[ \t]+'(.)'[ \t]*$", re.MULTILINE)
IF_ZERO = re.compile(r"^[ \t]*#[ \t]*if[ \t]+0\b")
ANY_IF = re.compile(r"^[ \t]*#[ \t]*if")
ANY_ENDIF = re.compile(r"^[ \t]*#[ \t]*endif\b")

# Tags the emulator defines and the standard does not describe under a heading
# of its own. Each one is here because leaving it out of a specification would
# be a hole rather than a simplification, so the list is checked and a new one
# upstream stops the build.
UNDOCUMENTED_MEANING = {
    "DIST_HEADER": (
        "Opens a distribution message and carries the atom cache. The standard "
        "describes it under a heading that names the header rather than the tag."
    ),
    "DIST_FRAG_HEADER": "Opens the first fragment of a message too large to send in one piece.",
    "DIST_FRAG_CONT": "Opens every fragment after the first.",
    "HOPEFUL_DATA": (
        "Wraps an encoding that used a tag the far end may not understand, with a fallback beside it."
    ),
    "ATOM_INTERNAL_REF2": (
        "An atom by its index in this VM's atom table, two bytes. Valid inside one runtime instance only."
    ),
    "ATOM_INTERNAL_REF3": (
        "An atom by its index in this VM's atom table, three bytes. Valid inside one runtime instance only."
    ),
    "BINARY_INTERNAL_REF": (
        "A pointer to an existing off heap binary, so a term can move between processes without a copy."
    ),
    "BITSTRING_INTERNAL_REF": (
        "A pointer to an existing bitstring that is not a whole number of bytes, again without a copy."
    ),
    "MAGIC_REF_INTERNAL_REF": (
        "A pointer to a magic reference, which is a handle on a resource and has no wire form at all."
    ),
    "COMPRESSED": (
        "Says the next four bytes are the uncompressed size and the rest is zlib. The standard "
        "describes it in its opening section, with no heading of its own."
    ),
}


def strip_if_zero(text: str) -> str:
    """Drop `#if 0` blocks.

    This is not a preprocessor and does not want to be. `#if 0` is the one
    directive worth handling, because a define inside one is dead code that
    still matches every pattern a define matches, and `external.h` has two of
    them sitting on values that would otherwise read as live tags.
    """
    out: list[str] = []
    dead_at: int | None = None
    depth = 0
    for line in text.splitlines():
        if dead_at is None:
            if IF_ZERO.match(line):
                dead_at, depth = 0, 0
                continue
            out.append(line)
            continue
        if ANY_IF.match(line):
            depth += 1
        elif ANY_ENDIF.match(line):
            if depth == 0:
                dead_at = None
                continue
            depth -= 1
    if dead_at is not None:
        raise Unreadable("an #if 0 block is never closed")
    return "\n".join(out)


def cells(line: str) -> list[str]:
    return [c.strip() for c in TABLE_ROW.match(line).group(1).split("|")]


def first_table(lines: list[str], start: int) -> tuple[list[str], list[str]]:
    """The widths row and the first body row of the table after `start`.

    Every tag in the standard is drawn the same way: a header row of field
    widths in bytes, a separator, then one row of field names with the tag's
    own value in the first cell. Reading both rows is what turns the table into
    a layout rather than a number.
    """
    for index in range(start, min(start + 12, len(lines))):
        if not SEPARATOR_ROW.match(lines[index]):
            continue
        widths = cells(lines[index - 1])
        fields = cells(lines[index + 1])
        if len(widths) != len(fields):
            raise Unreadable(f"line {index + 2}: {len(widths)} widths against {len(fields)} fields")
        return widths, fields
    raise Unreadable(f"no table within twelve lines of line {start}")


def read_standard(tree: Path) -> dict[str, dict]:
    """Every tag the standard gives a heading to, with its value and layout."""
    lines = (tree / EXT_DIST_MD).read_text(encoding="utf-8").splitlines()
    found: dict[str, dict] = {}
    for index, line in enumerate(lines):
        heading = TAG_HEADING.match(line)
        if not heading:
            continue
        name, status = heading.group(1), heading.group(2)
        widths, fields = first_table(lines, index + 1)
        number = BACKTICKED_NUMBER.match(fields[0])
        if not number:
            # A heading in capitals that is prose rather than a tag, such as
            # ATOM_CACHE_REF's neighbours in the distribution header section.
            continue
        found[name] = {
            "value": int(number.group(1)),
            "layout": list(zip(widths[1:], fields[1:], strict=True)),
            "status": status or "current",
        }
    if not found:
        raise Unreadable(f"{EXT_DIST_MD} parsed to no tags")
    return found


def read_emulator_tags(tree: Path) -> dict[str, int]:
    text = strip_if_zero(strip_comments((tree / EXTERNAL_H).read_text(encoding="utf-8")))
    return {name: ord(char) for name, char in CHAR_DEFINE.findall(text)}


def layout_of(pairs: list[tuple[str, str]]) -> str:
    """Turn one row of the standard's tables into a sentence.

    Three shapes have to survive this. A tag with no fields at all, where the
    row is one cell wide. A field whose width the standard leaves blank,
    because it is a term and its length is its own business. And `LOCAL_EXT`,
    whose whole payload is an ellipsis on purpose, since the standard declines
    to say what follows it.
    """
    if not pairs:
        return "nothing follows"
    if all(width == "..." or field == "..." for width, field in pairs):
        return "the standard does not say"
    parts = [field if width in {"", "..."} else f"{field} {width}" for width, field in pairs]
    return ", ".join(parts)


def etf_tags(tree: Path) -> list[str]:
    """The tag table, read from the standard and checked against the emulator."""
    standard = read_standard(tree)
    emulator = read_emulator_tags(tree)

    disagree = [
        f"{name} is {spec['value']} in the standard and {emulator[name]} in the emulator"
        for name, spec in standard.items()
        if name in emulator and emulator[name] != spec["value"]
    ]
    absent = sorted(name for name in standard if name not in emulator)
    if disagree or absent:
        raise Unreadable(
            "the standard and the emulator do not agree: "
            + "; ".join([*disagree, *[f"{n} is documented and not defined" for n in absent]])
        )

    rows = []
    for name, spec in sorted(standard.items(), key=lambda item: item[1]["value"]):
        rows.append([str(spec["value"]), f"`{name}`", layout_of(spec["layout"]), spec["status"]])
    return [
        f"Read from `{EXT_DIST_MD}` and checked against `{EXTERNAL_H}`. "
        f"{len(rows)} tags. Widths are in bytes, `N` means a whole encoded term "
        f"and `Len` or `Arity` means the field named earlier on the row.",
        "",
        *table(["Value", "Tag", "What follows the tag byte", "Status"], rows),
    ]


def etf_undocumented_tags(tree: Path) -> list[str]:
    """Tags the emulator defines that the standard gives no heading to."""
    standard = read_standard(tree)
    emulator = read_emulator_tags(tree)
    found = {name for name in emulator if name not in standard}
    unknown = found - set(UNDOCUMENTED_MEANING)
    missing = set(UNDOCUMENTED_MEANING) - found
    if unknown or missing:
        raise Unreadable(
            f"the undocumented tag list moved: added {sorted(unknown)}, gone {sorted(missing)}. "
            "Update UNDOCUMENTED_MEANING in tools/bpc.py rather than the blueprint."
        )
    rows = [
        [str(emulator[name]), f"`{name}`", UNDOCUMENTED_MEANING[name]]
        for name in sorted(found, key=lambda n: emulator[n])
    ]
    return [
        f"Defined in `{EXTERNAL_H}` with no heading of their own in the standard. "
        f"{len(rows)} of them.",
        "",
        *table(["Value", "Name", "What it is for"], rows),
    ]


GENERATORS = {
    "primary-tags": (primary_tags, TERM_H),
    "immediate-tags": (immediate_tags, TERM_H),
    "header-subtags": (header_subtags, TERM_H),
    "modified-timings": (modified_timings, f"{INIT_C} and {VM_H}"),
    "etf-tags": (etf_tags, f"{EXT_DIST_MD} and {EXTERNAL_H}"),
    "etf-undocumented-tags": (etf_undocumented_tags, f"{EXT_DIST_MD} and {EXTERNAL_H}"),
}


# ---------------------------------------------------------------------------
# Finding and rewriting the regions
# ---------------------------------------------------------------------------


def find_regions(lines: list[str]) -> tuple[list[Region], list[str]]:
    """Locate the generated regions, ignoring the ones inside a code fence.

    A document that explains the markers has to be able to show them, and
    CONTRIBUTING does. So a fenced block is text about a region rather than a
    region, and generating into it would rewrite the instructions with a table.
    """
    regions: list[Region] = []
    problems: list[str] = []
    open_at: tuple[str, int] | None = None
    fenced = False

    for index, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue

        begin = BEGIN.match(line.strip())
        end = END.match(line.strip())
        if begin:
            if open_at:
                problems.append(f"line {index + 1}: {begin.group(1)} opens inside {open_at[0]}")
                continue
            open_at = (begin.group(1), index)
        elif end:
            if not open_at:
                problems.append(f"line {index + 1}: end {end.group(1)} with nothing open")
                continue
            name, start = open_at
            if end.group(1) != name:
                problems.append(f"line {index + 1}: {name} is closed by end {end.group(1)}")
            regions.append(Region(name, start + 1, index, lines[start + 1 : index]))
            open_at = None

    if open_at:
        problems.append(f"line {open_at[1] + 1}: {open_at[0]} is never closed")
    return regions, problems


def prose_files(root: Path) -> list[Path]:
    found: list[Path] = []
    for pattern in ("*.md", "*.livemd"):
        for path in root.rglob(pattern):
            if not any(part in SKIP_DIRS for part in path.parts):
                found.append(path)
    return sorted(found)


def targets(argv: list[str]) -> list[Path]:
    roots = [Path(a) for a in argv] or [ROOT]
    found: list[Path] = []
    for root in roots:
        found.extend([root] if root.is_file() else prose_files(root))
    return found


def rebuild(path: Path, tree: Path, check: bool) -> tuple[list[str], bool]:
    """Regenerate every region in one file. Returns problems, and whether it moved."""
    lines = path.read_text(encoding="utf-8").splitlines()
    regions, problems = find_regions(lines)
    problems = [f"{path}: {p}" for p in problems]
    if not regions:
        return problems, False

    out = list(lines)
    moved = False
    for region in reversed(regions):
        if region.name not in GENERATORS:
            problems.append(f"{path}: no generator called {region.name}, have {sorted(GENERATORS)}")
            continue
        generator, _ = GENERATORS[region.name]
        try:
            fresh = generator(tree)
        except Unreadable as exc:
            problems.append(f"{path}: {region.name}: {exc}")
            continue
        if fresh == region.body:
            continue
        moved = True
        if check:
            diff = difflib.unified_diff(
                region.body,
                fresh,
                fromfile=f"{path} as committed",
                tofile=f"{region.name} regenerated",
                lineterm="",
            )
            problems.append(f"{path}: {region.name} is not what the source says\n" + "\n".join(diff))
        else:
            out[region.first : region.last] = fresh

    if moved and not check:
        path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return problems, moved


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    check = "--check" in argv
    strict = "--strict" in argv
    argv = [a for a in argv if a not in {"--check", "--strict"}]

    pin = load_pin(ROOT)
    tree = ROOT / pin["submodule"]
    readable = (tree / "erts").is_dir()

    files = targets(argv)
    if not readable:
        if strict:
            print(f"{pin['submodule']} is not checked out, so no region could be generated.")
            return 1
        print(f"bpc: {len(files)} files, skipped, {pin['submodule']} is not checked out")
        return 0

    problems: list[str] = []
    changed = 0
    regions = 0
    for path in files:
        found, _ = find_regions(path.read_text(encoding="utf-8").splitlines())
        regions += len(found)
        trouble, moved = rebuild(path, tree, check)
        problems.extend(trouble)
        changed += 1 if moved else 0

    for problem in problems:
        print(problem)

    verb = "would be rewritten" if check else "rewritten"
    print(
        f"bpc: {regions} regions in {len(files)} files at {pin['tag']}, "
        f"{changed} files {verb}, {len(problems)} problems"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
