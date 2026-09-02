%% The assertion vocabulary every conformance suite is written in.
%%
%% Deliberately small. A suite that needs a new kind of assertion is usually a
%% suite that has started testing the harness instead of the blueprint, and the
%% cost of adding one here is a good place to notice that.
%%
%% Every assertion takes a `What' first, and `What' is a sentence fragment that
%% reads back in the failure message. "the tag for 256" and not "tag256". A
%% failure report is the only part of a test suite most people ever read.
-module(ct_assert).

-export([eq/3, neq/3, is_true/2, raises/4, tag/1, wire/1, wire/2, words/1, fail/2]).

-define(FAILED(What, Detail), throw({ct_failed, What, Detail})).

%% Equality is `=:=' and never `=='. The two differ on 1 and 1.0, which is
%% exactly the pair a term format has to keep apart.
eq(_What, Same, Same) ->
    ok;
eq(What, Expected, Actual) ->
    ?FAILED(What, {expected, Expected, got, Actual}).

neq(What, Same, Same) ->
    ?FAILED(What, {expected_something_other_than, Same});
neq(_What, _A, _B) ->
    ok.

is_true(_What, true) ->
    ok;
is_true(What, Other) ->
    ?FAILED(What, {expected, true, got, Other}).

%% The exact class and the exact reason, because `badarg' and `system_limit'
%% are different answers and a suite that accepts either has not checked
%% anything. Section 5 of every blueprint states the class on purpose.
raises(What, Class, Reason, Fun) ->
    try Fun() of
        Value -> ?FAILED(What, {expected_raise, Class, Reason, but_returned, Value})
    catch
        Class:Reason -> ok;
        OtherClass:OtherReason ->
            ?FAILED(What, {expected_raise, Class, Reason, got, OtherClass, OtherReason})
    end.

%% Read the tag byte out of the bytes rather than inferring it from a size.
%% Two tags can produce the same length, so a size test that passes says
%% nothing about which tag was chosen.
tag(<<131, Tag, _/binary>>) ->
    Tag;
tag(Other) ->
    ?FAILED("the encoding starts with the version byte", {got, Other}).

wire(Term) ->
    byte_size(term_to_binary(Term)).

wire(Term, Opts) ->
    byte_size(term_to_binary(Term, Opts)).

words(Term) ->
    erts_debug:flat_size(Term).

fail(What, Detail) ->
    ?FAILED(What, Detail).
