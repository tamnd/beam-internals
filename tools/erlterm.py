"""Read an Erlang term written by `~0tp`, in Python.

Small on purpose. It reads what a bxtrace tape header holds, which is maps,
tuples, lists, binaries, atoms and numbers, and nothing else. Pids, references
and funs are not here because they cannot be on a tape in the first place.

The reason it exists is that `corpora/manifest.toml` says what an artefact is
and a tape says the same things about itself in its header. Checking one
against the other is what stops a manifest describing the file it used to
describe, and doing that check needs the header read on the Python side.

Atoms come back as `Atom`, a str subclass, so that the atom `pass` and the
binary `<<"pass">>` stay different things. Binaries come back as `bytes` for
the same reason.
"""

from __future__ import annotations

import re


class Atom(str):
    """An Erlang atom. A str so it compares and prints like one."""

    __slots__ = ()

    def __repr__(self) -> str:
        return f"Atom({str.__repr__(self)})"


class TermError(ValueError):
    """The text is not a term this reader understands."""


TOKENS = re.compile(
    r"""
      (?P<space>\s+)
    | (?P<float>-?\d+\.\d+(?:[eE][+-]?\d+)?)
    | (?P<int>-?\d+)
    | (?P<binopen><<)
    | (?P<binclose>>>)
    | (?P<arrow>=>)
    | (?P<string>"(?:[^"\\]|\\.)*")
    | (?P<quoted>'(?:[^'\\]|\\.)*')
    | (?P<atom>[a-z][a-zA-Z0-9_@]*)
    | (?P<mapopen>\#\{)
    | (?P<punct>[{}\[\],|])
    """,
    re.VERBOSE,
)

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "e": "\x1b", "s": " ", "0": "\0"}


def parse(text: str):
    """The one term in `text`, with a trailing full stop allowed."""
    stripped = text.strip()
    if stripped.endswith("."):
        stripped = stripped[:-1]
    tokens = tokenise(stripped)
    term, rest = read(tokens, 0)
    if rest != len(tokens):
        raise TermError(f"trailing text after the term, starting at token {tokens[rest]!r}")
    return term


def tokenise(text: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    at = 0
    while at < len(text):
        match = TOKENS.match(text, at)
        if match is None:
            raise TermError(f"cannot read {text[at : at + 20]!r}")
        at = match.end()
        kind = match.lastgroup
        assert kind is not None
        if kind != "space":
            tokens.append((kind, match.group()))
    return tokens


def read(tokens: list[tuple[str, str]], at: int):
    if at >= len(tokens):
        raise TermError("the term stops early")
    kind, text = tokens[at]

    if kind == "int":
        return int(text), at + 1
    if kind == "float":
        return float(text), at + 1
    if kind == "atom":
        return Atom(text), at + 1
    if kind == "quoted":
        return Atom(unescape(text[1:-1])), at + 1
    if kind == "string":
        # A quoted string is a list of character codes in Erlang, and that is
        # what it has to come back as. A tape writes text as a binary, so this
        # is rare, but a term that read a string as anything else would be a
        # reader that quietly changed the term.
        return [ord(c) for c in unescape(text[1:-1])], at + 1
    if kind == "mapopen":
        return read_map(tokens, at + 1)
    if kind == "binopen":
        return read_binary(tokens, at + 1)
    if kind == "punct" and text == "{":
        items, at = read_items(tokens, at + 1, "}")
        return tuple(items), at
    if kind == "punct" and text == "[":
        return read_list(tokens, at + 1)

    raise TermError(f"unexpected {text!r}")


def read_items(tokens: list[tuple[str, str]], at: int, closer: str):
    items: list = []
    if at < len(tokens) and tokens[at] == ("punct", closer):
        return items, at + 1
    while True:
        item, at = read(tokens, at)
        items.append(item)
        if at >= len(tokens):
            raise TermError(f"no closing {closer}")
        if tokens[at] == ("punct", ","):
            at += 1
            continue
        if tokens[at] == ("punct", closer):
            return items, at + 1
        raise TermError(f"expected , or {closer}, found {tokens[at][1]!r}")


def read_list(tokens: list[tuple[str, str]], at: int):
    items: list = []
    if at < len(tokens) and tokens[at] == ("punct", "]"):
        return items, at + 1
    while True:
        item, at = read(tokens, at)
        items.append(item)
        if at >= len(tokens):
            raise TermError("no closing ]")
        if tokens[at] == ("punct", ","):
            at += 1
            continue
        if tokens[at] == ("punct", "|"):
            # An improper list. Python has no such thing, so it comes back as
            # a tuple of the elements and the tail, tagged, rather than as a
            # list that silently lost its tail.
            tail, at = read(tokens, at + 1)
            if at >= len(tokens) or tokens[at] != ("punct", "]"):
                raise TermError("no closing ] after an improper tail")
            return ("$improper", items, tail), at + 1
        if tokens[at] == ("punct", "]"):
            return items, at + 1
        raise TermError(f"expected , or ] found {tokens[at][1]!r}")


def read_map(tokens: list[tuple[str, str]], at: int):
    out: dict = {}
    if at < len(tokens) and tokens[at] == ("punct", "}"):
        return out, at + 1
    while True:
        key, at = read(tokens, at)
        if at >= len(tokens) or tokens[at][0] != "arrow":
            raise TermError("a map key with no => after it")
        value, at = read(tokens, at + 1)
        out[key] = value
        if at >= len(tokens):
            raise TermError("no closing } on the map")
        if tokens[at] == ("punct", ","):
            at += 1
            continue
        if tokens[at] == ("punct", "}"):
            return out, at + 1
        raise TermError(f"expected , or }} found {tokens[at][1]!r}")


def read_binary(tokens: list[tuple[str, str]], at: int):
    if at < len(tokens) and tokens[at][0] == "binclose":
        return b"", at + 1
    if at < len(tokens) and tokens[at][0] == "string":
        text = unescape(tokens[at][1][1:-1])
        if at + 1 >= len(tokens) or tokens[at + 1][0] != "binclose":
            raise TermError("no closing >> on the binary")
        return text.encode("utf-8"), at + 2
    values: list[int] = []
    while True:
        if at >= len(tokens) or tokens[at][0] != "int":
            raise TermError("a binary holding something other than bytes")
        values.append(int(tokens[at][1]))
        at += 1
        if at < len(tokens) and tokens[at] == ("punct", ","):
            at += 1
            continue
        if at < len(tokens) and tokens[at][0] == "binclose":
            return bytes(values), at + 1
        raise TermError("no closing >> on the binary")


def unescape(text: str) -> str:
    out: list[str] = []
    at = 0
    while at < len(text):
        char = text[at]
        if char != "\\":
            out.append(char)
            at += 1
            continue
        at += 1
        if at >= len(text):
            raise TermError("a backslash at the end of a string")
        escape = text[at]
        if escape == "x":
            # \xHH and \x{HHHH}, the second being how anything above latin1 is
            # written when the writer was not told the output is unicode.
            if text[at + 1 : at + 2] == "{":
                close = text.index("}", at)
                out.append(chr(int(text[at + 2 : close], 16)))
                at = close + 1
            else:
                out.append(chr(int(text[at + 1 : at + 3], 16)))
                at += 3
            continue
        if escape.isdigit():
            digits = text[at : at + 3]
            out.append(chr(int(digits, 8)))
            at += len(digits)
            continue
        out.append(ESCAPES.get(escape, escape))
        at += 1
    return "".join(out)
