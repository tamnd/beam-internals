%% The crash dump specimens, and the thing that keeps them honest.
%%
%% Producing all fourteen takes about four minutes, which is a fine price to
%% pay when recording the corpus and a terrible one to pay on every test run.
%% So this suite runs two of them, the cheapest and the one with the most
%% moving parts, and tests everything else against the table and against dumps
%% written here by hand.
%%
%% The part worth testing hardest is the checking, not the producing. A
%% specimen that quietly stops reproducing its own cause is the failure that
%% would cost the most later, because a lesson would be teaching a dump that no
%% longer exists. So most of what is here is a doctored dump and the question of
%% whether the check notices.
-module(bxtrace_specimen_test).

-export([cases/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

cases() ->
    [
        {"every specimen has a name nobody else has", fun names_are_unique/0},
        {"every specimen says what it expects to find", fun every_one_expects_something/0},
        {"every specimen is one of the two groups", fun two_groups/0},
        {"a name that is not a specimen is not found", fun find_misses/0},
        {"a dump matching the expectation passes", fun a_good_dump_passes/0},
        {"a dump with the wrong slogan is caught", fun wrong_slogan/0},
        {"a dump missing a section it promised is caught", fun missing_section/0},
        {"a dump with too few of a section is caught", fun too_few/0},
        {"a dump that was cut off when it should not be is caught", fun unexpected_truncation/0},
        {"a line the specimen insists on, missing, is caught", fun missing_text/0},
        {"the simplest specimen records and reads back", fun records/0},
        {"a truncated specimen records and the tape says it is truncated", fun records_truncated/0}
    ].

%% ---------------------------------------------------------------------------
%% The table

names_are_unique() ->
    Names = bxtrace_specimen:names(),
    ?EQ("fourteen specimens", 14, length(Names)),
    ?EQ("names that appear more than once", [], Names -- lists:usort(Names)).

every_one_expects_something() ->
    Thin = [
        maps:get(name, Spec)
     || Spec <- bxtrace_specimen:all(),
        map_size(maps:get(expect, Spec, #{})) =< 1
    ],
    ?EQ("specimens that check nothing about the dump they produce", [], Thin).

%% Either it dies of something, in which case it says how, or it is the
%% distributed one, which is produced a different way because it needs somebody
%% on the other end. A specimen with neither would never run.
two_groups() ->
    Stranded = [
        maps:get(name, Spec)
     || Spec <- bxtrace_specimen:all(),
        not maps:is_key(eval, Spec),
        not maps:is_key(distributed, Spec)
    ],
    ?EQ("specimens with no way to produce a dump", [], Stranded).

find_misses() ->
    ?EQ("a name nobody has", not_found, bxtrace_specimen:find("dump-the-one-that-got-away")),
    {ok, Spec} = bxtrace_specimen:find("halt-slogan"),
    ?EQ("the one that was asked for", "halt-slogan", maps:get(name, Spec)).

%% ---------------------------------------------------------------------------
%% The checking
%%
%% These use a dump written here rather than a real one, because the question
%% is whether the check notices a dump that is wrong, and a real node will not
%% produce a wrong dump on request.

a_good_dump_passes() ->
    ?EQ("a dump that is what it claims", ok, check(spec(), dump())).

wrong_slogan() ->
    Doctored = binary:replace(dump(), <<"the expected slogan">>, <<"something else entirely">>),
    caught(slogan, check(spec(), Doctored)).

missing_section() ->
    Doctored = binary:replace(dump(), <<"=port:#Port<0.1>\n">>, <<>>),
    caught(missing_section, check(spec(), Doctored)).

too_few() ->
    Doctored = binary:replace(dump(), <<"=proc:<0.2.0>\nState: Waiting\n">>, <<>>),
    caught(too_few, check(spec(), Doctored)).

unexpected_truncation() ->
    Doctored = binary:replace(dump(), <<"=end\n">>, <<>>),
    caught(complete, check(spec(), Doctored)).

missing_text() ->
    Doctored = binary:replace(dump(), <<"State: Running">>, <<"State: Waiting">>),
    caught(missing_text, check(spec(), Doctored)).

%% The check reports through an error, because a specimen that is not what it
%% claims must not get as far as writing a tape. What is asserted here is that
%% the report names the problem, so somebody reading a failed recording knows
%% which of the five things went wrong.
caught(What, Result) ->
    case Result of
        {caught, Problems} ->
            case [P || P <- Problems, element(2, P) =:= What] of
                [] -> ct_assert:fail("the check names the problem", {wanted, What, found, Problems});
                [_ | _] -> ok
            end;
        ok ->
            ct_assert:fail("the check catches a doctored dump", {What, was_not_caught})
    end.

check(Spec, Raw) ->
    Path = temp("check"),
    ok = file:write_file(Path, Raw),
    try
        bxtrace_specimen:check(Spec, Path)
    catch
        error:{bxtrace_specimen, {not_what_it_claims, _, Problems}} -> {caught, Problems}
    after
        file:delete(Path)
    end.

%% A specimen whose expectation covers all five kinds of check at once, so one
%% dump can be doctored five ways.
spec() ->
    #{
        name => "a fixture",
        why => "the specimen used to test the checking",
        eval => "erlang:halt(\"the expected slogan\").",
        expect => #{
            slogan => <<"the expected slogan">>,
            complete => true,
            kinds => [erl_crash_dump, proc, port],
            at_least => #{proc => 2},
            must_contain => [<<"State: Running">>]
        }
    }.

dump() ->
    <<
        "=erl_crash_dump:0.5\n"
        "Sat Sep  5 23:05:22 2026\n"
        "Slogan: the expected slogan\n"
        "System version: Erlang/OTP 29 [erts-17.0.5]\n"
        "Atoms: 10382\n"
        "=proc:<0.1.0>\n"
        "State: Running\n"
        "Spawned as: proc_lib:init_p/5\n"
        "=proc:<0.2.0>\n"
        "State: Waiting\n"
        "=port:#Port<0.1>\n"
        "Slot: 1\n"
        "=end\n"
    >>.

%% ---------------------------------------------------------------------------
%% Two real ones, end to end
%%
%% The rest of the suite would pass with a producer that never worked, so two of
%% them are actually produced. The plain halt because it is the cheapest, and
%% the truncated one because it is the only specimen whose whole point is that
%% the dump is incomplete, which is the case a fixture is least likely to get
%% right.

records() ->
    ok = bxtrace_post_test:needs_a_digest(),
    {ok, Spec} = bxtrace_specimen:find("halt-slogan"),
    Path = temp("halt") ++ ".tape.gz",
    try
        {ok, Result} = bxtrace_specimen:record(Spec, Path, "test"),
        ?EQ("the slogan the specimen asked for", <<"a deliberate halt, the shortest path to a dump">>, maps:get(slogan, Result)),
        ?EQ("a complete dump", true, maps:get(complete, Result)),
        ?EQ("no section tag we do not know", [], maps:get(unknown_kinds, Result)),
        {ok, _Header, Rows} = bxtrace_tape:read(Path),
        Sections = [R || R <- Rows, element(1, R) =:= section],
        ?EQ("every section is on the tape", maps:get(sections, Result), length(Sections))
    after
        file:delete(Path)
    end.

records_truncated() ->
    ok = bxtrace_post_test:needs_a_digest(),
    {ok, Spec} = bxtrace_specimen:find("truncated"),
    Path = temp("truncated") ++ ".tape.gz",
    try
        {ok, Result} = bxtrace_specimen:record(Spec, Path, "test"),
        ?EQ("the tape says the dump stops early", false, maps:get(complete, Result)),
        ?EQ("the slogan survived the truncation", <<"a halt under a byte budget">>, maps:get(slogan, Result))
    after
        file:delete(Path)
    end.

temp(What) ->
    Base =
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
    filename:join(Base, "bxtrace-specimen-test-" ++ What ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))).
