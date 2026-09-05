#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% The conformance runner.
%%
%% Compiles every suite in conformance/suites and runs every case in it. No
%% build tool, no dependencies, nothing to install beyond the release the
%% suites are checking. That is on purpose: a conformance suite that needs a
%% package manager to run is a conformance suite people stop running.
%%
%%   ./conformance/run.escript              every suite
%%   ./conformance/run.escript ct_dist_001  one suite
%%   ./conformance/run.escript --list       what exists, without running it
%%
%% Exit status is 0 when every case passed and 1 otherwise, so it drops
%% straight into CI and into `just conformance'.

-mode(compile).

main(Args) ->
    Root = filename:dirname(filename:dirname(escript:script_name())),
    SuiteDir = filename:join([Root, "conformance", "suites"]),
    Sources = lists:sort(sources(SuiteDir)),
    case Sources of
        [] ->
            io:format("no suites found under ~ts~n", [SuiteDir]),
            halt(1);
        _ ->
            ok
    end,
    Modules = compile_all(Sources),
    Suites = [M || M <- Modules, erlang:function_exported(M, cases, 0)],
    case Args of
        ["--list"] ->
            list(Suites),
            halt(0);
        _ ->
            Wanted = select(Suites, Args),
            banner(Root),
            halt(run(Root, Wanted))
    end.

%% Anything whose name starts with a dot is not a suite. Copying this directory
%% off a Mac with tar produces an AppleDouble `._ct_assert.erl' next to every
%% real file, and those match "*.erl" and then fail to compile, which turns a
%% packaging accident into what looks like a broken suite. Cheaper to skip them
%% than to explain the error message to whoever hits it next.
sources(SuiteDir) ->
    [
        Source
     || Source <- filelib:wildcard(filename:join(SuiteDir, "*.erl")),
        hd(filename:basename(Source)) =/= $.
    ].

%% Compiled into a temporary directory rather than next to the sources, so that
%% a run never leaves a stale beam file behind for the next one to pick up.
compile_all(Sources) ->
    Out = temp_dir(),
    true = code:add_patha(Out),
    lists:map(
        fun(Source) ->
            case compile:file(Source, [{outdir, Out}, return_errors, debug_info, warnings_as_errors]) of
                {ok, Module} ->
                    {module, Module} = code:ensure_loaded(Module),
                    Module;
                {error, Errors, Warnings} ->
                    io:format("~ts does not compile~n~p~n~p~n", [Source, Errors, Warnings]),
                    halt(1)
            end
        end,
        Sources
    ).

temp_dir() ->
    Base = filename:join(
        [
            case os:getenv("TMPDIR") of
                false -> "/tmp";
                Set -> Set
            end,
            "ct-" ++ integer_to_list(erlang:unique_integer([positive]))
        ]
    ),
    ok = filelib:ensure_path(Base),
    Base.

select(Suites, []) ->
    Suites;
select(Suites, Names) ->
    Wanted = [list_to_atom(N) || N <- Names],
    case [N || N <- Wanted, not lists:member(N, Suites)] of
        [] ->
            [S || S <- Suites, lists:member(S, Wanted)];
        Missing ->
            io:format("no such suite: ~p~nthere is: ~p~n", [Missing, Suites]),
            halt(1)
    end.

list(Suites) ->
    lists:foreach(
        fun(Suite) ->
            io:format("~s  ~s~n", [Suite, Suite:blueprint()]),
            lists:foreach(
                fun({Id, Tier, Title, _}) ->
                    io:format("  ~-28s ~-4s ~ts~n", [Id, Tier, Title])
                end,
                Suite:cases()
            )
        end,
        Suites
    ).

banner(Root) ->
    io:format("conformance on OTP ~s, erts ~s, ~s ~s~n", [
        erlang:system_info(otp_release),
        erlang:system_info(version),
        erlang:system_info(system_architecture),
        integer_to_list(erlang:system_info(wordsize) * 8) ++ " bit"
    ]),
    io:format("pinned at ~s~n~n", [pin(Root)]).

