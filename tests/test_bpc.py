"""Generated blueprint regions.

Three things have to hold. The C expressions in the tag headers have to
evaluate to the same numbers a compiler would get. The region markers have to be
found, including the malformed ones. And a region somebody edited by hand has to
fail `--check`, because that is the only reason the tool exists.

The tests use fixtures rather than the pinned tree, so they run without three
hundred megabytes of Erlang source. The generators are exercised against the
real tree in CI, in the job that checks the submodule out.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

from tools import bpc

# A cut down erl_term.h with the shapes that matter: a plain define, one built
# from another, a function-like macro whose body is on the next line, and a
# comment in the middle of a value.
HEADER = """
#define _TAG_PRIMARY_SIZE	2
#define _TAG_PRIMARY_MASK	0x3
#define TAG_PRIMARY_HEADER	0x0
#define TAG_PRIMARY_IMMED1	0x3

#define _TAG_IMMED1_SIZE	4
#define _TAG_IMMED1_SMALL	((0x3 << _TAG_PRIMARY_SIZE) | TAG_PRIMARY_IMMED1)

#define __MAKE_SUBTAG(Pattern)                                                \\
     (((Pattern) << _TAG_PRIMARY_SIZE) & _TAG_HEADER_MASK)

#define MAP_SUBTAG             __MAKE_SUBTAG(0xB) /* the one with a comment */
#define _TAG_HEADER_MASK        0x3F
#define _TAG_HEADER_MAP	           (TAG_PRIMARY_HEADER|MAP_SUBTAG)
"""


@pytest.fixture
def macros(tmp_path: Path) -> bpc.Macros:
    path = tmp_path / "erl_term.h"
    path.write_text(HEADER, encoding="utf-8")
    return bpc.Macros.read(path)


def test_a_plain_define_is_read(macros: bpc.Macros) -> None:
    assert macros.value("_TAG_PRIMARY_SIZE") == 2


def test_a_define_built_from_another_is_expanded(macros: bpc.Macros) -> None:
    # (0x3 << 2) | 0x3
    assert macros.value("_TAG_IMMED1_SMALL") == 0xF


def test_a_function_like_macro_wrapped_onto_the_next_line_is_expanded(macros: bpc.Macros) -> None:
    # This is the one that bit first. The define patterns are anchored to a
    # line, so without joining the continuation the body is a single backslash
    # and the failure names an expression the header does not contain.
    assert macros.value("MAP_SUBTAG") == 0x2C


def test_a_trailing_comment_is_not_part_of_the_value(macros: bpc.Macros) -> None:
    assert macros.value("_TAG_HEADER_MAP") == 0x2C


def test_an_undefined_name_is_reported_by_name(macros: bpc.Macros) -> None:
    with pytest.raises(bpc.Unreadable, match="TAG_PRIMARY_LIST"):
        macros.value("TAG_PRIMARY_LIST")


@pytest.mark.parametrize(
    ("expression", "expected"),
    [
        ("(3*4000)/4", 3000),  # C divides integers, Python would give a float
        ("4000/3", 1333),
        ("(10*4000)/11", 3636),
        ("~(0x1 << 2) & 0x3F", 0x3B),  # the transparent tag mask, and it needs a negative
        ("0x2 << 4 | 0x3", 0x23),  # C and Python agree on shift before or
    ],
)
def test_c_integer_arithmetic(expression: str, expected: int) -> None:
    assert bpc.evaluate(expression) == expected


def test_something_that_is_not_arithmetic_is_refused() -> None:
    # The input is a file from another project, so the evaluator walks the tree
    # by hand and can only do arithmetic. A call is not arithmetic, and the walk
    # is asked directly here because expansion would stop this one earlier.
    with pytest.raises(bpc.Unreadable, match="Call"):
        bpc.walk(ast.parse("f(1)", mode="eval").body)


def test_a_string_that_does_not_parse_is_reported_with_the_text() -> None:
    with pytest.raises(bpc.Unreadable, match="cannot parse"):
        bpc.evaluate("0x3 <<")


def test_a_name_that_never_expanded_is_reported_rather_than_evaluated() -> None:
    with pytest.raises(bpc.Unreadable, match="SOME_MACRO"):
        bpc.evaluate("SOME_MACRO | 0x3")


def regions(text: str) -> tuple[list[bpc.Region], list[str]]:
    return bpc.find_regions(text.splitlines())


def test_a_region_is_found_with_its_body() -> None:
    found, problems = regions(
        "before\n<!-- bpc: primary-tags -->\nrow\n<!-- bpc: end primary-tags -->\nafter\n"
    )
    assert problems == []
    assert len(found) == 1
    assert found[0].name == "primary-tags"
    assert found[0].body == ["row"]


def test_an_empty_region_is_a_region() -> None:
    found, problems = regions("<!-- bpc: primary-tags -->\n<!-- bpc: end primary-tags -->\n")
    assert problems == []
    assert found[0].body == []


def test_a_region_that_is_never_closed_is_reported() -> None:
    _, problems = regions("<!-- bpc: primary-tags -->\nrow\n")
    assert any("never closed" in p for p in problems)


def test_a_region_closed_by_the_wrong_name_is_reported() -> None:
    _, problems = regions("<!-- bpc: primary-tags -->\n<!-- bpc: end header-subtags -->\n")
    assert any("closed by end header-subtags" in p for p in problems)


def test_an_end_with_nothing_open_is_reported() -> None:
    _, problems = regions("<!-- bpc: end primary-tags -->\n")
    assert any("nothing open" in p for p in problems)


def test_a_marker_inside_a_code_fence_is_an_example_and_not_a_region() -> None:
    # CONTRIBUTING shows an author what a region looks like. Before this, the
    # tool read the example as a region and offered to fill the instructions in
    # with a tag table.
    found, problems = regions("```\n<!-- bpc: primary-tags -->\n<!-- bpc: end primary-tags -->\n```\n")
    assert (found, problems) == ([], [])


def test_a_region_after_a_closed_fence_is_still_found() -> None:
    text = "```\nsample\n```\n<!-- bpc: primary-tags -->\nrow\n<!-- bpc: end primary-tags -->\n"
    found, problems = regions(text)
    assert problems == []
    assert [r.name for r in found] == ["primary-tags"]


def test_prose_that_mentions_a_marker_in_passing_is_not_a_marker() -> None:
    # The markers are matched whole, so a line about them in CONTRIBUTING does
    # not open a region that never closes.
    found, problems = regions("Write `<!-- bpc: primary-tags -->` above the table.\n")
    assert (found, problems) == ([], [])


def fake_tree(tmp_path: Path) -> Path:
    """A tree with the one header the test generator reads."""
    tree = tmp_path / "otp" / "erts" / "emulator" / "beam"
    tree.mkdir(parents=True)
    (tree / "erl_term.h").write_text(HEADER, encoding="utf-8")
    return tmp_path / "otp"


def test_a_hand_edited_region_fails_check(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(bpc.GENERATORS, "sample", (lambda _tree: ["| a | b |"], "nowhere"))
    page = tmp_path / "blueprint.md"
    page.write_text(
        "<!-- bpc: sample -->\n| a | edited by hand |\n<!-- bpc: end sample -->\n", encoding="utf-8"
    )

    problems, moved = bpc.rebuild(page, fake_tree(tmp_path), check=True)

    assert moved is True
    assert any("is not what the source says" in p for p in problems)
    assert "edited by hand" in page.read_text(encoding="utf-8")  # --check does not write


def test_the_diff_names_both_sides(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(bpc.GENERATORS, "sample", (lambda _tree: ["fresh"], "nowhere"))
    page = tmp_path / "blueprint.md"
    page.write_text("<!-- bpc: sample -->\nstale\n<!-- bpc: end sample -->\n", encoding="utf-8")

    problems, _ = bpc.rebuild(page, fake_tree(tmp_path), check=True)

    assert "-stale" in problems[0]
    assert "+fresh" in problems[0]


def test_a_region_that_already_matches_is_left_alone(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setitem(bpc.GENERATORS, "sample", (lambda _tree: ["| a | b |"], "nowhere"))
    page = tmp_path / "blueprint.md"
    original = "<!-- bpc: sample -->\n| a | b |\n<!-- bpc: end sample -->\n"
    page.write_text(original, encoding="utf-8")

    problems, moved = bpc.rebuild(page, fake_tree(tmp_path), check=True)

    assert (problems, moved) == ([], False)


def test_writing_replaces_the_body_and_keeps_the_markers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setitem(bpc.GENERATORS, "sample", (lambda _tree: ["one", "two"], "nowhere"))
    page = tmp_path / "blueprint.md"
    page.write_text("above\n<!-- bpc: sample -->\nold\n<!-- bpc: end sample -->\nbelow\n", encoding="utf-8")

    bpc.rebuild(page, fake_tree(tmp_path), check=False)

    assert page.read_text(encoding="utf-8") == (
        "above\n<!-- bpc: sample -->\none\ntwo\n<!-- bpc: end sample -->\nbelow\n"
    )


def test_two_regions_in_one_file_are_both_rewritten(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # Rewriting walks the regions backwards so that changing the length of the
    # first one does not move the second one out from under the indices.
    monkeypatch.setitem(bpc.GENERATORS, "first", (lambda _tree: ["a", "a", "a"], "nowhere"))
    monkeypatch.setitem(bpc.GENERATORS, "second", (lambda _tree: ["b"], "nowhere"))
    page = tmp_path / "blueprint.md"
    page.write_text(
        "<!-- bpc: first -->\nx\n<!-- bpc: end first -->\n"
        "middle\n"
        "<!-- bpc: second -->\ny\ny\n<!-- bpc: end second -->\n",
        encoding="utf-8",
    )

    bpc.rebuild(page, fake_tree(tmp_path), check=False)

    assert page.read_text(encoding="utf-8") == (
        "<!-- bpc: first -->\na\na\na\n<!-- bpc: end first -->\n"
        "middle\n"
        "<!-- bpc: second -->\nb\n<!-- bpc: end second -->\n"
    )


def test_a_region_naming_a_generator_that_does_not_exist_is_reported(tmp_path: Path) -> None:
    page = tmp_path / "blueprint.md"
    page.write_text("<!-- bpc: invented -->\n<!-- bpc: end invented -->\n", encoding="utf-8")

    problems, _ = bpc.rebuild(page, fake_tree(tmp_path), check=True)

    assert any("no generator called invented" in p for p in problems)


def test_a_generator_that_cannot_read_its_table_reports_rather_than_writes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def broken(_tree: Path) -> list[str]:
        raise bpc.Unreadable("the table moved")

    monkeypatch.setitem(bpc.GENERATORS, "sample", (broken, "nowhere"))
    page = tmp_path / "blueprint.md"
    page.write_text("<!-- bpc: sample -->\nkept\n<!-- bpc: end sample -->\n", encoding="utf-8")

    problems, _ = bpc.rebuild(page, fake_tree(tmp_path), check=False)

    assert any("the table moved" in p for p in problems)
    assert "kept" in page.read_text(encoding="utf-8")


def test_the_subtag_generator_stops_when_the_list_moves(tmp_path: Path) -> None:
    # A new subtag upstream has to be a failure and not a quietly shorter table,
    # because the sentence describing it is written by a person.
    tree = fake_tree(tmp_path)
    header = tree / "erts" / "emulator" / "beam" / "erl_term.h"
    header.write_text(HEADER + "\n#define INVENTED_SUBTAG __MAKE_SUBTAG(0xF)\n", encoding="utf-8")

    with pytest.raises(bpc.Unreadable, match="INVENTED"):
        bpc.header_subtags(tree)


def test_generated_output_is_a_markdown_table() -> None:
    rendered = bpc.table(["Name", "Value"], [["`a`", "1"]])
    assert rendered == ["| Name | Value |", "| --- | --- |", "| `a` | 1 |"]


def test_bits_pads_to_the_width_of_the_tag() -> None:
    assert bpc.bits(0x3, 6) == "000011"
