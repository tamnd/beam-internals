"""The wire tape reader.

Two halves, the same shape as the other tape readers. The first builds a
handshake byte by byte, which is the only way to test that a bad one is
refused: a real recorder cannot be asked to produce a handshake with a wrong
digest in it. The second reads the two real tapes, because the pair is the
whole point of having recorded two.
"""

from __future__ import annotations

import gzip
import hashlib
from pathlib import Path

import pytest

from tools import wire

COOKIE = "bxwire"
NODE_A = "a@127.0.0.1"
NODE_B = "b@127.0.0.1"

# Enough flags to be recognisable, and one bit that is not a flag at all, so
# that the reader's handling of a release it does not know about is exercised.
FLAGS = 0x0000006D07DF7FBD


def framed(payload: bytes) -> bytes:
    return len(payload).to_bytes(2, "big") + payload


def send_name(flags: int = FLAGS, creation: int = 1000, name: str = NODE_A) -> bytes:
    text = name.encode()
    return b"N" + flags.to_bytes(8, "big") + creation.to_bytes(4, "big") + len(text).to_bytes(2, "big") + text


def challenge(number: int, flags: int = FLAGS, creation: int = 2000, name: str = NODE_B) -> bytes:
    text = name.encode()
    return (
        b"N"
        + flags.to_bytes(8, "big")
        + number.to_bytes(4, "big")
        + creation.to_bytes(4, "big")
        + len(text).to_bytes(2, "big")
        + text
    )


def signed(number: int, cookie: str = COOKIE) -> bytes:
    return hashlib.md5(cookie.encode() + str(number).encode()).digest()


HEADER = (
    '#{schema => 1, kind => wire, otp => <<"29">>, erts => <<"17.0.5">>, '
    'arch => <<"aarch64-apple-darwin24.6.0">>, flavor => jit, build => opt, '
    'by_whom => <<"tamnd">>, recorded => <<"2026-09-06T09:00:00Z">>, '
    'node_a => <<"a@127.0.0.1">>, node_b => <<"b@127.0.0.1">>, '
    'cookie => <<"bxwire">>, hidden => false, segments => 5, '
    "bytes_a_to_b => 0, bytes_b_to_a => 0, handshake_bytes => 0}."
)


def erlang_binary(payload: bytes) -> str:
    return "<<" + ",".join(str(b) for b in payload) + ">>"


def tape(tmp_path: Path, segments: list[tuple[str, bytes]], name: str = "wire.tape.gz") -> Path:
    path = tmp_path / name
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        handle.write("%% bxtrace tape, schema 1, kind wire\n")
        handle.write(HEADER + "\n")
        for index, (direction, payload) in enumerate(segments, start=1):
            handle.write(f"{{segment,{index},{direction},{index * 10},{erlang_binary(payload)}}}.\n")
        handle.write(f"{{'$tape_end',{len(segments)}}}.\n")
    return path


def handshake(
    from_b: int = 111111,
    from_a: int = 222222,
    reply_digest: bytes | None = None,
    ack_digest: bytes | None = None,
    trailing: bytes = b"",
) -> list[tuple[str, bytes]]:
    """The five messages, split across reads the way a real one arrives.

    The last read deliberately carries the ack and whatever came after it in one
    piece, because that is what happens on a real connection and it is the case
    a reader that framed segments rather than streams would get wrong.
    """
    reply = b"r" + from_a.to_bytes(4, "big") + (reply_digest or signed(from_b))
    ack = b"a" + (ack_digest or signed(from_a))
    return [
        ("a_to_b", framed(send_name())),
        ("b_to_a", framed(b"sok")),
        ("b_to_a", framed(challenge(from_b))),
        ("a_to_b", framed(reply)),
        ("b_to_a", framed(ack) + trailing),
    ]


@pytest.fixture
def made(tmp_path: Path) -> wire.Capture:
    return wire.read(tape(tmp_path, handshake()))


