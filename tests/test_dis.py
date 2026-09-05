"""The disassembly tape reader.

Two halves. The first uses a small hand written tape, so that a wrong header, a
wrong kind and an empty file are all exercised without needing the corpus. The
second reads the real tape in `corpora/dis/l1.tape.gz`, because the numbers a
reader is going to quote come from that file and a reader with no `--disable-jit`
build has no way of producing it again.
"""

from __future__ import annotations

import gzip
from pathlib import Path

import pytest

from tools import dis

HEADER = (
    '#{schema => 1, kind => dis, otp => <<"29">>, erts => <<"17.0.5">>, '
    'arch => <<"x86_64-pc-linux-gnu">>, flavor => emu, build => opt, '
    'by_whom => <<"tamnd">>, recorded => <<"2026-09-05T19:36:40Z">>, '
    'module => <<"tiny">>, source => <<"tiny.erl">>, wordsize => 64, '
    "functions => 1, instructions => 2, opcodes => 2, code_bytes => 48, "
    "unresolved_addresses => 0, interpreter_bytes => 36608}."
)

BODY = [
    '{source,<<"tiny">>,<<"-module(tiny).\\n">>}.',
    '{function,1,<<"go">>,0,2,48}.',
    '{instruction,1,1,0,40,<<"i_func_info_IaaI">>,<<"0 `tiny` `go` 0">>}.',
    '{instruction,2,1,40,8,<<"return">>,<<>>}.',
    "{'$tape_end',4}.",
]


def write(path: Path, lines: list[str]) -> Path:
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        handle.write("%% bxtrace tape, schema 1, kind dis\n")
        for line in lines:
            handle.write(line + "\n")
    return path


@pytest.fixture
def tiny(tmp_path: Path) -> Path:
    return write(tmp_path / "tiny.tape.gz", [HEADER, *BODY])


def test_a_tape_reads_back_as_functions_and_instructions(tiny: Path) -> None:
    tape = dis.read(tiny)
    assert [f.signature for f in tape.functions] == ["go/0"]
    assert [i.op for i in tape.instructions] == ["i_func_info_IaaI", "return"]
    assert tape.source == "-module(tiny).\n"
    assert tape.word == 8


def test_instructions_are_grouped_by_the_function_they_belong_to(tiny: Path) -> None:
    tape = dis.read(tiny)
    assert [i.index for i in tape.of(tape.functions[0])] == [1, 2]


def test_a_tape_of_the_wrong_kind_says_which_kind_it_is(tmp_path: Path) -> None:
    path = write(tmp_path / "wrong.tape.gz", [HEADER.replace("kind => dis", "kind => reds")])
    with pytest.raises(dis.Unreadable, match="this is a reds tape"):
        dis.read(path)


def test_an_empty_file_is_reported_rather_than_read_as_nothing(tmp_path: Path) -> None:
    path = write(tmp_path / "empty.tape.gz", [])
    with pytest.raises(dis.Unreadable, match="there is nothing in it"):
        dis.read(path)


def test_the_listing_shows_the_size_in_words_as_well_as_bytes(tiny: Path) -> None:
    """The word column is the finding. Five words for the function header, one
    for a bare return, and the difference is operands sitting in the code."""
    lines = dis.listing(dis.read(tiny))
    assert any(line.split()[:3] == ["0", "40", "5"] for line in lines)
    assert any(line.split()[:3] == ["40", "8", "1"] for line in lines)


def test_the_opcode_view_counts_each_name(tiny: Path) -> None:
    assert dis.opcodes(dis.read(tiny)) == ["  i_func_info_IaaI  1", "  return            1"]


# ---------------------------------------------------------------------------
# The real tape

REAL = Path("corpora/dis/l1.tape.gz")


@pytest.fixture
def l1() -> dis.Tape:
    if not REAL.is_file():
        pytest.skip(f"{REAL} is not here")
    return dis.read(REAL)


def test_the_committed_tape_came_off_an_interpreter_build(l1: dis.Tape) -> None:
    """The one fact that cannot be recovered if it is wrong. A tape recorded on
    the JIT would be empty, so a tape with instructions on it that claimed the
    JIT would mean the flavor field is lying."""
    assert dis.text(l1.header["flavor"]) == "emu"
    assert l1.instructions


def test_the_loader_rewrote_every_instruction_the_compiler_emitted(l1: dis.Tape) -> None:
    """The finding Part 5 is built on. The beam file for these six lines holds
    `gc_bif2`, `is_eq_exact`, `move` and `call_only`. None of those four names
    is in memory by the time the module is loaded."""
    ops = {one.op for one in l1.instructions}
    assert "gc_bif2" not in ops
    assert "is_eq_exact" not in ops
    assert "call_only" not in ops
    assert "i_plus_xxjd" in ops
    assert "i_is_eq_exact_immed_frc" in ops


def test_the_counts_in_the_header_are_the_ones_a_lesson_will_quote(l1: dis.Tape) -> None:
    assert l1.header["functions"] == 5
    assert l1.header["instructions"] == 22
    assert l1.header["code_bytes"] == 520
    assert l1.header["interpreter_bytes"] == 36608


def test_every_instruction_is_a_whole_number_of_words(l1: dis.Tape) -> None:
    """Because the first word is the address of the code that runs it and the
    rest are operands, so there is nothing a fraction of a word could be."""
    assert all(one.size % l1.word == 0 for one in l1.instructions)
    assert all(one.size >= l1.word for one in l1.instructions)


def test_a_branch_target_names_an_instruction_on_the_tape(l1: dis.Tape) -> None:
    """Targets are rewritten from machine addresses to indexes when the tape is
    recorded, which is what makes two machines produce the same rows."""
    targets = [one.args for one in l1.instructions if "@" in one.args]
    assert targets, "the module branches somewhere, so something should have been rewritten"
    known = {one.index for one in l1.instructions}
    for args in targets:
        for piece in args.replace("(", " ").replace(")", " ").split():
            if piece.startswith("@"):
                assert int(piece[1:]) in known


def test_the_render_runs_over_the_real_tape(l1: dis.Tape) -> None:
    """Cheap, and it is the thing anybody actually runs."""
    out = dis.render(l1)
    assert "fib/3" in out
    assert "i_plus_xxjd" in out
    assert "opcodes" in out
