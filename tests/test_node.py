"""The degradation ladder, and the promise attached to its bottom rung.

Two halves. The first builds ladders in a temporary directory to check that a
broken one is refused, because the real ladder is correct and a checker only
proves itself against a wrong one. The second reads the real ladder and the
real lessons, since the claim that rung 4 costs a reader nothing but
interactivity is a claim about the pages rather than about this file.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools import bake, node, sitebuild

LADDER = Path("node/ladder.toml")
LESSONS = sorted(p.parent for p in Path("lessons").rglob("lesson.livemd"))


def rung(number: int, **changes: object) -> dict:
    one = {
        "number": number,
        "name": f"rung{number}",
        "title": f"Rung {number}",
        "badge": f"Badge {number}",
        "target": "node",
        "tone": "info",
        "session_minutes": 10,
        "extensions": 1,
        "note": "What happens if you press it.",
        "entered_when": "Something happened.",
        "costs_the_reader": "Something.",
    }
    one.update(changes)
    return one


def floor(number: int, **changes: object) -> dict:
    return rung(number, target="corpus", session_minutes=0, extensions=0, **changes)


def value(one: object) -> str:
    if isinstance(one, bool):
        return "true" if one else "false"
    if isinstance(one, int):
        return str(one)
    return '"' + str(one).replace('"', '\\"') + '"'


def written(tmp_path: Path, rungs: list[dict], standing_on: int = 1, **top: object) -> Path:
    """A ladder file, built from dictionaries so a test can break one field."""
    head = {"node_url": "https://node.example", "corpus_page": "corpus.md"}
    head.update(top)
    lines = [f"{key} = {value(one)}" for key, one in head.items()]
    lines += ["", "[current]", f"rung = {standing_on}", 'since = "2026-09-06"', 'why = "Because."']
    for one in rungs:
        lines += ["", "[[rung]]"] + [f"{key} = {value(field)}" for key, field in one.items()]
    path = tmp_path / "ladder.toml"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def test_a_ladder_that_only_gets_worse_is_accepted(tmp_path: Path) -> None:
    ladder = node.read(written(tmp_path, [rung(1), rung(2, session_minutes=5, extensions=0), floor(3)]))
    assert node.problems(ladder) == []


def test_a_rung_that_offers_more_than_the_one_above_it_is_refused(tmp_path: Path) -> None:
    """A ladder is a list of things getting worse. A rung further down offering
    longer sessions is either a typo or a plan nobody thought through, and
    either way the reader meets a badge promising something the service is not
    in a state to give."""
    ladder = node.read(written(tmp_path, [rung(1, session_minutes=5), rung(2, session_minutes=10), floor(3)]))
    assert any("goes up as it goes down" in problem for problem in node.problems(ladder))


def test_a_bottom_rung_that_still_needs_a_server_is_refused(tmp_path: Path) -> None:
    """The floor is the state where nothing of ours is running. A bottom rung
    pointing at the sandbox means there is no floor, only a ladder that ends in
    a dead link."""
    ladder = node.read(written(tmp_path, [rung(1), rung(2)]))
    assert any("not a floor" in problem for problem in node.problems(ladder))


def test_a_badge_that_opens_a_session_of_no_minutes_is_refused(tmp_path: Path) -> None:
    ladder = node.read(written(tmp_path, [rung(1, session_minutes=0), floor(2)]))
    assert any("dead badge" in problem for problem in node.problems(ladder))


def test_two_rungs_wearing_the_same_words_are_refused(tmp_path: Path) -> None:
    """The badge is the only part of the ladder a reader ever sees, so two rungs
    that say the same thing are two states the reader cannot tell apart."""
    ladder = node.read(written(tmp_path, [rung(1, badge="Open it"), rung(2, badge="Open it"), floor(3)]))
    assert any("cannot tell them apart" in problem for problem in node.problems(ladder))


def test_a_rung_missing_a_field_says_which_one(tmp_path: Path) -> None:
    broken = rung(1)
    del broken["note"]
    path = written(tmp_path, [broken, floor(2)])
    with pytest.raises(node.Broken, match="missing note"):
        node.read(path)


def test_standing_on_a_rung_that_is_not_there_is_refused(tmp_path: Path) -> None:
    ladder = node.read(written(tmp_path, [rung(1), floor(2)], standing_on=7))
    assert any("not on the ladder" in problem for problem in node.problems(ladder))


def test_rungs_numbered_with_a_gap_are_refused(tmp_path: Path) -> None:
    ladder = node.read(written(tmp_path, [rung(1), floor(3)]))
    assert any("no gaps" in problem for problem in node.problems(ladder))


def test_a_ladder_file_that_is_not_there_says_what_it_was_for(tmp_path: Path) -> None:
    with pytest.raises(node.Broken, match="badge on every lesson comes out of it"):
        node.read(tmp_path / "nothing.toml")


@pytest.fixture
def real() -> node.Ladder:
    return node.read(LADDER)


def test_the_committed_ladder_is_sound(real: node.Ladder) -> None:
    assert node.problems(real) == []


def test_the_four_rungs_are_the_four_that_were_designed(real: node.Ladder) -> None:
    """Named rather than counted. The ladder was designed before the sandbox
    was built, and a rung quietly disappearing is the kind of change that
    should need an argument."""
    assert [one.name for one in real.rungs] == ["normal", "queued", "throttled", "off"]


def test_every_rung_renders_a_badge_a_reader_can_press(real: node.Ladder) -> None:
    for one in real.rungs:
        drawn = node.badge(real, "t07", one)
        assert one.title in drawn
        assert one.note in drawn
        assert f"[{one.badge}](" in drawn
        assert ".md-button" in drawn


def test_a_rung_that_opens_a_session_links_at_the_sandbox(real: node.Ladder) -> None:
    for one in real.rungs:
        if one.opens_a_session:
            assert node.link(real, one, "m02") == f"{real.node_url}/m02"


def test_the_bottom_rung_links_at_a_page_the_site_stages(real: node.Ladder) -> None:
    """The one link that has to work when nothing of ours is running. It is
    relative, so it resolves from a file on disk rather than from a host, and
    the file it resolves to is one sitebuild copies in."""
    bottom = real.rungs[-1]
    assert node.link(real, bottom, "t07") == "../../corpus.md"
    staged = [name for name, _, _ in sitebuild.TOP]
    assert real.corpus_page in staged


def test_every_threat_has_a_control_and_a_way_of_checking_it() -> None:
    """A control nobody ever runs is a sentence. The milestone asked for egress
    verified absent by test rather than by configuration review, and this holds
    every row of the threat model to that, not only the egress one."""
    rows = node.defences()
    assert node.scope_problems(rows) == []
    assert len(rows) >= 5


def test_the_threat_model_names_the_things_a_sandbox_is_for() -> None:
    """Named rather than counted, because a threat model that loses the escape
    row and keeps the mining row still passes a count."""
    threats = " ".join(row.threat.lower() for row in node.defences())
    for must in ("escape", "persistence", "third parties", "exhaustion", "denial of service"):
        assert must in threats


def test_a_control_with_no_check_against_it_is_refused(tmp_path: Path) -> None:
    page = tmp_path / "scope.md"
    page.write_text(
        "# Scope\n\n"
        f"{node.DEFENDED}\n\n"
        "| Threat | Control | How it is checked |\n"
        "| --- | --- | --- |\n"
        "| Escape | The jailer | It runs on every deploy |\n"
        "| Egress | No route off the bridge |  |\n",
        encoding="utf-8",
    )
    assert any("no way of checking it" in one for one in node.scope_problems(node.defences(page)))


def test_a_scope_statement_with_no_threats_in_it_is_refused(tmp_path: Path) -> None:
    page = tmp_path / "scope.md"
    page.write_text(f"# Scope\n\n{node.DEFENDED}\n\nNothing here yet.\n", encoding="utf-8")
    assert any("not a threat model" in one for one in node.scope_problems(node.defences(page)))


def test_the_scope_statement_is_published_rather_than_kept_in_the_repository() -> None:
    """Published is the word the milestone used. A threat model nobody outside
    the project can read is a threat model nobody outside the project reviews,
    so the page is staged as part of the site like any other."""
    staged = {source: name for name, source, _ in sitebuild.TOP}
    assert node.SCOPE in staged


def test_the_current_rung_carries_a_reason(real: node.Ladder) -> None:
    assert len(real.why.split()) > 10
    assert real.since


def test_the_badge_goes_under_the_title_and_changes_nothing_else(real: node.Ladder) -> None:
    """A lesson page with a badge is the lesson plus a badge. Anything else and
    the page a reader sees has drifted from the notebook they can download."""
    text = (LESSONS[0] / "lesson.livemd").read_text(encoding="utf-8")
    staged = sitebuild.with_badge(text, LESSONS[0].name, real)
    drawn = node.badge(real, LESSONS[0].name).rstrip("\n")

    assert drawn in staged
    assert staged.startswith(text.splitlines()[0])
    assert staged.replace(drawn + "\n\n", "", 1) == text


def test_a_page_with_no_title_is_reported_rather_than_left_bare(real: node.Ladder) -> None:
    with pytest.raises(node.Broken, match="nowhere to put the badge"):
        sitebuild.with_badge("no heading here\n", "t07", real)


# The two cells a lesson deliberately does not print the output of, and why.
# Everything else the baker compares has to be on the page, because on rung 4
# the page is all a reader gets.
SHOWS_NOTHING = {
    # It prints the release and the machine in front of you. A fixed copy on
    # the page would be showing a reader somebody else's laptop and calling it
    # theirs.
    "banner",
    # The boss fight. Printing the grader's output would put the answer on the
    # page above the question, which is the one thing a boss fight cannot have.
    "boss",
}


@pytest.mark.parametrize("lesson", LESSONS, ids=[p.name for p in LESSONS])
def test_the_bottom_rung_costs_a_reader_no_information(lesson: Path, real: node.Ladder) -> None:
    """The promise on rung 4, checked against the pages rather than believed.

    With the Node off a reader cannot run a cell, so the only thing between
    them and the answer is what the lesson prints on the page. Every cell the
    baker compares shows its output inline, apart from the two named above, and
    the staged page still holds all of it with the badge in place.
    """
    cells = bake.parse(lesson / "lesson.livemd")
    compared = bake.plan(lesson).compared
    staged = sitebuild.with_badge((lesson / "lesson.livemd").read_text(encoding="utf-8"), lesson.name, real)

    silent = {cell.name for cell in cells if cell.name in compared and not cell.shown}
    assert silent <= SHOWS_NOTHING, (
        f"{lesson.name}: {sorted(silent - SHOWS_NOTHING)} runs and is compared and prints nothing on "
        f"the page, so a reader on rung 4 never sees the answer"
    )

    for cell in cells:
        if cell.name in compared and cell.shown:
            assert cell.shown.strip() in staged
