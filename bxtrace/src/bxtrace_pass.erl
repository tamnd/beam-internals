%% The pass tape.
%%
%% What the compiler does to a module, stage by stage: every top level pass in
%% the order it ran, how long it took, how large the thing it handed on was, and
%% every sub pass underneath it. Plus the module's own source, and the
%% intermediate forms at whichever stopping points were asked for.
%%
%% The figure this exists for is that a six line module goes through 33 top
%% level passes and 60 named sub passes on the way to a beam file, and that the
%% validator runs twice, before and after the back end, because the compiler
%% does not trust its own peephole optimisers. Both of those are one flag away
%% from anybody's shell, which is exactly the sort of claim this project prefers
%% to make.
%%
%% Same rule as the reduction tape: this records, it does not judge. Which pass
%% is worth a reader's attention is a judgement and belongs somewhere it can be
%% argued with.
%%
%% ---------------------------------------------------------------------------
%% Where the numbers come from, and the one liberty taken
%%
%% `erlc +time' prints the pass timings, and the obvious way to record them is
%% to run erlc and parse what it prints. That works and it loses things. The
%% printed format is `io:format(" ~-30s: ~10.3f s ~12s\n", ...)' for a top level
%% pass and `~-27s' for a sub pass. See
%% lib/compiler/src/compile.erl:1412@OTP-29.0.5 and
%% lib/compiler/src/compile.erl:1435@OTP-29.0.5. A name longer than the field
%% runs into the colon and a name longer still is cut off, and on a stock OTP 29
%% that already happens: skip_outgoing_tail_extraction prints as
%% skip_outgoing_tail_extracti. Times arrive rounded to a millisecond and sizes
%% to a tenth of a kilobyte, and the sub passes arrive already folded and
%% sorted, so the number of times each one ran is gone.
%%
%% None of that is necessary, because the printing is a handler and the handler
%% can be replaced. `time' as a bare atom expands to
%% `{time, fun print_pass_times/2}' at
%% lib/compiler/src/compile.erl:1197@OTP-29.0.5, and the tuple form is looked up
%% and called at lib/compiler/src/compile.erl:1319@OTP-29.0.5. Passing our own
%% function there gets the same data the printer gets, one step earlier: exact
%% native time, exact bytes, full names, and every sub pass invocation rather
%% than a fold of them.
%%
%% The liberty is that the tuple form is not documented. Only the bare atom is.
%% So the shape is checked on the way in and a change to it stops the recorder
%% with a message naming what changed, rather than quietly producing a tape that
%% is wrong. `bxtrace_pass_test' has a case that does nothing but assert the
%% shape, so a version bump reports this as a failing test rather than as a
%% strange tape three weeks later.

-module(bxtrace_pass).

-export([record/2]).

%% What is asked for when nothing is asked for. Core Erlang is where the
%% language stops being Erlang, and the assembly listing is where the compiler
%% writes down the types it worked out, so between them they cover the two
%% stages a reader most often wants to see.
-define(DEFAULT_STAGES, [to_core, to_asm]).

