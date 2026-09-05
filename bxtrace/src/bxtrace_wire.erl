%% The wire tape. Every byte two nodes send each other while they get connected.
%%
%% A distribution handshake is five messages and about a hundred and thirty
%% bytes, and almost every question about clustering is answered somewhere in
%% them. Which node am I talking to. What does it know how to do. Does it know
%% the cookie. What creation is this incarnation of it. All of that goes past in
%% under a millisecond and none of it is visible from inside either node,
%% because by the time a node can tell you it is connected the handshake is
%% already over.
%%
%% So it is recorded from the outside, byte for byte, in both directions, and
%% the tape is the bytes. Nothing is decoded here. tools/wire.py does the
%% decoding, which means the decoder can be wrong and be fixed without touching
%% the evidence, and it means a reader can disagree with the decoder and go look
%% at the bytes.
%%
%% ---------------------------------------------------------------------------
%% How the bytes are got at
%%
%% The two ways to watch a TCP connection are to run tcpdump as root or to put
%% something in the middle of it. Root is not available in the container CI runs
%% in and is not a reasonable thing for a recorder to want, so this puts a relay
%% in the middle: an ordinary TCP listener that accepts the connection, opens a
%% second one to the real node, and copies bytes across while writing down what
%% went which way.
%%
%% The relay cannot pretend to be the far node. The handshake carries the
%% responder's name and the initiator checks it against the atom of the node it
%% asked for, at lib/kernel/src/dist_util.erl:recv_challenge_new@OTP-29.0.5, so
%% a relay answering under its own name is hung up on. It has to sit in front of
%% the real node instead. That is the good outcome anyway, because it means both
%% ends of this recording are stock nodes doing the real thing, and the only
%% thing that is not ordinary is one wrong answer about a port number. See
%% bxtrace_wire_epmd.
%%
%% ---------------------------------------------------------------------------
%% The cookie is on the tape on purpose, and it is not a real one
%%
%% The last two messages are md5 of the cookie followed by the challenge, at
%% lib/kernel/src/dist_util.erl:546@OTP-29.0.5. Putting the cookie on the tape
%% is what lets a reader recompute both digests and prove the recording is a
%% real handshake rather than a picture of one, and tools/wire.py does exactly
%% that every time it reads a tape.
%%
%% It is also the reason this is the one recorder that must never be pointed at
%% a cluster anybody uses. A captured handshake is a challenge and a digest of a
%% short word, and short words do not survive being guessed at offline. The
%% cookie here is invented for the recording, the nodes exist for a second, and
%% they only ever listen on the loopback address.
%%
%% ---------------------------------------------------------------------------
%% What is not on the tape
%%
%% No hostname. Both nodes are named with the loopback address rather than
%% whatever the machine calls itself, so a tape recorded on somebody's laptop
%% does not publish the laptop. Both node names, the cookie, the challenges and
%% the creations are on the tape, and every one of them was made up for the
%% recording.

-module(bxtrace_wire).

-export([record/2]).

%% Both nodes and the cookie, in one place, because a reader of the tape sees
%% all three and should be able to find where they were decided.
-define(HOST, "127.0.0.1").
-define(NAME_A, "bxtrace-wire-a").
-define(NAME_B, "bxtrace-wire-b").
-define(COOKIE, "bxwire").

%% Long enough that a loaded machine still finishes, short enough that a broken
%% recording fails rather than hangs.
-define(NODE_TIMEOUT, 30000).
-define(CAPTURE_TIMEOUT, 20000).

%% record(Path, Opts) starts two nodes, connects one to the other through a
%% relay, and writes down the conversation.
%%
%%   #{by_whom => "tamnd",
%%     why     => "the five messages a handshake is made of",
%%     hidden  => false}
%%
%% `hidden' starts the connecting node with `-hidden', which turns off one flag
%% and is the cheapest way to see the flags do anything. Two nodes of one
%% release agree on everything, so a tape of that shows a table of yes down both
%% columns, and the pair of tapes is what shows the table being a negotiation.
record(Path, Opts) ->
    ByWhom = maps:get(by_whom, Opts),
    Why = maps:get(why, Opts),
    Hidden = maps:get(hidden, Opts, false),

    Dir = temp_dir(),
    try
        {Responder, NodeB} = start_responder(Dir),
        try
            {Segments, Framing} = capture(Dir, Responder, Hidden),
            write(Path, ByWhom, Why, Hidden, Segments, Framing)
        after
            stop(NodeB)
        end
    after
        file:del_dir_r(Dir)
    end.

