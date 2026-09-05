%% The disassembly tape recorder, checked against a module whose loaded shape is
%% known.
%%
%% Most of these cases cannot run on the machine you are reading this on. A
%% stock release ships the JIT, `erts_debug:disassemble/1' returns false on the
%% JIT, and there is nothing to record. So they report as skipped with the
%% reason rather than as passes, and the one case that can run everywhere is the
%% refusal, which runs on whichever flavor the other cases do not.
%%
%% The tape in corpora was recorded on an OTP 29.0.5 configured `--disable-jit'.
%% These tests re record the same module from source, so a release that changes
%% what the loader does shows up here as a failing test rather than as a corpus
%% file nobody re read.
-module(bxtrace_dis_test).

-export([cases/0]).

-define(EQ(What, Expected, Actual), ct_assert:eq(What, Expected, Actual)).

%% What the OTP 29.0.5 loader makes of the module below, in layout order,
%% written out rather than computed. Not one of these names is emitted by the
%% compiler: the beam file holds `gc_bif2', `is_eq_exact', `move' and
%% `call_only', and every one of them has been rewritten by the time it is in
%% memory. That is the fact the whole tape exists for, so it is the fact the
%% test pins.
-define(OPCODES, [
    %% add(A, B) -> A + B.
    <<"i_func_info_IaaI">>,
    <<"i_plus_xxjd">>,
    <<"return">>,
    %% fib(N) -> fib(N, 0, 1).
    <<"i_func_info_IaaI">>,
    <<"move_x2_c">>,
    <<"move_x1_c">>,
    <<"i_call_only_f">>,
    %% fib(0, A, _) -> A; fib(N, A, B) -> fib(N - 1, B, A + B).
    <<"i_func_info_IaaI">>,
    <<"i_is_eq_exact_immed_frc">>,
    <<"move_return_x">>,
    <<"i_increment_rWd">>,
    <<"i_plus_xxjd">>,
    <<"swap_xx">>,
    <<"i_call_only_f">>,
    %% module_info/0 and module_info/1, which nobody typed.
    <<"i_func_info_IaaI">>,
    <<"move_cr">>,
    <<"call_light_bif_only_be">>,
    <<"deallocate_return_Q">>,
    <<"i_func_info_IaaI">>,
    <<"move_shift_cxx">>,
    <<"call_light_bif_only_be">>,
    <<"deallocate_return_Q">>
]).

cases() ->
    [
        {"a recording reads back as a tape", fun reads_back/0},
        {"the loader rewrote every instruction the compiler emitted", fun the_opcodes/0},
        {"the five functions are on the tape, module_info included", fun the_functions/0},
        {"every instruction belongs to a function that is on the tape", fun instructions_belong/0},
        {"offsets start at zero in each function and only go up", fun offsets_climb/0},
        {"an instruction is a whole number of machine words", fun whole_words/0},
        {"no machine address survives on the tape", fun no_addresses/0},
        {"a branch target names an instruction on the tape", fun targets_resolve/0},
        {"the header counts agree with the events", fun counts_agree/0},
        {"the module's own source is on the tape", fun source_is_kept/0},
        {"the size of the interpreter loop is recorded", fun interpreter_size/0},
        {"nothing on the tape is a live term", fun no_live_terms/0},
        {"a JIT emulator refuses rather than writing an empty tape", fun refuses_on_the_jit/0}
    ].

%% ---------------------------------------------------------------------------
%% What runs where

%% The reason a case did not run, said in full, because a skip nobody can read
%% is the same as a test nobody wrote.
needs_the_interpreter() ->
    case erlang:system_info(emu_flavor) of
        emu ->
            ok;
        Other ->
            ct_assert:skip(
                lists:flatten(
                    io_lib:format(
                        "this emulator is the ~w flavor, erts_debug:disassemble/1 returns false "
                        "on it, and a disassembly tape needs an OTP configured --disable-jit",
                        [Other]
                    )
                )
            )
    end.

%% ---------------------------------------------------------------------------
%% The module under the microscope
%%
%% The same six lines the pass tape uses, so the two tapes are about one module
%% and a reader comparing them is comparing like with like.

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
    filename:join(Dir, io_lib:format("bxtrace-dis-~ts-~b~ts", [Name, erlang:unique_integer([positive]), Extension])).

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

with_recording(Name, Fun) ->
    ok = needs_the_interpreter(),
    with_source(source(), fun(Source) ->
        Path = scratch(Name, ".tape.gz"),
        Opts = #{by_whom => "tamnd", why => "the disassembly tape tests", source => Source},
        {ok, Result} = bxtrace_dis:record(Path, Opts),
        {ok, Header, Events} = bxtrace_tape:read(Path),
        try
            Fun(Header, Events, Result)
        after
            file:delete(Path)
        end
    end).

functions(Events) -> [F || F <- Events, element(1, F) =:= function].
instructions(Events) -> [I || I <- Events, element(1, I) =:= instruction].

opcodes(Events) -> [Op || {instruction, _, _, _, _, Op, _} <- instructions(Events)].

%% ---------------------------------------------------------------------------
%% Cases

reads_back() ->
    with_recording("reads-back", fun(Header, Events, Result) ->
        ?EQ("the kind", dis, maps:get(kind, Header)),
        ?EQ("the module", <<"l1">>, maps:get(module, Header)),
        ?EQ("the flavor", emu, maps:get(flavor, Header)),
        ?EQ("the module the recorder reported", l1, maps:get(module, Result)),
        ct_assert:is_true("there are instructions", instructions(Events) =/= [])
    end).

the_opcodes() ->
    with_recording("opcodes", fun(_Header, Events, _Result) ->
        ?EQ("the opcodes the loader chose", ?OPCODES, opcodes(Events))
    end).

the_functions() ->
    with_recording("functions", fun(_Header, Events, _Result) ->
        Named = [{Name, Arity} || {function, _, Name, Arity, _, _} <- functions(Events)],
        ?EQ(
            "the functions, in layout order",
            [{<<"add">>, 2}, {<<"fib">>, 1}, {<<"fib">>, 3}, {<<"module_info">>, 0}, {<<"module_info">>, 1}],
            Named
        ),
        Counted = [Count || {function, _, _, _, Count, _} <- functions(Events)],
        ?EQ("how many instructions each one is", [3, 4, 7, 4, 4], Counted)
    end).

instructions_belong() ->
    with_recording("belong", fun(_Header, Events, _Result) ->
        Known = [Index || {function, Index, _, _, _, _} <- functions(Events)],
        Orphans = [I || {instruction, _, F, _, _, _, _} = I <- instructions(Events), not lists:member(F, Known)],
        ?EQ("instructions belonging to no function", [], Orphans),
        %% And the other direction, which is the one that catches a function
        %% whose walk stopped early.
        Counted = [{Index, Count} || {function, Index, _, _, Count, _} <- functions(Events)],
        Actual = [
            {Index, length([I || {instruction, _, F, _, _, _, _} = I <- instructions(Events), F =:= Index])}
         || {Index, _} <- Counted
        ],
        ?EQ("what each function says it holds against what is there", Counted, Actual)
    end).

offsets_climb() ->
    with_recording("offsets", fun(_Header, Events, _Result) ->
        ByFunction = [
            {F, [{Offset, Bytes} || {instruction, _, G, Offset, Bytes, _, _} <- instructions(Events), G =:= F]}
         || {function, F, _, _, _, _} <- functions(Events)
        ],
        lists:foreach(
            fun({F, Rows}) ->
                ?EQ(
                    lists:flatten(io_lib:format("the first offset in function ~b", [F])),
                    0,
                    element(1, hd(Rows))
                ),
                %% Each instruction starts where the one before it ended. There
                %% is no padding between them, which is worth checking because
                %% it is the thing that makes an offset comparable at all.
                Walked = lists:foldl(fun({_, Bytes}, At) -> At + Bytes end, 0, lists:droplast(Rows)),
                ?EQ(
                    lists:flatten(io_lib:format("the last offset in function ~b", [F])),
                    Walked,
                    element(1, lists:last(Rows))
                )
            end,
            ByFunction
        )
    end).

whole_words() ->
    with_recording("words", fun(Header, Events, _Result) ->
        Word = maps:get(wordsize, Header) div 8,
        Odd = [I || {instruction, _, _, _, Bytes, _, _} = I <- instructions(Events), Bytes rem Word =/= 0],
        ?EQ("instructions that are not a whole number of words", [], Odd),
        %% Nothing is free. An instruction is at least the word holding the
        %% address of the code that runs it.
        Empty = [I || {instruction, _, _, _, Bytes, _, _} = I <- instructions(Events), Bytes < Word],
        ?EQ("instructions smaller than one word", [], Empty)
    end).

no_addresses() ->
    with_recording("addresses", fun(Header, Events, Result) ->
        ?EQ("addresses the recorder could not resolve", 0, maps:get(unresolved_addresses, Header)),
        ?EQ("what the recorder reported", 0, maps:get(unresolved_addresses, Result)),
        %% Belt and braces, because the count above is the recorder marking its
        %% own work. Eight hex digits in a row is either an address or a very
        %% strange atom, and there are none of the latter in this module.
        Left = [
            Args
         || {instruction, _, _, _, _, _, Args} <- instructions(Events),
            re:run(Args, "[0-9A-F]{8,}") =/= nomatch
        ],
        ?EQ("arguments still holding something that looks like an address", [], Left)
    end).

targets_resolve() ->
    with_recording("targets", fun(_Header, Events, _Result) ->
        Indexes = [Index || {instruction, Index, _, _, _, _, _} <- instructions(Events)],
        Targets = lists:append([
            [list_to_integer(N) || N <- named(Args)]
         || {instruction, _, _, _, _, _, Args} <- instructions(Events)
        ]),
        ct_assert:is_true("the module branches somewhere", Targets =/= []),
        ?EQ("targets naming an instruction that is not there", [], Targets -- Indexes)
    end).

named(Args) ->
    case re:run(Args, "@([0-9]+)", [global, {capture, all_but_first, list}]) of
        nomatch -> [];
        {match, Found} -> [N || [N] <- Found]
    end.

counts_agree() ->
    with_recording("counts", fun(Header, Events, _Result) ->
        ?EQ("the function count", length(functions(Events)), maps:get(functions, Header)),
        ?EQ("the instruction count", length(instructions(Events)), maps:get(instructions, Header)),
        ?EQ("the distinct opcode count", length(lists:usort(opcodes(Events))), maps:get(opcodes, Header)),
        Bytes = lists:sum([B || {instruction, _, _, _, B, _, _} <- instructions(Events)]),
        ?EQ("the total size of the code", Bytes, maps:get(code_bytes, Header))
    end).

source_is_kept() ->
    with_recording("source", fun(_Header, Events, _Result) ->
        ?EQ("the source on the tape", [{source, <<"l1">>, source()}], [
            S
         || S <- Events, element(1, S) =:= source
        ])
    end).

interpreter_size() ->
    with_recording("interpreter", fun(Header, _Events, _Result) ->
        Bytes = maps:get(interpreter_bytes, Header),
        ct_assert:is_true("the interpreter loop has a size", is_integer(Bytes) andalso Bytes > 0)
    end).

no_live_terms() ->
    with_recording("portable", fun(Header, Events, _Result) ->
        ?EQ("the header", ok, bxtrace_tape:portable(Header)),
        Bad = [E || E <- Events, bxtrace_tape:portable(E) =/= ok],
        ?EQ("events holding a pid, port, reference or fun", [], Bad)
    end).

%% The refusal is the case that matters most on a laptop, because a laptop is
%% where somebody will run this and get nothing. It has to say why.
refuses_on_the_jit() ->
    case erlang:system_info(emu_flavor) of
        emu ->
            ct_assert:skip(
                "this emulator is the interpreter, so there is no refusal to provoke here"
            );
        _ ->
            try bxtrace_dis:flavor_check() of
                Value -> ct_assert:fail("the flavor check on a JIT emulator", {returned, Value})
            catch
                error:{bxtrace_dis, Why} ->
                    ct_assert:is_true(
                        "the refusal mentions --disable-jit",
                        string:find(Why, "--disable-jit") =/= nomatch
                    )
            end
    end.
