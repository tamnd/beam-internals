%% The postmortem tape recorder, checked against a dump this suite makes.
%%
%% A recorder for crash dumps is easy to test badly, by writing a small file
%% that looks like a dump and checking the parser agrees with the file. That
%% proves the two match each other and nothing about crash dumps. So the
%% specimen here is a real one, written by a real node halting, and the fixtures
%% are only used for the cases a real node will not produce on demand: a dump
%% cut off halfway, and a file that is not a dump at all.
-module(bxtrace_post_test).

-export([cases/0]).
%% The specimen suite records postmortem tapes too, so it shares the gate below
%% rather than keeping a second copy of it.
-export([needs_a_digest/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

%% What the specimen node is told to say on the way out.
-define(SLOGAN, "a deliberate halt, for the postmortem tape tests").

cases() ->
    [
        {"a recording reads back as a tape", fun reads_back/0},
        {"the header says what the dump was", fun header/0},
        {"the tape carries what the dump says about itself", fun the_dump_speaks/0},
        {"every section in the dump is on the tape", fun every_section/0},
        {"every section tag in a stock dump is one we know", fun every_tag_is_known/0},
        {"every row belongs to a section the tape introduced", fun rows_belong/0},
        {"a fact section loses none of its lines", fun nothing_is_dropped/0},
        {"a line that is not a fact is kept as a line", fun lines_survive/0},
        {"the heaps are summarised rather than copied", fun heaps_are_summarised/0},
        {"two different blobs get two different digests", fun digests_differ/0},
        {"every process on the tape has a state", fun process_states/0},
        {"a dump cut off halfway is read, and the tape says so", fun truncated/0},
        {"a file that is not a dump is refused", fun not_a_dump/0},
        {"nothing on the tape is a live term", fun no_live_terms/0}
    ].

%% ---------------------------------------------------------------------------
%% The specimen
%%
%% Halting a node writes a crash dump, and halting this one would take the test
%% run with it, so the dump comes from a child. That costs about a second and a
%% half, which is why it is made once and kept. The erts version is in the name,
%% so a specimen left behind by a different release is never picked up by
%% mistake.

scratch() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Set -> Set
    end.

specimen() ->
    Path = filename:join(scratch(), "bxtrace-post-" ++ erlang:system_info(version) ++ ".dump"),
    case filelib:is_regular(Path) of
        true -> Path;
        false -> write_specimen(Path)
    end.

write_specimen(Path) ->
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Command = lists:flatten(
        io_lib:format(
            "ERL_CRASH_DUMP='~ts' '~ts' -noshell -eval 'erlang:halt(\"~ts\")' 2>&1",
            [Path, Erl, ?SLOGAN]
        )
    ),
    Said = os:cmd(Command),
    case filelib:is_regular(Path) of
        true -> Path;
        false -> ct_assert:fail("the child node writes a crash dump", {nothing_at, Path, Said})
    end.

%% ---------------------------------------------------------------------------
%% Recording

tape_path(Name) ->
    filename:join(scratch(), io_lib:format("bxtrace-post-~ts-~b.tape.gz", [Name, erlang:unique_integer([positive])])).

%% Every case that records a tape goes through here, so this is the one place
%% the digest has to be available. A build configured `--without-ssl' has no
%% crypto and the recorder refuses on it, which is correct behaviour and not
%% something to fail the suite over, so it is reported as a skip with the reason
%% and counted in the summary. The interpreter build the disassembly tapes come
%% from is exactly such a build, so this is met in practice rather than in
%% theory.
%% The recorder's own refusal is reused rather than restated, so there is one
%% description of what is missing and the skip reason cannot drift away from the
%% error a person recording by hand would see.
needs_a_digest() ->
    try bxtrace_post:digest_check() of
        ok -> ok
    catch
        error:{bxtrace_post, Why} -> ct_assert:skip(Why)
    end.

record(Name, Dump, Fun) ->
    ok = needs_a_digest(),
    Path = tape_path(Name),
    {ok, Result} = bxtrace_post:record(Path, #{
        by_whom => "tamnd", why => "the postmortem tape tests", dump => Dump
    }),
    {ok, Header, Rows} = bxtrace_tape:read(Path),
    try
        Fun(Header, Rows, Result)
    after
        file:delete(Path)
    end.

with_specimen(Name, Fun) -> record(Name, specimen(), Fun).

sections(Rows) -> [R || R <- Rows, element(1, R) =:= section].
facts(Rows) -> [R || R <- Rows, element(1, R) =:= fact].
lines(Rows) -> [R || R <- Rows, element(1, R) =:= line].
blobs(Rows) -> [R || R <- Rows, element(1, R) =:= blob].

%% Every section of one kind, as {At, Id, Lines}.
of_kind(Rows, Wanted) ->
    [{At, Id, Lines} || {section, At, Kind, Id, _, Lines} <- sections(Rows), Kind =:= Wanted].

%% ---------------------------------------------------------------------------
%% Cases

reads_back() ->
    with_specimen("reads-back", fun(_Header, Rows, Result) ->
        ct_assert:is_true("there are sections", sections(Rows) =/= []),
        ct_assert:is_true("there are facts", facts(Rows) =/= []),
        ct_assert:is_true("there are blobs", blobs(Rows) =/= []),
        ?EQ("the section count agrees with the recorder", length(sections(Rows)), maps:get(sections, Result))
    end).

header() ->
    with_specimen("header", fun(Header, Rows, _Result) ->
        ?EQ("the kind", postmortem, maps:get(kind, Header)),
        ?EQ("the sections", length(sections(Rows)), maps:get(sections, Header)),
        ?EQ("the dump was written all the way to the end", true, maps:get(complete, Header)),
        ct_assert:is_true("the dump's size is recorded", maps:get(dump_bytes, Header) > 0),
        Kinds = maps:get(kinds, Header),
        ?EQ("the count per kind agrees with the rows", length(of_kind(Rows, proc)), maps:get(proc, Kinds))
    end).

%% The header describes the machine that read the dump, and `dumped' describes
%% the node that wrote it. Keeping them apart is the point: a dump copied off a
%% different machine is the normal case, not the odd one.
the_dump_speaks() ->
    with_specimen("dumped", fun(Header, _Rows, Result) ->
        Dumped = maps:get(dumped, Header),
        ?EQ("the slogan is what the node was told to say", list_to_binary(?SLOGAN), maps:get(slogan, Dumped)),
        ?EQ("and the recorder returns the same one", list_to_binary(?SLOGAN), maps:get(slogan, Result)),
        ?EQ("the dump format version", <<"0.5">>, maps:get(version, Dumped)),
        ct_assert:is_true("the system version is there", is_binary(maps:get(<<"System version">>, Dumped))),
        ct_assert:is_true("so is the atom count", is_binary(maps:get(<<"Atoms">>, Dumped))),
        ct_assert:is_true("and the time it was written", maps:get(written, Dumped) =/= unknown)
    end).

every_section() ->
    Dump = specimen(),
    {ok, Raw} = file:read_file(Dump),
    Starts = length([L || L <- binary:split(Raw, <<"\n">>, [global]), is_start(L)]),
    with_specimen("sections", fun(_Header, Rows, _Result) ->
        ?EQ("one row per section header line in the file", Starts, length(sections(Rows))),
        Ats = [At || {section, At, _, _, _, _} <- sections(Rows)],
        ?EQ("numbered from one without a gap", lists:seq(1, Starts), Ats)
    end).

is_start(<<$=, _/binary>>) -> true;
is_start(_) -> false.

%% The version bump guard. The tag list comes from crashdump_viewer and a
%% release that adds a section would leave this recorder writing binaries where
%% it writes atoms everywhere else. That is not a crash, which is why it needs a
%% test rather than looking after itself.
every_tag_is_known() ->
    with_specimen("tags", fun(Header, _Rows, _Result) ->
        ?EQ("tags the recorder did not recognise", [], maps:get(unknown_kinds, Header))
    end).

rows_belong() ->
    with_specimen("belong", fun(_Header, Rows, _Result) ->
        Known = [At || {section, At, _, _, _, _} <- sections(Rows)],
        Used = lists:usort(
            [At || {fact, At, _, _} <- facts(Rows)] ++
                [At || {line, At, _, _} <- lines(Rows)] ++
                [At || {blob, At, _, _, _} <- blobs(Rows)]
        ),
        ?EQ("sections referred to but never introduced", [], Used -- Known)
    end).

%% The claim that a fact section keeps everything. A line that does not parse as
%% a fact becomes a line rather than disappearing, so the two together have to
%% account for the section exactly.
nothing_is_dropped() ->
    with_specimen("kept", fun(_Header, Rows, _Result) ->
        Blobs = [At || {blob, At, _, _, _} <- blobs(Rows)],
        Counted = count_by(
            [At || {fact, At, _, _} <- facts(Rows)] ++ [At || {line, At, _, _} <- lines(Rows)]
        ),
        Short = [
            {At, Kind, Lines, maps:get(At, Counted, 0)}
         || {section, At, Kind, _, _, Lines} <- sections(Rows),
            not lists:member(At, Blobs),
            maps:get(At, Counted, 0) =/= Lines
        ],
        ?EQ("fact sections whose rows do not account for their lines", [], Short)
    end).

count_by(Ats) ->
    lists:foldl(fun(At, Acc) -> maps:update_with(At, fun(N) -> N + 1 end, 1, Acc) end, #{}, Ats).

%% Three lines in a stock dump are not facts, and all three are worth keeping.
%% The first is the date, which is on its own line under the header with no key
%% in front of it.
lines_survive() ->
    with_specimen("lines", fun(_Header, Rows, _Result) ->
        Kept = lines(Rows),
        ct_assert:is_true("some lines were kept as lines", Kept =/= []),
        [{section, First, erl_crash_dump, _, _, _} | _] = sections(Rows),
        Header = [Text || {line, At, _, Text} <- Kept, At =:= First],
        ?EQ("the header section keeps exactly one, the date", 1, length(Header)),
        Arity = [Text || {line, _, _, Text} <- Kept, Text =:= <<"arity = 0">>],
        ct_assert:is_true("and a program counter keeps its arity line", Arity =/= [])
    end).

heaps_are_summarised() ->
    with_specimen("heaps", fun(_Header, Rows, _Result) ->
        Heaps = of_kind(Rows, proc_heap),
        ct_assert:is_true("the dump has process heaps", Heaps =/= []),
        Summarised = [At || {At, _, _} <- Heaps],
        Facts = [At || {fact, At, _, _} <- facts(Rows), lists:member(At, Summarised)],
        ?EQ("no heap was read as facts", [], Facts),
        Blobs = [{At, Count} || {blob, At, Count, _, _} <- blobs(Rows), lists:member(At, Summarised)],
        ?EQ("every heap has exactly one blob row", length(Heaps), length(Blobs)),
        Mismatched = [
            At
         || {At, _, Lines} <- Heaps, {A, Count} <- Blobs, A =:= At, Count =/= Lines
        ],
        ?EQ("blob line counts that disagree with the section", [], Mismatched)
    end).

%% The digest is the reason a blob row is worth writing down at all. Two heaps
%% of the same size are common and two heaps with the same contents are not, so
%% a tape whose blob rows all looked alike would say the wrong thing.
digests_differ() ->
    with_specimen("digests", fun(_Header, Rows, _Result) ->
        Digests = [Digest || {blob, _, Lines, _, Digest} <- blobs(Rows), Lines > 1],
        ct_assert:is_true("there is more than one blob with contents", length(Digests) > 1),
        ct_assert:is_true("they are not all the same", length(lists:usort(Digests)) > 1),
        ?EQ("and each is a sha256 in hex", [64], lists:usort([byte_size(D) || D <- Digests]))
    end).

process_states() ->
    with_specimen("processes", fun(_Header, Rows, _Result) ->
        Procs = [At || {At, _, _} <- of_kind(Rows, proc)],
        ct_assert:is_true("the dump has processes", Procs =/= []),
        States = [At || {fact, At, <<"State">>, _} <- facts(Rows), lists:member(At, Procs)],
        ?EQ("processes without a state", [], Procs -- States)
    end).

%% Most real crash dumps are truncated, because the thing that killed the node
%% often gets around to killing the write as well. A recorder that refused them
%% would refuse the dumps people actually turn up with.
truncated() ->
    Cut = cut(specimen(), 20000),
    try
        record("truncated", Cut, fun(Header, Rows, Result) ->
            ?EQ("the tape says the dump is short", false, maps:get(complete, Header)),
            ?EQ("and so does the recorder", false, maps:get(complete, Result)),
            ct_assert:is_true("and it still read the sections it had", sections(Rows) =/= []),
            ct_assert:is_true("including the slogan", maps:get(slogan, Result) =/= unknown)
        end)
    after
        file:delete(Cut)
    end.

cut(Path, Lines) ->
    {ok, Raw} = file:read_file(Path),
    Kept = lists:sublist(binary:split(Raw, <<"\n">>, [global]), Lines),
    Cut = filename:join(scratch(), io_lib:format("bxtrace-post-cut-~b.dump", [erlang:unique_integer([positive])])),
    ok = file:write_file(Cut, lists:join($\n, Kept)),
    Cut.

not_a_dump() ->
    ok = needs_a_digest(),
    Path = filename:join(scratch(), io_lib:format("bxtrace-post-junk-~b.txt", [erlang:unique_integer([positive])])),
    ok = file:write_file(Path, <<"this is a log file\nand it has no sections in it\n">>),
    try
        ct_assert:raises(
            "a file with no sections in it",
            error,
            {bxtrace_post, {not_a_crash_dump, Path}},
            fun() -> bxtrace_post:record(tape_path("junk"), #{by_whom => "tamnd", why => "the tests", dump => Path}) end
        )
    after
        file:delete(Path)
    end.

no_live_terms() ->
    with_specimen("portable", fun(_Header, Rows, _Result) ->
        ?EQ("terms that cannot be written down", ok, bxtrace_tape:portable(Rows))
    end).
