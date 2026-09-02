"""Staging the book into the site directory.

The thing worth testing is that a figure keeps working. A lesson refers to its
figures with a relative path, the notebook and the published page hold the same
text, so the page has to be staged somewhere that makes that relative path
resolve. That is why a lesson becomes a directory with an index rather than a
flat file, and why the directory of attached files keeps Livebook's name.
"""

from __future__ import annotations

from pathlib import Path

from tools import sitebuild


def test_attached_files_are_copied_next_to_the_page(tmp_path: Path) -> None:
    lesson = tmp_path / "t07"
    (lesson / "files").mkdir(parents=True)
    (lesson / "files" / "figure.svg").write_text("<svg/>", encoding="utf-8")

    page = tmp_path / "out" / "t07"
    page.mkdir(parents=True)
    sitebuild.stage_assets(lesson, page)

    assert (page / "files" / "figure.svg").read_text(encoding="utf-8") == "<svg/>"


def test_a_lesson_with_no_files_directory_is_not_a_problem(tmp_path: Path) -> None:
    lesson = tmp_path / "t07"
    lesson.mkdir()
    page = tmp_path / "out" / "t07"
    page.mkdir(parents=True)

    sitebuild.stage_assets(lesson, page)

    assert list(page.iterdir()) == []


def test_a_lesson_gets_a_directory_and_an_index(tmp_path: Path) -> None:
    nav = sitebuild.navigation([Path("lessons/01-tourist/t07/lesson.livemd")], [])
    assert "lessons/t07/index.md" in nav
