#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% What is on a tape, without drawing any of it.
%%
%% Header, provenance, and a count per event tag. That is the question people
%% actually ask about a file sitting in corpora, and answering it should not
%% require starting Livebook.
%%
%%   ./bxtrace/tape.escript corpora/traces/four-spinners.tape.gz

-mode(compile).

main([]) ->
    io:format("usage: bxtrace/tape.escript <tape> [<tape> ...]~n"),
    halt(1);
main(Paths) ->
    Root = filename:dirname(filename:dirname(escript:script_name())),
    load(Root),
    halt(lists:foldl(fun describe/2, 0, Paths)).

describe(Path, Worst) ->
    case bxtrace_tape:describe(Path) of
        ok -> Worst;
        {error, _} -> 1
    end.

%% Compiled into a temporary directory rather than next to the source, so a run
%% never leaves a stale beam file for the next one to pick up.
load(Root) ->
    Out = filename:join([
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
        "bxtrace-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Out),
    true = code:add_patha(Out),
    Source = filename:join([Root, "bxtrace", "src", "bxtrace_tape.erl"]),
    case compile:file(Source, [{outdir, Out}, return_errors, warnings_as_errors]) of
        {ok, Module} ->
            {module, Module} = code:ensure_loaded(Module),
            ok;
        {error, Errors, Warnings} ->
            io:format("~ts does not compile~n~p~n~p~n", [Source, Errors, Warnings]),
            halt(1)
    end.
