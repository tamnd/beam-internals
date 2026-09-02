"""The house style checker, tested on the mistakes it exists to catch.

Each test is one rule and one example of the thing going wrong, written the way
it would actually appear in a lesson rather than as a minimal string, because a
rule that only fires on a minimal string is a rule that does not fire.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools import lintprose


def rules(tmp_path: Path, text: str) -> list[str]:
    path = tmp_path / "sample.md"
    path.write_text(text, encoding="utf-8")
    return [problem.rule for problem in lintprose.check(path)]


def fired(found: list[str], rule: str) -> bool:
    # The banned word rule carries the pattern that matched, so the comparison
    # is on the prefix rather than the whole name.
    return any(name.split(" ")[0] == rule for name in found)


def test_clean_prose_passes(tmp_path: Path) -> None:
    text = "The scheduler gives a process 4000 reductions and then takes the core back.\n"
    assert rules(tmp_path, text) == []


def test_em_dash_is_rejected(tmp_path: Path) -> None:
    text = "The scheduler counts reductions — not milliseconds — and yields.\n"
    assert fired(rules(tmp_path, text), "em-dash")


def test_horizontal_rule_is_rejected(tmp_path: Path) -> None:
    text = "The loader reads twelve chunks.\n\n---\n\nThe interpreter never sees the file.\n"
    assert fired(rules(tmp_path, text), "horizontal-rule")


def test_sentence_wrapped_across_lines_is_rejected(tmp_path: Path) -> None:
    text = (
        "The scheduler counts reductions rather than time, which is why a tight\n"
        "loop does not starve its neighbours.\n"
    )
    assert fired(rules(tmp_path, text), "sentence-wrapped-across-lines")


@pytest.mark.parametrize(
    "word",
    ["simply", "just", "obviously", "trivially", "note that", "it turns out"],
)
def test_banned_words_are_rejected(tmp_path: Path, word: str) -> None:
    text = f"You {word} read the table and the answer is there.\n"
    assert fired(rules(tmp_path, text), "banned-word")


def test_banned_word_inside_code_is_allowed(tmp_path: Path) -> None:
    text = "The compiler pass is called `just_in_time` and the name is unfortunate.\n"
    assert not fired(rules(tmp_path, text), "banned-word")


def test_citation_without_a_tag_is_rejected(tmp_path: Path) -> None:
    text = "The budget is set in erts/emulator/beam/erl_vm.h:56 and nowhere else.\n"
    assert fired(rules(tmp_path, text), "citation-without-tag")


def test_citation_with_a_tag_passes(tmp_path: Path) -> None:
    text = "The budget is set in `erts/emulator/beam/erl_vm.h:56@OTP-29.0.5` and nowhere else.\n"
    assert not fired(rules(tmp_path, text), "citation-without-tag")


def test_trailing_whitespace_is_rejected(tmp_path: Path) -> None:
    text = "The run queue is per scheduler.  \n"
    assert fired(rules(tmp_path, text), "trailing-whitespace")


def test_allow_directive_suppresses_a_rule(tmp_path: Path) -> None:
    text = "<!-- lintprose: allow banned-word -->\nThe paper calls this obviously correct.\n"
    assert not fired(rules(tmp_path, text), "banned-word")
