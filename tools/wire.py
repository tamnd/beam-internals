"""Read a wire tape and decode the distribution handshake on it.

The tape is bytes. It holds every read the relay made while two nodes got
connected, in both directions, and nothing on it has been interpreted. All of
the interpretation is here, which is the arrangement that lets this file be
wrong and be fixed without anybody having to record two nodes again.

Three things happen when a tape is read. The byte stream is reassembled per
direction, because a segment is one read and not one message. The five
handshake messages are framed off the front of each stream and decoded field by
field. Then both digests are recomputed from the cookie and the challenges that
are on the tape, and a tape whose digests do not recompute is refused.

That last part is what makes this a capture rather than a picture. A handshake
proves that both sides knew the cookie, and the proof is checkable here, on a
machine with no Erlang on it, six months after the recording.

Run: python3 -m tools.wire corpora/dist/handshake.tape.gz
     python3 -m tools.wire --bytes corpora/dist/handshake.tape.gz
"""

from __future__ import annotations

import gzip
import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path

from tools import erlterm


class Unreadable(ValueError):
    """The file is not a wire tape, or what is on it is not a handshake."""


# The distribution flags, from lib/kernel/include/dist.hrl@OTP-29.0.5. Both
# nodes send the set they are willing to support and the connection runs on
# what they agree, so the interesting column in the output is the overlap.
#
# The two marked "only used internally" in the header are left out, because a
# node never puts them on the wire and a reader who saw one would be looking at
# a decoding bug rather than at a flag.
FLAGS = {
    0x00000001: "published",
    0x00000002: "atom_cache",
    0x00000004: "extended_references",
    0x00000008: "dist_monitor",
    0x00000010: "fun_tags",
    0x00000020: "dist_monitor_name",
    0x00000040: "hidden_atom_cache",
    0x00000080: "new_fun_tags",
    0x00000100: "extended_pids_ports",
    0x00000200: "export_ptr_tag",
    0x00000400: "bit_binaries",
    0x00000800: "new_floats",
    0x00001000: "unicode_io",
    0x00002000: "dist_hdr_atom_cache",
    0x00004000: "small_atom_tags",
    0x00010000: "utf8_atoms",
    0x00020000: "map_tag",
    0x00040000: "big_creation",
    0x00080000: "send_sender",
    0x00100000: "big_seqtrace_labels",
    0x00400000: "exit_payload",
    0x00800000: "fragments",
    0x01000000: "handshake_23",
    0x02000000: "unlink_id",
    0x04000000: "mandatory_25_digest",
    0x0100000000: "spawn",
    0x0200000000: "name_me",
    0x0400000000: "v4_nc",
    0x0800000000: "alias",
    0x2000000000: "altact_sig",
    0x4000000000: "native_records",
}

# What the five messages are for, in the order they go past. The tag is the
# first byte of the message and it is the whole of the message type.
WHAT = {
    "send_name": "who I am and what I can do",
    "status": "whether you are welcome",
    "challenge": "who I am, what I can do, and a number to sign",
    "challenge_reply": "your number signed, and one of mine",
    "challenge_ack": "your number signed back",
}


@dataclass(frozen=True)
class Segment:
    index: int
    direction: str
    micros: int
    payload: bytes


@dataclass(frozen=True)
class Message:
    order: int
    direction: str
    tag: str
    kind: str
    size: int
    fields: dict


@dataclass(frozen=True)
class Frame:
    """One thing sent after the handshake, which is a different framing."""

    direction: str
    size: int
    what: str


@dataclass(frozen=True)
class Capture:
    header: dict
    segments: list[Segment]
    messages: list[Message]
    frames: list[Frame]

    @property
    def cookie(self) -> str:
        return text(self.header["cookie"])

    def named(self, tag: str) -> Message:
        return next(one for one in self.messages if one.kind == tag)


def text(value) -> str:
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


def read(path: Path) -> Capture:
    header = None
    segments: list[Segment] = []

    with gzip.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("%%"):
                continue
            term = erlterm.parse(stripped)
            if header is None:
                if not isinstance(term, dict):
                    raise Unreadable(f"{path}: the first term is not a header")
                header = term
                if text(header.get("kind")) != "wire":
                    raise Unreadable(f"{path}: this is a {text(header.get('kind'))} tape, not a wire tape")
                continue
            if isinstance(term, tuple) and term and term[0] == "segment":
                segments.append(Segment(term[1], text(term[2]), term[3], term[4]))

    if header is None:
        raise Unreadable(f"{path}: there is nothing in it")

    messages, frames = decode(segments, text(header["cookie"]))
    return Capture(header, segments, messages, frames)


