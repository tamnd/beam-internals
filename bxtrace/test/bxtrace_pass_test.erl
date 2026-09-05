%% The pass tape recorder, checked against a module whose compilation is known.
%%
%% The module is six lines and the numbers it produces are the ones the project
%% quotes: 33 top level passes, 60 named sub passes, and a validator that runs
%% twice. Those numbers are pinned to the release, not to this machine, so a
%% failure here after a pin bump is news rather than flakiness.
-module(bxtrace_pass_test).

-export([cases/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

%% What OTP 29.0.5 does to the module below. Written out rather than computed,
%% because a test that recomputes the thing it is checking checks nothing.
-define(PASSES, 33).
-define(SUB_PASSES, 60).

cases() ->
    [
        {"a recording reads back as a tape", fun reads_back/0},
        {"the compiler still hands over the shape this reads", fun the_shape_holds/0},
        {"a six line module goes through 33 passes and 60 sub passes", fun the_count/0},
        {"the passes are on the tape in the order they ran", fun in_order/0},
        {"the validator runs twice, before and after the back end", fun validated_twice/0},
        {"every sub pass names a pass that is on the tape", fun sub_passes_belong/0},
        {"a sub pass records how many times it ran, not just how long", fun runs_are_counted/0},
        {"full pass names survive, including the one erlc truncates", fun names_are_not_cut_off/0},
        {"the module's own source is on the tape", fun source_is_kept/0},
        {"core erlang and the assembly listing are captured", fun stages_are_captured/0},
        {"asking for no stages records the passes and nothing else", fun no_stages/0},
        {"a module that will not compile says so", fun broken_module/0},
        {"nothing on the tape is a live term", fun no_live_terms/0}
    ].

%% ---------------------------------------------------------------------------
%% The module under the microscope

%% Six lines, two exported functions, one of them an accumulator loop. Small
%% enough that the pass count is about the compiler rather than about the
%% module, which is the whole point of the figure.
source() ->
    <<
        "-module(l1).\n"
        "-export([add/2, fib/1]).\n"
        "add(A, B) -> A + B.\n"
        "fib(N) -> fib(N, 0, 1).\n"
        "fib(0, A, _) -> A;\n"
        "fib(N, A, B) -> fib(N - 1, B, A + B).\n"
    >>.

scratch(Name, Extension) ->
    Dir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
    filename:join(Dir, io_lib:format("bxtrace-pass-~ts-~b~ts", [Name, erlang:unique_integer([positive]), Extension])).

%% The source is written to a real file because that is what the recorder takes
%% and what a corpus holds. The module is always called l1, so the file has to
%% be too.
with_source(Text, Fun) ->
    Dir = scratch("src", ""),
    ok = filelib:ensure_path(Dir),
    Path = filename:join(Dir, "l1.erl"),
    ok = file:write_file(Path, Text),
    try
        Fun(Path)
    after
        file:delete(Path),
        file:del_dir(Dir)
    end.

with_recording(Name, Opts, Fun) ->
    with_source(source(), fun(Source) ->
        Path = scratch(Name, ".tape.gz"),
        Base = #{by_whom => "tamnd", why => "the pass tape tests", source => Source},
        {ok, Result} = bxtrace_pass:record(Path, maps:merge(Base, Opts)),
        {ok, Header, Events} = bxtrace_tape:read(Path),
        try
            Fun(Header, Events, Result)
        after
            file:delete(Path)
        end
    end).

passes(Events) -> [P || P <- Events, element(1, P) =:= pass].
subpasses(Events) -> [P || P <- Events, element(1, P) =:= subpass].
stages(Events) -> [S || S <- Events, element(1, S) =:= stage].

names(Events) -> [Name || {pass, _, Name, _, _, _} <- passes(Events)].

%% ---------------------------------------------------------------------------
%% Cases

reads_back() ->
    with_recording("reads-back", #{}, fun(Header, Events, Result) ->
        ?EQ("the kind", pass, maps:get(kind, Header)),
        ?EQ("the module", <<"l1">>, maps:get(module, Header)),
        ?EQ("the module the recorder reported", <<"l1">>, maps:get(module, Result)),
        ct_assert:is_true("the compiler version is recorded", is_binary(maps:get(compiler, Header))),
        ct_assert:is_true("there are passes", passes(Events) =/= [])
    end).

%% The one case that exists only to fail. The recorder reads a shape the
%% compiler does not document, so this is the alarm on that door. A release that
%% changes the tuple the time handler is called with turns up here as a failing
%% test with the tuple in the message, rather than as a tape that is quietly
%% wrong.
the_shape_holds() ->
    with_source(source(), fun(Source) ->
        Self = self(),
        Handler = fun(File, Times) -> Self ! {times, File, Times} end,
        Dir = scratch("shape", ""),
        ok = filelib:ensure_path(Dir),
        try
            {ok, l1} = compile:file(Source, [{time, Handler}, {outdir, Dir}, report_errors]),
            receive
                {times, _File, Times} ->
                    ct_assert:is_true("the handler was called with a list", is_list(Times)),
                    Wrong = [T || T <- Times, not four_tuple(T)],
                    ?EQ("timings that are not {Name, Elapsed, Bytes, SubTimes}", [], Wrong),
                    Subs = lists:append([S || {_, _, _, S} <- Times]),
                    Odd = [S || S <- Subs, not pair(S)],
                    ?EQ("sub timings that are not {Name, Elapsed}", [], Odd)
            after 10000 ->
                ct_assert:fail("the time handler", it_was_never_called)
            end
        after
            [file:delete(F) || F <- filelib:wildcard(filename:join(Dir, "*"))],
            file:del_dir(Dir)
        end
    end).

four_tuple({Name, Elapsed, Bytes, Subs}) ->
    is_atom(Name) andalso is_integer(Elapsed) andalso is_integer(Bytes) andalso is_list(Subs);
four_tuple(_) ->
    false.

pair({Name, Elapsed}) -> is_atom(Name) andalso is_integer(Elapsed);
pair(_) -> false.

the_count() ->
    with_recording("count", #{}, fun(Header, Events, Result) ->
        ?EQ("top level passes on the tape", ?PASSES, length(passes(Events))),
        ?EQ("top level passes in the header", ?PASSES, maps:get(passes, Header)),
        Distinct = lists:usort([Name || {subpass, _, _, Name, _, _} <- subpasses(Events)]),
        ?EQ("named sub passes", ?SUB_PASSES, length(Distinct)),
        ?EQ("and the header agrees", ?SUB_PASSES, maps:get(sub_passes, Header)),
        %% The fact `erlc +time' throws away. Sub passes run once per function,
        %% so a three function module runs them far more often than the printed
        %% list of names suggests.
        ct_assert:is_true(
            "sub passes ran more often than there are of them",
            maps:get(sub_pass_runs, Result) > ?SUB_PASSES
        )
    end).

in_order() ->
    with_recording("order", #{}, fun(_Header, Events, _Result) ->
        Indexes = [At || {pass, At, _, _, _, _} <- passes(Events)],
        ?EQ("the indexes count up from one", lists:seq(1, ?PASSES), Indexes),
        Names = names(Events),
        ?EQ("the first pass", remove_file, hd(Names)),
        ?EQ("the last pass", save_binary, lists:last(Names)),
        %% Core Erlang is made before it is folded, and the folded core is what
        %% becomes SSA. An out of order tape would fail here.
        ct_assert:is_true("core comes before sys_core_fold", before(core, sys_core_fold, Names)),
        ct_assert:is_true("sys_core_fold comes before core_to_ssa", before(sys_core_fold, core_to_ssa, Names))
    end).

before(First, Second, Names) ->
    index_of(First, Names) < index_of(Second, Names).

index_of(Name, Names) ->
    {At, _} = lists:keyfind(Name, 2, lists:zip(lists:seq(1, length(Names)), Names)),
    At.

%% The teachable one. The compiler validates the code it generated, runs its
%% peephole passes over it, and then validates it again. It does not trust its
%% own optimisers, and it says so twice in a row on the tape.
validated_twice() ->
    with_recording("validator", #{}, fun(_Header, Events, _Result) ->
        Names = names(Events),
        ct_assert:is_true("the strong validator ran", lists:member(beam_validator_strong, Names)),
        ct_assert:is_true("the weak validator ran", lists:member(beam_validator_weak, Names)),
        ct_assert:is_true(
            "the strong one runs first",
            before(beam_validator_strong, beam_validator_weak, Names)
        ),
        %% And the peephole passes sit between them, which is what makes the
        %% second run worth doing.
        ct_assert:is_true("beam_jump is after the first", before(beam_validator_strong, beam_jump, Names)),
        ct_assert:is_true("and before the second", before(beam_jump, beam_validator_weak, Names))
    end).

sub_passes_belong() ->
    with_recording("belong", #{}, fun(_Header, Events, _Result) ->
        Known = [{At, Name} || {pass, At, Name, _, _, _} <- passes(Events)],
        Claimed = lists:usort([{At, Parent} || {subpass, At, Parent, _, _, _} <- subpasses(Events)]),
        ?EQ("sub passes claiming a pass that is not on the tape", [], Claimed -- Known)
    end).

runs_are_counted() ->
    with_recording("runs", #{}, fun(_Header, Events, _Result) ->
        Runs = [Runs || {subpass, _, _, _, _, Runs} <- subpasses(Events)],
        ct_assert:is_true("every sub pass ran at least once", lists:all(fun(N) -> N >= 1 end, Runs)),
        ct_assert:is_true("and at least one ran more than once", lists:max(Runs) > 1)
    end).

%% erlc pads the sub pass name to 27 characters and cuts off anything longer, so
%% skip_outgoing_tail_extraction comes out of `erlc +time' as
%% skip_outgoing_tail_extracti. Reading the handler instead of the printout is
%% what keeps the name whole, and this is the case that says so.
names_are_not_cut_off() ->
    with_recording("names", #{}, fun(_Header, Events, _Result) ->
        Names = [Name || {subpass, _, _, Name, _, _} <- subpasses(Events)],
        ct_assert:is_true(
            "the name erlc cuts short is on the tape in full",
            lists:member(skip_outgoing_tail_extraction, Names)
        ),
        ct_assert:is_true(
            "and the cut off version is not",
            not lists:member(skip_outgoing_tail_extracti, Names)
        )
    end).

source_is_kept() ->
    with_recording("source", #{}, fun(_Header, Events, _Result) ->
        [{source, Module, Text}] = [S || S <- Events, element(1, S) =:= source],
        ?EQ("the module", <<"l1">>, Module),
        ?EQ("the source", source(), Text)
    end).

stages_are_captured() ->
    with_recording("stages", #{}, fun(_Header, Events, Result) ->
        ?EQ("the stages recorded", [to_core, to_asm], maps:get(stages, Result)),
        Files = [File || {stage, _, File, _} <- stages(Events)],
        ct_assert:is_true("core erlang was written", lists:member(<<"l1.core">>, Files)),
        ct_assert:is_true("and the assembly listing", lists:member(<<"l1.S">>, Files)),
        %% Not just that a file appeared, but that it holds what it should. The
        %% assembly listing carries the types the compiler worked out, which is
        %% the reason to capture it at all.
        [Asm] = [Body || {stage, _, <<"l1.S">>, Body} <- stages(Events)],
        ct_assert:is_true("the listing names the function", binary:match(Asm, <<"{function, fib, 3">>) =/= nomatch),
        ct_assert:is_true("and carries an inferred type", binary:match(Asm, <<"t_integer">>) =/= nomatch),
        [Core] = [Body || {stage, _, <<"l1.core">>, Body} <- stages(Events)],
        ct_assert:is_true("the core erlang is core erlang", binary:match(Core, <<"module 'l1'">>) =/= nomatch)
    end).

no_stages() ->
    with_recording("bare", #{stages => []}, fun(_Header, Events, _Result) ->
        ?EQ("stages", [], stages(Events)),
        ?EQ("passes", ?PASSES, length(passes(Events)))
    end).

broken_module() ->
    Broken = <<"-module(l1).\n-export([add/2]).\nadd(A, B) -> A +\n">>,
    with_source(Broken, fun(Source) ->
        Path = scratch("broken", ".tape.gz"),
        try
            bxtrace_pass:record(Path, #{
                by_whom => "tamnd", why => "the pass tape tests", source => Source
            }),
            ct_assert:fail("recording a module that will not compile", it_was_accepted)
        catch
            error:{bxtrace_pass, {will_not_compile, _, Errors}} ->
                %% The compiler's own report comes back with the failure rather
                %% than going to stdout, so whoever is holding a broken module
                %% is told which line it broke on.
                ct_assert:is_true("the failure carries what the compiler said", Errors =/= [])
        after
            file:delete(Path)
        end
    end).

no_live_terms() ->
    with_recording("portable", #{}, fun(_Header, Events, _Result) ->
        ?EQ("terms that cannot be written down", ok, bxtrace_tape:portable(Events))
    end).
