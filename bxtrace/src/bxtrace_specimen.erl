%% The crash dump specimens, and the recipe for each one.
%%
%% A crash dump is the only evidence you get from a node that is already dead,
%% so reading one is a skill, and a skill needs examples. Fourteen of them here,
%% each produced by a child node that is made to die in a particular way.
%%
%% Two groups, and the difference matters. Eight of them die of different
%% causes: a deliberate halt, an uncaught exit during boot, a resource table
%% filling up, a signal from an operator, a supervision failure. Six of them die
%% the same way the first one does, but with the node in a different state:
%% thousands of processes alive, a dirty scheduler mid job, one process holding
%% an enormous heap, a mailbox nobody is reading. The second group is what shows
%% which parts of a dump are about the cause of death and which parts are there
%% every time.
%%
%% What gets kept is the tape, not the dump. A stock dump is about 1.8 MB and
%% most of that is heap and atom text that means nothing without the machine it
%% came from. Fourteen of them would be thirty megabytes of near identical hex
%% in a repository of prose. The tape is the dump indexed: every section, every
%% fact, every line of every section that is not a blob, and a digest and a line
%% count for the blobs. About a hundred kilobytes, and it holds every fact a
%% lesson would quote.
%%
%% Each specimen declares what it expects to see, and the recorder checks the
%% dump against that before writing a tape. A specimen that stops reproducing
%% its own cause, because a later release changed a slogan or stopped writing a
%% section, fails at record time rather than three lessons later.

-module(bxtrace_specimen).

-export([all/0, names/0, find/1, record/3, check/2]).

%% How long to wait for a child node to die and finish writing. Writing 1.8 MB
%% takes well under a second, and the slowest specimen here is the atom table
%% filling, which is a few seconds of work before the abort. Sixty is not a
%% budget, it is a limit that says something is wrong.
-define(PATIENCE, 60000).

%% ---------------------------------------------------------------------------
%% The specimens

all() ->
    causes() ++ states().

%% Eight nodes that died of eight different things.
causes() ->
    [
        #{
            name => "halt-slogan",
            why => "the simplest dump there is, a deliberate halt with a string",
            eval => "erlang:halt(\"a deliberate halt, the shortest path to a dump\").",
            expect => #{
                slogan => <<"a deliberate halt, the shortest path to a dump">>,
                complete => true,
                kinds => [erl_crash_dump, proc, scheduler, memory, 'end']
            }
        },
        #{
            name => "halt-term",
            why => "a halt whose slogan is a formatted term rather than a sentence",
            eval =>
                "erlang:halt(lists:flatten(io_lib:format(\"~p\", "
                "[{shutting_down, [{reason, asked_to}, {by, an_operator}]}]))).",
            expect => #{
                slogan => <<"{shutting_down,[{reason,asked_to},{by,an_operator}]}">>,
                complete => true,
                kinds => [erl_crash_dump, proc]
            }
        },
        #{
            name => "boot-exit",
            why => "an uncaught exit before the node finished starting",
            eval => "exit({no_such_config, \"sys.config\"}).",
            expect => #{
                slogan_starts => <<"Runtime terminating during boot ({no_such_config,">>,
                complete => true,
                kinds => [erl_crash_dump, proc]
            }
        },
        #{
            name => "kernel-pid-terminated",
            why => "a system process killed, which the kernel does not survive",
            eval => "exit(whereis(application_controller), kill), timer:sleep(30000).",
            expect => #{
                slogan_starts => <<"Kernel pid terminated (application_controller)">>,
                complete => true,
                kinds => [erl_crash_dump, proc]
            }
        },
        #{
            name => "atom-table-full",
            why => "the atom table filled, one of the aborts the VM raises itself",
            flags => ["+t", "16384"],
            eval =>
                "lists:foreach(fun(N) -> list_to_atom(\"bxtrace_atom_\" ++ "
                "integer_to_list(N)) end, lists:seq(1, 100000)), init:stop().",
            expect => #{
                slogan => <<"no more index entries in atom_tab (max=16384)">>,
                complete => true,
                kinds => [erl_crash_dump, atoms, index_table]
            }
        },
        #{
            name => "port-table-full",
            why => "the port table filled, so the dump has a full port table to read",
            flags => ["+Q", "1024"],
            eval =>
                "lists:foreach(fun(_) -> erlang:open_port({spawn_driver, \"udp_inet\"}, "
                "[binary]) end, lists:seq(1, 100000)), init:stop().",
            expect => #{
                slogan_starts => <<"Runtime terminating during boot ({system_limit,">>,
                complete => true,
                kinds => [erl_crash_dump, port],
                %% Well under the 1024 asked for, on purpose. The emulator keeps
                %% slots for itself and the table is sized in powers of two, so
                %% the number of ports a full table actually holds is not the
                %% number on the command line. The floor here only has to be
                %% far enough above the one port a stock node has to prove the
                %% table filled.
                at_least => #{port => 500}
            }
        },
        #{
            name => "sigusr1",
            why => "a dump asked for by an operator with a signal, on a node that was fine",
            eval => "timer:sleep(60000).",
            signal => "USR1",
            expect => #{
                slogan => <<"Received SIGUSR1">>,
                complete => true,
                kinds => [erl_crash_dump, proc, scheduler]
            }
        },
        #{
            name => "truncated",
            why => "a dump that stops mid section, because the byte budget ran out",
            env => [{"ERL_CRASH_DUMP_BYTES", "200000"}],
            eval => "erlang:halt(\"a halt under a byte budget\").",
            expect => #{
                slogan => <<"a halt under a byte budget">>,
                complete => false,
                kinds => [erl_crash_dump]
            }
        }
    ].