def stream(segments: list[Segment], direction: str) -> bytes:
    """One direction of the conversation, put back together.

    A segment is one read off a socket, so a message can arrive split across two
    of them and two messages can arrive in one. The tape records the reads
    because that is what happened, and the framing is done here because that is
    where the protocol is known.
    """
    return b"".join(one.payload for one in segments if one.direction == direction)


def frames(data: bytes, width: int, limit: int | None = None) -> tuple[list[bytes], bytes]:
    """Length prefixed messages off the front of a stream.

    Two widths exist on one connection. The handshake is prefixed with two
    bytes and everything after it with four, which is the reason the count is
    passed in: the switch happens after a known number of messages rather than
    at a marker anybody can see in the bytes.
    """
    out: list[bytes] = []
    at = 0
    while at + width <= len(data) and (limit is None or len(out) < limit):
        size = int.from_bytes(data[at : at + width], "big")
        if at + width + size > len(data):
            break
        out.append(data[at + width : at + width + size])
        at += width + size
    return out, data[at:]


def decode(segments: list[Segment], cookie: str) -> tuple[list[Message], list[Frame]]:
    """The five handshake messages, then whatever came after them.

    The initiator sends two and the responder sends three, and that split is
    fixed by the protocol rather than worked out from the bytes. Both counts are
    asserted, so a tape holding a handshake that went some other way is refused
    here rather than decoded into something that reads plausibly.
    """
    out_going, rest_a = frames(stream(segments, "a_to_b"), 2, HANDSHAKE["a_to_b"])
    in_coming, rest_b = frames(stream(segments, "b_to_a"), 2, HANDSHAKE["b_to_a"])
    if len(out_going) != 2 or len(in_coming) != 3:
        raise Unreadable(
            f"a handshake is two messages out and three back, and this tape has "
            f"{len(out_going)} out and {len(in_coming)} back"
        )

    send_name, challenge_reply = out_going
    status, challenge, challenge_ack = in_coming

    messages = [
        message(1, "a_to_b", send_name, name_of(send_name)),
        message(2, "b_to_a", status, status_of(status)),
        message(3, "b_to_a", challenge, challenge_of(challenge)),
        message(4, "a_to_b", challenge_reply, reply_of(challenge_reply)),
        message(5, "b_to_a", challenge_ack, ack_of(challenge_ack)),
    ]
    check(messages, cookie)

    after = [Frame("a_to_b", len(one), classify(one)) for one in frames(rest_a, 4)[0]]
    after += [Frame("b_to_a", len(one), classify(one)) for one in frames(rest_b, 4)[0]]
    return messages, after


def message(order: int, direction: str, raw: bytes, decoded: tuple[str, dict]) -> Message:
    kind, fields = decoded
    return Message(order, direction, chr(raw[0]), kind, len(raw), fields)


def name_of(raw: bytes) -> tuple[str, dict]:
    """`N' from the initiator. Flags, creation, and a name with a length."""
    if raw[0:1] != b"N":
        raise Unreadable(f"the first message is {raw[0:1]!r} and a handshake starts with N")
    flags = int.from_bytes(raw[1:9], "big")
    creation = int.from_bytes(raw[9:13], "big")
    length = int.from_bytes(raw[13:15], "big")
    return "send_name", {
        "flags": flags,
        "creation": creation,
        "name": raw[15 : 15 + length].decode("utf-8"),
    }


def status_of(raw: bytes) -> tuple[str, dict]:
    """`s' and a word. `ok' is the ordinary answer and the rest are the
    interesting ones: `nok' and `not_allowed' are refusals, `alive' means the
    responder still thinks it has a connection to this node, and `named:' is
    how a node with no name of its own gets given one."""
    return "status", {"status": raw[1:].decode("utf-8")}


