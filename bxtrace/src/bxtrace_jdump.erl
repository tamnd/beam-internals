%% The native code tape.
%%
%% What the JIT emitted for a module: every BEAM instruction the loader chose,
%% in order, and under each one the native instructions it turned into. The same
%% six line module recorded on two architectures gives the pair Part 6 is built
%% on, because the interesting question there is not what the native code says,
%% it is how much of it there is per BEAM instruction and how far that differs
%% between two machines running the same release.
%%
%% Pair this with the disassembly tape and there is a second finding sitting in
%% the opcode names. The interpreter loads `add(A, B) -> A + B' as
%% `i_plus_xxjd'. The JIT loads the same beam file as `i_plus_jIssd'. Neither
%% name is in the compiler and neither is in the other flavor, so there is no
%% single list of instructions the BEAM runs, there is one per flavor and the
%% loader picks from the one it was built with.
%%
%% Where the dump comes from
%%
%% `erl +JDdump true' makes the JIT write one `<module>.asm' file into the
%% current directory for every module it compiles, which is every module that
%% gets loaded, including the hundred or so a bare node loads on the way up. The
%% flag is read once at startup, at erts/emulator/beam/erl_init.c:150@OTP-29.0.5,
%% so it cannot be turned on from inside a running node. This recorder starts a
%% child with the flag set, in a directory of its own, and reads the one file it
%% wants back out.
%%
%% What makes the file readable is that the assembler is asked to log a comment
%% before each instruction carrying the name of the BEAM opcode being emitted,
%% at erts/emulator/beam/jit/arm/beam_asm_module.cpp:458@OTP-29.0.5 and at the
%% same place in the x86 assembler. So the file is already grouped by BEAM
%% instruction and the grouping is the emulator's own, not something guessed
%% here.
%%
%% Nothing on the tape is an address
%%
%% Same rule as the disassembly tape, and the dump needs it more. A stub jumping
%% into the emulator's C code shows up as `mov x14, 4412950416', which is a
%% different number every run on the same machine. Any operand that wide is
%% replaced by `addr(N)' against a table kept only while recording, so two stubs
%% going to the same place still look the same and neither shows a number that
%% means anything elsewhere. The header says how many distinct ones there were.
%%
%% The `.byte' runs go the same way and for a second reason. They hold the
%% module's own metadata, which includes the full path of the source file it was
%% compiled from, so copying them onto a tape would publish a directory off
%% somebody's machine. What is kept is the label and the byte count.

-module(bxtrace_jdump).

-export([record/2, jit_check/0]).

%% An operand at least this wide is treated as opaque. Anything a compiler puts
%% in the code as a real constant is far below it, and anything above it in a
%% dump is a pointer into this process.
-define(OPAQUE, 4294967296).

%% record(Path, Opts) compiles a module, loads it in a child with the dump flag
%% on, and writes down what the JIT made of it.
%%
%%   #{by_whom => "tamnd",
%%     why     => "the native code figure for m26",
%%     source  => "corpora/src/l1.erl"}
record(Path, Opts) ->
    Source = maps:get(source, Opts),
    ByWhom = maps:get(by_whom, Opts),
    Why = maps:get(why, Opts),

    ok = jit_check(),
    {ok, Text} = file:read_file(Source),
    Module = list_to_atom(filename:basename(Source, ".erl")),

    {Dump, Jitted} = dump(Source, Module),
    {Functions, Groups, Rows, Addresses} = parse(Dump),

    Header = maps:merge(
        bxtrace_tape:header(jdump, ByWhom, Why),
        #{
            module => atom_to_binary(Module),
            source => list_to_binary(filename:basename(Source)),
            native => native(),
            functions => length(Functions),
            opcodes => length(Groups),
            distinct_opcodes => length(lists:usort([Name || {group, _, _, Name, _} <- Groups])),
            natives => lists:sum([N || {group, _, _, _, N} <- Groups]),
            %% How many modules the node compiled to native code on the way up,
            %% this one included. It is here because it is the number that says
            %% what the JIT costs at startup, and because it is one line to
            %% count and impossible to recover from the tape later.
            modules_jitted => Jitted,
            addresses => Addresses
        }
    ),

    {ok, Tape} = bxtrace_tape:open(Path, Header),
    Written = write_all(Tape, Module, Text, Functions, Groups, Rows),
    {ok, Path, Count} = bxtrace_tape:close(Written),
    {ok, #{
        path => Path,
        events => Count,
        module => Module,
        native => maps:get(native, Header),
        functions => length(Functions),
        opcodes => length(Groups),
        natives => maps:get(natives, Header),
        modules_jitted => Jitted,
        addresses => Addresses
    }}.