%% record(Path, Opts) compiles a module and writes down what the compiler did.
%%
%%   #{by_whom => "tamnd",
%%     why     => "the 93 stages figure",
%%     source  => "corpora/src/l1.erl",
%%     options => [],                  extra options, on every compile it runs
%%     stages  => [to_core, to_asm]}   stopping points to capture
record(Path, Opts) ->
    Source = maps:get(source, Opts),
    ByWhom = maps:get(by_whom, Opts),
    Why = maps:get(why, Opts),
    Extra = maps:get(options, Opts, []),
    Stages = maps:get(stages, Opts, ?DEFAULT_STAGES),

    {ok, Text} = file:read_file(Source),
    Module = list_to_binary(filename:rootname(filename:basename(Source))),

    {Passes, SubPasses} = timings(Source, Extra),
    Captured = [{Stage, capture(Source, Stage, Extra)} || Stage <- Stages],

    Header = maps:merge(
        bxtrace_tape:header(pass, ByWhom, Why),
        #{
            module => Module,
            source => list_to_binary(filename:basename(Source)),
            options => Extra,
            stages => Stages,
            compiler => compiler_version(),
            time_unit => microsecond,
            passes => length(Passes),
            %% Distinct names, which is the number `erlc +time' prints, and
            %% total invocations, which it does not. They are wildly different
            %% and the difference is the interesting part.
            sub_passes => length(lists:usort([Name || {_, _, Name, _, _} <- SubPasses])),
            sub_pass_runs => lists:sum([Runs || {_, _, _, _, Runs} <- SubPasses])
        }
    ),
    {ok, Tape} = bxtrace_tape:open(Path, Header),
    Written = write_all(Tape, Module, Text, Passes, SubPasses, Captured),
    {ok, Path, Count} = bxtrace_tape:close(Written),
    {ok, #{
        path => Path,
        events => Count,
        module => Module,
        passes => length(Passes),
        sub_passes => maps:get(sub_passes, Header),
        sub_pass_runs => maps:get(sub_pass_runs, Header),
        stages => [Stage || {Stage, _} <- Captured]
    }}.

%% ---------------------------------------------------------------------------
%% The timings

%% One compile, with our own handler in place of the printer.
%%
%% The handler does not run in this process. The compiler spawns a worker and
%% compiles in it, which is why `no_spawn_compiler_process' exists as an option
%% for callers who have already spawned workers of their own. So the data comes
%% back as a message rather than through the process dictionary, tagged with a
%% reference so that two recordings running at once cannot read each other's.
%%
%% The receive does not wait. The handler is called inside the worker before the
%% worker finishes, and messages from one process to another arrive in the order
%% they were sent, so by the time compile:file/2 has its answer the timings are
%% already in the mailbox. Waiting instead of not finding them would turn a
%% release that stopped honouring the option into a recorder that hangs.
timings(Source, Extra) ->
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_File, Times) -> Self ! {times, Ref, Times} end,
    Result = in_a_temp_dir(fun(Dir) ->
        compile:file(Source, [{time, Handler}, {outdir, Dir}, return_errors | Extra])
    end),
    case Result of
        {ok, _} -> ok;
        {error, Errors, _Warnings} -> error({bxtrace_pass, {will_not_compile, Source, Errors}})
    end,
    receive
        {times, Ref, Times} ->
            check(Times),
            {top_level(Times), sub_passes(Times)}
    after 0 ->
        %% The handler is looked up and called unconditionally once the option
        %% is present, so this can only mean the tuple form is no longer
        %% honoured.
        error({bxtrace_pass, the_time_handler_was_never_called})
    end.

%% The shape this recorder reads, asserted rather than assumed. Everything after
%% this point may take it for granted, and a release that changes it fails here
%% with the tuple that was not understood.
check(Times) when is_list(Times) ->
    lists:foreach(
        fun
            ({Name, Elapsed, Bytes, Subs}) when
                is_atom(Name), is_integer(Elapsed), is_integer(Bytes), is_list(Subs)
            ->
                lists:foreach(fun check_sub/1, Subs);
            (Other) ->
                error({bxtrace_pass, {pass_timings_changed_shape, Other}})
        end,
        Times
    );
check(Other) ->
    error({bxtrace_pass, {pass_timings_changed_shape, Other}}).

check_sub({Name, Elapsed}) when is_atom(Name), is_integer(Elapsed) -> ok;
check_sub(Other) -> error({bxtrace_pass, {sub_pass_timings_changed_shape, Other}}).

top_level(Times) ->
    lists:map(
        fun({At, {Name, Elapsed, Bytes, Subs}}) ->
            {At, Name, micros(Elapsed), Bytes, length(lists:usort([S || {S, _} <- Subs]))}
        end,
        numbered(Times)
    ).

