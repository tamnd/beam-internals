#!/usr/bin/env escript
%% -*- erlang -*-
%%! -noshell

%% The recordings that go in corpora, and the provenance that goes with them.
%%
%% Every artefact in corpora has an entry in corpora/manifest.toml saying which
%% build made it, on what, by whom and why. Typing that entry by hand is how a
%% manifest ends up describing a file that was replaced six months ago, so this
%% prints the entry rather than asking anybody to remember the fields. Paste
%% what it prints into corpora/manifest.toml, and `python3 -m tools.corpus'
%% checks that what is pasted matches the file that is there.
%%
%% The recording is the command in the entry. That is the point of naming them:
%% `produced_by' has to be something a reader can run, and a name is easier to
%% run correctly than a paragraph describing what somebody did once.
%%
%%   ./bxtrace/record.escript --list
%%   ./bxtrace/record.escript l1-passes
%%   ./bxtrace/record.escript --dumps
%%   ./bxtrace/record.escript --all
%%   ./bxtrace/record.escript --entry l1-dis

-mode(compile).

main(Args) ->
    Root = filename:dirname(filename:dirname(escript:script_name())),
    Out = build(Root),
    case who(Args) of
        {_, ["--list"]} -> list();
        {_, ["--entry" | Names]} -> entries(Root, Names);
        {By, ["--all"]} -> run_what_it_can(Root, Out, By, recordings());
        {By, ["--dumps"]} -> run_what_it_can(Root, Out, By, specimens());
        {_, []} -> usage();
        {By, Names} -> run(Root, Out, By, Names)
    end.

usage() ->
    io:format("usage: record.escript [--by NAME] [--list | --all | --dumps | --entry NAME ... | NAME ...]~n"),
    halt(2).

%% Who is recording this. It defaults to whoever is logged in, which is right
%% often enough, and takes a name for the times it is not: a shared machine, a
%% container, or anywhere USER says something nobody can be asked a question.
who(["--by", Name | Rest]) -> {Name, Rest};
who(Args) -> {default_by_whom(), Args}.

default_by_whom() ->
    case os:getenv("USER") of
        false -> "unknown";
        User -> User
    end.

list() ->
    [io:format("~-26s  ~ts~ts~n", [Name, note(Spec), maps:get(why, Spec)]) || {Name, Spec} <- recordings()],
    halt(0).

%% A recording that needs a particular machine says so in the listing, so that
%% somebody deciding what to re record can see it before running it rather than
%% after.
note(Spec) ->
    case maps:get(needs, Spec, []) of
        [] -> "";
        Needs -> io_lib:format("[needs ~ts] ", [lists:join(" and ", [wants(N) || N <- Needs])])
    end.

wants({flavor, Flavor}) -> io_lib:format("the ~w flavor", [Flavor]);
wants({arch, Arch}) -> io_lib:format("~ts", [Arch]).

%% ---------------------------------------------------------------------------
%% What there is to record
%%
%% One entry per artefact, and the entry is the whole definition: where it goes,
%% why it is needed, which lessons will be graded against it, and the function
%% that makes it. Adding a recording means adding one of these, which is the
%% cheapest thing that still leaves the manifest able to be generated.

recordings() ->
    fixed() ++ specimens().

