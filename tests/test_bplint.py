"""The blueprint shape checker.

Most of what bplint enforces is structural and boring on purpose. The part worth
testing carefully is the promotion gate, because that is the only rule here that
decides whether a document is allowed to claim it has been checked, and a gate
that can be walked around is worse than no gate at all.
"""

from __future__ import annotations

from pathlib import Path

from tools import bplint

SECTIONS = "\n\n".join(f"## {s}\n\nText." for s in bplint.SECTIONS)

HEADER = """# BP-TEST-001 A thing

Status: {status}
Applies to: OTP-29.0.5 (erts-17.0.5)
Lesson: m01
Depends on: BP-TERM-001
Conformance: {conformance}

"""


def blueprint(
    tmp_path: Path, status: str = "draft", conformance: str = "CT-TEST-001", body: str = ""
) -> Path:
    path = tmp_path / "BP-TEST-001.md"
    path.write_text(HEADER.format(status=status, conformance=conformance) + (body or SECTIONS))
    return path


def test_a_complete_draft_passes(tmp_path: Path) -> None:
    assert bplint.check(blueprint(tmp_path)) == []


def test_a_missing_section_is_rejected(tmp_path: Path) -> None:
    body = "\n\n".join(f"## {s}\n\nText." for s in bplint.SECTIONS if not s.startswith("6."))
    problems = bplint.check(blueprint(tmp_path, body=body))
    assert any("Observable surface" in problem for problem in problems)


def test_an_unknown_status_is_rejected(tmp_path: Path) -> None:
    assert bplint.check(blueprint(tmp_path, status="finished")) != []


def test_a_backreference_to_the_lesson_is_rejected(tmp_path: Path) -> None:
    body = SECTIONS.replace(
        "## 5. Edge cases and error behaviour\n\nText.",
        "## 5. Edge cases and error behaviour\n\nAs we saw above, it fails.",
    )
    problems = bplint.check(blueprint(tmp_path, body=body))
    assert any("refers back" in problem for problem in problems)


def test_an_ordering_guarantee_needs_a_boundary(tmp_path: Path) -> None:
    body = SECTIONS.replace(
        "## 4. Invariants, ordering guarantees and yield points\n\nText.",
        "## 4. Invariants, ordering guarantees and yield points\n\nORD-TEST-1. Pairs come out sorted.",
    )
    problems = bplint.check(blueprint(tmp_path, body=body))
    assert any("what is not guaranteed" in problem for problem in problems)


def test_a_yield_marker_needs_a_yield_point(tmp_path: Path) -> None:
    body = SECTIONS.replace("## 3. Algorithms\n\nText.", "## 3. Algorithms\n\n1. walk the list [yield]")
    problems = bplint.check(blueprint(tmp_path, body=body))
    assert any("does not list it" in problem for problem in problems)


# The promotion gate.


def test_draft_needs_no_suite(tmp_path: Path) -> None:
    """Which is the whole point of draft. A blueprint has to be writable before
    it is checkable, and the gate is on leaving draft rather than on entering it."""
    assert bplint.check(blueprint(tmp_path, conformance="CT-NOTHING-999")) == []


def test_reviewed_without_a_suite_file_is_rejected(tmp_path: Path) -> None:
    problems = bplint.check(blueprint(tmp_path, status="reviewed", conformance="CT-NOTHING-999"))
    assert any("has to exist" in problem for problem in problems)


def test_reviewed_needs_section_seven_to_name_the_suite(tmp_path: Path) -> None:
    body = SECTIONS.replace("## 7. Conformance\n\nText.", "## 7. Conformance\n\nSomebody should write this.")
    problems = bplint.check(blueprint(tmp_path, status="reviewed", body=body))
    assert any("section 7 has to name" in problem for problem in problems)


def test_the_suite_path_comes_from_the_id() -> None:
    assert bplint.suite_path("CT-DIST-001") == Path("conformance/suites/ct_dist_001.erl")


def test_every_committed_blueprint_passes() -> None:
    files = [p for p in Path("blueprints").rglob("*.md") if p.name != "NOTATION.md"]
    assert files
    assert [problem for path in files for problem in bplint.check(path)] == []
