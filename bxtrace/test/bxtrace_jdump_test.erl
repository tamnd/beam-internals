%% The native code tape recorder, checked against a module whose loaded shape is
%% known.
%%
%% These are the mirror image of the disassembly tests. Those need an emulator
%% configured `--disable-jit' and skip everywhere else, and these need a stock
%% release and skip on the interpreter. Between the two suites every case runs
%% somewhere, and no machine runs both.
%%
%% What is pinned here is deliberately not the native code. That changes with the
%% architecture, and pinning it would turn this into a test that only passes on
%% the machine it was written on. What is pinned is the shape: five functions, a
%% group for every BEAM instruction, native instructions under each group, no
%% address anywhere, and the names the loader chose. The names are the finding
%% worth protecting, because they are not the names the other flavor chose for
%% the same beam file.
-module(bxtrace_jdump_test).

-export([cases/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

%% What the interpreter calls the addition in `add(A, B) -> A + B', pinned in
%% bxtrace_dis_test against a real interpreter. No JIT build emits this name, and
%% that is the point of holding a copy of it here.
-define(WHAT_THE_INTERPRETER_CALLS_IT, <<"i_plus_xxjd">>).

%% The BEAM instructions that cost no native code at all in this module.
%%
%% Four of them are positions rather than work: three kinds of label and the two
%% line markers, which are there so a stack trace can name a line and are written
%% into a table beside the code instead of into it.
%%
%% `i_flush_stubs' is AArch64 only. A branch on AArch64 reaches 128 MB and a
%% module further away than that needs a veneer, so the assembler is told where
%% the safe places to put one are. Nothing is emitted when none is needed.
%%
%% `deallocate_t' is the interesting one. The emitter at
%% erts/emulator/beam/jit/arm/instr_common.cpp:223@OTP-29.0.5 adds the frame size
%% back to the stack pointer, and adding zero is nothing, so a function whose
%% frame held only the return address deallocates for free. The `return' that
%% follows pops that word itself.
-define(FREE, [
    <<"aligned_label_Lt">>,
    <<"deallocate_t">>,
    <<"func_line_I">>,
    <<"i_flush_stubs">>,
    <<"i_func_label_L">>,
    <<"label_L">>,
    <<"line_I">>
]).

cases() ->
    [
        {"a recording reads back as a tape", fun reads_back/0},
        {"the five functions are on the tape, module_info included", fun the_functions/0},
        {"every function got its name from the dump", fun every_function_is_named/0},
        {"the only instructions that cost nothing are the ones that are not work", fun groups_have_code/0},
        {"every row belongs to a group that is on the tape", fun rows_belong/0},
        {"nothing on the tape is anything but printable text", fun nothing_but_text/0},
        {"the module has a code section and a constants section", fun the_sections/0},
        {"a section marker with rubbish stuck to it keeps its name", fun trimmed_markers/0},
        {"the JIT does not call addition what the interpreter calls it", fun a_different_name/0},
        {"an opcode name is a bare identifier and a note never is", fun names_against_notes/0},
        {"no machine address survives on the tape", fun no_addresses/0},
        {"a run of bytes is counted rather than copied", fun bytes_are_counted/0},
        {"the header counts agree with the events", fun counts_agree/0},
        {"the module's own source is on the tape", fun source_is_kept/0},
        {"booting the child compiled the rest of the system too", fun the_boot_cost/0},
        {"nothing on the tape is a live term", fun no_live_terms/0},
        {"an interpreter refuses rather than writing an empty tape", fun refuses_on_the_interpreter/0}
    ].

%% ---------------------------------------------------------------------------
%% What runs where

%% The recorder's own refusal is reused rather than restated, so the skip reason
%% and the error a person recording by hand would see are one sentence with one
%% place to change it.
needs_the_jit() ->
    try bxtrace_jdump:jit_check() of
        ok -> ok
    catch
        error:{bxtrace_jdump, Why} -> ct_assert:skip(Why)
    end.

%% ---------------------------------------------------------------------------
%% The module under the microscope
%%
%% The same six lines the pass tape and the disassembly tape use, so all three
%% are about one module and a reader comparing them is comparing like with like.

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
    filename:join(Dir, io_lib:format("bxtrace-jdump-~ts-~b~ts", [Name, erlang:unique_integer([positive]), Extension])).

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

%% One recording, read back once, handed to every case.
%%
%% The other recorders here take milliseconds and each case does its own. This
%% one starts a whole node, and that node compiles a hundred modules to native
%% code before it gets to ours, which is about nine seconds. Thirteen of those
%% would be two minutes on every run for thirteen readings of the same file, so
%% the tape is recorded once and kept.
with_recording(Fun) ->
    ok = needs_the_jit(),
    {Header, Events, Result} = recording(),
    Fun(Header, Events, Result).

recording() ->
    case persistent_term:get(?MODULE, none) of
        none ->
            Recorded = record(),
            persistent_term:put(?MODULE, Recorded),
            Recorded;
        Recorded ->
            Recorded
    end.

record() ->
    with_source(source(), fun(Source) ->
        Path = scratch("tape", ".tape.gz"),
        Opts = #{by_whom => "tamnd", why => "the native code tape tests", source => Source},
        {ok, Result} = bxtrace_jdump:record(Path, Opts),
        {ok, Header, Events} = bxtrace_tape:read(Path),
        ok = file:delete(Path),
        {Header, Events, Result}
    end).

functions(Events) -> [F || F <- Events, element(1, F) =:= function].
groups(Events) -> [G || G <- Events, element(1, G) =:= group].
natives(Events) -> [N || N <- Events, element(1, N) =:= native].
notes(Events) -> [N || N <- Events, element(1, N) =:= note].
data(Events) -> [D || D <- Events, element(1, D) =:= data].

names(Events) -> [Name || {group, _, _, Name, _} <- groups(Events)].

%% ---------------------------------------------------------------------------
%% Cases

reads_back() ->
    with_recording(fun(Header, Events, Result) ->
        ?EQ("the kind", jdump, maps:get(kind, Header)),
        ?EQ("the module", <<"l1">>, maps:get(module, Header)),
        ?EQ("the flavor", jit, maps:get(flavor, Header)),
        ?EQ("the module the recorder reported", l1, maps:get(module, Result)),
        ct_assert:is_true("there are BEAM instructions", groups(Events) =/= []),
        ct_assert:is_true("there is native code", natives(Events) =/= [])
    end).

the_functions() ->
    with_recording(fun(_Header, Events, _Result) ->
        Named = [{Name, Arity} || {function, _, Name, Arity, _, _} <- functions(Events)],
        ?EQ(
            "the functions, in layout order",
            [{<<"add">>, 2}, {<<"fib">>, 1}, {<<"fib">>, 3}, {<<"module_info">>, 0}, {<<"module_info">>, 1}],
            Named
        )
    end).

%% A function whose name never turned up in the dump is written down as
%% `unnamed', because guessing would be worse. It is still a bug, so it fails
%% here rather than reaching a tape.
every_function_is_named() ->
    with_recording(fun(_Header, Events, _Result) ->
        Nameless = [F || {function, _, <<"unnamed">>, _, _, _} = F <- functions(Events)],
        ?EQ("functions the dump never named", [], Nameless)
    end).