%% Six nodes that died the same way, doing six different things at the time.
states() ->
    [
        #{
            name => "many-processes",
            why => "a halt with two thousand processes alive, so the process table is the dump",
            eval =>
                "lists:foreach(fun(_) -> spawn(fun() -> receive after infinity -> ok end end) end, "
                "lists:seq(1, 2000)), erlang:halt(\"a halt with two thousand processes alive\").",
            expect => #{
                slogan => <<"a halt with two thousand processes alive">>,
                complete => true,
                kinds => [proc, proc_heap, proc_stack],
                at_least => #{proc => 2000}
            }
        },
        #{
            name => "dirty-scheduler",
            why => "a halt while a dirty CPU scheduler is in the middle of a job",
            eval =>
                "spawn(fun() -> erts_debug:dirty_cpu(wait, 20000) end), timer:sleep(500), "
                "erlang:halt(\"a halt while a dirty scheduler is busy\").",
            expect => #{
                slogan => <<"a halt while a dirty scheduler is busy">>,
                complete => true,
                kinds => [scheduler, proc | dirty_sections()],
                must_contain => [<<"DIRTY_RUNNING">>, <<"Last scheduled in for: erts_debug:dirty_cpu/2">>]
            }
        },
        #{
            name => "large-heap",
            why => "a halt with one process holding a two million element list",
            eval =>
                "spawn(fun() -> L = lists:seq(1, 2000000), receive stop -> L end end), "
                "timer:sleep(3000), erlang:halt(\"a halt with one very large heap\").",
            expect => #{
                slogan => <<"a halt with one very large heap">>,
                complete => true,
                kinds => [proc, proc_heap]
            }
        },
        #{
            name => "long-message-queue",
            why => "a halt with fifty thousand messages queued for a process that is not reading",
            eval =>
                "P = spawn(fun() -> timer:sleep(infinity) end), "
                "lists:foreach(fun(N) -> P ! {work, N} end, lists:seq(1, 50000)), "
                "timer:sleep(1000), erlang:halt(\"a halt with a mailbox nobody is reading\").",
            expect => #{
                slogan => <<"a halt with a mailbox nobody is reading">>,
                complete => true,
                kinds => [proc, proc_messages]
            }
        },
        #{
            name => "many-ets-tables",
            why => "a halt with five hundred ETS tables holding rows",
            eval =>
                "lists:foreach(fun(N) -> T = ets:new(t, [public]), "
                "ets:insert(T, [{K, N} || K <- lists:seq(1, 100)]) end, lists:seq(1, 500)), "
                "erlang:halt(\"a halt with five hundred ets tables\").",
            expect => #{
                slogan => <<"a halt with five hundred ets tables">>,
                complete => true,
                kinds => [ets],
                at_least => #{ets => 500}
            }
        },
        #{
            name => "distributed",
            why => "a halt on a node that was connected to another one",
            distributed => true,
            expect => #{
                slogan => <<"a halt while connected to another node">>,
                complete => true,
                kinds => [node, visible_node]
            }
        }
    ].

%% A crash dump carries the dirty schedulers and their run queues only where the
%% emulator can wrap the walk over them in its home made try catch, built out of
%% signal handlers. It cannot do that on Apple platforms, so the condition at
%% erts/emulator/sys/unix/erl_unix_sys.h:406@OTP-29.0.5 leaves ERTS_HAVE_TRY_CATCH
%% undefined there, and the whole block that prints them, from
%% erts/emulator/beam/erl_crash_dump.c:616@OTP-29.0.5 down, is compiled out. A
%% dump from macOS has ten =scheduler sections and not one dirty one.
%%
%% What survives everywhere is in the process section. The process running the
%% dirty job is DIRTY_RUNNING and its last scheduled call is the dirty BIF, so
%% that is what the specimen insists on regardless of where it was recorded.
dirty_sections() ->
    case os:type() of
        {unix, darwin} -> [];
        _ -> [dirty_cpu_scheduler, dirty_cpu_run_queue, dirty_io_scheduler, dirty_io_run_queue]
    end.