%% The fourteen crash dump specimens. They are not written out one by one here
%% because the recipe for each already lives in bxtrace_specimen, next to what
%% the dump is expected to contain. This turns each of those into a recording
%% with a name, which is what makes `produced_by' a command somebody can run.
specimens() ->
    [
        {"dump-" ++ maps:get(name, Spec), #{
            path => "dumps/" ++ maps:get(name, Spec) ++ ".tape.gz",
            kind => postmortem,
            why => maps:get(why, Spec),
            needed_by => ["m62"],
            record => fun(_Root, By, Path) -> bxtrace_specimen:record(Spec, Path, By) end
        }}
     || Spec <- bxtrace_specimen:all()
    ].

fixed() ->
    [
        {"l1-passes", #{
            path => "passes/l1.tape.gz",
            kind => pass,
            why => "the figure that a six line module runs 33 passes and 60 sub passes",
            needed_by => ["m12"],
            record => fun(Root, By, Path) ->
                bxtrace_pass:record(Path, #{
                    by_whom => By,
                    why => "the figure that a six line module runs 33 passes and 60 sub passes",
                    source => filename:join([Root, "corpora", "src", "l1.erl"]),
                    stages => [to_core, to_asm]
                })
            end
        }},
        %% The two disassembly tapes. Both need an emulator configured
        %% `--disable-jit', because `erts_debug:disassemble/1' is one line
        %% returning false on the JIT, so neither of these can be re-recorded on
        %% a release you installed with a package manager. The recorder says so
        %% rather than writing an empty tape.
        {"l1-dis", #{
            path => "dis/l1.tape.gz",
            kind => dis,
            needs => [{flavor, emu}],
            why => "the opcodes the loader chose for a six line module, none of which the compiler emitted",
            needed_by => ["m21"],
            record => fun(Root, By, Path) ->
                bxtrace_dis:record(Path, #{
                    by_whom => By,
                    why =>
                        "the opcodes the loader chose for a six line module, none of which the "
                        "compiler emitted",
                    source => filename:join([Root, "corpora", "src", "l1.erl"])
                })
            end
        }},
        {"spinner-dis", #{
            path => "dis/spinner.tape.gz",
            kind => dis,
            needs => [{flavor, emu}],
            why => "the smallest loop there is, so the cost of one iteration can be counted in instructions",
            needed_by => ["m21"],
            record => fun(Root, By, Path) ->
                bxtrace_dis:record(Path, #{
                    by_whom => By,
                    why =>
                        "the smallest loop there is, so the cost of one iteration can be counted "
                        "in instructions",
                    source => filename:join([Root, "corpora", "src", "spinner.erl"])
                })
            end
        }},
        %% The two native code tapes. Same module, same release, two instruction
        %% sets, which is the pair the comparison is made from. Both need the
        %% JIT, so they are the other half of the pair above and cannot be
        %% recorded on the same machine as it.
        {"l1-jdump-x86_64", #{
            path => "jdump/l1-x86_64.tape.gz",
            kind => jdump,
            needs => [{flavor, jit}, {arch, "x86_64"}],
            why => "what the JIT emitted for a six line module on x86-64",
            needed_by => ["m26"],
            record => fun(Root, By, Path) ->
                bxtrace_jdump:record(Path, #{
                    by_whom => By,
                    why => "what the JIT emitted for a six line module on x86-64",
                    source => filename:join([Root, "corpora", "src", "l1.erl"])
                })
            end
        }},
        {"l1-jdump-aarch64", #{
            path => "jdump/l1-aarch64.tape.gz",
            kind => jdump,
            needs => [{flavor, jit}, {arch, "aarch64"}],
            why => "the same module on AArch64, so the two can be put side by side",
            needed_by => ["m26"],
            record => fun(Root, By, Path) ->
                bxtrace_jdump:record(Path, #{
                    by_whom => By,
                    why => "the same module on AArch64, so the two can be put side by side",
                    source => filename:join([Root, "corpora", "src", "l1.erl"])
                })
            end
        }},
        %% The two wire tapes. Same two nodes, same release, and the only
        %% difference is that the connecting node is started `-hidden' in the
        %% second one. That turns off one flag, and the pair is what shows the
        %% flags to be a negotiation rather than a formality: the handshake is
        %% the same 133 bytes either way and what happens afterwards is not.
        %%
        %% Neither needs a particular machine. They need a loopback interface
        %% and an epmd, which is what `erl -name' starts on its own.
        {"handshake", #{
            path => "dist/handshake.tape.gz",
            kind => wire,
            why => "the five messages two nodes exchange before they are connected",
            needed_by => ["m56"],
            record => fun(_Root, By, Path) ->
                bxtrace_wire:record(Path, #{
                    by_whom => By,
                    why => "the five messages two nodes exchange before they are connected"
                })
            end
        }},
        {"handshake-hidden", #{
            path => "dist/handshake-hidden.tape.gz",
            kind => wire,
            why => "the same handshake from a hidden node, which is one flag different",
            needed_by => ["m56"],
            record => fun(_Root, By, Path) ->
                bxtrace_wire:record(Path, #{
                    by_whom => By,
                    why => "the same handshake from a hidden node, which is one flag different",
                    hidden => true
                })
            end
        }},
        {"one-spinner", #{
            path => "traces/one-spinner.tape.gz",
            kind => reds,
            why => "the opening figure for t07, one process spending one budget at a time",
            needed_by => ["t07"],
            record => fun(_Root, By, Path) ->
                bxtrace_reds:record(Path, #{
                    by_whom => By,
                    why => "the opening figure for t07, one process spending one budget at a time",
                    run => fun() -> spinner:spin(200000) end,
                    for => 60000
                })
            end
        }}
    ].