%% Some BEAM instructions cost nothing at all, and which ones is worth pinning,
%% because a real instruction quietly emitting nothing would mean the parse lost
%% its lines rather than that the JIT was clever.
groups_have_code() ->
    with_recording(fun(_Header, Events, _Result) ->
        Silent = lists:usort([Name || {group, _, _, Name, 0} <- groups(Events)]),
        ?EQ("instructions that emitted nothing", [], Silent -- ?FREE),
        Claimed = [{At, N} || {group, At, _, _, N} <- groups(Events)],
        Counted = [{At, length([R || {native, G, _} = R <- natives(Events), G =:= At])} || {At, _} <- Claimed],
        ?EQ("what each group says it emitted against what is there", Claimed, Counted)
    end).

rows_belong() ->
    with_recording(fun(_Header, Events, _Result) ->
        Known = [At || {group, At, _, _, _} <- groups(Events)],
        Rows = natives(Events) ++ notes(Events) ++ data(Events),
        %% Group zero is the handful of lines the assembler writes before the
        %% first instruction, which belong to the file and not to any BEAM
        %% instruction. Anything else pointing at a group nobody wrote is a bug.
        Orphans = [R || R <- Rows, element(2, R) =/= 0, not lists:member(element(2, R), Known)],
        ?EQ("rows belonging to no group", [], Orphans),

        Owners = [F || {group, _, F, _, _} <- groups(Events)],
        Owned = [Index || {function, Index, _, _, _, _} <- functions(Events)],
        ?EQ("groups belonging to no function", [], lists:usort(Owners) -- ([0 | Owned]))
    end).