def challenge_of(raw: bytes) -> tuple[str, dict]:
    """`N' from the responder. The same as the initiator's, with a challenge
    wedged in front of the creation."""
    flags = int.from_bytes(raw[1:9], "big")
    challenge = int.from_bytes(raw[9:13], "big")
    creation = int.from_bytes(raw[13:17], "big")
    length = int.from_bytes(raw[17:19], "big")
    return "challenge", {
        "flags": flags,
        "challenge": challenge,
        "creation": creation,
        "name": raw[19 : 19 + length].decode("utf-8"),
    }


def reply_of(raw: bytes) -> tuple[str, dict]:
    return "challenge_reply", {
        "challenge": int.from_bytes(raw[1:5], "big"),
        "digest": raw[5:21],
    }


def ack_of(raw: bytes) -> tuple[str, dict]:
    return "challenge_ack", {"digest": raw[1:17]}


def digest(cookie: str, challenge: int) -> bytes:
    """md5 of the cookie followed by the challenge written out in decimal, from
    lib/kernel/src/dist_util.erl:546@OTP-29.0.5. Decimal rather than the four
    bytes that went past on the wire, which is the detail that makes this worth
    checking rather than assuming."""
    return hashlib.md5(cookie.encode() + str(challenge).encode()).digest()


def check(messages: list[Message], cookie: str) -> None:
    """Both digests, recomputed. This is the whole argument for the tape.

    Each side signs the number the other one sent, so the reply signs the
    challenge from message three and the ack signs the challenge from message
    four. Getting those two the wrong way round still produces sixteen bytes, so
    the test is worth having.
    """
    pairs = [
        ("challenge_reply", messages[2].fields["challenge"], messages[3].fields["digest"]),
        ("challenge_ack", messages[3].fields["challenge"], messages[4].fields["digest"]),
    ]
    for what, challenge, signed in pairs:
        if digest(cookie, challenge) != signed:
            raise Unreadable(
                f"the {what} on this tape does not sign challenge {challenge} with cookie "
                f"{cookie!r}, so it is not a recording of a handshake that worked"
            )


def classify(frame: bytes) -> str:
    """What a post handshake frame is, without decoding the term inside it.

    Only enough to say what kind of thing it is. A zero length frame is a tick,
    which is the keepalive, and the rest carry a term the emulator wrote. The
    second byte says how: 68 is a distribution header carrying the atom cache
    and 80 is the same thing compressed. Going further than this means an
    external term format decoder, and that belongs with the wire oracle rather
    than here.
    """
    if not frame:
        return "tick"
    if frame[0:1] != b"\x83":
        return f"something starting {frame[0]:#04x}"
    if len(frame) > 1 and frame[1] == 68:
        return "message, atom cache header"
    if len(frame) > 1 and frame[1] == 80:
        return "message, compressed"
    return "message"


def named_flags(flags: int) -> list[str]:
    return [name for bit, name in sorted(FLAGS.items()) if flags & bit]


def unknown_flags(flags: int) -> int:
    """Anything set that is not in the table above, which on a tape from a
    newer release is how you find out there is a new flag."""
    known = 0
    for bit in FLAGS:
        known |= bit
    return flags & ~known


def summary(capture: Capture) -> list[str]:
    header = capture.header
    return [
        f"{text(header['node_a'])} connecting to {text(header['node_b'])}",
        f"recorded {text(header['recorded'])} by {text(header['by_whom'])}",
        f"OTP {text(header['otp'])} erts {text(header['erts'])}, {text(header['arch'])}",
        (
            f"{header['segments']} reads, {header['bytes_a_to_b']} bytes out and "
            f"{header['bytes_b_to_a']} back, of which {header['handshake_bytes']} were the handshake"
        ),
    ]


# How many of the five each side sends. The initiator sends two and the
# responder sends three, and the split is the protocol rather than something
# counted off this tape.
HANDSHAKE = {"a_to_b": 2, "b_to_a": 3}


def arrow(direction: str) -> str:
    return "a -> b" if direction == "a_to_b" else "a <- b"


def transcript(capture: Capture) -> list[str]:
    lines = ["", "the handshake"]
    for one in capture.messages:
        lines.append("")
        lines.append(f"{one.order}. {arrow(one.direction)}  {one.kind}  {one.size} bytes, tag {one.tag}")
        lines.append(f"     {WHAT[one.kind]}")
        for key, value in one.fields.items():
            if key == "flags":
                lines.append(f"     flags       {value:#018x}, {len(named_flags(value))} of them")
            elif key == "digest":
                lines.append(f"     digest      {value.hex()}")
                lines.append("     recomputed  md5 of the cookie and the challenge, and it matches")
            else:
                lines.append(f"     {key.ljust(11)} {value}")
    return lines