%% ---------------------------------------------------------------------------
%% Running one

run(Root, _Out, By, Names) ->
    Specs = [{Name, spec(Name)} || Name <- Names],
    [one(Root, By, Name, Spec) || {Name, Spec} <- Specs],
    halt(0).

run_what_it_can(Root, Out, By, Specs) ->
    lists:foreach(
        fun({Name, Spec}) ->
            io:format("%% skipped ~ts: this is a ~w ~ts machine and that tape needs ~ts~n", [
                Name,
                erlang:system_info(emu_flavor),
                arch(erlang:system_info(system_architecture)),
                lists:join(" and ", [wants(N) || N <- unmet(Spec)])
            ])
        end,
        [Pair || {_, Spec} = Pair <- Specs, skip(Spec)]
    ),
    run(Root, Out, By, [Name || {Name, Spec} <- Specs, not skip(Spec)]).

%% Some recordings only work on a particular machine. Two things come up so far.
%% A disassembly tape needs the interpreter and a stock release is the JIT, and
%% a native code dump needs the JIT and exists once per instruction set, so the
%% pair of them has to be recorded on two machines.
%%
%% Asked for by name it refuses, because somebody typed that name and wants the
%% tape. Reached through `--all' it says what it skipped and carries on, because
%% `--all' on a laptop should re record everything a laptop can and then tell
%% you what it could not.
skip(Spec) -> unmet(Spec) =/= [].

unmet(Spec) -> [Need || Need <- maps:get(needs, Spec, []), not met(Need)].

met({flavor, Flavor}) -> erlang:system_info(emu_flavor) =:= Flavor;
met({arch, Arch}) -> arch(erlang:system_info(system_architecture)) =:= Arch.

spec(Name) ->
    case lists:keyfind(Name, 1, recordings()) of
        {_, Spec} ->
            Spec;
        false ->
            io:format("no recording called ~ts. there is:~n", [Name]),
            [io:format("  ~ts~n", [N]) || {N, _} <- recordings()],
            halt(1)
    end.

one(Root, By, Name, Spec) ->
    Path = filename:join([Root, "corpora", maps:get(path, Spec)]),
    Record = maps:get(record, Spec),
    {ok, Result} = Record(Root, By, Path),
    entry(Root, Name),
    io:format("%% ~ts: ~p~n~n", [Name, maps:remove(path, Result)]).

%% The entry for a tape that is already recorded, without recording it again.
%%
%% This exists because the machine that can make a tape is not always the
%% machine that can describe it. The disassembly tapes come off an OTP built
%% `--disable-jit', and a build like that is configured with as little as
%% possible in it, so it has no crypto and cannot work out a sha256. Copy the
%% tape somewhere ordinary and run this, and the entry comes out the same,
%% because every field in it is read from the tape rather than from the machine
%% printing it.
entries(_Root, []) ->
    io:format("usage: record.escript --entry NAME ...~n"),
    halt(2);
entries(Root, Names) ->
    [entry(Root, Name) || Name <- Names],
    halt(0).

entry(Root, Name) ->
    Spec = spec(Name),
    Path = filename:join([Root, "corpora", maps:get(path, Spec)]),
    io:format("~ts~n", [manifest(Name, Spec, Path)]).

%% ---------------------------------------------------------------------------
%% The manifest entry
%%
%% Every field is read out of the tape rather than asked of the machine running
%% this, except the two things no machine can answer: what the tape is for and
%% which lessons need it. Those two come from the recording's own entry above,
%% where a person wrote them.
%%
%% Reading the tape rather than the machine is what makes the entry checkable.
%% `python3 -m tools.corpus' compares the manifest against the tape header field
%% by field, and if the entry were printed from the live VM those two would
%% agree because they were both true at the same moment rather than because they
%% describe the same file. Six months later, when somebody copies a tape into
%% place and pastes an entry printed on their own laptop, only one of those two
%% catches it.

