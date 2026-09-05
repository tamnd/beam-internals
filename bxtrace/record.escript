#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% The recordings that go in corpora, and the provenance that goes with them.
%%
%% Every artefact in corpora has an entry in corpora/manifest.toml saying which
%% build made it, on what, by whom and why. Typing that entry by hand is how a
%% manifest ends up describing a file that was replaced six months ago, so this
%% prints the entry rather than asking anybody to remember the fields. Paste
%% what it prints into corpora/manifest.toml, and `python3 -m tools.corpus'
%% checks that what is pasted matches the file that is there.
%%
%% The recording is the command in the entry. That is the point of naming them:
%% `produced_by' has to be something a reader can run, and a name is easier to
%% run correctly than a paragraph describing what somebody did once.
%%
%%   ./bxtrace/record.escript --list
%%   ./bxtrace/record.escript l1-passes
%%   ./bxtrace/record.escript --all

-mode(compile).

main(Args) ->
    Root = filename:dirname(filename:dirname(escript:script_name())),
    Out = build(Root),
    case who(Args) of
        {_, ["--list"]} -> list();
        {By, ["--all"]} -> run(Root, Out, By, [Name || {Name, _} <- recordings()]);
        {_, []} -> usage();
        {By, Names} -> run(Root, Out, By, Names)
    end.

usage() ->
    io:format("usage: record.escript [--by NAME] [--list | --all | NAME ...]~n"),
    halt(2).

%% Who is recording this. It defaults to whoever is logged in, which is right
%% often enough, and takes a name for the times it is not: a shared machine, a
%% container, or anywhere USER says something nobody can be asked a question.
who(["--by", Name | Rest]) -> {Name, Rest};
who(Args) -> {default_by_whom(), Args}.

default_by_whom() ->
    case os:getenv("USER") of
        false -> "unknown";
        User -> User
    end.

list() ->
    [io:format("~-14s  ~ts~n", [Name, maps:get(why, Spec)]) || {Name, Spec} <- recordings()],
    halt(0).

%% ---------------------------------------------------------------------------
%% What there is to record
%%
%% One entry per artefact, and the entry is the whole definition: where it goes,
%% why it is needed, which lessons will be graded against it, and the function
%% that makes it. Adding a recording means adding one of these, which is the
%% cheapest thing that still leaves the manifest able to be generated.

recordings() ->
    [
        {"l1-passes", #{
            path => "passes/l1.tape.gz",
            kind => pass,
            why => "the figure that a six line module runs 33 passes and 60 sub passes",
            needed_by => ["m12"],
            record => fun(Root, By, Path) ->
                bxtrace_pass:record(Path, #{
                    by_whom => By,
                    why => "the figure that a six line module runs 33 passes and 60 sub passes",
                    source => filename:join([Root, "corpora", "src", "l1.erl"]),
                    stages => [to_core, to_asm]
                })
            end
        }},
        {"one-spinner", #{
            path => "traces/one-spinner.tape.gz",
            kind => reds,
            why => "the opening figure for t07, one process spending one budget at a time",
            needed_by => ["t07"],
            record => fun(_Root, By, Path) ->
                bxtrace_reds:record(Path, #{
                    by_whom => By,
                    why => "the opening figure for t07, one process spending one budget at a time",
                    run => fun() -> spinner:spin(200000) end,
                    for => 60000
                })
            end
        }}
    ].

%% ---------------------------------------------------------------------------
%% Running one

run(Root, _Out, By, Names) ->
    Specs = [{Name, spec(Name)} || Name <- Names],
    [one(Root, By, Name, Spec) || {Name, Spec} <- Specs],
    halt(0).

spec(Name) ->
    case lists:keyfind(Name, 1, recordings()) of
        {_, Spec} ->
            Spec;
        false ->
            io:format("no recording called ~ts. there is:~n", [Name]),
            [io:format("  ~ts~n", [N]) || {N, _} <- recordings()],
            halt(1)
    end.

one(Root, By, Name, Spec) ->
    Path = filename:join([Root, "corpora", maps:get(path, Spec)]),
    Record = maps:get(record, Spec),
    {ok, Result} = Record(Root, By, Path),
    io:format("~ts~n", [manifest(Name, By, Spec, Path)]),
    io:format("%% ~ts: ~p~n~n", [Name, maps:remove(path, Result)]).

%% ---------------------------------------------------------------------------
%% The manifest entry
%%
%% Everything here is asked of the machine rather than typed, except the two
%% things a machine cannot answer: who ran it and what needs it. Those two are
%% the difference between evidence and a file somebody found, and they are the
%% only two fields in the entry that a person is trusted with.

manifest(Name, By, Spec, Path) ->
    {ok, Bytes} = file:read_file(Path),
    {_Family, OsName} = os:type(),
    [
        io_lib:format("[[artefact]]~n", []),
        field("path", maps:get(path, Spec)),
        field("produced_by", "./bxtrace/record.escript " ++ Name),
        field("kind", atom_to_list(maps:get(kind, Spec))),
        field("flavor", atom_to_list(erlang:system_info(emu_flavor))),
        field("arch", arch()),
        field("os", lists:flatten(io_lib:format("~w ~ts", [OsName, os_version()]))),
        field("build", atom_to_list(erlang:system_info(build_type))),
        field("recorded", today()),
        field("by_whom", By),
        field("why", maps:get(why, Spec)),
        io_lib:format("needed_by = [~ts]~n", [
            lists:join(", ", [io_lib:format("\"~ts\"", [L]) || L <- maps:get(needed_by, Spec)])
        ]),
        io_lib:format("bytes = ~b~n", [byte_size(Bytes)]),
        field("sha256", binary_to_list(binary:encode_hex(crypto:hash(sha256, Bytes), lowercase)))
    ].

field(Key, Value) -> io_lib:format("~ts = \"~ts\"~n", [Key, Value]).

%% The manifest wants the instruction set on its own, because the JIT emits a
%% different one on each and a tape that only said `aarch64-apple-darwin24.6.0'
%% would need parsing by everything that reads it.
arch() ->
    hd(string:split(erlang:system_info(system_architecture), "-")).

os_version() ->
    case os:version() of
        {Major, Minor, Release} -> lists:flatten(io_lib:format("~b.~b.~b", [Major, Minor, Release]));
        Text when is_list(Text) -> Text
    end.

today() ->
    {{Year, Month, Day}, _} = calendar:universal_time(),
    lists:flatten(io_lib:format("~4..0b-~2..0b-~2..0b", [Year, Month, Day])).

%% ---------------------------------------------------------------------------
%% Building
%%
%% The same one step compile the test runner does, for the same reason: these
%% are small modules with no dependencies and a build system between here and
%% running them would be a build system to keep working.

build(Root) ->
    Out = temp_dir(),
    true = code:add_patha(Out),
    [
        compile_one(Out, S)
     || S <-
            sources(filename:join([Root, "bxtrace", "src"])) ++
                sources(filename:join([Root, "corpora", "src"]))
    ],
    Out.

sources(Dir) ->
    [S || S <- filelib:wildcard(filename:join(Dir, "*.erl")), hd(filename:basename(S)) =/= $.].

compile_one(Out, Source) ->
    case compile:file(Source, [{outdir, Out}, return_errors, debug_info]) of
        {ok, Module} ->
            {module, Module} = code:ensure_loaded(Module),
            Module;
        {error, Errors, Warnings} ->
            io:format("~ts does not compile~n~p~n~p~n", [Source, Errors, Warnings]),
            halt(1)
    end.

temp_dir() ->
    Base = filename:join([
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
        "bxtrace-record-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Base),
    Base.
