%% The disassembly tape.
%%
%% What the loader actually left in memory for a module: every instruction in
%% the order it sits there, the opcode the loader chose, its operands, how many
%% bytes it takes up, and which function it belongs to.
%%
%% This is the tape Part 5 is built on. A reader who has got as far as beam
%% assembly has seen `gc_bif2' and `is_eq_exact' and reasonably assumes those
%% are what runs. They are not. The loader rewrites them, picks a variant per
%% operand shape, and fuses common pairs into single instructions, so the six
%% line module in corpora/src/l1.erl arrives as `i_plus_xxjd', `move_x2_c' and
%% `i_is_eq_exact_immed_frc'. None of those names appear anywhere in the
%% compiler. Showing that is much easier than arguing it.
%%
%% ---------------------------------------------------------------------------
%% Why this one needs a build
%%
%% A stock release is the JIT. `erts_debug:disassemble/1' is inside
%% `#ifndef BEAMASM' and the JIT half of it is one line returning `false', at
%% erts/emulator/beam/beam_debug.c:512@OTP-29.0.5. So on anything you can
%% install with a package manager, `erts_debug:df/1' opens a file, writes
%% nothing to it and reports `ok'. That is the whole reason this recorder exists
%% instead of a lesson telling a reader to run `df/1' themselves: the tape gets
%% recorded once on a `--disable-jit' build and read everywhere.
%%
%% The refusal below is loud for the same reason. A recorder that produced an
%% empty tape and said `ok' would put an empty tape in corpora.
%%
%% ---------------------------------------------------------------------------
%% Why not just run erts_debug:df/1 and keep the file
%%
%% `df/1' is a loop over `erts_debug:disassemble/1' that throws away everything
%% except the printed line, at lib/kernel/src/erts_debug.erl:436@OTP-29.0.5. The
%% BIF hands back the address of the next instruction and the MFA this one
%% belongs to, and both are gone by the time the text reaches the file. Calling
%% the BIF directly keeps them, which is what gives every instruction a size and
%% a function without parsing anything back out.
%%
%% The addresses are the other reason. A printed line starts with the raw
%% address of the instruction, and a branch target is printed the same way, so
%% `f(00007FC7C2FC8348)' in one run is a different number in the next run on the
%% same machine. Those are the two things on a tape that cannot be compared, and
%% both go: an instruction records its offset from the start of its function,
%% and a target that names another instruction in this module is rewritten to
%% `@' and that instruction's index. Two machines that loaded the same module
%% then produce byte identical instruction rows, which is the point.

-module(bxtrace_dis).

-export([record/2, flavor_check/0]).

%% record(Path, Opts) loads a module and writes down what the loader made of it.
%%
%%   #{by_whom => "tamnd",
%%     why     => "the specialised opcodes m21 is about",
%%     source  => "corpora/src/l1.erl"}
record(Path, Opts) ->
    Source = maps:get(source, Opts),
    ByWhom = maps:get(by_whom, Opts),
    Why = maps:get(why, Opts),

    ok = flavor_check(),
    {ok, Text} = file:read_file(Source),
    Module = load(Source),

    Raw = [{Mfa, walk(Mfa)} || Mfa <- functions(Module)],
    {Functions, Instructions} = number(Raw),
    {Rows, Unresolved} = resolve(Instructions),

    Header = maps:merge(
        bxtrace_tape:header(dis, ByWhom, Why),
        #{
            module => atom_to_binary(Module),
            source => list_to_binary(filename:basename(Source)),
            compiler => compiler_version(),
            functions => length(Functions),
            instructions => length(Rows),
            opcodes => length(lists:usort([Op || {instruction, _, _, _, _, Op, _} <- Rows])),
            code_bytes => lists:sum([Bytes || {function, _, _, _, _, Bytes} <- Functions]),
            %% Every branch target inside this module is rewritten to an
            %% instruction index. This counts the addresses that were not
            %% rewritten because nothing on the tape sits at them, and it is
            %% zero on the corpus modules. A tape where it is not zero still
            %% holds a raw address somewhere, which is worth seeing rather than
            %% finding out from a diff that never settles.
            unresolved_addresses => Unresolved,
            %% The size of the whole interpreter loop in bytes. One number, and
            %% it is the answer to the question every reader of Part 5 asks
            %% first, which is how big the thing running all this is.
            interpreter_bytes => erts_debug:interpreter_size()
        }
    ),
    {ok, Tape} = bxtrace_tape:open(Path, Header),
    Written = write_all(Tape, Module, Text, Functions, Rows),
    {ok, Path, Count} = bxtrace_tape:close(Written),
    {ok, #{
        path => Path,
        events => Count,
        module => Module,
        functions => length(Functions),
        instructions => length(Rows),
        opcodes => maps:get(opcodes, Header),
        code_bytes => maps:get(code_bytes, Header),
        unresolved_addresses => Unresolved
    }}.