manifest(Name, Spec, Path) ->
    {ok, Bytes} = file:read_file(Path),
    {ok, Header, _} = read_header(Path),
    {_Family, OsName, OsVersion} = maps:get(os, Header),
    said("kind", Name, atom_to_list(maps:get(kind, Spec)), atom_to_list(maps:get(kind, Header))),
    [
        io_lib:format("[[artefact]]~n", []),
        field("path", maps:get(path, Spec)),
        field("produced_by", "./bxtrace/record.escript " ++ Name),
        field("kind", atom_to_list(maps:get(kind, Header))),
        field("flavor", atom_to_list(maps:get(flavor, Header))),
        field("arch", arch(maps:get(arch, Header))),
        field("os", lists:flatten(io_lib:format("~w ~ts", [OsName, OsVersion]))),
        field("build", atom_to_list(maps:get(build, Header))),
        field("recorded", day(maps:get(recorded, Header))),
        field("by_whom", maps:get(by_whom, Header)),
        field("why", maps:get(why, Spec)),
        io_lib:format("needed_by = [~ts]~n", [
            lists:join(", ", [io_lib:format("\"~ts\"", [L]) || L <- maps:get(needed_by, Spec)])
        ]),
        io_lib:format("bytes = ~b~n", [byte_size(Bytes)]),
        field("sha256", binary_to_list(binary:encode_hex(crypto:hash(sha256, Bytes), lowercase)))
    ].

%% Reading the whole tape to get at its first line is wasteful and it is also
%% the only reader there is, and these are small. A tape that will not read is a
%% tape with no entry, which is the right answer.
read_header(Path) ->
    case bxtrace_tape:fold(Path, fun(_, N) -> N + 1 end, 0) of
        {ok, Header, Count} ->
            {ok, Header, Count};
        {error, Reason} ->
            io:format("~ts will not read: ~p~n", [Path, Reason]),
            halt(1)
    end.

said(Field, Name, Same, Same) ->
    {Field, Name, Same};
said(Field, Name, Spec, Tape) ->
    io:format("~ts says its ~ts is ~ts and the tape says ~ts~n", [Name, Field, Spec, Tape]),
    halt(1).

field(Key, Value) -> io_lib:format("~ts = \"~ts\"~n", [Key, Value]).

%% The manifest wants the instruction set on its own, because the JIT emits a
%% different one on each and a tape that only said `aarch64-apple-darwin24.6.0'
%% would need parsing by everything that reads it.
arch(Triple) ->
    hd(string:split(Triple, "-")).

%% The tape stamps the second it was recorded and the manifest holds the day,
%% because a manifest is read by people and nobody needs the second.
day(Timestamp) ->
    hd(string:split(Timestamp, "T")).

%% ---------------------------------------------------------------------------
%% Building
%%
%% The same one step compile the test runner does, for the same reason: these
%% are small modules with no dependencies and a build system between here and
%% running them would be a build system to keep working.

build(Root) ->
    Out = temp_dir(),
    true = code:add_patha(Out),
    [
        compile_one(Out, S)
     || S <-
            sources(filename:join([Root, "bxtrace", "src"])) ++
                sources(filename:join([Root, "corpora", "src"]))
    ],
    Out.

sources(Dir) ->
    [S || S <- filelib:wildcard(filename:join(Dir, "*.erl")), hd(filename:basename(S)) =/= $.].

compile_one(Out, Source) ->
    case compile:file(Source, [{outdir, Out}, return_errors, debug_info]) of
        {ok, Module} ->
            {module, Module} = code:ensure_loaded(Module),
            Module;
        {error, Errors, Warnings} ->
            io:format("~ts does not compile~n~p~n~p~n", [Source, Errors, Warnings]),
            halt(1)
    end.

temp_dir() ->
    Base = filename:join([
        case os:getenv("TMPDIR") of
            false -> "/tmp";
            Set -> Set
        end,
        "bxtrace-record-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Base),
    Base.
