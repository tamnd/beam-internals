%% The tape format. One reader, one writer, and the rule about what may go on a
%% tape.
%%
%% A tape is a recording of something the VM did, kept so that it can be
%% replayed by a reader who was not there. Three kinds exist: the reduction
%% tape, the pass tape and the postmortem. They record different things and they
%% all sit in this format, because a widget that can draw one of them should not
%% need a second parser to draw the next.
%%
%% The file is gzipped text. Inside it there is a comment line, a header term, a
%% run of event terms one per line, and a footer carrying the count. Text
%% because a tape that can be diffed is a tape whose change between two releases
%% can be read by a person. One term per line because a tool that only wants the
%% third event should not have to parse the first two hundred thousand. Gzipped
%% because a scheduling trace of a busy second is large and repetitive, and
%% these are committed to a repository.
%%
%% The footer is the reason a truncated tape is caught rather than quietly read
%% short. A recorder that is killed halfway leaves a file that looks fine until
%% somebody notices the run ended early, and a count at the end turns that into
%% an error at the point of reading.

-module(bxtrace_tape).

-export([schema/0, header/3, open/2, write/2, close/1]).
-export([read/1, fold/3, describe/1]).
-export([portable/1, explain/1]).

-define(SCHEMA, 1).
-define(END, '$tape_end').

