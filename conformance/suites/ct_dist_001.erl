%% CT-DIST-001, the conformance suite for BP-DIST-001, the external term format.
%%
%% Section 7 of that blueprint was written before any of this existed, as a
%% specification of what the suite has to assert. This module is that section
%% turned into code, one case per paragraph, in the same order, so the two can
%% be read side by side and a paragraph with no case is visible.
%%
%% Everything here is Tier 0. One node, no name, no network, no special build.
%% That is not a coincidence and it is worth saying out loud: the bytes
%% `term_to_binary/1' produces are the bytes the distribution sends, so the
%% whole of this format can be checked without ever starting a second node.
-module(ct_dist_001).

-export([blueprint/0, cases/0]).

-import(ct_assert, [eq/3, neq/3, is_true/2, raises/4, tag/1, wire/1, wire/2, words/1]).

%% Tag values, spelled out rather than written as numbers at the point of use.
%% A test that says `eq(..., 107, tag(Bin))' is a test nobody can review.
-define(SMALL_INTEGER_EXT, 97).
-define(INTEGER_EXT, 98).
-define(SMALL_TUPLE_EXT, 104).
-define(LARGE_TUPLE_EXT, 105).
-define(STRING_EXT, 107).
-define(LIST_EXT, 108).
-define(BINARY_EXT, 109).
-define(SMALL_BIG_EXT, 110).
-define(LARGE_BIG_EXT, 111).
-define(MAP_EXT, 116).
-define(ATOM_UTF8_EXT, 118).
-define(SMALL_ATOM_UTF8_EXT, 119).
-define(BIT_BINARY_EXT, 77).
-define(NEW_PID_EXT, 88).
-define(COMPRESSED, 80).

%% One full scheduler slice. A call that consumes more than this must have been
%% rescheduled at least once, which is how a yield point is observed from
%% Erlang without a trace or a special build.
-define(CONTEXT_REDS, 4000).

blueprint() -> "BP-DIST-001".

cases() ->
    [
        {"round-trip", t0, "Every term kind survives an encode and a decode under =:=", fun round_trip/0},
        {"round-trip-deterministic", t0, "The same corpus survives with the deterministic option set",
            fun round_trip_deterministic/0},
        {"external-size-agrees", t0, "external_size/1 gives the same number as byte_size of the encoding",
            fun external_size_agrees/0},
        {"tag-small-integer", t0, "255 takes the one byte integer tag and 256 does not", fun tag_small_integer/0},
        {"tag-integer", t0, "The wire stops calling an integer small at 2^31, in both directions",
            fun tag_integer/0},
        {"tag-atom", t0, "The atom tag is chosen by byte count while the limit on the name is in characters",
            fun tag_atom/0},
        {"tag-tuple", t0, "255 elements take the one byte arity and 256 take the four byte one",
            fun tag_tuple/0},
        {"tag-string", t0, "65535 bytes take the compact string tag and 65536 take the general list tag",
            fun tag_string/0},
        {"string-three-conditions", t0, "All three conditions on the compact string tag, each on its own",
            fun string_three_conditions/0},
        {"size-integer-band", t0, "The band of integers that are free on the heap and bignums on the wire",
            fun size_integer_band/0},
        {"size-list-tuple-swap", t0, "A list and a tuple order the opposite way on the two measures",
            fun size_list_tuple_swap/0},
        {"deterministic-map-order", t0, "With the option the pairs are in term order, and the bytes repeat",
            fun deterministic_map_order/0},
        {"compression-declines", t0, "A term that will not shrink comes back plain, with nothing to say so",
            fun compression_declines/0},
        {"compression-works", t0, "A term that will shrink gets the compressed tag and still round trips",
            fun compression_works/0},
        {"safe-atom-order", t0, "safe refuses, then plain accepts, then safe accepts the same bytes",
            fun safe_atom_order/0},
        {"trailing-bytes-ignored", t0, "binary_to_term/1 decodes and ignores whatever follows the term",
            fun trailing_bytes_ignored/0},
        {"identifier-creation", t0, "Two pids differing only in creation are different pids on the same node",
            fun identifier_creation/0},
        {"identifier-unknown-node", t0, "An identifier for a node this runtime has never spoken to decodes",
            fun identifier_unknown_node/0},
        {"bitstring-tags", t0, "A whole number of bytes takes one tag and a partial byte takes the other",
            fun bitstring_tags/0},
        {"failure-classes", t0, "Each documented failure raises its exact class and reason",
            fun failure_classes/0},
        {"failure-atom-too-long", t0, "The atom limit raises a different class depending on the route in",
            fun failure_atom_too_long/0},
        {"yield-encoding", t0, "Encoding a large term consumes more than one scheduler slice",
            fun yield_encoding/0},
        {"yield-decoding", t0, "Decoding a large term consumes more than one scheduler slice",
            fun yield_decoding/0}
    ].

