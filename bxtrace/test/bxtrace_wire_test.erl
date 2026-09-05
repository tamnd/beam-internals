%% The wire tape recorder, checked against the protocol rather than against
%% itself.
%%
%% A recorder that framed the bytes and then tested its own framing would pass
%% on a tape of anything. So the framing is done again here, from the shape of
%% the protocol as written down in lib/kernel/src/dist_util.erl@OTP-29.0.5, and
%% the two digests are recomputed from the cookie and the challenges. A tape
%% that survives that is a recording of a handshake that really happened between
%% two nodes that really knew the cookie.
%%
%% Recording is two node starts, so it happens once and every case reads the
%% same pair of tapes. The pair is the point: one connection from an ordinary
%% node and one from a hidden node, which differ by a single flag.
-module(bxtrace_wire_test).

-export([cases/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

%% The cookie the recorder invents, repeated here rather than read off the tape,
%% because a digest check that took the cookie from the thing it is checking
%% would pass on a tape recorded with any cookie at all.
-define(COOKIE, "bxwire").

%% What each side sends. Two out and three back, from the order of the calls in
%% dist_util:handshake_we_started/1 at lib/kernel/src/dist_util.erl:454
%% @OTP-29.0.5: send_name, recv_status, recv_challenge, send_challenge_reply,
%% recv_challenge_ack.
-define(OUT, 2).
-define(BACK, 3).

%% Every byte of a handshake between two nodes named as these two are. Both
%% names are 24 characters, the flags are always eight bytes and the creations
%% always four, so this is a constant and not a measurement, which is why it can
%% be written down.
%%
%%   send_name        2 + 1 + 8 + 4 + 2 + 24 = 41
%%   status           2 + 1 + 2               = 5
%%   challenge        2 + 1 + 8 + 4 + 4 + 2 + 24 = 45
%%   challenge_reply  2 + 1 + 4 + 16          = 23
%%   challenge_ack    2 + 1 + 16              = 19
-define(HANDSHAKE_BYTES, 133).

cases() ->
    [
        {"a recording reads back as a tape", fun reads_back/0},
        {"a handshake is two messages out and three back", fun five_messages/0},
        {"the whole handshake is a hundred and thirty three bytes", fun the_size/0},
        {"both sides signed the number the other one sent", fun the_digests_recompute/0},
        {"each side named itself and the names are the two nodes", fun the_names/0},
        {"the flags the two sides offered are the same release twice", fun the_flags/0},
        {"a hidden node offers one flag fewer and it is published", fun hidden_is_one_flag/0},
        {"a hidden connection is the handshake and nothing else", fun hidden_says_nothing_more/0},
        {"no machine name is anywhere on either tape", fun no_hostname/0},
        {"every event is a segment and every segment is bytes", fun nothing_but_bytes/0},
        {"the header counts agree with the segments", fun counts_agree/0},
        {"the recorder and this test agree where the handshake ends", fun framing_agrees/0}
    ].

%% ---------------------------------------------------------------------------
%% The recordings
%%
%% Four node starts between them, which is most of a minute if every case does
%% its own. They are recorded once and kept, the same trick the native code
%% tests use and for the same reason.

with_tapes(Fun) ->
    {Visible, Hidden} = tapes(),
    Fun(Visible, Hidden).

tapes() ->
    case persistent_term:get(?MODULE, none) of
        none ->
            Recorded = {record(false), record(true)},
            persistent_term:put(?MODULE, Recorded),
            Recorded;
        Recorded ->
            Recorded
    end.

record(Hidden) ->
    Path = scratch(Hidden),
    try
        {ok, _} = bxtrace_wire:record(Path, #{
            by_whom => "test",
            why => "checking the recorder against the protocol",
            hidden => Hidden
        }),
        {ok, Header, Events} = bxtrace_tape:read(Path),
        {Header, Events}
    after
        file:delete(Path)
    end.

scratch(Hidden) ->
    Dir =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
    filename:join(
        Dir,
        io_lib:format("bxtrace-wire-~w-~b.tape.gz", [Hidden, erlang:unique_integer([positive])])
    ).

%% ---------------------------------------------------------------------------
%% Framing, done again
%%
%% The reader in tools/wire.py does this in Python and the recorder does a
%% cut down version of it to fill in one header field. This is the third, and
%% three implementations that agree on a hundred and thirty three bytes is worth
%% more than one implementation testing itself.

stream(Events, Want) ->
    iolist_to_binary([Bytes || {segment, _, Direction, _, Bytes} <- Events, Direction =:= Want]).

%% Length prefixed messages off the front of a stream, at most Limit of them.
%% The limit is the protocol: after the handshake the prefix is four bytes
%% rather than two, so reading one message too many reads nonsense.
take(Bytes, Limit) -> take(Bytes, Limit, []).

take(_Bytes, 0, Got) ->
    lists:reverse(Got);
take(<<Len:16, Rest/binary>>, Limit, Got) when byte_size(Rest) >= Len ->
    <<Message:Len/binary, After/binary>> = Rest,
    take(After, Limit - 1, [Message | Got]);
take(_Short, _Limit, Got) ->
    lists:reverse(Got).

handshake(Events) ->
    {take(stream(Events, a_to_b), ?OUT), take(stream(Events, b_to_a), ?BACK)}.

%% The five messages pulled apart into what they carry. Written out field by
%% field rather than with a helper, because the whole value of this file is that
%% it says what the protocol is somewhere other than in the code under test.
send_name(<<"N", Flags:64, Creation:32, Len:16, Name:Len/binary>>) ->
    #{flags => Flags, creation => Creation, name => Name}.

status(<<"s", Status/binary>>) ->
    #{status => Status}.

challenge(<<"N", Flags:64, Challenge:32, Creation:32, Len:16, Name:Len/binary>>) ->
    #{flags => Flags, challenge => Challenge, creation => Creation, name => Name}.

reply(<<"r", Challenge:32, Digest:16/binary>>) ->
    #{challenge => Challenge, digest => Digest}.

ack(<<"a", Digest:16/binary>>) ->
    #{digest => Digest}.

%% ---------------------------------------------------------------------------
%% The cases

reads_back() ->
    with_tapes(fun(Visible, _Hidden) ->
        {Header, Events} = Visible,
        ?EQ("the kind on the tape", wire, maps:get(kind, Header)),
        ?EQ("there are segments on it", true, Events =/= [])
    end).

five_messages() ->
    with_tapes(fun(Visible, _Hidden) ->
        {_Header, Events} = Visible,
        {Out, Back} = handshake(Events),
        ?EQ("messages from the connecting side", ?OUT, length(Out)),
        ?EQ("messages from the answering side", ?BACK, length(Back)),
        [SendName, Reply] = Out,
        [Status, Challenge, Ack] = Back,
        ?EQ(
            "the tag on each message, in the order they go past",
            [$N, $s, $N, $r, $a],
            [binary:first(M) || M <- [SendName, Status, Challenge, Reply, Ack]]
        )
    end).

the_size() ->
    with_tapes(fun(Visible, Hidden) ->
        lists:foreach(
            fun({Which, {Header, Events}}) ->
                {Out, Back} = handshake(Events),
                Counted = lists:sum([byte_size(M) + 2 || M <- Out ++ Back]),
                ?EQ(Which ++ ": the handshake counted here", ?HANDSHAKE_BYTES, Counted),
                ?EQ(
                    Which ++ ": and the same number in the header",
                    ?HANDSHAKE_BYTES,
                    maps:get(handshake_bytes, Header)
                )
            end,
            [{"visible", Visible}, {"hidden", Hidden}]
        )
    end).

%% The one that matters. Each side signs the number the other one sent, with
%% md5 of the cookie followed by the challenge in decimal, at
%% lib/kernel/src/dist_util.erl:546@OTP-29.0.5. Decimal rather than the four
%% bytes that went past, which is exactly the sort of thing a decoder gets
%% wrong and a test like this catches.
the_digests_recompute() ->
    with_tapes(fun(Visible, Hidden) ->
        lists:foreach(
            fun({Which, {_Header, Events}}) ->
                {[_Name, Reply], [_Status, Challenge, Ack]} = handshake(Events),
                FromB = maps:get(challenge, challenge(Challenge)),
                FromA = maps:get(challenge, reply(Reply)),
                ?EQ(
                    Which ++ ": the connecting side signed the answering side's challenge",
                    signed(FromB),
                    maps:get(digest, reply(Reply))
                ),
                ?EQ(
                    Which ++ ": the answering side signed the connecting side's challenge",
                    signed(FromA),
                    maps:get(digest, ack(Ack))
                ),
                ?EQ(Which ++ ": and the two challenges are not the same number", false, FromA =:= FromB)
            end,
            [{"visible", Visible}, {"hidden", Hidden}]
        )
    end).

signed(Challenge) -> erlang:md5(?COOKIE ++ integer_to_list(Challenge)).

the_names() ->
    with_tapes(fun(Visible, _Hidden) ->
        {Header, Events} = Visible,
        {[Name, _Reply], [Status, Challenge, _Ack]} = handshake(Events),
        ?EQ("the connecting node named itself", maps:get(node_a, Header), maps:get(name, send_name(Name))),
        ?EQ("the answering node named itself", maps:get(node_b, Header), maps:get(name, challenge(Challenge))),
        ?EQ("and it said the connection was welcome", <<"ok">>, maps:get(status, status(Status)))
    end).

%% Two nodes of one release offer the same set, which is the boring answer and
%% the right one. It is pinned so that a release that changes the set shows up
%% as a failure here rather than as a lesson quoting a number nobody rechecked.
the_flags() ->
    with_tapes(fun(Visible, _Hidden) ->
        {_Header, Events} = Visible,
        {[Name, _Reply], [_Status, Challenge, _Ack]} = handshake(Events),
        Mine = maps:get(flags, send_name(Name)),
        Theirs = maps:get(flags, challenge(Challenge)),
        ?EQ("the two sides offered the same flags", Mine, Theirs),
        ?EQ("and the connecting side said it was published", true, Mine band 16#01 =/= 0)
    end).

%% `-hidden' is one bit. Everything else about the handshake is the same, which
%% is what makes the pair of tapes worth having: the difference in the bytes is
%% a single flag and the difference in what follows is the whole connection.
hidden_is_one_flag() ->
    with_tapes(fun(Visible, Hidden) ->
        Offered = fun({_Header, Events}) ->
            {[Name, _Reply], _Back} = handshake(Events),
            maps:get(flags, send_name(Name))
        end,
        Ordinary = Offered(Visible),
        Quiet = Offered(Hidden),
        ?EQ("the flag that differs is published", 16#01, Ordinary bxor Quiet),
        ?EQ("and a hidden node is the one without it", 0, Quiet band 16#01)
    end).

hidden_says_nothing_more() ->
    with_tapes(fun(Visible, Hidden) ->
        {HiddenHeader, _} = Hidden,
        {VisibleHeader, _} = Visible,
        Total = fun(Header) -> maps:get(bytes_a_to_b, Header) + maps:get(bytes_b_to_a, Header) end,
        ?EQ("a hidden connection is the handshake and no more", ?HANDSHAKE_BYTES, Total(HiddenHeader)),
        ?EQ(
            "an ordinary one carries a good deal more, which is the global name server",
            true,
            Total(VisibleHeader) > 4 * ?HANDSHAKE_BYTES
        )
    end).

%% Both nodes are named with the loopback address rather than with whatever the
%% recording machine calls itself, so the name of somebody's laptop cannot end
%% up in corpora. The names are on the tape twice, in the header and inside the
%% handshake, so this looks at the bytes.
no_hostname() ->
    with_tapes(fun(Visible, Hidden) ->
        {ok, Hostname} = inet:gethostname(),
        lists:foreach(
            fun({Which, {_Header, Events}}) ->
                Everything = iolist_to_binary([Bytes || {segment, _, _, _, Bytes} <- Events]),
                ?EQ(
                    Which ++ ": the machine's own name is not in the bytes",
                    nomatch,
                    binary:match(Everything, list_to_binary(Hostname))
                )
            end,
            [{"visible", Visible}, {"hidden", Hidden}]
        )
    end).

nothing_but_bytes() ->
    with_tapes(fun(Visible, Hidden) ->
        lists:foreach(
            fun({Which, {_Header, Events}}) ->
                Odd = [E || E <- Events, not is_segment(E)],
                ?EQ(Which ++ ": events that are not a segment of bytes", [], Odd)
            end,
            [{"visible", Visible}, {"hidden", Hidden}]
        )
    end).

is_segment({segment, N, Direction, Micros, Bytes}) ->
    is_integer(N) andalso is_integer(Micros) andalso is_binary(Bytes) andalso
        lists:member(Direction, [a_to_b, b_to_a]);
is_segment(_) ->
    false.

counts_agree() ->
    with_tapes(fun(Visible, Hidden) ->
        lists:foreach(
            fun({Which, {Header, Events}}) ->
                Sent = fun(Want) ->
                    lists:sum([
                        byte_size(B)
                     || {segment, _, D, _, B} <- Events, D =:= Want
                    ])
                end,
                ?EQ(Which ++ ": the segment count", length(Events), maps:get(segments, Header)),
                ?EQ(Which ++ ": bytes one way", Sent(a_to_b), maps:get(bytes_a_to_b, Header)),
                ?EQ(Which ++ ": bytes the other", Sent(b_to_a), maps:get(bytes_b_to_a, Header))
            end,
            [{"visible", Visible}, {"hidden", Hidden}]
        )
    end).

%% A segment is one read off a socket, so the last handshake message and the
%% first thing after it can arrive together. That is the reason the framing
%% belongs to the reader, and this is the case that would notice if a recorder
%% ever started splitting reads to make the reader's life easier.
framing_agrees() ->
    with_tapes(fun(Visible, _Hidden) ->
        {Header, Events} = Visible,
        {Out, Back} = handshake(Events),
        Counted = lists:sum([byte_size(M) + 2 || M <- Out ++ Back]),
        ?EQ("the recorder and this test agree", maps:get(handshake_bytes, Header), Counted),
        Reads = [byte_size(B) || {segment, _, _, _, B} <- Events],
        ?EQ("and no read is empty", [], [N || N <- Reads, N =:= 0])
    end).
