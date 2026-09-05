"""Citation parsing and the rules that apply to a citation.

The pattern is the part that has to be right, because a citation the regex does
not recognise is not reported as broken, it is simply never checked. So the
tests are mostly about what the pattern picks up and what it leaves alone.
"""

from __future__ import annotations

from pathlib import Path

from tools import refcheck


def cite(tmp_path: Path, text: str) -> list[refcheck.Citation]:
    path = tmp_path / "sample.md"
    path.write_text(text, encoding="utf-8")
    return refcheck.collect([path])


def test_a_single_line_citation_is_read(tmp_path: Path) -> None:
    found = cite(tmp_path, "The budget lives at `erts/emulator/beam/erl_vm.h:56@OTP-29.0.5`.\n")
    assert len(found) == 1
    assert found[0].path == "erts/emulator/beam/erl_vm.h"
    assert found[0].start == 56
    assert found[0].end == 56
    assert found[0].tag == "OTP-29.0.5"


def test_a_span_is_read(tmp_path: Path) -> None:
    found = cite(tmp_path, "The subtags are `erts/emulator/beam/erl_term.h:131-148@OTP-29.0.5`.\n")
    assert (found[0].start, found[0].end) == (131, 148)


def test_a_table_outside_the_tree_is_ignored(tmp_path: Path) -> None:
    assert cite(tmp_path, "See notes/scratch.md:12@OTP-29.0.5 for the working.\n") == []


def test_several_citations_on_one_line_are_all_read(tmp_path: Path) -> None:
    text = (
        "Compare `lib/compiler/src/genop.tab:1@OTP-29.0.5` with "
        "`erts/emulator/beam/emu/ops.tab:1@OTP-29.0.5`.\n"
    )
    assert len(cite(tmp_path, text)) == 2


def test_the_generated_file_list_and_the_table_list_do_not_overlap() -> None:
    config = refcheck.load_config(Path("."))
    generated = set(config["rules"]["generated"])
    tables = set(config["rules"]["tables"])
    assert generated & tables == set()


def test_the_pin_is_a_tag_and_a_commit() -> None:
    pin = refcheck.load_config(Path("."))["pin"]
    assert pin["tag"].startswith("OTP-")
    assert len(pin["commit"]) == 40


def test_notebooks_are_collected(tmp_path: Path) -> None:
    (tmp_path / "lesson.livemd").write_text(
        "The budget is `erts/emulator/beam/erl_vm.h:53@OTP-29.0.5`.\n", encoding="utf-8"
    )
    found = refcheck.collect([tmp_path])
    assert [c.path for c in found] == ["erts/emulator/beam/erl_vm.h"]


def test_a_jit_citation_is_read(tmp_path: Path) -> None:
    found = cite(tmp_path, "See `erts/emulator/beam/jit/x86/instr_call.cpp:70@OTP-29.0.5`.\n")
    assert found[0].path == "erts/emulator/beam/jit/x86/instr_call.cpp"
    assert found[0].start == 70


# A citation at the end of a sentence used to swallow the full stop, and then
# report itself as pinned to OTP-29.0.5. rather than OTP-29.0.5. Nothing in the
# tree happened to end a sentence that way until our own Erlang started citing
# it, which is exactly how a pattern bug stays hidden.
def test_a_citation_at_the_end_of_a_sentence_keeps_the_tag_clean(tmp_path: Path) -> None:
    found = cite(tmp_path, "The block is at erts/emulator/beam/erl_crash_dump.c:616@OTP-29.0.5.\n")
    assert found[0].tag == "OTP-29.0.5"
    assert found[0].path == "erts/emulator/beam/erl_crash_dump.c"


# Our own Erlang cites the tree in its comments, for the same reason prose does.
# A citation nobody checks is a citation that rots.
def test_erlang_sources_are_collected(tmp_path: Path) -> None:
    (tmp_path / "mod.erl").write_text(
        "%% The condition is at erts/emulator/sys/unix/erl_unix_sys.h:406@OTP-29.0.5.\n",
        encoding="utf-8",
    )
    (tmp_path / "run.escript").write_text(
        "%% And the block at erts/emulator/beam/erl_crash_dump.c:616@OTP-29.0.5.\n",
        encoding="utf-8",
    )
    found = refcheck.collect([tmp_path])
    assert sorted(c.path for c in found) == [
        "erts/emulator/beam/erl_crash_dump.c",
        "erts/emulator/sys/unix/erl_unix_sys.h",
    ]
