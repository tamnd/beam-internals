#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% The tests for the tape recorders.
%%
%% Separate from conformance/run.escript because the two answer different
%% questions. A conformance suite asks whether the runtime in front of you still
%% behaves the way a blueprint says it does, and a failure there is news about
%% Erlang. These ask whether our own code works, and a failure here is news
%% about us. Mixing them would make the scorecard mean two things.
%%
%% The assertion vocabulary is shared, though, because there is no reason for
%% this repository to have two of those.
%%
%%   ./bxtrace/test.escript                every module
%%   ./bxtrace/test.escript bxtrace_tape   one of them

-mode(compile).

main(Args) ->
    Root = filename:dirname(filename:dirname(escript:script_name())),
    Out = temp_dir(),
    true = code:add_patha(Out),
    compile_all(Out, [
        filename:join([Root, "conformance", "suites", "ct_assert.erl"])
        | sources(filename:join([Root, "bxtrace", "src"])) ++
            sources(filename:join([Root, "bxtrace", "test"]))
    ]),
    Modules = select(test_modules(), Args),
    io:format("bxtrace on OTP ~s, erts ~s, ~s~n~n", [
        erlang:system_info(otp_release),
        erlang:system_info(version),
        erlang:system_info(system_architecture)
    ]),
    halt(run(Modules)).

%% Anything whose name starts with a dot is not a source. Copying this tree off
%% a Mac with tar leaves an AppleDouble `._name.erl' next to every real file,
%% and those match "*.erl" and then fail to compile.
sources(Dir) ->
    [S || S <- filelib:wildcard(filename:join(Dir, "*.erl")), hd(filename:basename(S)) =/= $.].

compile_all(Out, Sources) ->
    [compile_one(Out, S) || S <- Sources].

compile_one(Out, Source) ->
    case compile:file(Source, [{outdir, Out}, return_errors, debug_info, warnings_as_errors]) of
        {ok, Module} ->
            {module, Module} = code:ensure_loaded(Module),
            Module;
        {error, Errors, Warnings} ->
            io:format("~ts does not compile~n~p~n~p~n", [Source, Errors, Warnings]),
            halt(1)
    end.

test_modules() ->
    lists:sort([M || {M, _} <- code:all_loaded(), erlang:function_exported(M, cases, 0)]).

select(Modules, []) ->
    Modules;
select(Modules, Names) ->
    Wanted = [list_to_atom(N ++ "_test") || N <- Names],
    case [W || W <- Wanted, not lists:member(W, Modules)] of
        [] -> [M || M <- Modules, lists:member(M, Wanted)];
        Missing -> io:format("no such test module: ~p~nthere is: ~p~n", [Missing, Modules]), halt(1)
    end.

temp_dir() ->
    Base = filename:join([
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
        "bxtrace-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Base),
    Base.

run(Modules) ->
    Results = [run_module(M) || M <- Modules],
    Failed = lists:sum([F || {_, F, _} <- Results]),
    Skipped = lists:sum([S || {_, _, S} <- Results]),
    Total = lists:sum([T || {T, _, _} <- Results]),
    io:format("~n~b cases, ~b passed, ~b failed, ~b skipped~n", [
        Total, Total - Failed - Skipped, Failed, Skipped
    ]),
    case Failed of
        0 -> 0;
        _ -> 1
    end.

run_module(Module) ->
    io:format("~s~n", [Module]),
    Cases = Module:cases(),
    {Failures, Skips} = lists:foldl(
        fun(Case, {F, S}) ->
            case run_case(Case) of
                fail -> {F + 1, S};
                skip -> {F, S + 1};
                pass -> {F, S}
            end
        end,
        {0, 0},
        Cases
    ),
    io:nl(),
    {length(Cases), Failures, Skips}.

run_case({Name, Fun}) ->
    try Fun() of
        _ ->
            io:format("  pass  ~ts~n", [Name]),
            pass
    catch
        throw:{ct_skipped, Why} ->
            io:format("  skip  ~ts~n        ~ts~n", [Name, Why]),
            skip;
        throw:{ct_failed, What, Detail} ->
            io:format("  FAIL  ~ts~n        ~ts~n        ~P~n", [Name, What, Detail, 12]),
            fail;
        Class:Reason:Stack ->
            io:format("  CRASH ~ts~n        ~p:~P~n", [Name, Class, Reason, 12]),
            [io:format("        ~P~n", [Frame, 8]) || Frame <- lists:sublist(Stack, 5)],
            fail
    end.