def agreed(capture: Capture) -> list[str]:
    """What each side offered and what they have in common.

    The overlap is what the connection runs on, at
    lib/kernel/src/dist_util.erl:adjust_flags@OTP-29.0.5. A flag one side offers
    and the other does not is not an error, it is a feature that will not be
    used, and seeing which ones those are is most of what this view is for.
    """
    mine = capture.named("send_name").fields["flags"]
    theirs = capture.named("challenge").fields["flags"]
    lines = ["", "what the two sides offered", "", "flag                   a    b"]
    for bit, name in sorted(FLAGS.items()):
        a, b = "y" if mine & bit else ".", "y" if theirs & bit else "."
        if a == "y" or b == "y":
            lines.append(f"{name.ljust(20)}  {a}    {b}")
    lines.append("")
    lines.append(f"{bin(mine & theirs).count('1')} flags agreed by both sides")
    for bit, name in sorted(FLAGS.items()):
        if bool(mine & bit) != bool(theirs & bit):
            side = "only the connecting side" if mine & bit else "only the answering side"
            lines.append(f"{name} was offered by {side}, so the connection does without it")
    left = unknown_flags(mine | theirs)
    if left:
        lines.append(
            f"{left:#x} was offered and is not a flag this reader knows, which means a newer release"
        )
    return lines


def afterwards(capture: Capture) -> list[str]:
    """The framing changes the moment the handshake is done.

    Two bytes of length become four, and what follows is terms rather than
    fields. That switch is the line between this file and the wire oracle, so
    what is printed is a count and a shape and nothing more.

    Counted per direction rather than listed in order, because the tape records
    reads and one read can hold three frames. Which of two frames going opposite
    ways went first is not on the tape and is not worth pretending to know.
    """
    lines = ["", "after the handshake, where the length prefix becomes four bytes"]
    if not capture.frames:
        lines.append("  nothing, the connection closed")
        return lines
    for direction in ("a_to_b", "b_to_a"):
        mine = [one for one in capture.frames if one.direction == direction]
        if not mine:
            continue
        kinds = sorted({one.what for one in mine})
        lines.append(
            f"  {arrow(direction)}  {len(mine)} frames, {sum(one.size for one in mine)} bytes, "
            f"{' and '.join(kinds)}"
        )
    return lines


def render(capture: Capture) -> str:
    return "\n".join(summary(capture) + transcript(capture) + agreed(capture) + afterwards(capture))


def dump(capture: Capture) -> str:
    """Every handshake message as bytes, for reading against the transcript."""
    lines = []
    for one in capture.messages:
        raw = raw_of(capture, one)
        lines.append(f"{one.order}. {arrow(one.direction)}  {one.kind}")
        for at in range(0, len(raw), 16):
            row = raw[at : at + 16]
            shown = " ".join(f"{b:02x}" for b in row)
            printable = "".join(chr(b) if 32 <= b < 127 else "." for b in row)
            lines.append(f"     {at:04x}  {shown.ljust(47)}  {printable}")
        lines.append("")
    return "\n".join(lines)


def raw_of(capture: Capture, wanted: Message) -> bytes:
    """The bytes of one message, framed off its own direction again.

    The count matters. Framing three messages out of a stream that holds two of
    them takes a bite out of the post handshake traffic, which is a different
    framing, and produces a message that looks almost right.
    """
    direction = wanted.direction
    out = frames(stream(capture.segments, direction), 2, HANDSHAKE[direction])[0]
    same = [one for one in capture.messages if one.direction == direction]
    return out[same.index(wanted)]


def main(argv: list[str]) -> int:
    show = render
    if argv and argv[0] == "--bytes":
        show, argv = dump, argv[1:]
    if not argv:
        print("usage: python3 -m tools.wire [--bytes] corpora/dist/handshake.tape.gz")
        return 2
    for name in argv:
        try:
            print(show(read(Path(name))))
        except (OSError, Unreadable, erlterm.TermError) as problem:
            print(problem)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