def test_the_five_messages_come_off_in_the_order_they_went_past(made: wire.Capture) -> None:
    assert [one.kind for one in made.messages] == [
        "send_name",
        "status",
        "challenge",
        "challenge_reply",
        "challenge_ack",
    ]
    assert [one.tag for one in made.messages] == ["N", "s", "N", "r", "a"]
    assert [one.direction for one in made.messages] == [
        "a_to_b",
        "b_to_a",
        "b_to_a",
        "a_to_b",
        "b_to_a",
    ]


def test_each_message_is_pulled_apart_into_its_fields(made: wire.Capture) -> None:
    assert made.named("send_name").fields["name"] == NODE_A
    assert made.named("send_name").fields["creation"] == 1000
    assert made.named("status").fields["status"] == "ok"
    assert made.named("challenge").fields["name"] == NODE_B
    assert made.named("challenge").fields["challenge"] == 111111
    assert made.named("challenge_reply").fields["challenge"] == 222222


def test_a_message_split_across_two_reads_is_still_one_message(tmp_path: Path) -> None:
    """TCP is a stream and a segment is one read. Cutting the challenge in half
    between two segments changes nothing about what was sent, so it has to
    change nothing about what is decoded."""
    whole = handshake()
    third = whole[2][1]
    split = [*whole[:2], ("b_to_a", third[:9]), ("b_to_a", third[9:]), *whole[3:]]
    capture = wire.read(tape(tmp_path, split))
    assert capture.named("challenge").fields["challenge"] == 111111
    assert len(capture.messages) == 5


def test_bytes_arriving_after_the_ack_in_the_same_read_are_not_the_handshake(tmp_path: Path) -> None:
    """The case that made the framing belong to the reader. The last handshake
    message and the first frame after it arrive together, so a reader that took
    a segment for a message would read the tail of one as the head of another."""
    after = (0).to_bytes(4, "big") + (2).to_bytes(4, "big") + b"\x83\x44"
    capture = wire.read(tape(tmp_path, handshake(trailing=after)))
    assert len(capture.messages) == 5
    assert [one.what for one in capture.frames] == ["tick", "message, atom cache header"]


def test_a_digest_that_does_not_recompute_is_refused(tmp_path: Path) -> None:
    """The check the whole tape exists for. Sixteen bytes that are not md5 of
    the cookie and the challenge are sixteen bytes of something else, and a
    reader that showed them as a digest would be showing a handshake that never
    happened."""
    path = tape(tmp_path, handshake(reply_digest=b"\x00" * 16))
    with pytest.raises(wire.Unreadable, match="does not sign challenge 111111"):
        wire.read(path)


def test_signing_the_wrong_challenge_is_refused(tmp_path: Path) -> None:
    """Each side signs the number the other one sent. Signing your own produces
    a digest of the right length that recomputes against the wrong number, which
    is the mistake a decoder actually makes."""
    path = tape(tmp_path, handshake(reply_digest=signed(222222)))
    with pytest.raises(wire.Unreadable, match="challenge_reply"):
        wire.read(path)


def test_a_handshake_that_did_not_finish_is_refused(tmp_path: Path) -> None:
    path = tape(tmp_path, handshake()[:3])
    with pytest.raises(wire.Unreadable, match="two messages out and three back"):
        wire.read(path)


def test_a_tape_of_the_wrong_kind_says_which_kind_it_is(tmp_path: Path) -> None:
    path = tmp_path / "wrong.tape.gz"
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        handle.write(HEADER.replace("kind => wire", "kind => dis") + "\n")
    with pytest.raises(wire.Unreadable, match="this is a dis tape"):
        wire.read(path)


def test_an_empty_file_is_reported_rather_than_read_as_nothing(tmp_path: Path) -> None:
    path = tmp_path / "empty.tape.gz"
    with gzip.open(path, "wt", encoding="utf-8") as handle:
        handle.write("%% bxtrace tape, schema 1, kind wire\n")
    with pytest.raises(wire.Unreadable, match="there is nothing in it"):
        wire.read(path)


