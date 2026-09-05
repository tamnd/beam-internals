"""The animation driver, and the rule that every animation has a still.

The rule is in bxmanim/README.md: a still that carries the same information is
part of the figure, not a courtesy. A rule in a README is a rule somebody
forgets on the fourth scene, so the shape it needs is checked here.

Nothing in this file imports Manim. The driver reads the scene files with `ast`
for exactly that reason, so `just check` still runs on a machine that has never
installed the anim extra, which is every machine in CI except the one that draws.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools import figures

SCENE = """
STILL = "lessons/02-terms/m02/files/tag-doors.png"


class TagDoors(Scene):
    pass


class TagDoorsStill(Scene):
    pass
"""


def scene_file(tmp_path: Path, body: str = SCENE) -> Path:
    path = tmp_path / "m99_example.py"
    path.write_text(body)
    return path


def test_a_well_formed_scene_file_declares_both(tmp_path: Path) -> None:
    still, scenes = figures.declared(scene_file(tmp_path))
    assert still == "lessons/02-terms/m02/files/tag-doors.png"
    assert scenes == ["TagDoors", "TagDoorsStill"]


def test_a_scene_with_no_still_constant_is_rejected(tmp_path: Path) -> None:
    body = SCENE.replace('STILL = "lessons/02-terms/m02/files/tag-doors.png"', "")
    with pytest.raises(figures.Broken, match="declares no STILL"):
        figures.declared(scene_file(tmp_path, body))


def test_a_moving_scene_with_no_still_scene_is_rejected(tmp_path: Path) -> None:
    body = SCENE.replace("class TagDoorsStill(Scene):\n    pass\n", "")
    with pytest.raises(figures.Broken, match="one moving scene"):
        figures.declared(scene_file(tmp_path, body))


def test_two_moving_scenes_in_one_file_are_rejected(tmp_path: Path) -> None:
    """Because then the still is ambiguous, and the wrong one gets published
    quietly rather than loudly."""
    body = SCENE + "\n\nclass TagDoorsAgain(Scene):\n    pass\n"
    with pytest.raises(figures.Broken, match="one moving scene"):
        figures.declared(scene_file(tmp_path, body))


def test_the_vocabulary_is_not_treated_as_a_scene() -> None:
    assert Path("bxmanim/vocabulary.py") not in figures.scene_files()


def test_every_scene_in_the_repository_has_its_still_committed() -> None:
    files = figures.scene_files()
    assert files, "bxmanim has no scenes, which means this rule is checking nothing"
    for path in files:
        still, _ = figures.declared(path)
        assert Path(still).exists(), f"{path} declares {still} and the file is not there"