%% How a term is written down, and the three modifiers all matter.
%%
%% The zero is the line width, and zero means never wrap. A term broken across
%% four lines to fit in eighty columns would break the one term per line rule
%% the whole format rests on.
%%
%% The `t' is unicode. Without it an atom or a binary holding anything above
%% latin1 comes out as escapes, and the file is opened as utf8, so it can hold
%% the characters themselves.
%%
%% The `p' rather than `w' is the readability. `~w' writes <<"29">> as
%% <<50,57>>, which parses back to the same binary and tells a person nothing.
%% Both round trip through erl_parse, so the only difference is whether the
%% claim about being diffable by a person is true.
-define(TERM, "~0tp.~n").

%% The schema version, bumped when the shape of a header or an event changes in
%% a way an older reader would get wrong. A reader that meets a tape from the
%% future says so rather than guessing.
schema() -> ?SCHEMA.

%% Build a header. Everything a machine can answer about itself is filled in
%% here, and the two things it cannot are asked of the caller: who ran this, and
%% what needs it. Those two are the difference between evidence and a file
%% somebody found, which is the same rule corpora/manifest.toml states.
header(Kind, ByWhom, Why) when is_atom(Kind), is_list(ByWhom), is_list(Why) ->
    {Family, Name} = os:type(),
    #{
        schema => ?SCHEMA,
        kind => Kind,
        recorded => list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])),
        by_whom => list_to_binary(ByWhom),
        why => list_to_binary(Why),
        otp => list_to_binary(erlang:system_info(otp_release)),
        erts => list_to_binary(erlang:system_info(version)),
        arch => list_to_binary(erlang:system_info(system_architecture)),
        wordsize => erlang:system_info(wordsize) * 8,
        %% A stock release ships the jit flavor only, so a tape recorded against
        %% the interpreter can only have come from a local build. Recording the
        %% flavor is what makes that visible later.
        flavor => erlang:system_info(emu_flavor),
        build => erlang:system_info(build_type),
        schedulers => erlang:system_info(schedulers),
        schedulers_online => erlang:system_info(schedulers_online),
        os => {Family, Name, list_to_binary(os_version())}
    }.

os_version() ->
    case os:version() of
        {Major, Minor, Release} -> lists:flatten(io_lib:format("~b.~b.~b", [Major, Minor, Release]));
        Text when is_list(Text) -> Text
    end.

open(Path, Header) when is_map(Header) ->
    case portable(Header) of
        ok ->
            ok = filelib:ensure_dir(Path),
            case file:open(Path, [write, compressed, {encoding, utf8}]) of
                {ok, Fd} ->
                    Kind = maps:get(kind, Header, unknown),
                    io:format(Fd, "%% bxtrace tape, schema ~b, kind ~w~n", [?SCHEMA, Kind]),
                    io:format(Fd, ?TERM, [Header]),
                    {ok, #{fd => Fd, path => Path, written => 0}};
                {error, Reason} ->
                    {error, {cannot_write, Path, Reason}}
            end;
        {not_portable, _, _} = Problem ->
            {error, Problem}
    end.

%% Writing checks the event, and a bad one crashes the recorder rather than
%% landing on the tape. That is on purpose. A pid written into a tape is a
%% number that means nothing on the machine that reads it, and finding that out
%% while writing a recorder is cheap while finding it out from a widget drawing
%% nonsense is not.
write(#{fd := Fd, written := Written} = Tape, Event) ->
    case portable(Event) of
        ok ->
            io:format(Fd, ?TERM, [Event]),
            Tape#{written := Written + 1};
        {not_portable, _, _} = Problem ->
            error({bxtrace_tape, explain(Problem)})
    end.

close(#{fd := Fd, path := Path, written := Written}) ->
    io:format(Fd, ?TERM, [{?END, Written}]),
    ok = file:close(Fd),
    {ok, Path, Written}.

%% The whole tape in memory, which is what a test wants and what a small tape
%% can afford. Anything recorded from a real run gets folded instead.
read(Path) ->
    case fold(Path, fun(Event, Acc) -> [Event | Acc] end, []) of
        {ok, Header, Reversed} -> {ok, Header, lists:reverse(Reversed)};
        {error, _} = Problem -> Problem
    end.

fold(Path, Fun, Acc0) when is_function(Fun, 2) ->
    case file:open(Path, [read, compressed, {encoding, utf8}]) of
        {ok, Fd} ->
            try
                case next(Fd, Path) of
                    {ok, Header} when is_map(Header) -> fold_events(Fd, Path, Header, Fun, Acc0);
                    {ok, Other} -> {error, {no_header, Path, Other}};
                    eof -> {error, {empty_tape, Path}}
                end
            after
                file:close(Fd)
            end;
        {error, Reason} ->
            {error, {cannot_read, Path, Reason}}
    end.

fold_events(Fd, Path, Header, Fun, Acc0) ->
    case maps:get(schema, Header, missing) of
        ?SCHEMA -> fold_events(Fd, Path, Header, Fun, Acc0, 0);
        Newer when is_integer(Newer), Newer > ?SCHEMA -> {error, {tape_from_the_future, Path, Newer, ?SCHEMA}};
        Other -> {error, {unknown_schema, Path, Other}}
    end.

fold_events(Fd, Path, Header, Fun, Acc, Seen) ->
    case next(Fd, Path) of
        {ok, {?END, Seen}} ->
            {ok, Header, Acc};
        {ok, {?END, Claimed}} ->
            {error, {tape_count_wrong, Path, Claimed, Seen}};
        {ok, Event} ->
            fold_events(Fd, Path, Header, Fun, Fun(Event, Acc), Seen + 1);
        eof ->
            {error, {tape_truncated, Path, Seen}}
    end.

next(Fd, Path) ->
    case io:get_line(Fd, "") of
        eof ->
            eof;
        {error, Reason} ->
            error({bxtrace_tape, {unreadable, Path, Reason}});
        Line ->
            case string:trim(Line) of
                "" -> next(Fd, Path);
                [$% | _] -> next(Fd, Path);
                Text -> {ok, parse(Text, Path)}
            end
    end.

parse(Text, Path) ->
    case erl_scan:string(Text) of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} -> Term;
                {error, {_, Module, Detail}} -> error({bxtrace_tape, {bad_line, Path, message(Module, Detail)}})
            end;
        {error, {_, Module, Detail}, _} ->
            error({bxtrace_tape, {bad_line, Path, message(Module, Detail)}})
    end.

message(Module, Detail) ->
    unicode:characters_to_binary(Module:format_error(Detail)).

%% What is on a tape, without drawing any of it. Enough to answer the question
%% somebody actually asks about a file in corpora, which is where it came from
%% and roughly what is in it.
describe(Path) ->
    case fold(Path, fun tally/2, #{}) of
        {ok, Header, Counts} ->
            #{otp := Otp, erts := Erts, arch := Arch, flavor := Flavor} = Header,
            io:format("~ts~n", [Path]),
            io:format("  kind      ~w, schema ~b~n", [maps:get(kind, Header), maps:get(schema, Header)]),
            io:format("  recorded  ~ts by ~ts~n", [maps:get(recorded, Header), maps:get(by_whom, Header)]),
            io:format("  why       ~ts~n", [maps:get(why, Header)]),
            io:format("  build     OTP ~ts erts ~ts, ~ts, ~w flavor~n", [Otp, Erts, Arch, Flavor]),
            io:format("  events~n"),
            lists:foreach(
                fun({Tag, Count}) -> io:format("    ~-24w ~b~n", [Tag, Count]) end,
                lists:sort(maps:to_list(Counts))
            ),
            ok;
        {error, Reason} ->
            io:format("~ts cannot be read: ~p~n", [Path, Reason]),
            {error, Reason}
    end.

tally(Event, Counts) when is_tuple(Event), tuple_size(Event) > 0 ->
    Tag = element(1, Event),
    maps:update_with(Tag, fun(N) -> N + 1 end, 1, Counts);
tally(_, Counts) ->
    maps:update_with(untagged, fun(N) -> N + 1 end, 1, Counts).

%% What may go on a tape.
%%
%% Everything that survives being written as text and read back on a different
%% machine, and nothing else. A pid is the interesting exclusion: it prints as
%% <0.113.0> which no parser will take back, and even if it did, the number
%% names a slot in a process table that no longer exists. A recorder that wants
%% to talk about a process records an index or the result of pid_to_list/1 and
%% keeps the mapping in the tape, where a reader can see it.
%%
%% A report says where in the term the trouble is, as a path from the outside
%% in. Positions count from one in a tuple and from one in a list, a map is
%% entered by its key, and an improper tail is called `tail'.
portable(Term) -> walk(Term, []).

