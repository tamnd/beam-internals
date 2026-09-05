"""The filters, and the thing that matters more, what they must not erase.

Every filter here is a regular expression let loose on the output of a lesson,
which is the kind of tool that works for a year and then quietly eats the one
number a reader came for. So each filter gets two sets of tests. One says it
erases the noise it was written for. The other feeds it real output from the
lessons in this repository and insists that it changes nothing, because a heap
word count, a byte count and a reduction count are answers and a filter that
touches them has broken the lesson rather than fixed it.

The strings here are real. They were taken from `expected/` and from the output
of the cells the lessons run, rather than invented, because an invented example
is an example of what somebody expected the output to look like.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.normalise import FILTERS, Unknown, normalise

# Real output, from the recordings in this repository.
WIRE = """\
[1, 2, 3]      36 bytes  [131, 108, 0, 0, 0, 3, 97, 1, 97, 2, 97, 3, 106]
{1, 2, 3}      12 bytes  [131, 104, 3, 97, 1, 97, 2, 97, 3]
"""

SIZES = """\
42                        0 words
9999999999999999999999    4 words
a 64 byte binary          9 words
a 65 byte binary          6 words
"""

REDUCTIONS = """\
20000 small integer adds       20016 reductions        38 us
20000 4096 bit multiplies      24874 reductions    199413 us
"""


def test_a_pid_keeps_its_shape_and_loses_its_numbers() -> None:
    assert normalise("owner: #PID<0.213.0>\n", ["pids"]) == "owner: #PID<0.PID.0>\n"
    assert normalise("=proc:<0.213.0>\n", ["pids"]) == "=proc:<0.PID.0>\n"


def test_a_port_and_a_reference_go_the_same_way() -> None:
    assert normalise("port: #Port<0.7>", ["ports"]) == "port: #Port<0.PORT>"
    assert normalise("ref: #Reference<0.1.2.3>", ["refs"]) == "ref: #Reference<REF>"
    assert normalise("ref: #Ref<0.1.2.3>", ["refs"]) == "ref: #Ref<REF>"


def test_a_duration_loses_its_number_and_keeps_its_unit() -> None:
    """The unit stays because a cell that starts reporting milliseconds where it
    reported microseconds has changed, and that is worth being told about."""
    assert normalise("finished at 326 ms", ["times"]) == "finished at <TIME> ms"
    assert normalise("took 1.5 s", ["times"]) == "took <TIME> s"
    assert normalise("took 900 us", ["times"]) == "took <TIME> us"
    assert normalise("took 900 µs", ["times"]) == "took <TIME> µs"
    assert normalise("took 12 ns", ["times"]) == "took <TIME> ns"


def test_a_duration_takes_its_column_padding_with_it() -> None:
    """A cell that lines durations up in a column pads with spaces, so the width
    of the number leaks into the width of the padding. Erasing one without the
    other leaves the difference sitting in the whitespace."""
    padded = "adds         38 us\nmultiplies   199413 us\n"
    assert normalise(padded, ["times"]) == "adds <TIME> us\nmultiplies <TIME> us\n"


def test_a_time_filter_does_not_touch_a_count() -> None:
    """The one that would hurt. Every number in these two blocks is an answer."""
    assert normalise(REDUCTIONS, ["times"]).count("20016 reductions") == 1
    assert normalise(SIZES, ["times"]) == SIZES
    assert normalise(WIRE, ["times"]) == WIRE


def test_a_time_filter_does_not_eat_a_word_that_starts_with_its_unit() -> None:
    """`s` is a unit and it is also the first letter of a great many words, so a
    number in front of one of them is the obvious way for this to go wrong."""
    assert normalise("10 scheduler(s) online", ["times"]) == "10 scheduler(s) online"
    assert normalise("4 spinners", ["times"]) == "4 spinners"
    assert normalise("3 seconds", ["times"]) == "3 seconds"
    assert normalise("36 bytes", ["times"]) == "36 bytes"


def test_a_path_goes_and_a_citation_stays() -> None:
    """Every citation in this repository is a path relative to the root of the
    OTP tree, so a filter that ate relative paths would eat the citations."""
    assert normalise("code: /usr/local/lib/erlang", ["paths"]) == "code: <PATH>"
    cited = "at erts/emulator/beam/erl_process.c:15010"
    assert normalise(cited, ["paths"]) == cited
    assert normalise("and/or", ["paths"]) == "and/or"


def test_a_node_name_keeps_the_half_somebody_chose() -> None:
    assert normalise("node: probe@some-laptop.local", ["nodes"]) == "node: probe@HOST"


def test_a_long_hex_number_goes_and_a_byte_value_stays() -> None:
    assert normalise("at 0x7fb4c0a01000", ["addresses"]) == "at 0xADDR"
    assert normalise("tag 0x83", ["addresses"]) == "tag 0x83"


def test_the_build_line_keeps_the_release_and_the_erts_version() -> None:
    """The line is the emulator saying what it is, and most of it is what this
    particular machine happens to be. The release and the erts version are the
    part the lessons are pinned to, so they are the part that survives."""
    banner = (
        "Erlang/OTP 29 [erts-17.0.5] [source] [64-bit] [smp:10:10] "
        "[ds:10:10:10] [async-threads:1] [jit] [dtrace]\n"
    )
    assert normalise(banner, ["build-flags"]) == "Erlang/OTP 29 [erts-17.0.5] [...]\n"


def test_the_build_line_filter_notices_a_different_release() -> None:
    """The whole reason for keeping the front of the line."""
    old = "Erlang/OTP 28 [erts-16.0.2] [source] [64-bit] [smp:8:8]\n"
    assert normalise(old, ["build-flags"]) == "Erlang/OTP 28 [erts-16.0.2] [...]\n"


def test_a_scheduler_count_goes_in_both_shapes_it_is_printed_in() -> None:
    assert normalise("10 scheduler(s) online", ["schedulers"]) == "<N> scheduler(s) online"
    assert normalise("schedulers online  10", ["schedulers"]) == "schedulers online  <N>"


def test_filters_run_in_the_order_they_are_named() -> None:
    text = "Erlang/OTP 29 [erts-17.0.5] [smp:10:10]\nschedulers online  10\n"
    both = normalise(text, ["build-flags", "schedulers"])
    assert both == "Erlang/OTP 29 [erts-17.0.5] [...]\nschedulers online  <N>\n"


def test_naming_no_filters_changes_nothing() -> None:
    assert normalise(REDUCTIONS, []) == REDUCTIONS


def test_a_filter_that_does_not_exist_says_which_ones_do() -> None:
    with pytest.raises(Unknown, match="no such filter: timings"):
        normalise("anything", ["timings"])


def test_every_filter_leaves_the_mark_it_claims_to_leave() -> None:
    """A checker asks whether a filter fired by looking for its mark, so a filter
    whose mark is not what it actually writes would report every cell as one the
    filter did nothing to."""
    samples = {
        "pids": "#PID<0.213.0>",
        "ports": "#Port<0.7>",
        "refs": "#Reference<0.1.2.3>",
        "times": "326 ms",
        "paths": "/usr/local/lib/erlang",
        "nodes": "probe@some-laptop.local",
        "addresses": "0x7fb4c0a01000",
        "build-flags": "Erlang/OTP 29 [erts-17.0.5] [source] [64-bit]",
        "schedulers": "10 scheduler(s) online",
    }
    assert sorted(samples) == sorted(FILTERS), "a filter with no sample here is a filter nobody tested"
    for name, sample in samples.items():
        assert FILTERS[name].mark in normalise(sample, [name]), name


def test_no_filter_bites_a_recording_it_was_not_asked_to() -> None:
    """Every filter against every recording in the repository, which is the only
    version of this that can catch a filter somebody widened last week.

    Two of these are expected and they are the reason the filters are named per
    cell rather than run over everything. `m55` builds a pid and a reference for
    the node `a@b` out of binary literals and prints what it decoded, so the
    `nodes` filter would erase the answer to the question the lesson is asking.
    That lesson does not name the filter, and this is the test that says what
    would happen if it did.
    """
    known = {
        ("lessons/12-dist/m55/expected/handmade.txt", "nodes"),
        ("lessons/12-dist/m55/expected/options.txt", "nodes"),
    }
    found = set()
    recordings = sorted(Path("lessons").rglob("expected/*.txt"))
    assert recordings, "no recordings, which means this test is checking nothing"
    for recording in recordings:
        text = recording.read_text()
        for name, one in FILTERS.items():
            if one.apply(text) != text:
                found.add((recording.as_posix(), name))

    assert found == known


def test_every_filter_is_stable_when_run_twice() -> None:
    """Filters get named together and a recording gets normalised more than once
    on its way through the baker, so a filter that eats its own output would turn
    a recording into something that never settles."""
    text = (
        "Erlang/OTP 29 [erts-17.0.5] [smp:10:10]\n"
        "owner #PID<0.213.0> on probe@some-laptop.local at /usr/local/lib/erlang\n"
        "ref #Reference<0.1.2.3> port #Port<0.7> at 0x7fb4c0a01000\n"
        "10 scheduler(s) online, finished at 326 ms\n"
    )
    names = sorted(FILTERS)
    once = normalise(text, names)
    assert normalise(once, names) == once
