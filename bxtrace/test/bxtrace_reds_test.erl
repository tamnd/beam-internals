%% The reduction tape recorder, checked against workloads whose cost is known.
%%
%% A recorder is hard to test because the thing it records is the thing you
%% would use to check it. The way out is a workload whose reduction count can be
%% worked out on paper: a tail recursive loop of N iterations costs N reductions
%% and nothing else. If the tape says something far from N then the tape is
%% wrong, and if it says something within a handful of N then the difference is
%% the call into the loop, the read that follows it, and which flavor of
%% emulator is running, all of which are worked out in what_it_cost/0 below.
-module(bxtrace_reds_test).

-export([cases/0]).
%% Spawned into the workload, so it has to be callable from outside.
-export([spin/1, grow/2]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

%% The loop the cost claims are made about.
-define(SPIN, 200000).

%% The default scheduler slice, and the floor the cost has to clear. The
%% interpreter charges one reduction less per slice than the JIT does, so a loop
%% this long comes out about fifty short there. See what_it_cost/0 below.
-define(SLICE, 4000).
-define(FLOOR, ?SPIN - (?SPIN div ?SLICE) - 10).

cases() ->
    [
        {"a recording reads back as a tape", fun reads_back/0},
        {"the header says how it was recorded", fun header/0},
        {"every index an event uses is in the process table", fun indexes_resolve/0},
        {"the worker was scheduled in and scheduled out", fun in_and_out/0},
        {"time starts at zero and never goes backwards", fun timeline/0},
        {"the tape says what the loop cost, to the reduction", fun what_it_cost/0},
        {"the cost barely moves from one run to the next", fun the_cost_is_stable/0},
        {"an allocating workload leaves garbage collections on the tape", fun collections/0},
        {"a workload that crashes still produces a tape", fun crashing/0},
        {"a workload that overruns is given up on and the tape says so", fun overrunning/0},
        {"the tape names the schedulers the work ran on", fun schedulers/0},
        {"every event carries how far behind the collector was", fun lag/0},
        {"nothing on the tape is a live term", fun no_live_terms/0}
    ].

%% ---------------------------------------------------------------------------
%% Workloads

%% Exactly N reductions, and the reason it is exactly N is the subject of t07.
spin(0) -> ok;
spin(N) -> spin(N - 1).

grow(0, Acc) -> length(Acc);
grow(N, Acc) -> grow(N - 1, [{N, N} | Acc]).

%% ---------------------------------------------------------------------------
%% Recording

scratch(Name) ->
    Dir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
    filename:join(Dir, io_lib:format("bxtrace-reds-~ts-~b.tape.gz", [Name, erlang:unique_integer([positive])])).

with_recording(Name, Opts, Fun) ->
    Path = scratch(Name),
    Base = #{by_whom => "tamnd", why => "the reduction tape tests"},
    {ok, Result} = bxtrace_reds:record(Path, maps:merge(Base, Opts)),
    {ok, Header, Events} = bxtrace_tape:read(Path),
    try
        Fun(Header, Events, Result)
    after
        file:delete(Path)
    end.

%% One spinner, which is the smallest workload that produces a real tape.
one_spinner(Name, Opts, Fun) ->
    with_recording(Name, Opts#{run => fun() -> ?MODULE:spin(?SPIN) end}, Fun).

events(Events) -> [E || E <- Events, element(1, E) =:= event].
procs(Events) -> [P || P <- Events, element(1, P) =:= proc].

tags(Events) -> lists:usort([Tag || {event, _, _, Tag, _, _, _} <- events(Events)]).

%% Which index on the tape ran the workload. The recorder says so, in the header
%% and in what it returns, because working it out from the outside means
%% guessing which of a dozen processes was the one you asked for.
worker(Header) -> maps:get(worker, Header).

%% What the workload spent, as the tape records it.
spent(Events) ->
    [Reductions] = [R || {spent, _, R} <- Events],
    Reductions.

%% ---------------------------------------------------------------------------
%% Cases

reads_back() ->
    one_spinner("reads-back", #{}, fun(_Header, Events, Result) ->
        ct_assert:is_true("there are events", length(events(Events)) > 0),
        ct_assert:is_true("there are processes", length(procs(Events)) > 0),
        ct_assert:is_true("the workload has an index", is_integer(maps:get(worker, Result))),
        ?EQ("the outcome", finished, maps:get(outcome, Result))
    end).

header() ->
    one_spinner("header", #{}, fun(Header, _Events, _Result) ->
        ?EQ("the kind", reds, maps:get(kind, Header)),
        ?EQ("the time unit", microsecond, maps:get(time_unit, Header)),
        ?EQ("the outcome", finished, maps:get(outcome, Header)),
        ct_assert:is_true("the deepest the collector fell behind", is_integer(maps:get(peak_lag, Header))),
        ct_assert:is_true("the flags are recorded", lists:member(running, maps:get(flags, Header)))
    end).

%% The point of the index. A tape whose events mention a process the tape does
%% not introduce is a tape a reader cannot draw.
indexes_resolve() ->
    one_spinner("indexes", #{}, fun(_Header, Events, _Result) ->
        Known = [Index || {proc, Index, _, _} <- procs(Events)],
        Used = lists:usort([Index || {event, Index, _, _, _, _, _} <- events(Events)]),
        ?EQ("indexes used but never introduced", [], Used -- Known)
    end).

in_and_out() ->
    one_spinner("in-and-out", #{}, fun(Header, Events, _Result) ->
        Worker = worker(Header),
        Mine = [Tag || {event, Index, _, Tag, _, _, _} <- events(Events), Index =:= Worker],
        ct_assert:is_true("the worker was scheduled in", lists:member(in, Mine)),
        ct_assert:is_true("the worker was scheduled out", lists:member(out, Mine)),
        %% Two hundred thousand reductions is fifty budgets, so it cannot have
        %% run in one slice on any machine.
        Outs = length([Tag || Tag <- Mine, Tag =:= out]),
        ct_assert:is_true("it was scheduled out more than once", Outs > 1)
    end).

timeline() ->
    one_spinner("time", #{}, fun(_Header, Events, _Result) ->
        Times = [Micros || {event, _, Micros, _, _, _, _} <- events(Events)],
        ?EQ("the first event is at zero", 0, hd(Times)),
        ?EQ("time never goes backwards", lists:sort(Times), Times)
    end).

%% The one that says the recorder measures what it claims to.
%%
%% A tail recursive loop of two hundred thousand iterations costs two hundred
%% thousand and one reductions, one per call including the call that hits the
%% base clause. Around it sit the fun the recorder was handed, the call into
%% this module, and the process_info read that collects the number, and those
%% are small and countable rather than noise.
%%
%% The floor sits a little under the iteration count, and that gap is a real
%% difference between the two flavors rather than slack. Under the JIT this loop
%% costs 200003, the same number on every run of every machine here. Under an
%% emulator built `--disable-jit' it costs 199955, and the shortfall is not
%% noise either: it grows by exactly one for every four thousand iterations,
%% which is the default slice, so the interpreter is charging one reduction less
%% each time the loop is scheduled out and back in. Measured at four thousand,
%% fifty thousand, two hundred thousand, four hundred thousand and eight hundred
%% thousand iterations, where the difference from the iteration count ran +4, -7,
%% -45, -95 and -195.
%%
%% So the floor allows one lost reduction per slice and a handful either way,
%% which is still narrow enough that a recorder reading the wrong process fails
%% it by two orders of magnitude.
what_it_cost() ->
    one_spinner("cost", #{}, fun(_Header, Events, Result) ->
        Spent = spent(Events),
        ?EQ("what the tape says and what the recorder returned", Spent, maps:get(spent, Result)),
        ct_assert:is_true("the loop cost about what its iterations cost", Spent >= ?FLOOR),
        ct_assert:is_true("and barely more than that", Spent =< ?SPIN + 100)
    end).

%% Reading a process's own reduction count is exact, so the answer does not
%% wander with load, scheduling, or how far behind the collector happened to
%% fall. That is the whole reason the number is read there and not in the
%% tracer, and a run to run spread of a few reductions makes the point far
%% better than one run landing inside a band.
%%
%% It is a few rather than none. Ten runs on macOS and aarch64 gave 200006 to
%% 200012, and ten on Linux and x86-64 gave 200006 to 200014, while the
%% collector's own lag over those same runs swung from 2 to 82 on the first
%% machine and stayed between 2 and 5 on the second. The workload's number holds
%% to within eight either way, which is the thing being claimed here: a number
%% read from inside a process does not care how the recorder is doing.
the_cost_is_stable() ->
    Costs = [
        one_spinner("stable", #{}, fun(_Header, Events, _Result) -> spent(Events) end)
     || _ <- lists:seq(1, 5)
    ],
    Spread = lists:max(Costs) - lists:min(Costs),
    ct_assert:is_true("the spread across five runs is a handful", Spread =< 100).

collections() ->
    with_recording(
        "gc",
        #{run => fun() -> ?MODULE:grow(50000, []) end},
        fun(_Header, Events, _Result) ->
            Tags = tags(Events),
            ct_assert:is_true("a minor collection was recorded", lists:member(gc_minor_start, Tags))
        end
    ).

crashing() ->
    with_recording(
        "crash",
        #{run => fun() -> error(deliberate) end},
        fun(Header, Events, Result) ->
            {crashed, Class, Reason} = maps:get(outcome, Result),
            ?EQ("the class", <<"error">>, Class),
            ct_assert:is_true("the reason is on the tape's header", is_binary(Reason)),
            ct_assert:is_true("the header agrees", element(1, maps:get(outcome, Header)) =:= crashed),
            ct_assert:is_true("and there is still a tape", events(Events) =/= [])
        end
    ).

overrunning() ->
    with_recording(
        "overrun",
        #{run => fun() -> timer:sleep(infinity) end, for => 200},
        fun(Header, Events, Result) ->
            ?EQ("the outcome", timeout, maps:get(outcome, Result)),
            ?EQ("the header agrees", timeout, maps:get(outcome, Header)),
            %% A process that was killed never got to read its own count, and
            %% the tape says that rather than putting a zero there.
            ?EQ("what it spent", unknown, spent(Events))
        end
    ).

schedulers() ->
    one_spinner("schedulers", #{}, fun(_Header, Events, _Result) ->
        Schedulers = lists:usort([S || {event, _, _, _, S, _, _} <- events(Events)]),
        ct_assert:is_true(
            "every scheduler id is a positive integer",
            lists:all(fun(S) -> is_integer(S) andalso S > 0 end, Schedulers)
        )
    end).

%% The lag column is how a reader tells a gap in the timeline from a gap in the
%% recording. It has to be on every event for that to work.
lag() ->
    one_spinner("lag", #{}, fun(Header, Events, _Result) ->
        Lags = [Lag || {event, _, _, _, _, Lag, _} <- events(Events)],
        ct_assert:is_true("every event carries one", lists:all(fun is_integer/1, Lags)),
        ?EQ("and the header carries the deepest of them", lists:max(Lags), maps:get(peak_lag, Header))
    end).

%% The writer refuses a live term, so a recording that completes has already
%% proved this. Checking it here as well is worth the three lines, because the
%% failure it guards against is one where a recorder starts dropping events to
%% avoid the refusal.
no_live_terms() ->
    one_spinner("portable", #{}, fun(_Header, Events, _Result) ->
        ?EQ("terms that cannot be written down", ok, bxtrace_tape:portable(Events))
    end).