walk(Term, _Where) when
    is_atom(Term); is_integer(Term); is_float(Term); is_binary(Term); is_bitstring(Term)
->
    ok;
walk(Term, Where) when is_list(Term) ->
    walk_list(Term, 1, Where);
walk(Term, Where) when is_tuple(Term) ->
    walk_list(tuple_to_list(Term), 1, Where);
walk(Term, Where) when is_map(Term) ->
    walk_map(maps:to_list(Term), Where);
walk(Term, Where) when is_pid(Term) ->
    {not_portable, pid, lists:reverse(Where)};
walk(Term, Where) when is_port(Term) ->
    {not_portable, port, lists:reverse(Where)};
walk(Term, Where) when is_reference(Term) ->
    {not_portable, reference, lists:reverse(Where)};
walk(Term, Where) when is_function(Term) ->
    {not_portable, function, lists:reverse(Where)}.

walk_list([], _At, _Where) ->
    ok;
walk_list([Head | Tail], At, Where) ->
    case walk(Head, [At | Where]) of
        ok when is_list(Tail) -> walk_list(Tail, At + 1, Where);
        ok -> walk(Tail, [tail | Where]);
        Problem -> Problem
    end;
walk_list(Improper, _At, Where) ->
    walk(Improper, [tail | Where]).

walk_map([], _Where) ->
    ok;
walk_map([{Key, Value} | Rest], Where) ->
    case walk(Key, [key | Where]) of
        ok ->
            case walk(Value, [Key | Where]) of
                ok -> walk_map(Rest, Where);
                Problem -> Problem
            end;
        Problem ->
            Problem
    end.

%% The error a recorder author reads, which is worth more than the tuple.
explain({not_portable, What, Where}) ->
    unicode:characters_to_binary(
        io_lib:format(
            "a ~w cannot go on a tape, and there is one at ~p. A tape is read on machines that "
            "never ran the recorder, so it holds only terms that survive being written as text. "
            "Record pid_to_list/1, or an index into a table the tape carries, and keep the live "
            "term on this side.",
            [What, Where]
        )
    ).