%% The corpus. One entry per term kind that has a wire representation, plus the
%% shapes that are easy to get right for the ordinary case and wrong at the
%% edge: an improper list, the empty containers, a bignum past the four byte
%% length field, a bitstring that is not a whole number of bytes, and a map
%% whose keys are of three different types.
corpus() ->
    [
        0,
        -1,
        255,
        256,
        (1 bsl 31) - 1,
        1 bsl 31,
        -(1 bsl 31),
        1 bsl 3000,
        -(1 bsl 3000),
        1 bsl 20000,
        3.14159,
        0.0,
        -0.0,
        an_atom,
        '',
        list_to_atom(lists:duplicate(255, $a)),
        [],
        [1, 2, 3],
        [1, 2 | 3],
        [[], [[]], [[[]]]],
        {},
        {1},
        list_to_tuple(lists:duplicate(300, ok)),
        <<>>,
        <<"bytes">>,
        <<1:3>>,
        <<255, 255, 1:1>>,
        #{},
        #{a => 1, "b" => 2, 3 => <<"c">>},
        maps:from_list([{I, I * I} || I <- lists:seq(0, 99)]),
        self(),
        make_ref(),
        fun lists:reverse/1,
        {[nested, {deeply, #{in => [a, <<"mix">>, 2.5]}}], 1 bsl 64}
    ].

round_trip() ->
    lists:foreach(
        fun(Term) ->
            eq(what("round trips", Term), Term, binary_to_term(term_to_binary(Term)))
        end,
        corpus()
    ).

round_trip_deterministic() ->
    lists:foreach(
        fun(Term) ->
            Bytes = term_to_binary(Term, [deterministic]),
            eq(what("round trips deterministically", Term), Term, binary_to_term(Bytes)),
            %% Twice, because the point of the option is that it repeats.
            eq(what("encodes to the same bytes twice", Term), Bytes, term_to_binary(Term, [deterministic]))
        end,
        corpus()
    ).

external_size_agrees() ->
    lists:foreach(
        fun(Term) ->
            eq(
                what("external_size agrees with byte_size", Term),
                byte_size(term_to_binary(Term)),
                erlang:external_size(Term)
            ),
            eq(
                what("external_size agrees under deterministic", Term),
                byte_size(term_to_binary(Term, [deterministic])),
                erlang:external_size(Term, [deterministic])
            )
        end,
        corpus()
    ).

tag_small_integer() ->
    eq("the tag for 0", ?SMALL_INTEGER_EXT, tag(term_to_binary(0))),
    eq("the tag for 255", ?SMALL_INTEGER_EXT, tag(term_to_binary(255))),
    eq("the tag for 256", ?INTEGER_EXT, tag(term_to_binary(256))),
    %% The one byte field is unsigned, so -1 does not fit it however small it
    %% looks. An implementation that reads the range as signed encodes -1 as
    %% 255 and the far side reads back a different number.
    eq("the tag for -1", ?INTEGER_EXT, tag(term_to_binary(-1))),
    eq("the size of 255", 3, wire(255)),
    eq("the size of -1", 6, wire(-1)).

tag_integer() ->
    eq("the tag for 2^31 - 1", ?INTEGER_EXT, tag(term_to_binary((1 bsl 31) - 1))),
    eq("the tag for 2^31", ?SMALL_BIG_EXT, tag(term_to_binary(1 bsl 31))),
    eq("the tag for -2^31", ?INTEGER_EXT, tag(term_to_binary(-(1 bsl 31)))),
    eq("the tag for -2^31 - 1", ?SMALL_BIG_EXT, tag(term_to_binary(-(1 bsl 31) - 1))),
    %% Past 255 bytes of magnitude the one byte digit count runs out. 2^2040 is
    %% 256 bytes of magnitude and is the first value that needs the wide form.
    eq("the tag for 2^2039", ?SMALL_BIG_EXT, tag(term_to_binary(1 bsl 2039))),
    eq("the tag for 2^2040", ?LARGE_BIG_EXT, tag(term_to_binary(1 bsl 2040))),
    %% Sign and magnitude, not two's complement, so the two differ in one byte
    %% and not in length.
    eq("a bignum and its negation are the same length", wire(1 bsl 2039), wire(-(1 bsl 2039))).

tag_atom() ->
    Ascii255 = list_to_atom(lists:duplicate(255, $a)),
    eq("255 ascii characters is 255 bytes", 255, length(atom_to_list(Ascii255))),
    eq("the tag for a 255 byte name", ?SMALL_ATOM_UTF8_EXT, tag(term_to_binary(Ascii255))),

    %% 128 characters of two byte text is 256 bytes of name, which is a legal
    %% atom and does not fit the one byte length field. Byte count and
    %% character count are different limits and neither implies the other.
    Wide128 = binary_to_atom(binary:copy(<<16#C3, 16#A9>>, 128), utf8),
    eq("128 two byte characters is 128 characters", 128, length(atom_to_list(Wide128))),
    eq("the tag for a 256 byte name", ?ATOM_UTF8_EXT, tag(term_to_binary(Wide128))),

    %% The longest legal atom, which is 255 characters and 510 bytes.
    Wide255 = binary_to_atom(binary:copy(<<16#C3, 16#A9>>, 255), utf8),
    eq("255 two byte characters is 255 characters", 255, length(atom_to_list(Wide255))),
    eq("the tag for a 510 byte name", ?ATOM_UTF8_EXT, tag(term_to_binary(Wide255))),
    eq("the longest atom round trips", Wide255, binary_to_term(term_to_binary(Wide255))).

tag_tuple() ->
    Small = list_to_tuple(lists:duplicate(255, ok)),
    Large = list_to_tuple(lists:duplicate(256, ok)),
    eq("the tag for 255 elements", ?SMALL_TUPLE_EXT, tag(term_to_binary(Small))),
    eq("the tag for 256 elements", ?LARGE_TUPLE_EXT, tag(term_to_binary(Large))),
    eq("the empty tuple", ?SMALL_TUPLE_EXT, tag(term_to_binary({}))).

tag_string() ->
    Fits = lists:duplicate(65535, 1),
    Overflows = lists:duplicate(65536, 1),
    eq("the tag for 65535 bytes", ?STRING_EXT, tag(term_to_binary(Fits))),
    eq("the tag for 65536 bytes", ?LIST_EXT, tag(term_to_binary(Overflows))),
    %% One byte per element on one side of the boundary and two on the other,
    %% so adding a single element adds 65540 bytes.
    eq("the size at 65535", 65539, wire(Fits)),
    eq("the size at 65536", 131079, wire(Overflows)),
    eq("what one more element costs", 65540, wire(Overflows) - wire(Fits)).

string_three_conditions() ->
    %% Three conditions have to hold together. Each of these fails exactly one
    %% of them, so a suite that varies only the length passes for the wrong
    %% reason.
    eq("a short proper list of bytes", ?STRING_EXT, tag(term_to_binary([1, 2, 3]))),
    eq("a short improper list of bytes", ?LIST_EXT, tag(term_to_binary([1, 2 | 3]))),
    eq("a short list with one element above 255", ?LIST_EXT, tag(term_to_binary([1, 256, 3]))),
    eq("a short list with a negative element", ?LIST_EXT, tag(term_to_binary([1, -1, 3]))),
    eq("a short list with a non integer element", ?LIST_EXT, tag(term_to_binary([1, a, 3]))).

size_integer_band() ->
    case erlang:system_info(wordsize) of
        8 ->
            %% Free on the heap all the way to 2^59, and a bignum on the wire
            %% from 2^31. The largest integer that costs nothing to hold is
            %% twelve bytes to send.
            eq("2^59 - 1 costs no heap words", 0, words((1 bsl 59) - 1)),
            eq("2^59 - 1 is twelve wire bytes", 12, wire((1 bsl 59) - 1)),
            eq("2^59 costs two heap words", 2, words(1 bsl 59)),
            eq("2^59 is twelve wire bytes too", 12, wire(1 bsl 59)),
            eq("2^31 costs no heap words", 0, words(1 bsl 31)),
            eq("2^31 is eight wire bytes", 8, wire(1 bsl 31)),
            eq("2^31 - 1 is six wire bytes", 6, wire((1 bsl 31) - 1));
        Other ->
            %% Not a skip. The numbers are different on a 32 bit build and this
            %% suite has never run on one, so saying nothing is the honest
            %% outcome and the scorecard records it.
            ct_assert:fail("the heap column is only written down for a 64 bit build", {wordsize, Other})
    end.

size_list_tuple_swap() ->
    eq("[1, 2, 3] on the wire", 7, wire([1, 2, 3])),
    eq("{1, 2, 3} on the wire", 9, wire({1, 2, 3})),
    eq("[1, 2, 3] on the heap", 6, words([1, 2, 3])),
    eq("{1, 2, 3} on the heap", 4, words({1, 2, 3})),
    %% The whole point. The cheaper of the two swaps places depending on which
    %% cost is being counted, so neither measure predicts the other.
    is_true("the list is cheaper on the wire", wire([1, 2, 3]) < wire({1, 2, 3})),
    is_true("the tuple is cheaper on the heap", words({1, 2, 3}) < words([1, 2, 3])).

deterministic_map_order() ->
    Pairs = [{I, I * 2 rem 251} || I <- lists:seq(0, 99)],
    Forwards = maps:from_list(Pairs),
    Backwards = maps:from_list(lists:reverse(Pairs)),
    OneAtATime = lists:foldl(fun({K, V}, Acc) -> Acc#{K => V} end, #{}, shuffle(Pairs)),

    Bytes = term_to_binary(Forwards, [deterministic]),
    eq("the map tag", ?MAP_EXT, tag(Bytes)),
    eq("the keys are in term order", lists:sort(maps:keys(Forwards)), keys_in_wire_order(Bytes)),

    %% Three different routes to the same map, one set of bytes.
    eq(
        "insertion order does not reach the wire",
        Bytes,
        term_to_binary(Backwards, [deterministic])
    ),
    eq(
        "neither does inserting one at a time",
        Bytes,
        term_to_binary(OneAtATime, [deterministic])
    ),

    %% Without the option the order is a hash trie walk. This asserts that it
    %% is not term order, which is the misconception, and deliberately does not
    %% assert what it is instead, because that is not specified and a suite
    %% that pins it has invented a guarantee.
    Plain = term_to_binary(Forwards),
    neq("the plain order is not term order", keys_in_wire_order(Bytes), keys_in_wire_order(Plain)),
    eq("both orders decode to the same map", Forwards, binary_to_term(Plain)).

compression_declines() ->
    Small = <<"hi">>,
    Plain = term_to_binary(Small),
    Asked = term_to_binary(Small, [compressed]),
    eq("a term that will not shrink comes back plain", Plain, Asked),
    neq("and carries no compressed tag", ?COMPRESSED, tag(Asked)),
    eq("the tag is the one it would have had anyway", ?BINARY_EXT, tag(Asked)),
    %% There is no other signal. This is the whole observable surface of the
    %% decision, which is why it is worth an assertion of its own.
    eq("the size is unchanged", byte_size(Plain), byte_size(Asked)).

compression_works() ->
    Compressible = binary:copy(<<"a">>, 4000),
    Plain = term_to_binary(Compressible),
    Squeezed = term_to_binary(Compressible, [compressed]),
    eq("the compressed tag", ?COMPRESSED, tag(Squeezed)),
    is_true("compression made it smaller", byte_size(Squeezed) < byte_size(Plain)),
    eq("and it still round trips", Compressible, binary_to_term(Squeezed)),
    %% The uncompressed size is declared in the four bytes after the tag, and
    %% it is the length of the plain encoding without its version byte.
    <<131, ?COMPRESSED, Declared:32, _/binary>> = Squeezed,
    eq("the declared size", byte_size(Plain) - 1, Declared).

safe_atom_order() ->
    %% The name is built here rather than written down, so that nothing in the
    %% setup of this suite can have created the atom already. That matters:
    %% the first assertion is about an atom that does not exist yet, and it
    %% passes for the wrong reason if anything has touched the name.
    Name = iolist_to_binary(["ct_dist_001_", integer_to_list(erlang:unique_integer([positive]))]),
    Bytes = <<131, ?SMALL_ATOM_UTF8_EXT, (byte_size(Name)), Name/binary>>,

    raises("safe refuses an atom that does not exist", error, badarg, fun() ->
        binary_to_term(Bytes, [safe])
    end),

    Created = binary_to_term(Bytes),
    eq("plain decoding creates it", Name, atom_to_binary(Created, utf8)),

    %% The same bytes, the same option, a different answer. safe is a check on
    %% novelty and not on content, and a test that asserts a fixed encoding is
    %% always refused will pass and then fail in the same run.
    eq("safe now accepts the same bytes", Created, binary_to_term(Bytes, [safe])).

trailing_bytes_ignored() ->
    Term = {a, b, c},
    Encoded = term_to_binary(Term),
    Padded = <<Encoded/binary, "and then some junk">>,

    %% There is no framing check. binary_to_term/1 reads one term and stops,
    %% and says nothing at all about the bytes it did not read. A caller that
    %% treats a successful decode as proof that the whole input was one term
    %% is wrong, and the failure is silent.
    eq("the term decodes anyway", Term, binary_to_term(Padded)),
    eq("one trailing byte is ignored too", 1, binary_to_term(<<131, ?SMALL_INTEGER_EXT, 1, 0>>)),

    %% used is the only way to find out, and it is the reason the option exists.
    eq(
        "used reports what was actually read",
        {Term, byte_size(Encoded)},
        binary_to_term(Padded, [used])
    ),

    %% Missing bytes are a different matter, because the decoder runs out of
    %% input rather than finishing early.
    raises("a truncated encoding fails", error, badarg, fun() ->
        binary_to_term(binary:part(Encoded, 0, byte_size(Encoded) - 1))
    end).

identifier_creation() ->
    Node = 'never@spoken.example',
    A = handmade_pid(Node, 7, 0, 1),
    B = handmade_pid(Node, 7, 0, 2),
    eq("both report the same node", node(A), node(B)),
    %% Creation is part of the identity and not a comment on it. This is what
    %% stops a message addressed to a process on a node that has since
    %% restarted from reaching a process on the new one with the same number.
    neq("but they are different pids", A, B),
    is_true("and they are both pids", is_pid(A) andalso is_pid(B)),
    eq("the node is the one the bytes named", Node, node(A)).

identifier_unknown_node() ->
    %% Nothing in decoding an identifier checks that the node exists, has ever
    %% existed, or is reachable. It cannot: a pid has to be able to travel
    %% through a third node to a node that has never spoken to its owner.
    Pid = handmade_pid('also@never.example', 42, 3, 9),
    eq("it decodes to a pid", true, is_pid(Pid)),
    eq("it can be compared", true, Pid =:= Pid),
    eq("it can be a map key", ok, maps:get(Pid, #{Pid => ok})),
    eq("it survives a round trip", Pid, binary_to_term(term_to_binary(Pid))).

bitstring_tags() ->
    eq("a whole number of bytes", ?BINARY_EXT, tag(term_to_binary(<<1, 2, 3>>))),
    eq("the empty binary", ?BINARY_EXT, tag(term_to_binary(<<>>))),
    eq("three bits", ?BIT_BINARY_EXT, tag(term_to_binary(<<1:3>>))),

    %% The bits field holds 1 through 8 and not 0 through 7, and the bits are
    %% counted from the most significant end of the last byte. An
    %% implementation that writes 0 for a whole final byte produces something
    %% no conforming decoder will read.
    <<131, ?BIT_BINARY_EXT, Len:32, Bits, Data/binary>> = term_to_binary(<<1:3>>),
    eq("one byte of data", 1, Len),
    eq("three significant bits", 3, Bits),
    eq("counted from the top", <<16#20>>, Data),

    eq("a partial byte round trips", <<1:3>>, binary_to_term(term_to_binary(<<1:3>>))),
    eq("and so does a long one", <<255, 255, 1:1>>, binary_to_term(term_to_binary(<<255, 255, 1:1>>))).

failure_classes() ->
    %% Exact class and exact reason. `badarg' and `{badarg, ...}' are different
    %% answers and reimplementations get this wrong.
    raises("a tag no version defines", error, badarg, fun() ->
        binary_to_term(<<131, 1, 2, 3>>)
    end),
    raises("bytes with no version byte", error, badarg, fun() ->
        binary_to_term(<<?SMALL_INTEGER_EXT, 1>>)
    end),
    raises("an empty binary", error, badarg, fun() ->
        binary_to_term(<<>>)
    end),
    %% The old fun tag has an arm of its own in the decoder whose only action
    %% is to fail, so that a removed tag is a refusal and not an unhandled
    %% case. The result a caller sees is the same either way.
    raises("the removed fun tag", error, badarg, fun() ->
        binary_to_term(<<131, 117, 0, 0, 0, 0>>)
    end),
    %% The two options ask for opposite things, since one writes an instance
    %% specific hash and the other promises the same bytes for the same term.
    raises("local combined with deterministic", error, badarg, fun() ->
        term_to_binary(anything, [local, deterministic])
    end).

failure_atom_too_long() ->
    Long = binary:copy(<<16#C3, 16#A9>>, 256),
    Bytes = <<131, ?ATOM_UTF8_EXT, (byte_size(Long)):16, Long/binary>>,

    %% 256 characters is one past the limit, and the multibyte text is
    %% deliberate: an implementation that counts bytes rather than characters
    %% rejects the legal 255 character atom above and accepts this one.
    raises("decoding an atom of 256 characters", error, badarg, fun() ->
        binary_to_term(Bytes)
    end),

    %% The same limit, a different class, because a different function is
    %% reporting it. A suite that asserts one class for both routes fails
    %% against ERTS, and a blueprint that states one class for both is wrong.
    raises("building an atom of 256 characters", error, system_limit, fun() ->
        list_to_atom(lists:duplicate(256, $a))
    end).

yield_encoding() ->
    Big = lists:seq(1, 500000),
    Spent = reductions(fun() -> term_to_binary(Big) end),
    %% More than one full slice means the process gave the scheduler its thread
    %% back and was put on again, at least once. It is the strongest statement
    %% about a yield point that can be made from Erlang without a trace.
    is_true("encoding was rescheduled at least once", Spent > ?CONTEXT_REDS).

yield_decoding() ->
    Bytes = term_to_binary(lists:seq(1, 500000)),
    Spent = reductions(fun() -> binary_to_term(Bytes) end),
    is_true("decoding was rescheduled at least once", Spent > ?CONTEXT_REDS).

%% Helpers.

%% Bytes for a pid on a node this runtime has never spoken to. Written by hand
%% rather than taken from a live pid, because the point is that the decoder
%% builds one out of bytes it has never seen before.
handmade_pid(Node, Id, Serial, Creation) ->
    Name = atom_to_binary(Node, utf8),
    binary_to_term(
        <<131, ?NEW_PID_EXT, ?SMALL_ATOM_UTF8_EXT, (byte_size(Name)), Name/binary, Id:32, Serial:32,
            Creation:32>>
    ).

%% A parser for one shape only: a map whose keys and values are all integers in
%% 0 through 255. That covers the map this suite builds and nothing else, and
%% keeping it that narrow is deliberate, because a general decoder written here
%% would be a second implementation to keep correct.
keys_in_wire_order(<<131, ?MAP_EXT, Arity:32, Rest/binary>>) ->
    read_pairs(Arity, Rest, []);
keys_in_wire_order(Other) ->
    ct_assert:fail("the encoding is a map of small integers", {got, binary:part(Other, 0, 8)}).

read_pairs(0, <<>>, Acc) ->
    lists:reverse(Acc);
read_pairs(N, <<?SMALL_INTEGER_EXT, Key, ?SMALL_INTEGER_EXT, _Value, Rest/binary>>, Acc) when N > 0 ->
    read_pairs(N - 1, Rest, [Key | Acc]);
read_pairs(N, Rest, _Acc) ->
    ct_assert:fail("every pair is a small integer key and a small integer value", {left, N, Rest}).

%% Reductions charged to this process by one call. process_info reads the
%% counter the scheduler maintains, so a call that traps and comes back is
%% counted across all of its slices.
reductions(Fun) ->
    Before = element(2, erlang:process_info(self(), reductions)),
    _ = Fun(),
    After = element(2, erlang:process_info(self(), reductions)),
    After - Before.

shuffle(List) ->
    [X || {_, X} <- lists:sort([{erlang:phash2({I, seed}), X} || {I, X} <- lists:enumerate(List)])].

what(Sentence, Term) ->
    lists:flatten(io_lib:format("~ts: ~P", [Sentence, Term, 6])).
