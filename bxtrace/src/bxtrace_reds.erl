%% The reduction tape.
%%
%% Every scheduling event for a workload: when each process was scheduled in,
%% when it was scheduled out, which scheduler it ran on, what it was running,
%% and every garbage collection in between.
%%
%% This is the first of the three tapes and the one the project's opening figure
%% is drawn from. The claim that figure makes is that a process stops running for
%% several different reasons and that running out of budget is not the most
%% common one. A tape is how that claim stops being folklore.
%%
%% The recorder is deliberately dull. It sets trace flags, it collects messages,
%% it writes a file. Working out why a process stopped is not done here, because
%% that is a judgement and judgements belong somewhere they can be argued with.
%% The tape carries the facts a judgement would need.
%%
%% Tracing goes on before the workload is spawned and not after. Spawning first
%% is a race: the worker can be scheduled out before tracing is switched on, and
%% whether that shows up depends on which of the two wins. The t07 lesson made
%% exactly this mistake and it cost a rewrite, so it is stated here.
%%
%% There is no reduction count on each boundary, and bxtrace/README.md has the
%% measurement that says why. The short version is that reading another
%% process's reduction count is a signal round trip, which puts the collector so
%% far behind that by the time it asks, the process it wanted to ask about has
%% exited. What the tape does carry is the workload's own total, read by the
%% workload itself, which is exact and costs nothing.

-module(bxtrace_reds).

-export([record/2]).