%% ---------------------------------------------------------------------------
%% The node being connected to
%%
%% Started the ordinary way and registered with the real epmd, because the point
%% of the recording is that this side has no idea anything unusual is happening.
%%
%% It reports its own port back by asking epmd for it, which is both the honest
%% way to find out and the way that avoids pinning a port number. Two recordings
%% running at once on one machine would fight over a fixed port and one of them
%% would fail in a way nobody would enjoy reading.
start_responder(Dir) ->
    ok = wait_until_free([?NAME_A, ?NAME_B]),
    Ready = filename:join(Dir, "responder.port"),
    Eval = lists:flatten(
        io_lib:format(
            "{ok, Names} = erl_epmd:names({127,0,0,1}), "
            "{_, Port} = lists:keyfind(\"~ts\", 1, Names), "
            "ok = file:write_file(\"~ts\", integer_to_binary(Port)), "
            "timer:sleep(~b), init:stop().",
            [?NAME_B, Ready, ?NODE_TIMEOUT]
        )
    ),
    Node = erl([
        "-name", ?NAME_B "@" ?HOST, "-setcookie", ?COOKIE, "-noshell", "-eval", Eval
    ]),
    {wait_for(Ready, Node, ?NODE_TIMEOUT div 50), Node}.

%% Both node names are fixed, which is what makes the size of a handshake a
%% constant worth writing down: the names are always 24 characters and the rest
%% of the five messages is fixed width. The price is that two recordings cannot
%% overlap, and that a node killed a moment ago is still registered with epmd
%% for a little while after its process is gone. Killing is what the recorder
%% does when it is finished, so running it twice in a row hits that window
%% often enough to matter, and it fails in a way that reads like a bug in the
%% handshake rather than a name still being taken.
%%
%% So the names are waited for rather than assumed. epmd drops a registration
%% when the node's socket closes, which happens promptly, and the wait is short.
wait_until_free(Names) -> wait_until_free(Names, 100).

wait_until_free(Names, 0) ->
    error({bxtrace_wire, {names_still_taken, Names, registered_names()}});
wait_until_free(Names, Tries) ->
    case [Name || Name <- Names, lists:keymember(Name, 1, registered_names())] of
        [] ->
            ok;
        _Taken ->
            timer:sleep(50),
            wait_until_free(Names, Tries - 1)
    end.

registered_names() ->
    case erl_epmd:names({127, 0, 0, 1}) of
        {ok, Names} -> Names;
        %% No epmd yet means nothing is registered, and the node started below
        %% will bring one up.
        {error, _} -> []
    end.

wait_for(_Ready, Node, 0) ->
    stop(Node),
    error({bxtrace_wire, {responder_never_came_up, said(Node)}});
wait_for(Ready, Node, Tries) ->
    case file:read_file(Ready) of
        {ok, Port} ->
            binary_to_integer(Port);
        {error, _} ->
            receive
                {Node, {exit_status, Status}} ->
                    error({bxtrace_wire, {responder_died, Status, said(Node)}})
            after 50 ->
                wait_for(Ready, Node, Tries - 1)
            end
    end.

%% ---------------------------------------------------------------------------
%% The relay and the node that dials it
%%
%% The listener goes up before the initiator starts, so there is no window where
%% the initiator dials a port nothing is on yet. Port zero because the operating
%% system knows which ports are free and this does not.