%% ---------------------------------------------------------------------------
%% The refusal

%% Said in full, because the person who hits this is running a package manager
%% release and has no reason to know that the emulator ships in two flavors.
flavor_check() ->
    case erlang:system_info(emu_flavor) of
        emu ->
            ok;
        Other ->
            error(
                {bxtrace_dis,
                    "this emulator is the " ++ atom_to_list(Other) ++
                        " flavor, and erts_debug:disassemble/1 returns false on it. A stock "
                        "release ships that flavor only, so a disassembly tape has to be "
                        "recorded on an OTP configured with --disable-jit. The tape in corpora "
                        "was recorded once on such a build and the manifest entry says which."}
            )
    end.

%% ---------------------------------------------------------------------------
%% Walking a function
%%
%% The BIF takes an MFA or an address and hands back the address of the next
%% instruction, the line, and the MFA the instruction it just printed belongs
%% to. Walking stops when that MFA changes, which is how the end of a function
%% is found, since nothing announces it.

walk(Mfa) ->
    walk(erts_debug:disassemble(Mfa), Mfa, []).

walk(false, _Mfa, Acc) ->
    lists:reverse(Acc);
walk(undef, Mfa, _Acc) ->
    error({bxtrace_dis, {not_loaded, Mfa}});
walk({Next, Line, Mfa}, Mfa, Acc) ->
    walk(erts_debug:disassemble(Next), Mfa, [{address(Line), Line} | Acc]);
walk({_, _, _}, _Mfa, Acc) ->
    %% A different MFA, so the previous instruction was the last one in this
    %% function and this line belongs to the next.
    lists:reverse(Acc).

%% A printed line is the address, a colon and a space, then the opcode and its
%% operands. See erts/emulator/beam/beam_debug.c:476@OTP-29.0.5 for the prefix.
%% The width is 16 hex digits on 64 bit and 8 on 32 bit, so the split is on the
%% separator rather than on a fixed offset.
address(Line) ->
    [Hex, _] = binary:split(Line, <<": ">>),
    binary_to_integer(Hex, 16).

split(Line) ->
    [_, Rest] = binary:split(Line, <<": ">>),
    case binary:split(string:trim(Rest, trailing), <<" ">>) of
        [Op, Args] -> {Op, string:trim(Args, trailing)};
        [Op] -> {Op, <<>>}
    end.

%% Everything the module defines, local functions included, in the order the
%% loader laid them out. `module_info/0' and `module_info/1' are in there and
%% they stay: they are generated rather than written, and a reader who has just
%% learned that the loader rewrites everything is well served by seeing two
%% functions nobody typed.
functions(Module) ->
    Mfas = [{Module, Name, Arity} || {Name, Arity} <- Module:module_info(functions)],
    [Mfa || {_, Mfa} <- lists:sort([{entry(Mfa), Mfa} || Mfa <- Mfas])].

entry(Mfa) ->
    case erts_debug:disassemble(Mfa) of
        {_, Line, Mfa} -> address(Line);
        Other -> error({bxtrace_dis, {cannot_disassemble, Mfa, Other}})
    end.

%% ---------------------------------------------------------------------------
%% Numbering
%%
%% Two passes, because a branch target can point forwards. The first gives every
%% instruction an index and works out its offset and its size, and the second
%% rewrites the targets now that every address has an index. The absolute
%% address rides along between the two passes and is dropped at the end of the
%% second, since it is the one thing on the row that means nothing anywhere
%% else.
%%
%% An instruction's size is the distance to the next one, and the last
%% instruction in a function has no next one on this tape. Its size is the
%% distance to the address the BIF handed back, which is the first word after
%% the function, so it is measured rather than guessed.

number(Raw) ->
    number(Raw, 1, 1, [], []).

number([], _FunIndex, _Index, Functions, Placed) ->
    {lists:reverse(Functions), lists:reverse(Placed)};