%% The compiler records every sub pass invocation separately, because they run
%% once per function rather than once per module, and folds them only when it
%% prints. The fold is done here as well so the tape can be checked against what
%% `erlc +time' shows, and the number of invocations is kept alongside, because
%% that is the fact the printed output throws away. A sub pass that ran two
%% hundred times on a three function module is a different thing from one that
%% ran once, and only one of those two facts survives printing.
%%
%% Slowest first, which is the order the compiler prints them in. Ordering by
%% time is not a judgement about which one matters, it is the only ordering the
%% source data supports, since the invocations arrive interleaved.
sub_passes(Times) ->
    lists:append([
        [
            {At, Parent, Name, micros(Total), Runs}
         || {Name, Total, Runs} <- fold(Subs)
        ]
     || {At, {Parent, _, _, Subs}} <- numbered(Times), Subs =/= []
    ]).

fold(Subs) ->
    Summed = lists:foldl(
        fun({Name, Elapsed}, Acc) ->
            maps:update_with(Name, fun({T, N}) -> {T + Elapsed, N + 1} end, {Elapsed, 1}, Acc)
        end,
        #{},
        Subs
    ),
    Flat = [{Name, Total, Runs} || {Name, {Total, Runs}} <- maps:to_list(Summed)],
    lists:reverse(lists:keysort(2, Flat)).

numbered(Items) -> lists:zip(lists:seq(1, length(Items)), Items).

micros(Native) -> erlang:convert_time_unit(Native, native, microsecond).

%% ---------------------------------------------------------------------------
%% The intermediate forms
%%
%% Each stopping point needs its own compile, because a compile can only stop
%% once. That is not a cost worth avoiding: these modules are small and the
%% alternative is reaching inside the pipeline, which would make the tape a
%% recording of our own cleverness rather than of the compiler.
%%
%% Which file a stopping point writes is not guessed at. `to_core' writes
%% l1.core and `to_asm' writes l1.S, but `to_exp' writes l1.abstr under the same
%% name `to_abstr' uses, `dexp' writes l1.expand, and `to_dis' writes a beam
%% file as well as the listing. So the compile runs into an empty directory and
%% whatever turns up in it is the answer. Beam files are dropped, because a beam
%% file is the output rather than a stage on the way to it.
capture(Source, Stage, Extra) ->
    in_a_temp_dir(fun(Dir) ->
        case compile:file(Source, [Stage, {outdir, Dir}, return_errors | Extra]) of
            {error, Errors, _Warnings} ->
                error({bxtrace_pass, {will_not_compile, Source, Stage, Errors}});
            _ ->
                case [F || F <- filelib:wildcard(filename:join(Dir, "*")), filename:extension(F) =/= ".beam"] of
                    [] -> error({bxtrace_pass, {stage_wrote_nothing, Stage}});
                    Files -> [{list_to_binary(filename:basename(F)), read(F)} || F <- lists:sort(Files)]
                end
        end
    end).

read(File) ->
    {ok, Bytes} = file:read_file(File),
    Bytes.

in_a_temp_dir(Fun) ->
    Dir = filename:join(scratch(), io_lib:format("bxtrace-pass-~b", [erlang:unique_integer([positive])])),
    ok = filelib:ensure_path(Dir),
    try
        Fun(Dir)
    after
        [file:delete(F) || F <- filelib:wildcard(filename:join(Dir, "*"))],
        file:del_dir(Dir)
    end.

scratch() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Set -> Set
    end.

compiler_version() ->
    list_to_binary(filename:basename(code:lib_dir(compiler))).

%% ---------------------------------------------------------------------------
%% Writing
%%
%% Source first, then the passes in the order they ran, then the sub passes
%% under the index of the pass they belong to, then the intermediate forms.
%%
%% A stage's text goes on the tape as one binary, so a listing of two hundred
%% lines is one line of tape with its newlines escaped. That looks odd the first
%% time and it is the rule the whole format rests on: a reader is allowed to
%% stop after one line, so one term is one line whatever the term holds.
write_all(Tape, Module, Text, Passes, SubPasses, Captured) ->
    Rows =
        [{source, Module, Text}] ++
            [{pass, At, Name, Micros, Bytes, Subs} || {At, Name, Micros, Bytes, Subs} <- Passes] ++
            [{subpass, At, Parent, Name, Micros, Runs} || {At, Parent, Name, Micros, Runs} <- SubPasses] ++
            [
                {stage, Stage, File, Body}
             || {Stage, Files} <- Captured, {File, Body} <- Files
            ],
    lists:foldl(fun(Row, Acc) -> bxtrace_tape:write(Acc, Row) end, Tape, Rows).