%% The interpreter has no JIT to dump, so `+JDdump true' on it writes nothing
%% and the file this wants is never created. Saying so beats a `file:read_file'
%% failure that names a path and not a reason.
jit_check() ->
    case erlang:system_info(emu_flavor) of
        jit ->
            ok;
        Other ->
            error(
                {bxtrace_jdump,
                    "this emulator is the " ++ atom_to_list(Other) ++
                        " flavor, so there is no native code to dump and +JDdump writes nothing. "
                        "Record this one on a stock release, which ships the jit flavor, and record "
                        "the disassembly tape on the --disable-jit build instead."}
            )
    end.

%% Which instruction set the dump is in. The emulator's architecture triple is
%% the honest source for it, because the dump is whatever the assembler for that
%% build emits and there is no separate field saying so.
native() ->
    Triple = erlang:system_info(system_architecture),
    list_to_binary(hd(string:split(Triple, "-"))).

%% ---------------------------------------------------------------------------
%% Getting the dump

%% A child rather than this node, because the flag is read at startup. A
%% directory of its own, because the child writes one file per module it loads
%% and that is over a hundred files nobody asked for.
dump(Source, Module) ->
    Dir = scratch(Module),
    try
        ok = compile_into(Source, Dir),
        ok = load_in_child(Dir, Module),
        Asm = filename:join(Dir, atom_to_list(Module) ++ ".asm"),
        case file:read_file(Asm) of
            {ok, Bytes} ->
                Lines = [unicode:characters_to_list(L) || L <- binary:split(Bytes, <<"\n">>, [global])],
                {Lines, length(filelib:wildcard("*.asm", Dir))};
            {error, Reason} ->
                error({bxtrace_jdump, {no_dump_was_written, Asm, Reason}})
        end
    after
        clean(Dir)
    end.

scratch(Module) ->
    Name = lists:flatten(io_lib:format("jdump-~ts-~b", [Module, erlang:unique_integer([positive])])),
    Dir = filename:join("scratch", Name),
    ok = filelib:ensure_path(Dir),
    Dir.

clean(Dir) ->
    [file:delete(filename:join(Dir, Name)) || Name <- filelib:wildcard("*", Dir)],
    file:del_dir(Dir),
    ok.

compile_into(Source, Dir) ->
    case compile:file(Source, [{outdir, Dir}, return_errors]) of
        {ok, _Module} -> ok;
        {error, Errors, _Warnings} -> error({bxtrace_jdump, {will_not_compile, Source, Errors}})
    end.

%% The child loads the module and stops. `module_info/0' is the cheapest call
%% that forces the load, and the load is what makes the JIT compile it.
%%
%% The dump lands in the working directory, so the working directory is set here
%% rather than by the child, because the hundred modules a node loads while
%% booting are compiled long before any code of ours could run.
load_in_child(Dir, Module) ->
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Eval = lists:flatten(io_lib:format("~w:module_info(module), init:stop().", [Module])),
    Port = open_port({spawn_executable, Erl}, [
        {args, ["+JDdump", "true", "-pa", ".", "-noshell", "-eval", Eval]},
        {cd, Dir},
        exit_status,
        stderr_to_stdout,
        hide,
        binary
    ]),
    wait(Port, []).

wait(Port, Said) ->
    receive
        {Port, {data, More}} -> wait(Port, [More | Said]);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} -> error({bxtrace_jdump, {child_failed, Status, said(Said)}})
    after 120000 ->
        error({bxtrace_jdump, {child_never_finished, said(Said)}})
    end.

said(Said) -> iolist_to_binary(lists:reverse(Said)).

%% ---------------------------------------------------------------------------
%% Reading the dump
%%
%% Four kinds of line and one rule for telling them apart.
%%
%% A comment is the assembler's log of something the emitter asked it to say.
%% Most of them are the name of the BEAM opcode about to be emitted, and the
%% rest are notes a human wrote into the emitter, like the module and function a
%% `func_info' belongs to or which BIF a call goes to. An opcode name is a bare
%% identifier and a note never is, because the notes all carry a space, a colon
%% or a slash. That is the whole rule and the tests hold it to it.
%%
%% An indented line is a native instruction. A line ending in a colon is a
%% label. A line starting with a dot is a directive, either a run of bytes or an
%% assembler section marker.