number([{{_, Name, Arity}, Lines} | Rest], FunIndex, Index, Functions, Placed) ->
    Entry = element(1, hd(Lines)),
    Sized = sizes(Lines),
    Rows = [
        {Address, {instruction, Index + At - 1, FunIndex, Address - Entry, Bytes, Op, Args}}
     || {At, {Address, Bytes, Op, Args}} <- numbered(Sized)
    ],
    Function =
        {function, FunIndex, atom_to_binary(Name), Arity, length(Rows),
            lists:sum([Bytes || {_, Bytes, _, _} <- Sized])},
    number(
        Rest,
        FunIndex + 1,
        Index + length(Rows),
        [Function | Functions],
        lists:reverse(Rows) ++ Placed
    ).

%% The distance to the next instruction, and for the last one the distance to
%% wherever the disassembler went next.
sizes([{Address, Line} | Rest]) ->
    {Op, Args} = split(Line),
    case Rest of
        [{NextAddress, _} | _] -> [{Address, NextAddress - Address, Op, Args} | sizes(Rest)];
        [] -> [{Address, last_size(Address), Op, Args}]
    end.

last_size(Address) ->
    case erts_debug:disassemble(Address) of
        {Next, _, _} -> Next - Address;
        false -> erlang:system_info(wordsize)
    end.

numbered(Items) -> lists:zip(lists:seq(1, length(Items)), Items).

%% ---------------------------------------------------------------------------
%% Rewriting the targets
%%
%% A branch prints its target as a raw address, `f(00007FC7C2FC8348)'. That is
%% the address of another instruction in this module, so it becomes `@' and that
%% instruction's index, and the tape stops depending on where the loader
%% happened to put the module.
%%
%% Only hex runs that are addresses of instructions on this tape are rewritten.
%% Anything else that happens to look like hex is left where it is and counted,
%% because silently replacing a thing nobody checked is how a tape ends up
%% describing something that was never there.

resolve(Placed) ->
    Known = #{Address => Index || {Address, {instruction, Index, _, _, _, _, _}} <- Placed},
    lists:mapfoldl(
        fun({_, {instruction, Index, FunIndex, Offset, Bytes, Op, Args}}, Left) ->
            {Rewritten, Missed} = rewrite(Args, Known),
            {{instruction, Index, FunIndex, Offset, Bytes, Op, Rewritten}, Left + Missed}
        end,
        0,
        Placed
    ).

rewrite(Args, Known) ->
    case re:run(Args, "[0-9A-F]{8,16}", [global, {capture, first, index}]) of
        nomatch -> {Args, 0};
        {match, Spans} -> patch(Args, lists:reverse(Spans), Known, 0)
    end.

%% Back to front, so replacing one span does not move the others.
patch(Args, [], _Known, Missed) ->
    {Args, Missed};
patch(Args, [[{At, Len}] | Rest], Known, Missed) ->
    Hex = binary:part(Args, At, Len),
    case maps:find(binary_to_integer(Hex, 16), Known) of
        {ok, Index} ->
            Before = binary:part(Args, 0, At),
            After = binary:part(Args, At + Len, byte_size(Args) - At - Len),
            Replaced = <<Before/binary, "@", (integer_to_binary(Index))/binary, After/binary>>,
            patch(Replaced, Rest, Known, Missed);
        error ->
            patch(Args, Rest, Known, Missed + 1)
    end.

%% ---------------------------------------------------------------------------
%% Loading

%% Compiled here rather than taken off the code path, so the tape records what
%% this source produces on this release and not whatever beam file happened to
%% be lying about.
load(Source) ->
    case compile:file(Source, [binary, return_errors, debug_info]) of
        {ok, Module, Binary} ->
            {module, Module} = code:load_binary(Module, Source, Binary),
            Module;
        {error, Errors, _Warnings} ->
            error({bxtrace_dis, {will_not_compile, Source, Errors}})
    end.

compiler_version() ->
    list_to_binary(filename:basename(code:lib_dir(compiler))).

%% ---------------------------------------------------------------------------
%% Writing
%%
%% Source first so a reader of the tape can see the six lines before the fifteen
%% instructions, then the functions, then the instructions in layout order.

write_all(Tape, Module, Text, Functions, Rows) ->
    Events = [{source, atom_to_binary(Module), Text}] ++ Functions ++ Rows,
    lists:foldl(fun(Event, Acc) -> bxtrace_tape:write(Acc, Event) end, Tape, Events).
