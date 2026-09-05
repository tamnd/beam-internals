"""The Erlang term reader.

It exists so that a tape header can be checked against the manifest entry that
claims to describe it, which means the thing worth testing is the distinctions
it keeps: an atom is not a binary, a binary of text is not a list of bytes, and
a term it cannot read says so rather than coming back half read.
"""

from __future__ import annotations

import pytest

from tools import erlterm
from tools.erlterm import Atom


def test_the_shapes_a_tape_header_is_made_of() -> None:
    text = '#{schema => 1, kind => reds, otp => <<"29">>, os => {unix, darwin, <<"24.6.0">>}}.'
    assert erlterm.parse(text) == {
        Atom("schema"): 1,
        Atom("kind"): Atom("reds"),
        Atom("otp"): b"29",
        Atom("os"): (Atom("unix"), Atom("darwin"), b"24.6.0"),
    }


def test_an_atom_and_a_binary_of_the_same_text_stay_apart() -> None:
    assert erlterm.parse("pass") != erlterm.parse('<<"pass">>')
    assert erlterm.parse("pass") == Atom("pass")
    assert erlterm.parse('<<"pass">>') == b"pass"


def test_a_binary_written_as_bytes_reads_as_the_same_binary() -> None:
    assert erlterm.parse("<<50,57>>") == erlterm.parse('<<"29">>')


def test_an_empty_binary_and_an_empty_map_and_an_empty_list() -> None:
    assert erlterm.parse("<<>>") == b""
    assert erlterm.parse("#{}") == {}
    assert erlterm.parse("[]") == []


def test_a_quoted_atom_keeps_the_text_and_not_the_quotes() -> None:
    assert erlterm.parse("'end'") == Atom("end")
    assert erlterm.parse("'Not an atom otherwise'") == Atom("Not an atom otherwise")


def test_numbers() -> None:
    assert erlterm.parse("[-1, 0, 42, 1.5, -2.25e3]") == [-1, 0, 42, 1.5, -2250.0]


def test_the_events_a_reduction_tape_holds() -> None:
    text = "{event,1,12,in,6,1,[{erlang,apply,2}]}."
    assert erlterm.parse(text) == (
        Atom("event"),
        1,
        12,
        Atom("in"),
        6,
        1,
        [(Atom("erlang"), Atom("apply"), 2)],
    )


def test_escapes_inside_a_binary() -> None:
    assert erlterm.parse('<<"one\\ntwo">>') == b"one\ntwo"
    assert erlterm.parse('<<"a \\"quote\\" in it">>') == b'a "quote" in it'


def test_an_improper_list_is_not_quietly_made_proper() -> None:
    assert erlterm.parse("[1,2|3]") == ("$improper", [1, 2], 3)


def test_a_string_is_a_list_of_character_codes() -> None:
    assert erlterm.parse('"AB"') == [65, 66]


@pytest.mark.parametrize(
    "text",
    [
        "#{a => 1",
        "{1, 2",
        "[1, 2",
        "#{a, 1}",
        "<<1,2",
        "1 2",
        "",
        "@",
    ],
)
def test_what_it_will_not_read(text: str) -> None:
    with pytest.raises(erlterm.TermError):
        erlterm.parse(text)
