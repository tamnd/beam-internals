"""The baker's parser and its bookkeeping.

Nothing here runs Elixir. The half of the baker that reads notebooks and checks
that the recordings line up with `meta.toml` is deliberately separate from the
half that needs a release on the path, so that a contributor with no Erlang
installed can still run the test suite and still be told when a cell has gone
missing from a list.
"""

from __future__ import annotations

import re
import textwrap
from pathlib import Path

import pytest

from tools import bake

NOTEBOOK = """\
# A lesson

Some prose.

<!-- cell: banner -->

```elixir
IO.puts("hello")
```

More prose.

<!-- cell: answer -->

```elixir
6 * 7
```

```
42
```

<!-- cell: none, a listing -->

```elixir
this_is_never_run()
```

<!-- cell: none, a diagram -->

```mermaid
graph TD
```
"""

META = """\
id = "x99"

[bake]
deterministic = ["answer"]
not_compared = ["banner"]
"""


def lesson(tmp_path: Path, notebook: str = NOTEBOOK, meta: str = META, **recordings: str) -> Path:
    room = tmp_path / "x99"
    (room / "expected").mkdir(parents=True)
    (room / "lesson.livemd").write_text(notebook)
    (room / "meta.toml").write_text(meta)
    for name, body in recordings.items():
        (room / "expected" / f"{name}.txt").write_text(body)
    return room


def test_the_marked_elixir_cells_come_back_in_order(tmp_path: Path) -> None:
    cells = bake.parse(lesson(tmp_path) / "lesson.livemd")
    assert [cell.name for cell in cells] == ["banner", "answer"]
    assert cells[0].code == 'IO.puts("hello")\n'


def test_a_listing_is_not_a_cell(tmp_path: Path) -> None:
    """The lessons print code they want read rather than run, and there has to
    be a way to say so that is not silence."""
    names = [cell.name for cell in bake.parse(lesson(tmp_path) / "lesson.livemd")]
    assert "none, a listing" not in names


def test_an_unmarked_elixir_block_is_refused(tmp_path: Path) -> None:
    notebook = NOTEBOOK + "\n```elixir\nforgotten()\n```\n"
    with pytest.raises(bake.Broken, match="no cell marker"):
        bake.parse(lesson(tmp_path, notebook=notebook) / "lesson.livemd")


def test_a_marker_separated_from_its_block_by_prose_does_not_count(tmp_path: Path) -> None:
    notebook = "<!-- cell: stray -->\n\nprose in between\n\n```elixir\nx = 1\n```\n"
    with pytest.raises(bake.Broken, match="no cell marker"):
        bake.parse(lesson(tmp_path, notebook=notebook) / "lesson.livemd")


def test_the_output_block_under_a_cell_is_picked_up(tmp_path: Path) -> None:
    cells = bake.parse(lesson(tmp_path) / "lesson.livemd")
    answer = next(cell for cell in cells if cell.name == "answer")
    assert answer.shown == "42\n"


def test_a_cell_with_no_output_block_shows_nothing(tmp_path: Path) -> None:
    """Both boss fights print no output in the lesson, on purpose, because a
    lesson that arrives with the answer on the page is not a prediction gate."""
    cells = bake.parse(lesson(tmp_path) / "lesson.livemd")
    banner = next(cell for cell in cells if cell.name == "banner")
    assert banner.shown is None


def test_an_elixir_block_is_not_mistaken_for_an_output_block(tmp_path: Path) -> None:
    notebook = "<!-- cell: one -->\n\n```elixir\nx = 1\n```\n\n<!-- cell: two -->\n\n```elixir\nx + 1\n```\n"
    cells = bake.parse(lesson(tmp_path, notebook=notebook) / "lesson.livemd")
    assert [cell.shown for cell in cells] == [None, None]


def test_a_fence_that_never_closes_is_refused(tmp_path: Path) -> None:
    notebook = "<!-- cell: one -->\n\n```elixir\nx = 1\n"
    with pytest.raises(bake.Broken, match="never closes"):
        bake.parse(lesson(tmp_path, notebook=notebook) / "lesson.livemd")


def test_a_lesson_that_lines_up_has_no_problems(tmp_path: Path) -> None:
    room = lesson(tmp_path, answer="42\n")
    assert bake.bookkeeping(room, bake.parse(room / "lesson.livemd")) == []


def test_a_cell_in_neither_list_is_reported(tmp_path: Path) -> None:
    meta = META.replace('not_compared = ["banner"]', "not_compared = []")
    room = lesson(tmp_path, meta=meta, answer="42\n")
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("banner" in p and "neither list" in p for p in problems)