capture(Dir, Responder, Hidden) ->
    {ok, Listener} = gen_tcp:listen(0, [
        binary, {ip, {127, 0, 0, 1}}, {active, false}, {packet, 0}, {reuseaddr, true}
    ]),
    try
        {ok, Relay} = inet:port(Listener),
        Result = filename:join(Dir, "initiator.result"),
        Node = start_initiator(Result, Relay, Hidden),
        try
            {ok, From} = accept(Listener, Node),
            Recorded =
                try
                    pump(From, Responder, Node)
                after
                    gen_tcp:close(From)
                end,
            ok = connected(Result, Node),
            Recorded
        after
            stop(Node)
        end
    after
        gen_tcp:close(Listener)
    end.

%% The initiator connects, waits long enough for the connection to settle, and
%% stops. Stopping is what closes the socket, which is what ends the recording,
%% so the tape has a definite end rather than a timeout.
start_initiator(Result, Relay, Hidden) ->
    Eval = lists:flatten(
        io_lib:format(
            "Connected = net_kernel:connect_node('~ts@~ts'), "
            "timer:sleep(300), "
            "ok = file:write_file(\"~ts\", term_to_binary(Connected)), "
            "init:stop().",
            [?NAME_B, ?HOST, Result]
        )
    ),
    erl(
        [
            "-name",
            ?NAME_A "@" ?HOST,
            "-setcookie",
            ?COOKIE,
            "-noshell",
            "-pa",
            beams(),
            "-epmd_module",
            "bxtrace_wire_epmd",
            "-bxtrace_wire_peer",
            ?NAME_B,
            "-bxtrace_wire_relay",
            integer_to_list(Relay)
        ] ++
            [
                "-hidden"
             || Hidden
            ] ++
            ["-eval", Eval]
    ).

%% Whether the handshake worked, asked of the node that did it rather than
%% guessed at from the bytes. A refused connection also produces five messages
%% and a tape that looks fine until somebody decodes the status message, so this
%% is checked before anything is written down.
connected(Result, Node) ->
    case file:read_file(Result) of
        {ok, Term} ->
            case binary_to_term(Term) of
                true -> ok;
                Other -> error({bxtrace_wire, {handshake_refused, Other, said(Node)}})
            end;
        {error, Reason} ->
            error({bxtrace_wire, {initiator_said_nothing, Reason, said(Node)}})
    end.

accept(Listener, Node) ->
    case gen_tcp:accept(Listener, ?CAPTURE_TIMEOUT) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> error({bxtrace_wire, {initiator_never_dialled, Reason, said(Node)}})
    end.

%% Copying bytes and writing down what went past.
%%
%% Everything is recorded exactly as it came out of one socket and went into the
%% other, which means a segment on the tape is one read and not one protocol
%% message. TCP is a stream and the split between reads is the operating
%% system's business, so the framing is left to the reader, which knows the
%% protocol. Recording reads rather than messages is the difference between a
%% capture and a transcript, and only one of them can be checked.
pump(From, Responder, Node) ->
    {ok, To} = gen_tcp:connect({127, 0, 0, 1}, Responder, [binary, {active, true}, {packet, 0}]),
    ok = inet:setopts(From, [{active, true}]),
    Start = erlang:monotonic_time(microsecond),
    try
        relay(From, To, Node, Start, [])
    after
        gen_tcp:close(To)
    end.

relay(From, To, Node, Start, Seen) ->
    receive
        {tcp, From, Bytes} ->
            ok = gen_tcp:send(To, Bytes),
            relay(From, To, Node, Start, [segment(a_to_b, Start, Bytes) | Seen]);
        {tcp, To, Bytes} ->
            ok = gen_tcp:send(From, Bytes),
            relay(From, To, Node, Start, [segment(b_to_a, Start, Bytes) | Seen]);
        {tcp_closed, _} ->
            {lists:reverse(Seen), framing(lists:reverse(Seen))};
        {tcp_error, _, Reason} ->
            error({bxtrace_wire, {connection_broke, Reason}});
        {Node, {data, _}} ->
            relay(From, To, Node, Start, Seen);
        {Node, {exit_status, _}} ->
            relay(From, To, Node, Start, Seen)
    after ?CAPTURE_TIMEOUT ->
        error({bxtrace_wire, {nothing_more_arrived, length(Seen)}})
    end.

segment(Direction, Start, Bytes) ->
    {segment, Direction, erlang:monotonic_time(microsecond) - Start, Bytes}.