%% A dump is text about code. Anything on a tape that is not printable ASCII
%% arrived from the module's own bytes rather than from the assembler's words,
%% which is the thing this recorder exists to keep out.
%%
%% This is not hypothetical. A section marker sometimes arrives with a fragment
%% of the module's metadata sitting in the middle of it, left in the assembler's
%% log buffer, and copying that line as it stood put four bytes of a compile
%% chunk on a committed tape. It is not every run and not every machine, so this
%% case is the only thing between that and a tape nobody rereads.
nothing_but_text() ->
    with_recording(fun(_Header, Events, _Result) ->
        Texts = [Text || Row <- Events, is_tuple(Row), Text <- [element(tuple_size(Row), Row)], is_binary(Text)],
        Odd = [Text || Text <- Texts, Text =/= source(), re:run(Text, "[^\\x20-\\x7e]") =/= nomatch],
        ?EQ("rows holding something that is not printable ASCII", [], Odd)
    end).

%% And the marker itself, which is the row that went wrong. There are two
%% sections in a module, the code and the constants, and a third name here would
%% mean the trimming had gone too far or not far enough.
the_sections() ->
    with_recording(fun(_Header, Events, _Result) ->
        Found = lists:usort([Name || {section, _, Name} <- Events]),
        ?EQ("the sections the module has", [<<".rodata">>, <<".text">>], Found)
    end).

%% The trimming itself, called directly, because it cannot be provoked. The
%% rubbish comes from the assembler's log buffer, it is there on some runs and
%% not others, and the two shapes below are the two that have actually turned up
%% on a CI machine. The second one is why matching a name and stopping at the
%% first character that cannot be in one was not enough: the tail of a label is
%% letters, and letters can be in a name.
trimmed_markers() ->
    Markers = [
        ".section .text {#1}",
        ".section .rodata {#1}",
        ".section .rodata3, 0x69, 0x6F, 0x6E, 0x6B, 0x00,  {#1}",
        ".section .rodataodeInfoPrologue",
        ".section .gcc_except_table {#1}"
    ],
    ?EQ(
        "the name each marker leaves behind",
        [{ok, ".text"}, {ok, ".rodata"}, {ok, ".rodata"}, {ok, ".rodata"}, {ok, ".gcc_except_table"}],
        [bxtrace_jdump:section_name(Marker) || Marker <- Markers]
    ).

%% The reason both tapes exist. One beam file, one release, and the two flavors
%% do not run the same instruction. The exact name here is architecture
%% dependent, so what is asserted is that addition is there and that it is not
%% the interpreter's name for it.
a_different_name() ->
    with_recording(fun(_Header, Events, _Result) ->
        Plus = [Name || Name <- names(Events), binary:match(Name, <<"i_plus">>) =:= {0, 6}],
        ct_assert:is_true("the JIT emitted an addition", Plus =/= []),
        ?EQ(
            "the JIT calling addition what the interpreter calls it",
            [],
            [Name || Name <- Plus, Name =:= ?WHAT_THE_INTERPRETER_CALLS_IT]
        )
    end).

%% The whole parse rests on one rule: a comment that is a bare lowercase
%% identifier is an opcode name, and anything else is a note somebody wrote into
%% the emitter. If a release ever writes an opcode name with a space in it, or a
%% note that looks like an identifier, this is where it shows up.
names_against_notes() ->
    with_recording(fun(_Header, Events, _Result) ->
        Odd = [Name || Name <- names(Events), re:run(Name, "^[a-z][A-Za-z0-9_]*$") =:= nomatch],
        ?EQ("group names that are not bare identifiers", [], Odd),
        Plain = [Text || {note, _, Text} <- notes(Events), re:run(Text, "^[a-z][A-Za-z0-9_]*$") =/= nomatch],
        ?EQ("notes that would have been read as opcode names", [], Plain)
    end).