parse(Lines) ->
    Start = #{
        funs => [],
        groups => [],
        rows => [],
        addrs => #{},
        fun_index => 0,
        group_index => 0
    },
    finish(lists:foldl(fun line/2, Start, Lines)).

line(Raw, State) ->
    case classify(string:trim(Raw, trailing)) of
        blank -> State;
        {comment, Text} -> comment(Text, State);
        {native, Text} -> native_row(Text, State);
        {align, To} -> row({align, group(State), To}, State);
        {label, Text} -> row({label, group(State), list_to_binary(Text)}, State);
        {data, Directive, Bytes} -> row({data, group(State), list_to_binary(Directive), Bytes}, State)
    end.

classify("") ->
    blank;
classify([$# | Rest]) ->
    {comment, string:trim(Rest)};
classify([$\s | _] = Line) ->
    indented(string:trim(Line));
classify([$. | _] = Line) ->
    directive(Line);
classify(Line) ->
    case lists:last(Line) of
        $: -> {label, lists:droplast(Line)};
        _ -> indented(string:trim(Line))
    end.

%% Padding is not an instruction and does not belong in a count of them. It is
%% kept as a row of its own because it is a real difference between the two
%% architectures: x86 pads a function entry to a boundary and AArch64, whose
%% instructions are all four bytes wide, is already there.
indented("align " ++ To) -> {align, list_to_integer(string:trim(To))};
indented(Text) -> {native, Text}.

%% A `.byte' run is counted, never copied. A `.section' marker is kept as it is,
%% because it says which of the module's areas the bytes after it land in and it
%% carries nothing machine specific.
directive(Line) ->
    case string:split(Line, " ") of
        [".section", Rest] -> {label, ".section " ++ Rest};
        [Directive, Rest] -> {data, Directive, count_bytes(Directive, Rest)};
        [Directive] -> {data, Directive, 0}
    end.

count_bytes(Directive, Rest) ->
    Width = width(Directive),
    Width * length(string:split(Rest, ",", all)).

%% The two assemblers name their data directives differently, which is one more
%% thing a reader should not have to know to compare two tapes.
width(".byte") -> 1;
width(".word") -> 4;
width(".xword") -> 8;
width(".db") -> 1;
width(".dw") -> 2;
width(".dd") -> 4;
width(".dq") -> 8;
width(_) -> 0.

%% A bare identifier is the opcode the emitter is about to emit, so it opens a
%% group. Anything else is a note and belongs to the group that is open.
comment(Text, State) ->
    case is_opcode(Text) of
        true -> open(Text, State);
        false -> row({note, group(State), list_to_binary(Text)}, State)
    end.

is_opcode([First | Rest]) when First >= $a, First =< $z ->
    lists:all(fun(C) -> ok_in_name(C) end, Rest);
is_opcode(_) ->
    false.

ok_in_name(C) when C >= $a, C =< $z -> true;
ok_in_name(C) when C >= $A, C =< $Z -> true;
ok_in_name(C) when C >= $0, C =< $9 -> true;
ok_in_name($_) -> true;
ok_in_name(_) -> false.

%% A function starts where the loader put its label. That is one opcode earlier
%% than the `func_info' whose emitter prints the name, and it is the right
%% boundary anyway, because the label belongs to the function it points at. The
%% name arrives a moment later as a note and is filled in then.
open("i_func_label_L" = Name, State) ->
    open_group(Name, begin_function(State));
open(Name, State) ->
    open_group(Name, State).

begin_function(#{fun_index := At, funs := Funs} = State) ->
    State#{fun_index := At + 1, funs := [At + 1 | Funs]}.

open_group(Name, #{group_index := At, groups := Groups} = State) ->
    State#{
        group_index := At + 1,
        groups := [{group, At + 1, current_function(State), list_to_binary(Name), 0} | Groups]
    }.

current_function(#{fun_index := At}) -> At.

group(#{group_index := At}) -> At.

%% Every native instruction gets its address shaped operands replaced before it
%% goes anywhere near the tape.
native_row(Text, #{addrs := Addrs} = State) ->
    {Rewritten, Grown} = rewrite(Text, Addrs),
    Counted = bump(State),
    row({native, group(Counted), list_to_binary(Rewritten)}, Counted#{addrs := Grown}).

bump(#{groups := [{group, At, Fun, Name, N} | Rest]} = State) ->
    State#{groups := [{group, At, Fun, Name, N + 1} | Rest]};
bump(State) ->
    State.

row(Row, #{rows := Rows} = State) ->
    State#{rows := [Row | Rows]}.

%% Decimal and hexadecimal both, because the two assemblers disagree about which
%% one to print a wide operand in and the tape should not.
rewrite(Text, Addrs) ->
    case re:run(Text, "0x[0-9A-Fa-f]{9,16}|[0-9]{10,20}", [global, {capture, first, index}]) of
        nomatch -> {Text, Addrs};
        {match, Spans} -> patch(Text, lists:reverse(Spans), Addrs)
    end.

patch(Text, [], Addrs) ->
    {Text, Addrs};
patch(Text, [[{At, Len}] | Rest], Addrs) ->
    Literal = lists:sublist(Text, At + 1, Len),
    case value(Literal) of
        {ok, Value} when Value >= ?OPAQUE ->
            {Index, Grown} = index_of(Value, Addrs),
            Before = lists:sublist(Text, At),
            After = lists:nthtail(At + Len, Text),
            patch(Before ++ "addr(" ++ integer_to_list(Index) ++ ")" ++ After, Rest, Grown);
        _ ->
            patch(Text, Rest, Addrs)
    end.

value("0x" ++ Hex) ->
    try
        {ok, list_to_integer(Hex, 16)}
    catch
        error:badarg -> not_a_number
    end;
value(Decimal) ->
    try
        {ok, list_to_integer(Decimal)}
    catch
        error:badarg -> not_a_number
    end.

index_of(Value, Addrs) ->
    case maps:find(Value, Addrs) of
        {ok, Index} -> {Index, Addrs};
        error -> {maps:size(Addrs) + 1, Addrs#{Value => maps:size(Addrs) + 1}}
    end.

%% ---------------------------------------------------------------------------
%% Putting the names on the functions

%% The name comes from the note the `func_info' emitter prints, which is the
%% only place in the dump that says what a function is called. A function with
%% no such note is left `unnamed' rather than guessed at, and the tests refuse a
%% tape that has one.
finish(#{funs := Funs, groups := Groups, rows := Rows, addrs := Addrs}) ->
    InOrder = lists:reverse(Groups),
    RowsInOrder = lists:reverse(Rows),
    Named = [name(At, InOrder, RowsInOrder) || At <- lists:reverse(Funs)],
    {Named, InOrder, RowsInOrder, maps:size(Addrs)}.

name(At, Groups, Rows) ->
    Mine = [Index || {group, Index, Fun, _, _} <- Groups, Fun =:= At],
    Notes = [Text || {note, Index, Text} <- Rows, lists:member(Index, Mine)],
    {Name, Arity} = signature(Notes),
    {function, At, Name, Arity, length(Mine),
        lists:sum([N || {group, _, Fun, _, N} <- Groups, Fun =:= At])}.

signature([]) ->
    {<<"unnamed">>, -1};
signature([Note | Rest]) ->
    case re:run(Note, "^[^ :]+:(.+)/([0-9]+)$", [{capture, all_but_first, binary}]) of
        {match, [Name, Arity]} -> {Name, binary_to_integer(Arity)};
        nomatch -> signature(Rest)
    end.

%% ---------------------------------------------------------------------------
%% Writing

%% The functions first, then the dump itself in the order the assembler logged
%% it: each group followed by the lines it produced. A reader that only wants
%% the shape of the module stops after the functions, and a reader that wants
%% the code reads on and never has to sort anything.
write_all(Tape, Module, Text, Functions, Groups, Rows) ->
    ByGroup = lists:foldl(
        fun(Row, Acc) -> maps:update_with(element(2, Row), fun(Was) -> [Row | Was] end, [Row], Acc) end,
        #{},
        Rows
    ),
    Body = lists:flatmap(fun({group, At, _, _, _} = Group) -> [Group | belonging(At, ByGroup)] end, Groups),
    Events =
        [{source, atom_to_binary(Module), Text}] ++ Functions ++ belonging(0, ByGroup) ++ Body,
    lists:foldl(fun(Event, Acc) -> bxtrace_tape:write(Acc, Event) end, Tape, Events).

belonging(At, ByGroup) -> lists:reverse(maps:get(At, ByGroup, [])).
