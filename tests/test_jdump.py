"""The native code tape reader.

Two halves, the same shape as the disassembly tests. The first uses a small hand
written tape so that a wrong kind, an empty file and the rendering of each kind
of row are exercised without the corpus. The second reads both real tapes,
because the comparison between them is the whole reason the pair was recorded
and nobody reading this has both machines to hand.
"""

from __future__ import annotations

import gzip
from pathlib import Path

import pytest

from tools import jdump

HEADER = (
    '#{schema => 1, kind => jdump, otp => <<"29">>, erts => <<"17.0.5">>, '
    'arch => <<"aarch64-apple-darwin24.6.0">>, flavor => jit, build => opt, '
    'by_whom => <<"tamnd">>, recorded => <<"2026-09-05T19:36:40Z">>, '
    'module => <<"tiny">>, source => <<"tiny.erl">>, native => <<"aarch64">>, '
    "functions => 1, opcodes => 2, distinct_opcodes => 2, natives => 2, "
    "modules_jitted => 109, addresses => 1}."
)

BODY = [
    '{source,<<"tiny">>,<<"-module(tiny).\\n">>}.',
    '{function,1,<<"go">>,0,2,2}.',
    '{group,1,1,<<"i_func_label_L">>,0}.',
    '{label,1,<<"label_2">>}.',
    "{align,1,8}.",
    '{group,2,1,<<"return">>,2}.',
    '{note,2,<<"tiny:go/0">>}.',
    '{native,2,<<"mov x14, addr(1)">>}.',
    '{native,2,<<"ret x30">>}.',
    '{data,2,<<".byte">>,24}.',
    '{section,2,<<".rodata">>}.',
    "{'$tape_end',11}.",
]


def write(path: Path, lines: list[str]) -> Path:
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        handle.write("%% bxtrace tape, schema 1, kind jdump\n")
        for line in lines:
            handle.write(line + "\n")
    return path


@pytest.fixture
def tiny(tmp_path: Path) -> Path:
    return write(tmp_path / "tiny.tape.gz", [HEADER, *BODY])


def test_a_tape_reads_back_as_functions_and_groups(tiny: Path) -> None:
    tape = jdump.read(tiny)
    assert [f.signature for f in tape.functions] == ["go/0"]
    assert [g.op for g in tape.groups] == ["i_func_label_L", "return"]
    assert tape.native == "aarch64"
    assert tape.source == "-module(tiny).\n"


def test_rows_are_filed_under_the_instruction_that_emitted_them(tiny: Path) -> None:
    tape = jdump.read(tiny)
    first, second = tape.groups
    assert [row.kind for row in first.rows] == ["label", "align"]
    assert [row.kind for row in second.rows] == ["note", "native", "native", "data", "section"]


def test_the_census_counts_each_beam_instruction(tiny: Path) -> None:
    assert jdump.read(tiny).census() == {"i_func_label_L": 1, "return": 1}


def test_a_tape_of_the_wrong_kind_says_which_kind_it_is(tmp_path: Path) -> None:
    path = write(tmp_path / "wrong.tape.gz", [HEADER.replace("kind => jdump", "kind => dis")])
    with pytest.raises(jdump.Unreadable, match="this is a dis tape"):
        jdump.read(path)


def test_an_empty_file_is_reported_rather_than_read_as_nothing(tmp_path: Path) -> None:
    path = write(tmp_path / "empty.tape.gz", [])
    with pytest.raises(jdump.Unreadable, match="there is nothing in it"):
        jdump.read(path)


def test_each_kind_of_row_is_shown_as_what_it_is(tiny: Path) -> None:
    """A label is not indented like code, padding says what it is rather than
    pretending to be an instruction, and a run of bytes shows a size because the
    bytes themselves were never copied onto the tape."""
    shown = [jdump.show(row) for group in jdump.read(tiny).groups for row in group.rows]
    assert "    label_2:" in shown
    assert "      pad to a 8 byte boundary" in shown
    assert "      # tiny:go/0" in shown
    assert "      mov x14, addr(1)" in shown
    assert "      .byte  24 bytes of data" in shown
    assert "  .rodata" in shown


def test_the_listing_puts_each_instruction_under_its_function(tiny: Path) -> None:
    out = "\n".join(jdump.listing(jdump.read(tiny)))
    assert "go/0  2 BEAM instructions, 2 native" in out
    assert "  return" in out