no_addresses() ->
    with_recording(fun(Header, Events, _Result) ->
        %% There are addresses in a dump. What matters is that all of them were
        %% caught and replaced, so the count is a positive number and not a
        %% claim that a dump had none.
        ct_assert:is_true("the recorder found addresses to replace", maps:get(addresses, Header) > 0),
        Left = [
            Text
         || {native, _, Text} <- natives(Events),
            re:run(Text, "0x[0-9A-Fa-f]{9,16}|[0-9]{10,20}") =/= nomatch
        ],
        ?EQ("native instructions still holding something address shaped", [], Left)
    end).

%% The runs of bytes hold the module's own metadata, including the path of the
%% file it was compiled from, so a tape that copied them would publish a
%% directory off somebody's machine. What is kept is a size.
bytes_are_counted() ->
    with_recording(fun(_Header, Events, _Result) ->
        Rows = data(Events),
        ct_assert:is_true("the module carries some data", Rows =/= []),
        Sized = [R || {data, _, _, Size} = R <- Rows, is_integer(Size), Size > 0],
        ct_assert:is_true("the data runs have sizes", Sized =/= []),
        Wrong = [R || {data, _, _, Size} = R <- Rows, not is_integer(Size)],
        ?EQ("data rows holding something other than a byte count", [], Wrong)
    end).

counts_agree() ->
    with_recording(fun(Header, Events, Result) ->
        ?EQ("the function count", length(functions(Events)), maps:get(functions, Header)),
        ?EQ("the BEAM instruction count", length(groups(Events)), maps:get(opcodes, Header)),
        ?EQ("the distinct name count", length(lists:usort(names(Events))), maps:get(distinct_opcodes, Header)),
        ?EQ("the native instruction count", length(natives(Events)), maps:get(natives, Header)),
        ?EQ("the header and what the recorder reported", maps:get(natives, Header), maps:get(natives, Result)),

        %% And the same numbers again from the functions, which is the check
        %% that catches a group filed under the wrong one.
        ?EQ(
            "the instructions the functions between them claim",
            length(groups(Events)) - length([G || {group, _, 0, _, _} = G <- groups(Events)]),
            lists:sum([N || {function, _, _, _, N, _} <- functions(Events)])
        )
    end).

source_is_kept() ->
    with_recording(fun(_Header, Events, _Result) ->
        ?EQ("the source on the tape", [{source, <<"l1">>, source()}], [
            S
         || S <- Events, element(1, S) =:= source
        ])
    end).

%% The child was asked to load one module and it compiled a hundred, because
%% every module a node loads on the way up goes through the JIT first. That is
%% the number worth having on the tape, and the only sanity check available for
%% it here is that it is much larger than one.
the_boot_cost() ->
    with_recording(fun(Header, _Events, _Result) ->
        ct_assert:is_true(
            "the node compiled the standard library on the way up",
            maps:get(modules_jitted, Header) > 50
        )
    end).

no_live_terms() ->
    with_recording(fun(Header, Events, _Result) ->
        ?EQ("the header", ok, bxtrace_tape:portable(Header)),
        Bad = [E || E <- Events, bxtrace_tape:portable(E) =/= ok],
        ?EQ("events holding a pid, port, reference or fun", [], Bad)
    end).

%% The refusal is the case that matters most on the interpreter build, because
%% that is where somebody will run this and get an empty directory. It has to say
%% why, and it has to say where to go instead.
refuses_on_the_interpreter() ->
    case erlang:system_info(emu_flavor) of
        jit ->
            ct_assert:skip(
                "this emulator is the JIT, so there is no refusal to provoke here"
            );
        _ ->
            try bxtrace_jdump:jit_check() of
                Value -> ct_assert:fail("the flavor check on an interpreter", {returned, Value})
            catch
                error:{bxtrace_jdump, Why} ->
                    ct_assert:is_true(
                        "the refusal mentions +JDdump",
                        string:find(Why, "+JDdump") =/= nomatch
                    )
            end
    end.