def test_a_listed_cell_the_notebook_does_not_have_is_reported(tmp_path: Path) -> None:
    meta = META.replace('not_compared = ["banner"]', 'not_compared = ["banner", "ghost"]')
    room = lesson(tmp_path, meta=meta, answer="42\n")
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("ghost" in p and "no such cell" in p for p in problems)


def test_a_deterministic_cell_with_no_recording_is_reported(tmp_path: Path) -> None:
    room = lesson(tmp_path)
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("expected/answer.txt" in p for p in problems)


def test_a_recording_that_belongs_to_nothing_is_reported(tmp_path: Path) -> None:
    room = lesson(tmp_path, answer="42\n", leftover="from a cell that was deleted\n")
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("leftover" in p and "belongs to no" in p for p in problems)


def test_a_name_in_both_lists_is_reported(tmp_path: Path) -> None:
    meta = META.replace('not_compared = ["banner"]', 'not_compared = ["banner", "answer"]')
    room = lesson(tmp_path, meta=meta, answer="42\n")
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("deterministic and as not compared" in p for p in problems)


def test_the_lesson_showing_something_other_than_the_recording_is_reported(tmp_path: Path) -> None:
    """This is the one worth having. A reader compares what they see against
    what the page prints, and the page is the thing they cannot check."""
    room = lesson(tmp_path, answer="41\n")
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("is not what expected/answer.txt records" in p for p in problems)


def test_two_cells_with_the_same_name_are_reported(tmp_path: Path) -> None:
    notebook = "<!-- cell: twice -->\n\n```elixir\n1\n```\n\n<!-- cell: twice -->\n\n```elixir\n2\n```\n"
    meta = 'id = "x99"\n\n[bake]\ndeterministic = []\nnot_compared = ["twice"]\n'
    room = lesson(tmp_path, notebook=notebook, meta=meta)
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("two cells called twice" in p for p in problems)


def test_a_missing_bake_section_is_reported(tmp_path: Path) -> None:
    room = lesson(tmp_path, meta='id = "x99"\n')
    problems = bake.bookkeeping(room, bake.parse(room / "lesson.livemd"))
    assert any("no [bake] section" in p for p in problems)


def test_write_brings_the_recording_and_the_page_forward_together(tmp_path: Path) -> None:
    room = lesson(tmp_path, answer="42\n")
    cells = bake.parse(room / "lesson.livemd")
    changed = bake.write(room, cells, {"banner": "hello\n", "answer": "43\n"})

    assert (room / "expected" / "answer.txt").read_text() == "43\n"
    assert "```\n43\n```" in (room / "lesson.livemd").read_text()
    assert len(changed) == 2


def test_write_leaves_a_cell_whose_output_did_not_move_alone(tmp_path: Path) -> None:
    room = lesson(tmp_path, answer="42\n")
    before = (room / "lesson.livemd").read_text()
    cells = bake.parse(room / "lesson.livemd")

    assert bake.write(room, cells, {"banner": "hello\n", "answer": "42\n"}) == []
    assert (room / "lesson.livemd").read_text() == before


def test_write_says_so_rather_than_raising_a_key_error(tmp_path: Path) -> None:
    """`--write` runs even when the bookkeeping is unhappy, because half of what
    the bookkeeping reports is exactly what writing is there to fix. A lesson
    with no [bake] section at all is the one thing it cannot fix."""
    room = lesson(tmp_path, meta='id = "x99"\n')
    cells = bake.parse(room / "lesson.livemd")
    with pytest.raises(bake.Broken, match=re.escape("no [bake] section")):
        bake.write(room, cells, {"banner": "hello\n", "answer": "42\n"})


def test_every_lesson_in_the_repository_keeps_its_books(tmp_path: Path) -> None:
    """The real thing, which is the only version of this test that can catch a
    lesson somebody added yesterday."""
    found = bake.lessons([])
    assert found, "no lessons, which means this test is checking nothing"
    for room in found:
        assert bake.bookkeeping(room, bake.parse(room / "lesson.livemd")) == []


def test_asking_for_a_lesson_that_is_not_there_says_so() -> None:
    with pytest.raises(bake.Broken, match="no such lesson: t99"):
        bake.lessons(["t99"])


def test_a_difference_names_both_sides() -> None:
    report = bake.difference("answer", "42\n", "43\n")
    assert "expected/answer.txt" in report
    assert "this run" in report
    assert "-42" in report and "+43" in report


def test_the_runner_is_executable_elixir() -> None:
    """The Python half shells out to it by name, so a rename that misses one of
    the two is worth catching here rather than at the end of a bake."""
    assert bake.RUNNER.exists()
    assert textwrap.dedent(bake.RUNNER.read_text()).startswith("#")