%% ---------------------------------------------------------------------------
%% Writing

write(Path, ByWhom, Why, Hidden, Segments, Framing) ->
    Header = maps:merge(
        bxtrace_tape:header(wire, ByWhom, Why),
        #{
            node_a => list_to_binary(?NAME_A "@" ?HOST),
            node_b => list_to_binary(?NAME_B "@" ?HOST),
            hidden => Hidden,
            %% Made up for this recording, which is why it can be written down.
            %% See the note at the top about why that matters.
            cookie => list_to_binary(?COOKIE),
            segments => length(Segments),
            bytes_a_to_b => sent(a_to_b, Segments),
            bytes_b_to_a => sent(b_to_a, Segments),
            handshake_bytes => Framing
        }
    ),
    {ok, Tape} = bxtrace_tape:open(Path, Header),
    Numbered = [
        {segment, N, Direction, Micros, Bytes}
     || {N, {segment, Direction, Micros, Bytes}} <- lists:enumerate(Segments)
    ],
    Written = lists:foldl(fun(Event, Acc) -> bxtrace_tape:write(Acc, Event) end, Tape, Numbered),
    {ok, Path, Count} = bxtrace_tape:close(Written),
    {ok, #{
        path => Path,
        events => Count,
        segments => length(Segments),
        bytes_a_to_b => sent(a_to_b, Segments),
        bytes_b_to_a => sent(b_to_a, Segments),
        handshake_bytes => Framing
    }}.

sent(Direction, Segments) ->
    lists:sum([byte_size(Bytes) || {segment, D, _, Bytes} <- Segments, D =:= Direction]).

%% How much of the conversation was the handshake.
%%
%% Recorded as a number rather than trusted to the reader, because it is the one
%% fact the recorder knows and the reader has to work out: the handshake is five
%% length prefixed messages and everything after them is a different framing.
%% If the reader ever disagrees with this number, one of the two is wrong about
%% the protocol and that is worth a failing test.
framing(Segments) ->
    Stream = fun(Want) ->
        iolist_to_binary([Bytes || {segment, D, _, Bytes} <- Segments, D =:= Want])
    end,
    messages(Stream(a_to_b), 2, 0) + messages(Stream(b_to_a), 3, 0).

messages(_Rest, 0, Bytes) ->
    Bytes;
messages(<<Len:16, Rest/binary>>, Left, Bytes) when byte_size(Rest) >= Len ->
    messages(binary:part(Rest, Len, byte_size(Rest) - Len), Left - 1, Bytes + 2 + Len);
messages(Short, Left, _Bytes) ->
    error({bxtrace_wire, {handshake_cut_short, Left, byte_size(Short)}}).

%% ---------------------------------------------------------------------------
%% Running a node

erl(Args) ->
    open_port({spawn_executable, filename:join([code:root_dir(), "bin", "erl"])}, [
        {args, Args}, exit_status, stderr_to_stdout, hide, binary
    ]).

%% Closing the port closes the pipe and leaves the node running, so the
%% operating system is asked instead. Same as bxtrace_specimen, same reason.
stop(Node) ->
    case erlang:port_info(Node, os_pid) of
        {os_pid, OsPid} ->
            os:cmd(io_lib:format("kill ~b", [OsPid])),
            catch_close(Node);
        undefined ->
            ok
    end.

catch_close(Node) ->
    try
        port_close(Node)
    catch
        error:badarg -> ok
    end,
    ok.

%% Whatever the node printed, which for a node that failed to start is the only
%% explanation there is going to be.
said(Node) ->
    receive
        {Node, {data, Bytes}} -> <<Bytes/binary, (said(Node))/binary>>
    after 100 -> <<>>
    end.

%% Where bxtrace_wire_epmd was compiled to, so the initiator can load it. Asking
%% the code server is what makes this work from the test runner and from
%% record.escript, which compile to different temporary directories.
beams() ->
    filename:dirname(code:which(bxtrace_wire_epmd)).

temp_dir() ->
    Base = filename:join([
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
        "bxtrace-wire-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Base),
    Base.
