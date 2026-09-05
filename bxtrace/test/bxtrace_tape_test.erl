%% The tape format, checked from both ends.
%%
%% The cases that matter are the ones about a tape that is wrong rather than a
%% tape that is right. A round trip passing tells you the happy path works. A
%% truncated tape being caught tells you the format is worth committing files
%% in.
-module(bxtrace_tape_test).

-export([cases/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

cases() ->
    [
        {"a tape written and read back holds the same events", fun round_trip/0},
        {"the header records the build without being asked", fun header_knows_the_build/0},
        {"a header missing its schema is refused rather than guessed at", fun no_schema/0},
        {"a tape from a newer schema says so instead of being read wrong", fun from_the_future/0},
        {"a tape cut off partway through is an error, not a short read", fun truncated/0},
        {"a footer that disagrees with the events is an error", fun miscounted/0},
        {"an empty file is not a tape", fun empty/0},
        {"comments and blank lines are skipped", fun comments/0},
        {"a binary holding a newline survives the round trip", fun newline_in_a_binary/0},
        {"text on a tape is written as text and not as bytes", fun text_stays_text/0},
        {"one term is one line however long the term is", fun one_term_one_line/0},
        {"an atom needing quotes survives the round trip", fun awkward_atom/0},
        {"a deep term survives the round trip", fun deep_term/0},
        {"a pid may not go on a tape", fun no_pids/0},
        {"a reference may not go on a tape", fun no_references/0},
        {"a function may not go on a tape", fun no_functions/0},
        {"the report names where in the term the trouble is", fun where_the_trouble_is/0},
        {"an improper list is walked to its tail", fun improper_list/0},
        {"a map is walked through its keys as well as its values", fun map_keys/0},
        {"writing a pid crashes the recorder rather than the reader", fun writing_a_pid_crashes/0},
        {"folding sees every event in order", fun folding/0},
        {"describe reads a tape without drawing it", fun describing/0}
    ].

%% A tape somewhere nothing else will find it. The tests write real files
%% because the format is a file format, and a test that mocks the file system
%% checks the mock.
scratch(Name) ->
    Dir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
    filename:join(Dir, io_lib:format("bxtrace-test-~ts-~b.tape.gz", [Name, erlang:unique_integer([positive])])).

with_tape(Name, Events, Fun) ->
    Path = scratch(Name),
    {ok, Tape} = bxtrace_tape:open(Path, bxtrace_tape:header(test, "tamnd", "the tape format tests")),
    Closed = lists:foldl(fun(Event, Acc) -> bxtrace_tape:write(Acc, Event) end, Tape, Events),
    {ok, Path, _} = bxtrace_tape:close(Closed),
    try
        Fun(Path)
    after
        file:delete(Path)
    end.

round_trip() ->
    Events = [{in, 1, 4000}, {out, 1, 0, budget}, {in, 2, 4000}],
    with_tape("round-trip", Events, fun(Path) ->
        {ok, _Header, Read} = bxtrace_tape:read(Path),
        ?EQ("the events read back", Events, Read)
    end).

header_knows_the_build() ->
    with_tape("header", [{a, 1}], fun(Path) ->
        {ok, Header, _} = bxtrace_tape:read(Path),
        ?EQ("the schema", bxtrace_tape:schema(), maps:get(schema, Header)),
        ?EQ("the kind", test, maps:get(kind, Header)),
        ?EQ("the release", list_to_binary(erlang:system_info(otp_release)), maps:get(otp, Header)),
        ?EQ("the flavor", erlang:system_info(emu_flavor), maps:get(flavor, Header)),
        ?EQ("who recorded it", <<"tamnd">>, maps:get(by_whom, Header)),
        ct_assert:is_true("the word size is set", is_integer(maps:get(wordsize, Header)))
    end).

%% The next three write a file by hand, because there is no way to produce a
%% broken tape through the writer, which is the point of the writer.
handwritten(Name, Lines) ->
    Path = scratch(Name),
    {ok, Fd} = file:open(Path, [write, compressed, {encoding, utf8}]),
    [io:format(Fd, "~ts~n", [Line]) || Line <- Lines],
    ok = file:close(Fd),
    Path.

with_handwritten(Name, Lines, Fun) ->
    Path = handwritten(Name, Lines),
    try
        Fun(Path)
    after
        file:delete(Path)
    end.

no_schema() ->
    with_handwritten("no-schema", ["#{kind => test}.", "{a,1}.", "{'$tape_end',1}."], fun(Path) ->
        {error, {unknown_schema, _, missing}} = bxtrace_tape:read(Path),
        ok
    end).

from_the_future() ->
    Line = io_lib:format("#{schema => ~b, kind => test}.", [bxtrace_tape:schema() + 1]),
    with_handwritten("future", [Line, "{a,1}.", "{'$tape_end',1}."], fun(Path) ->
        {error, {tape_from_the_future, _, _, _}} = bxtrace_tape:read(Path),
        ok
    end).

truncated() ->
    Line = io_lib:format("#{schema => ~b, kind => test}.", [bxtrace_tape:schema()]),
    with_handwritten("truncated", [Line, "{a,1}.", "{a,2}."], fun(Path) ->
        {error, {tape_truncated, _, 2}} = bxtrace_tape:read(Path),
        ok
    end).

miscounted() ->
    Line = io_lib:format("#{schema => ~b, kind => test}.", [bxtrace_tape:schema()]),
    with_handwritten("miscounted", [Line, "{a,1}.", "{'$tape_end',9}."], fun(Path) ->
        {error, {tape_count_wrong, _, 9, 1}} = bxtrace_tape:read(Path),
        ok
    end).

empty() ->
    with_handwritten("empty", [], fun(Path) ->
        {error, {empty_tape, _}} = bxtrace_tape:read(Path),
        ok
    end).

comments() ->
    Line = io_lib:format("#{schema => ~b, kind => test}.", [bxtrace_tape:schema()]),
    Lines = ["%% written by hand", Line, "", "%% and a note halfway", "{a,1}.", "", "{'$tape_end',1}."],
    with_handwritten("comments", Lines, fun(Path) ->
        {ok, _, Events} = bxtrace_tape:read(Path),
        ?EQ("the events past the comments", [{a, 1}], Events)
    end).

%% The one that would break a naive line based format. A binary holding a
%% newline is written escaped rather than raw, so one term stays one line.
newline_in_a_binary() ->
    Event = {line, <<"first\nsecond">>},
    with_tape("newline", [Event], fun(Path) ->
        {ok, _, Events} = bxtrace_tape:read(Path),
        ?EQ("the binary with the newline in it", [Event], Events)
    end).

%% The claim the format makes is that a tape can be diffed and the diff read by
%% a person. A writer using ~w keeps that claim technically true and practically
%% false: the OTP release in every header comes out as <<50,57>> instead of
%% <<"29">>, parses back to the same binary, and tells a reader nothing. So the
%% check is on the bytes in the file rather than on what comes back out of it,
%% because the round trip passes either way.
lines(Path) ->
    {ok, Fd} = file:open(Path, [read, compressed, {encoding, utf8}]),
    try
        collect(Fd, [])
    after
        file:close(Fd)
    end.

collect(Fd, Done) ->
    case io:get_line(Fd, "") of
        eof -> lists:reverse(Done);
        Line -> collect(Fd, [string:trim(Line) | Done])
    end.

text_stays_text() ->
    with_tape("readable", [{note, <<"a spinner ran out of budget">>}], fun(Path) ->
        Joined = lists:flatten(lines(Path)),
        Found = string:find(Joined, "<<\"a spinner ran out of budget\">>"),
        ct_assert:is_true("the binary is written as the text it holds", Found =/= nomatch)
    end).

%% A term that would not fit in eighty columns still has to be one line, because
%% every reader of this format counts on being able to stop after one.
one_term_one_line() ->
    Long = {wide, lists:seq(1, 400), <<"and a binary on the end of it as well">>},
    with_tape("one-line", [Long], fun(Path) ->
        %% The comment, the header, the event, the footer.
        ?EQ("lines in the file", 4, length(lines(Path))),
        {ok, _, Events} = bxtrace_tape:read(Path),
        ?EQ("and it still reads back", [Long], Events)
    end).

awkward_atom() ->
    Event = {'an atom with spaces', 'Capitalised', '', 'ünïcode'},
    with_tape("atoms", [Event], fun(Path) ->
        {ok, _, Events} = bxtrace_tape:read(Path),
        ?EQ("the awkward atoms", [Event], Events)
    end).

deep_term() ->
    Event = {gc, #{before => [1, 2, [3, {4, 5}]], 'after' => #{words => 233, kind => minor}}, 3.5, <<0, 1, 255>>},
    with_tape("deep", [Event], fun(Path) ->
        {ok, _, Events} = bxtrace_tape:read(Path),
        ?EQ("the deep term", [Event], Events)
    end).

no_pids() ->
    {not_portable, pid, _} = bxtrace_tape:portable({in, self(), 4000}),
    ok.

no_references() ->
    {not_portable, reference, _} = bxtrace_tape:portable({tag, make_ref()}),
    ok.

no_functions() ->
    {not_portable, function, _} = bxtrace_tape:portable({run, fun() -> ok end}),
    ok.

where_the_trouble_is() ->
    {not_portable, pid, Where} = bxtrace_tape:portable({event, [ok, {nested, self()}]}),
    ?EQ("the path to the pid", [2, 2, 2], Where),
    Explained = bxtrace_tape:explain({not_portable, pid, Where}),
    ct_assert:is_true("the explanation names the kind", binary:match(Explained, <<"pid">>) =/= nomatch).

improper_list() ->
    {not_portable, pid, [1, tail]} = bxtrace_tape:portable({[a, b | self()]}),
    ok.

map_keys() ->
    {not_portable, reference, _} = bxtrace_tape:portable(#{make_ref() => ok}),
    ok.

%% The check is in the writer and not only in a helper somebody may forget to
%% call, so a recorder that tries to tape a pid dies at the line that tried.
writing_a_pid_crashes() ->
    Path = scratch("crash"),
    {ok, Tape} = bxtrace_tape:open(Path, bxtrace_tape:header(test, "tamnd", "the tape format tests")),
    try
        bxtrace_tape:write(Tape, {in, self()}),
        ct_assert:fail("writing a pid to a tape", it_was_accepted)
    catch
        error:{bxtrace_tape, Message} ->
            ct_assert:is_true("the crash carries the explanation", is_binary(Message))
    after
        file:close(maps:get(fd, Tape)),
        file:delete(Path)
    end.

folding() ->
    Events = [{n, N} || N <- lists:seq(1, 50)],
    with_tape("fold", Events, fun(Path) ->
        {ok, _, Sum} = bxtrace_tape:fold(Path, fun({n, N}, Acc) -> Acc + N end, 0),
        ?EQ("the sum of every event", 1275, Sum)
    end).

describing() ->
    with_tape("describe", [{in, 1}, {out, 1}, {in, 2}], fun(Path) ->
        ok = bxtrace_tape:describe(Path)
    end).