def test_two_tapes_of_different_modules_will_not_be_compared(tiny: Path, tmp_path: Path) -> None:
    other = write(
        tmp_path / "other.tape.gz",
        [HEADER.replace('module => <<"tiny">>', 'module => <<"large">>'), *BODY],
    )
    with pytest.raises(jdump.Unreadable, match="not all of the same module"):
        jdump.compare([jdump.read(tiny), jdump.read(other)])


# ---------------------------------------------------------------------------
# The real pair

ARM = Path("corpora/jdump/l1-aarch64.tape.gz")
X86 = Path("corpora/jdump/l1-x86_64.tape.gz")


@pytest.fixture
def pair() -> list[jdump.Tape]:
    if not ARM.is_file() or not X86.is_file():
        pytest.skip("the recorded pair is not here")
    return [jdump.read(X86), jdump.read(ARM)]


def test_the_pair_is_one_module_on_two_machines(pair: list[jdump.Tape]) -> None:
    """The condition the whole comparison rests on. Same module, same release,
    same flavor, and the only thing that differs is the instruction set."""
    assert [one.native for one in pair] == ["x86_64", "aarch64"]
    assert {jdump.text(one.header["module"]) for one in pair} == {"l1"}
    assert {jdump.text(one.header["otp"]) for one in pair} == {"29"}
    assert {jdump.text(one.header["flavor"]) for one in pair} == {"jit"}


def test_the_counts_a_lesson_will_quote(pair: list[jdump.Tape]) -> None:
    x86, arm = pair
    assert (x86.header["opcodes"], arm.header["opcodes"]) == (56, 61)
    assert (x86.header["natives"], arm.header["natives"]) == (129, 132)
    assert (x86.header["functions"], arm.header["functions"]) == (5, 5)


def test_the_two_machines_do_not_run_the_same_beam_instructions(pair: list[jdump.Tape]) -> None:
    """The finding. It would be no surprise that two machines have different
    native code, and it is a surprise that the difference reaches back into
    which BEAM instructions the loader picked for the same beam file."""
    x86, arm = (one.census() for one in pair)
    assert "i_plus_ssjd" in x86 and "i_plus_ssjd" not in arm
    assert "i_plus_jIssd" in arm and "i_plus_jIssd" not in x86
    assert "i_flush_stubs" in arm and "i_flush_stubs" not in x86


def test_neither_machine_uses_the_name_the_interpreter_uses(pair: list[jdump.Tape]) -> None:
    """`corpora/dis/l1.tape.gz` has `i_plus_xxjd` for the same line of source,
    and that name is in neither of these."""
    for one in pair:
        assert "i_plus_xxjd" not in one.census()


def test_no_address_survived_on_either_tape(pair: list[jdump.Tape]) -> None:
    for one in pair:
        assert one.header["addresses"] > 0
        for group in one.groups:
            for row in group.rows:
                if row.kind == "native":
                    assert "0x" not in row.text


def test_nothing_on_either_tape_is_anything_but_printable_text(pair: list[jdump.Tape]) -> None:
    """A dump is text about code. Anything else on a tape came off the module's
    own bytes, and the section markers are where that happened once: they used
    to be copied whole, and the assembler sometimes leaves a fragment of the
    compile chunk sitting in the middle of one."""
    for one in pair:
        for group in one.groups:
            for row in group.rows:
                assert row.text.isprintable(), f"{one.native}: {row.kind} row {row.text!r}"


def test_the_only_sections_are_the_code_and_the_constants(pair: list[jdump.Tape]) -> None:
    for one in pair:
        found = {row.text for group in one.groups for row in group.rows if row.kind == "section"}
        assert found == {".text", ".rodata"}


def test_the_comparison_marks_an_absence_as_an_absence(pair: list[jdump.Tape]) -> None:
    """A zero would read as a count of something that was measured. A dot says
    the machine never emitted it at all."""
    out = jdump.compare(pair)
    row = next(line for line in out.splitlines() if line.startswith("i_flush_stubs"))
    assert row.split()[1:] == [".", "5"]
    assert "modules compiled at boot" in out


def test_the_render_runs_over_a_real_tape(pair: list[jdump.Tape]) -> None:
    out = jdump.render(pair[0])
    assert "fib/3" in out
    assert "native instructions per BEAM instruction" in out