%% What running looks like, plus the scheduler the process ran on and a
%% timestamp on every message. `procs' is in there for spawn and exit, which is
%% how a tape can say a process existed at all.
-define(FLAGS, [running, garbage_collection, procs, scheduler_id, monotonic_timestamp]).

%% A recorder that hangs is worse than one that records nothing, because nobody
%% is watching it.
-define(DEFAULT_LIMIT, 60000).

%% record(Path, Opts) runs the workload with the tracing on and writes the tape.
%%
%%   #{by_whom => "tamnd",
%%     why     => "the opening figure for t07",
%%     run     => fun() -> spinners(4, 200000) end,
%%     for     => 60000}          milliseconds before the workload is given up on
record(Path, Opts) ->
    Run = maps:get(run, Opts),
    ByWhom = maps:get(by_whom, Opts),
    Why = maps:get(why, Opts),
    Limit = maps:get(for, Opts, ?DEFAULT_LIMIT),

    %% Spawned before the tracing goes on, so that the collector is not one of
    %% the processes it is collecting.
    Collector = spawn_link(fun() -> collect([], 0) end),

    erlang:trace(new_processes, true, ?FLAGS ++ [{tracer, Collector}]),
    {Outcome, Value, Worker, Spent} = drive(Run, Limit),
    erlang:trace(new_processes, false, ?FLAGS),

    %% Every trace message generated before this point has reached the collector
    %% by the time the reply arrives. Without it the tail of the recording is
    %% whatever happened to have been delivered, which is a different tape on
    %% every run.
    Delivered = erlang:trace_delivered(all),
    receive
        {trace_delivered, all, Delivered} -> ok
    end,

    {Raw, Peak} = stop(Collector),
    {Procs, Events} = digest(Raw),
    untrace(Procs),

    %% Which index on the tape is the workload. Everything else on a tape is
    %% whatever else the machine was doing, and a reader who cannot tell the two
    %% apart is reading noise.
    Index = maps:get(Worker, Procs, unknown),

    Header = maps:merge(
        bxtrace_tape:header(reds, ByWhom, Why),
        #{
            flags => ?FLAGS,
            worker => Index,
            outcome => Outcome,
            time_unit => microsecond,
            %% The deepest the collector's mailbox got. Zero means it kept up
            %% with the run, and anything large means the timestamps are still
            %% exact but the run was being watched by something that could not
            %% keep up, which is worth knowing before drawing conclusions from
            %% the gaps.
            peak_lag => Peak
        }
    ),
    {ok, Tape} = bxtrace_tape:open(Path, Header),
    Written = write_all(Tape, Procs, Events, Index, Spent),
    {ok, Path, Count} = bxtrace_tape:close(Written),
    {ok, #{
        path => Path,
        events => Count,
        procs => map_size(Procs),
        worker => Index,
        spent => Spent,
        peak_lag => Peak,
        outcome => Outcome,
        value => Value
    }}.

%% The workload runs in a process of its own so that the recorder is not the
%% thing being recorded. A crash is recorded rather than raised, because a tape
%% of a run that fell over is often the tape somebody wanted.
%%
%% The reduction count is read by the workload about itself, one line after the
%% work finishes. That read is exact and costs a handful of reductions, which is
%% the whole difference between asking a process about itself and asking it
%% about somebody else.
drive(Run, Limit) ->
    Parent = self(),
    Worker = spawn(fun() ->
        Result =
            try Run() of
                Value -> {finished, Value}
            catch
                Class:Reason -> {crashed, text(Class), text(Reason)}
            end,
        {reductions, Spent} = process_info(self(), reductions),
        Parent ! {worker_done, self(), Result, Spent}
    end),
    receive
        {worker_done, Worker, {finished, Value}, Spent} ->
            {finished, Value, Worker, Spent};
        {worker_done, Worker, {crashed, Class, Reason}, Spent} ->
            {{crashed, Class, Reason}, undefined, Worker, Spent}
    after Limit ->
        exit(Worker, kill),
        {timeout, undefined, Worker, unknown}
    end.

untrace(Procs) ->
    maps:foreach(
        fun(Pid, _) ->
            %% A dead process cannot be untraced and does not need to be.
            try erlang:trace(Pid, false, ?FLAGS) of
                _ -> ok
            catch
                error:badarg -> ok
            end
        end,
        Procs
    ).

%% ---------------------------------------------------------------------------
%% The collector
%%
%% This does as little as a process can do and still be said to be collecting.
%% Every message is kept as it arrived, with the depth of the mailbox at that
%% moment, and nothing is looked up, indexed or converted. All of that happens
%% after the run, where being slow costs nothing.
%%
%% The reason for the discipline is that a tracer process is scheduled like any
%% other, so work done here is work done in the middle of the thing being
%% measured. The first version of this called process_info twice per event and
%% ended up a hundred messages behind on a workload of one spinning process.

collect(Kept, Peak) ->
    receive
        {stop, From, Ref} ->
            From ! {Ref, lists:reverse(Kept), Peak};
        Message when element(1, Message) =:= trace_ts ->
            {message_queue_len, Lag} = process_info(self(), message_queue_len),
            collect([{Message, Lag} | Kept], max(Peak, Lag));
        _Other ->
            collect(Kept, Peak)
    end.

stop(Collector) ->
    Ref = make_ref(),
    Collector ! {stop, self(), Ref},
    receive
        {Ref, Kept, Peak} -> {Kept, Peak}
    end.

%% ---------------------------------------------------------------------------
%% Turning messages into events, after the run

digest(Raw) ->
    {Events, {Procs, _Next}} = lists:mapfoldl(fun one/2, {#{}, 1}, Raw),
    {Procs, Events}.

%% Every trace message with a scheduler id and a timestamp has the same shape at
%% both ends: the pid second, the tag third, the timestamp last, the scheduler
%% id before it, and whatever the tag carries in between. `spawned' carries two
%% things and `in' carries one, so the middle is taken as a list rather than
%% matched per tag. A new trace tag then lands on the tape instead of being
%% dropped by a clause nobody wrote.
one({Message, Lag}, State) ->
    Size = tuple_size(Message),
    Time = element(Size, Message),
    Scheduler = element(Size - 1, Message),
    Pid = element(2, Message),
    Tag = element(3, Message),
    Info = [element(I, Message) || I <- lists:seq(4, Size - 2)],

    {Index, State1} = index(Pid, State),
    {Softened, State2} = soften(Info, State1),
    {{event, Index, Time, Tag, Scheduler, Lag, Softened}, State2}.

%% A pid gets a number the first time the tape mentions it, and that number is
%% what every later event uses. The pid itself is written once, as text, in the
%% process table at the top of the tape. That is the whole reason a tape can be
%% read on a machine where none of these processes ever existed.
index(Pid, {Procs, Next}) when is_pid(Pid) ->
    case Procs of
        #{Pid := Index} -> {Index, {Procs, Next}};
        _ -> {Next, {Procs#{Pid => Next}, Next + 1}}
    end.

%% Trace messages carry live terms. A spawn carries the fun that was spawned, a
%% link carries the pid on the other end, and none of that survives being
%% written down. Pids become their index, so the tape stays internally
%% consistent, and everything else becomes the text the shell would have shown.
soften(Term, State) when is_pid(Term) ->
    {Index, Next} = index(Term, State),
    {{p, Index}, Next};
soften(Term, State) when is_port(Term) ->
    {{port, text(Term)}, State};
soften(Term, State) when is_reference(Term) ->
    {{ref, text(Term)}, State};
soften(Term, State) when is_function(Term) ->
    {{'fun', text(Term)}, State};
soften(Term, State) when is_list(Term) ->
    soften_list(Term, State, []);
soften(Term, State) when is_tuple(Term) ->
    {Items, Next} = soften_list(tuple_to_list(Term), State, []),
    {list_to_tuple(Items), Next};
soften(Term, State) when is_map(Term) ->
    {Pairs, Next} = soften_list(maps:to_list(Term), State, []),
    {maps:from_list(Pairs), Next};
soften(Term, State) ->
    {Term, State}.

soften_list([], State, Done) ->
    {lists:reverse(Done), State};
soften_list([Head | Tail], State, Done) ->
    {Soft, Next} = soften(Head, State),
    case is_list(Tail) of
        true ->
            soften_list(Tail, Next, [Soft | Done]);
        false ->
            %% An improper list stays improper. Quietly turning [a | b] into
            %% [a, b] would be a tape saying something the run did not.
            {SoftTail, Last} = soften(Tail, Next),
            {lists:reverse([Soft | Done], SoftTail), Last}
    end.

text(Term) when is_binary(Term) -> Term;
text(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).

%% ---------------------------------------------------------------------------
%% Writing

%% The process table first, so a reader meets every index before any event uses
%% one, then what the workload spent, then the events.
%%
%% The events are sorted by the timestamp the VM put on them, which is not the
%% order they were delivered in. Two schedulers write to the collector's mailbox
%% at once and neither waits for the other, so delivery order is a fact about
%% the mailbox and the timestamp is a fact about the run. The sort is stable, so
%% events sharing a timestamp keep the order they arrived in.
%%
%% Time is counted from the first event. Absolute monotonic time is a large
%% negative number that means nothing off this machine, and two tapes recorded
%% an hour apart are far easier to compare when both start at zero.
write_all(Tape, Procs, Events, Worker, Spent) ->
    Ordered = lists:keysort(1, [{Index, Pid} || {Pid, Index} <- maps:to_list(Procs)]),
    WithProcs = lists:foldl(
        fun({Index, Pid}, Acc) -> bxtrace_tape:write(Acc, {proc, Index, text(Pid), label(Pid, Index, Worker)}) end,
        Tape,
        Ordered
    ),
    WithSpent = bxtrace_tape:write(WithProcs, {spent, Worker, Spent}),
    case lists:keysort(3, Events) of
        [] ->
            WithSpent;
        [{event, _, First, _, _, _, _} | _] = Sorted ->
            lists:foldl(
                fun(Event, Acc) -> bxtrace_tape:write(Acc, relative(Event, First)) end,
                WithSpent,
                Sorted
            )
    end.

%% Whatever the process can still say about itself, which is nothing once it has
%% exited. Most of the interesting ones have exited by the time this runs, and
%% the label is a convenience rather than evidence, so best effort is the right
%% amount of effort. What a process was is on the tape anyway, in the fun its
%% spawn event carries.
%%
%% The workload is the exception and gets named outright. It is the one process
%% on the tape a reader came for, it has almost always finished and exited by
%% the time anything can be asked of it, and asking would only ever get back
%% erlang:apply/2 because it was spawned as a fun.
label(_Pid, Index, Index) ->
    <<"the workload">>;
label(Pid, _Index, _Worker) ->
    case process_info(Pid, [registered_name, initial_call]) of
        [{registered_name, Name} | _] when Name =/= [] ->
            text(Name);
        [_, {initial_call, {M, F, A}}] ->
            unicode:characters_to_binary(io_lib:format("~w:~w/~w", [M, F, A]));
        _ ->
            <<"gone before it could be asked">>
    end.

relative({event, Index, Time, Tag, Scheduler, Lag, Info}, First) ->
    Micros = erlang:convert_time_unit(Time - First, native, microsecond),
    {event, Index, Micros, Tag, Scheduler, Lag, Info}.