%% The suites check the runtime in front of them, and the blueprints are
%% written against one pinned release. Printing both means a green run against
%% the wrong release is visible in the log rather than invisible in an
%% assumption.
pin(Root) ->
    case file:read_file(filename:join(Root, "refcheck.toml")) of
        {ok, Contents} ->
            case re:run(Contents, "tag *= *\"([^\"]+)\"", [{capture, all_but_first, list}]) of
                {match, [Tag]} -> Tag;
                nomatch -> "unknown"
            end;
        _ ->
            "unknown"
    end.

run(Root, Suites) ->
    Results = [run_suite(Root, S) || S <- Suites],
    Failed = lists:sum([F || {_, _, F, _} <- Results]),
    Skipped = lists:sum([S || {_, _, _, S} <- Results]),
    Total = lists:sum([T || {_, T, _, _} <- Results]),
    io:format("~n~b cases, ~b passed, ~b failed, ~b skipped~n", [
        Total, Total - Failed - Skipped, Failed, Skipped
    ]),
    case Failed of
        0 -> 0;
        _ -> 1
    end.

run_suite(Root, Suite) ->
    Blueprint = Suite:blueprint(),
    io:format("~s  checks ~s~n", [Suite, Blueprint]),
    ok = check_blueprint_agrees(Root, Suite, Blueprint),
    Cases = Suite:cases(),
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
    {Suite, length(Cases), Failures, Skips}.

%% A suite says which blueprint it checks and the blueprint says which suite
%% checks it. Neither is worth much alone, so the runner insists the two agree
%% before it runs anything. A suite pointed at a blueprint that has been
%% renamed is a suite nobody is reading the results of.
check_blueprint_agrees(Root, Suite, Blueprint) ->
    Pattern = filename:join([Root, "blueprints", "*", Blueprint ++ ".md"]),
    case filelib:wildcard(Pattern) of
        [Path] ->
            {ok, Contents} = file:read_file(Path),
            Expected = list_to_binary(string:uppercase(atom_to_list(Suite))),
            Wanted = binary:replace(Expected, <<"_">>, <<"-">>, [global]),
            case binary:match(Contents, <<"Conformance: ", Wanted/binary>>) of
                nomatch ->
                    io:format("  ~ts does not name ~ts in its header~n", [Blueprint, Wanted]),
                    halt(1);
                _ ->
                    ok
            end;
        [] ->
            io:format("  no blueprint named ~ts~n", [Blueprint]),
            halt(1);
        Many ->
            io:format("  more than one blueprint named ~ts: ~p~n", [Blueprint, Many]),
            halt(1)
    end.

run_case({Id, _Tier, Title, Fun}) ->
    Started = erlang:monotonic_time(millisecond),
    Outcome =
        try Fun() of
            _ -> pass
        catch
            throw:{ct_skipped, Why} -> {skip, Why};
            throw:{ct_failed, What, Detail} -> {fail, What, Detail};
            Class:Reason:Stack -> {crash, Class, Reason, Stack}
        end,
    Took = erlang:monotonic_time(millisecond) - Started,
    report(Id, Title, Took, Outcome).

report(Id, _Title, Took, pass) ->
    io:format("  pass  ~-28s ~5b ms~n", [Id, Took]),
    pass;
report(Id, Title, _Took, {skip, Why}) ->
    io:format("  skip  ~-28s ~ts~n", [Id, Title]),
    io:format("        ~ts~n", [Why]),
    skip;
report(Id, Title, _Took, {fail, What, Detail}) ->
    io:format("  FAIL  ~-28s ~ts~n", [Id, Title]),
    io:format("        ~ts~n", [What]),
    io:format("        ~P~n", [Detail, 12]),
    fail;
report(Id, Title, _Took, {crash, Class, Reason, Stack}) ->
    io:format("  CRASH ~-28s ~ts~n", [Id, Title]),
    io:format("        ~p:~P~n", [Class, Reason, 12]),
    lists:foreach(fun(Frame) -> io:format("        ~P~n", [Frame, 8]) end, lists:sublist(Stack, 5)),
    fail.