names() ->
    [maps:get(name, Spec) || Spec <- all()].

find(Name) ->
    case [Spec || Spec <- all(), maps:get(name, Spec) =:= Name] of
        [Spec] -> {ok, Spec};
        [] -> not_found
    end.

%% ---------------------------------------------------------------------------
%% Producing one and recording it
%%
%% The dump goes to a temporary file and is deleted afterwards. It is the tape
%% that is kept, and the recipe above is what makes the dump reproducible.

record(Spec, TapePath, ByWhom) ->
    Dump = temp_dump(maps:get(name, Spec)),
    try
        ok = produce(Spec, Dump),
        ok = check(Spec, Dump),
        bxtrace_post:record(TapePath, #{
            dump => Dump,
            by_whom => ByWhom,
            why => maps:get(why, Spec)
        })
    after
        file:delete(Dump)
    end.

produce(#{distributed := true} = Spec, Dump) ->
    with_peer(fun(Peer) ->
        Eval = lists:flatten(
            io_lib:format(
                "true = net_kernel:connect_node('~ts'), timer:sleep(500), "
                "erlang:halt(\"a halt while connected to another node\").",
                [Peer]
            )
        ),
        run(Spec#{eval => Eval, flags => ["-name", "bxtrace-dumper@127.0.0.1", "-setcookie", "bxtrace"]}, Dump)
    end);
produce(Spec, Dump) ->
    run(Spec, Dump).

%% A node the specimen can connect to, so the dump has somebody on the other end
%% of the distribution sections.
%%
%% It is a second child rather than this VM. Turning this VM distributed with
%% net_kernel:start/1 works on a developer machine and does not work in a
%% container, where the same call comes back as nodistribution while `erl -name'
%% starts up fine. Starting a child the ordinary way avoids the whole question.
%%
%% The name is an address rather than a hostname, so the node name that ends up
%% on the tape is the same wherever the specimen is recorded, and nobody's
%% machine name gets published along with it.
with_peer(Body) ->
    Name = "bxtrace-peer@127.0.0.1",
    Ready = temp_dump("peer-ready"),
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Eval = lists:flatten(
        io_lib:format("file:write_file(\"~ts\", <<\"up\">>), timer:sleep(120000), init:stop().", [Ready])
    ),
    Port = open_port({spawn_executable, Erl}, [
        {args, ["-name", Name, "-setcookie", "bxtrace", "-noshell", "-eval", Eval]},
        exit_status,
        stderr_to_stdout,
        hide,
        binary
    ]),
    try
        wait_for_peer(Ready, Port, 200),
        Body(list_to_atom(Name))
    after
        file:delete(Ready),
        stop_peer(Port)
    end.

%% The peer writes a file once it is up, which happens after `erl -name' has
%% started distribution, so the file appearing means the specimen can connect.
%% Sleeping a fixed number of seconds instead would be either too short on a
%% loaded machine or too long on every other one.
wait_for_peer(_Ready, Port, 0) ->
    stop_peer(Port),
    error({bxtrace_specimen, peer_never_came_up});
wait_for_peer(Ready, Port, Tries) ->
    case filelib:is_regular(Ready) of
        true ->
            ok;
        false ->
            receive
                {Port, {exit_status, Status}} ->
                    error({bxtrace_specimen, {peer_died, Status}})
            after 50 ->
                wait_for_peer(Ready, Port, Tries - 1)
            end
    end.

%% Closing the port closes the pipe and leaves the node running, so this asks
%% the operating system instead.
stop_peer(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            os:cmd(io_lib:format("kill ~b", [OsPid])),
            catch_close(Port);
        undefined ->
            ok
    end.

catch_close(Port) ->
    try
        port_close(Port)
    catch
        error:badarg -> already_gone
    end,
    ok.

run(Spec, Dump) ->
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Args = maps:get(flags, Spec, []) ++ ["-noshell", "-eval", maps:get(eval, Spec)],
    Env = [{"ERL_CRASH_DUMP", Dump} | maps:get(env, Spec, [])],
    Port = open_port({spawn_executable, Erl}, [
        {args, Args}, {env, Env}, exit_status, stderr_to_stdout, hide, binary
    ]),
    maybe_signal(Spec, Port),
    wait(Port, maps:get(name, Spec)),
    settle(Dump, maps:get(name, Spec)).

%% The specimens that are asked for a dump rather than dying of something get
%% their signal here. The child has to be up first, and there is no event that
%% says so, so this waits for the node to have been running long enough to have
%% finished booting.
maybe_signal(#{signal := Signal}, Port) ->
    timer:sleep(3000),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    os:cmd(io_lib:format("kill -~ts ~b", [Signal, OsPid])),
    ok;
maybe_signal(_Spec, _Port) ->
    ok.

wait(Port, Name) ->
    receive
        {Port, {data, _}} -> wait(Port, Name);
        {Port, {exit_status, _}} -> ok
    after ?PATIENCE ->
        catch_close(Port),
        error({bxtrace_specimen, {took_too_long, Name}})
    end.

%% The child has exited, which is not the same as the dump being on disk. The
%% write happens as the emulator goes down and the file system may still be
%% catching up, so this waits for the size to stop moving rather than reading
%% whatever is there the instant the process is gone.
settle(Dump, Name) ->
    settle(Dump, Name, 0, 200).

settle(_Dump, Name, _Was, 0) ->
    error({bxtrace_specimen, {dump_never_settled, Name}});
settle(Dump, Name, Was, Tries) ->
    case filelib:file_size(Dump) of
        0 ->
            timer:sleep(50),
            settle(Dump, Name, 0, Tries - 1);
        Was ->
            ok;
        Now ->
            timer:sleep(50),
            settle(Dump, Name, Now, Tries - 1)
    end.

%% ---------------------------------------------------------------------------
%% Checking the specimen still produces what it says it produces
%%
%% This is the part that keeps the collection honest across a version bump. A
%% slogan is not an API and a section list is not a promise, so both will change
%% one day. When they do, the recording fails and says which specimen and what
%% it saw, which is a much better morning than a lesson quoting a dump that no
%% longer exists.

check(Spec, Dump) ->
    {ok, Raw} = file:read_file(Dump),
    Expect = maps:get(expect, Spec),
    Name = maps:get(name, Spec),
    Lines = binary:split(Raw, <<"\n">>, [global]),
    Problems =
        slogan_problems(Name, Expect, Lines) ++
            complete_problems(Name, Expect, Lines) ++
            kind_problems(Name, Expect, Lines) ++
            text_problems(Name, Expect, Raw),
    case Problems of
        [] -> ok;
        _ -> error({bxtrace_specimen, {not_what_it_claims, Name, Problems}})
    end.

slogan_problems(Name, Expect, Lines) ->
    Found = slogan(Lines),
    case Expect of
        #{slogan := Want} when Found =/= Want ->
            [{Name, slogan, wanted, Want, found, Found}];
        #{slogan_starts := Prefix} ->
            Size = byte_size(Prefix),
            case Found of
                <<Prefix:Size/binary, _/binary>> -> [];
                _ -> [{Name, slogan, wanted_prefix, Prefix, found, Found}]
            end;
        _ ->
            []
    end.

slogan(Lines) ->
    case [L || <<"Slogan: ", L/binary>> <- Lines] of
        [First | _] -> string:trim(First, trailing);
        [] -> no_slogan
    end.

complete_problems(Name, Expect, Lines) ->
    Want = maps:get(complete, Expect, true),
    Found = complete(Lines),
    case Found =:= Want of
        true -> [];
        false -> [{Name, complete, wanted, Want, found, Found}]
    end.

complete(Lines) ->
    case [L || L <- Lines, string:trim(L) =/= <<>>] of
        [] -> false;
        Kept -> string:trim(lists:last(Kept)) =:= <<"=end">>
    end.

kind_problems(Name, Expect, Lines) ->
    Counts = counts(Lines),
    Missing = [
        {Name, missing_section, Kind}
     || Kind <- maps:get(kinds, Expect, []), maps:get(Kind, Counts, 0) =:= 0
    ],
    Short = [
        {Name, too_few, Kind, wanted, Least, found, maps:get(Kind, Counts, 0)}
     || {Kind, Least} <- maps:to_list(maps:get(at_least, Expect, #{})),
        maps:get(Kind, Counts, 0) < Least
    ],
    Missing ++ Short.

%% Some of what makes a specimen the specimen is not a section, it is a line
%% inside one. A state flag on a process, a call it was last scheduled in for.
%% These are checked as text because that is what they are.
text_problems(Name, Expect, Raw) ->
    [
        {Name, missing_text, Want}
     || Want <- maps:get(must_contain, Expect, []), binary:match(Raw, Want) =:= nomatch
    ].

counts(Lines) ->
    lists:foldl(
        fun
            (<<$=, Rest/binary>>, Acc) ->
                [Tag | _] = binary:split(string:trim(Rest, trailing), <<":">>),
                Kind = binary_to_atom(Tag),
                Acc#{Kind => maps:get(Kind, Acc, 0) + 1};
            (_Line, Acc) ->
                Acc
        end,
        #{},
        Lines
    ).

temp_dump(Name) ->
    Base =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
    filename:join(Base, "bxtrace-specimen-" ++ Name ++ "-" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".dump").