def test_a_flag_this_reader_has_never_heard_of_is_reported(tmp_path: Path) -> None:
    """What a tape from a future release looks like. The bit is not decoded and
    saying so is better than dropping it, because the whole reason to keep the
    bytes is that the reader will one day be out of date."""
    newer = FLAGS | (1 << 60)
    segments = handshake()
    segments[0] = ("a_to_b", framed(send_name(flags=newer)))
    out = wire.agreed(wire.read(tape(tmp_path, segments)))
    assert any("is not a flag this reader knows" in line for line in out)


def test_the_hexdump_shows_each_handshake_message(made: wire.Capture) -> None:
    """The point of a hexdump is that the parts of a message that are text can
    be read straight out of the right hand column, so that is what is checked.
    The node name starts at offset 15 and runs over the end of the first row,
    which is what a hexdump of a protocol with a length prefix looks like."""
    out = wire.dump(made)
    assert "1. a -> b  send_name" in out
    assert "5. a <- b  challenge_ack" in out
    assert "0000  4e 00 00 00 6d 07 df 7f bd" in out
    assert "@127.0.0.1" in out


# ---------------------------------------------------------------------------
# The real pair

ORDINARY = Path("corpora/dist/handshake.tape.gz")
HIDDEN = Path("corpora/dist/handshake-hidden.tape.gz")


@pytest.fixture
def pair() -> list[wire.Capture]:
    if not ORDINARY.is_file() or not HIDDEN.is_file():
        pytest.skip("the recorded pair is not here")
    return [wire.read(ORDINARY), wire.read(HIDDEN)]


def test_both_tapes_are_handshakes_that_worked(pair: list[wire.Capture]) -> None:
    """Reading them at all is the assertion. wire.read recomputes both digests
    and refuses a tape whose digests do not match, so a pair that reads is a
    pair of recordings of real handshakes between nodes that knew the cookie."""
    for one in pair:
        assert one.messages[0].kind == "send_name"
        assert one.named("status").fields["status"] == "ok"


def test_a_handshake_is_a_hundred_and_thirty_three_bytes(pair: list[wire.Capture]) -> None:
    """Fixed width fields and two node names of 24 characters, so this is a
    constant rather than a measurement. It is the same on both tapes because
    being hidden changes a flag and not a length."""
    for one in pair:
        assert one.header["handshake_bytes"] == 133
        assert sum(message.size + 2 for message in one.messages) == 133


def test_the_names_on_the_wire_are_the_names_in_the_header(pair: list[wire.Capture]) -> None:
    for one in pair:
        assert one.named("send_name").fields["name"] == wire.text(one.header["node_a"])
        assert one.named("challenge").fields["name"] == wire.text(one.header["node_b"])


def test_the_two_sides_of_one_release_offer_the_same_flags(pair: list[wire.Capture]) -> None:
    ordinary = pair[0]
    assert ordinary.named("send_name").fields["flags"] == ordinary.named("challenge").fields["flags"]
    assert wire.unknown_flags(ordinary.named("send_name").fields["flags"]) == 0


def test_being_hidden_is_one_flag(pair: list[wire.Capture]) -> None:
    """The finding, and the reason a second tape was recorded. Everything about
    the two handshakes is the same except one bit."""
    ordinary, hidden = (one.named("send_name").fields["flags"] for one in pair)
    assert ordinary ^ hidden == 0x01
    assert "published" in wire.named_flags(ordinary)
    assert "published" not in wire.named_flags(hidden)


def test_that_one_flag_is_the_difference_between_a_connection_and_a_conversation(
    pair: list[wire.Capture],
) -> None:
    """A hidden node connects and says nothing else. An ordinary one immediately
    starts the global name server talking to its opposite number, which is most
    of the bytes on the ordinary tape and none of the bytes on the hidden one."""
    ordinary, hidden = pair
    assert hidden.frames == []
    assert sum(one.size for one in ordinary.frames) > 10 * 133


def test_the_render_runs_over_both_tapes(pair: list[wire.Capture]) -> None:
    for one in pair:
        out = wire.render(one)
        assert "recomputed  md5 of the cookie and the challenge, and it matches" in out
        assert "what the two sides offered" in out
