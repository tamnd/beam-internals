%% The postmortem tape.
%%
%% A crash dump turned into something a person can navigate. The dump this was
%% written against is 1.8 megabytes, 58735 lines and 1214 sections, and the
%% honest description of reading one in a text editor is that you scroll until
%% you give up. The tape is the index: every section named, in file order, with
%% the line it starts on, and for the sections that are a list of facts, the
%% facts themselves.
%%
%% It is not a replacement for the dump. The dump stays in corpora/dumps and the
%% tape points into it. That split is on purpose. The encoded heap of forty
%% three processes is most of the file and none of the reading, so the tape
%% records that a heap is there, how large it is, and a digest of it, and leaves
%% the bytes where they are.
%%
%% Same rule as the other two tapes: this records, it does not judge. Which
%% process killed the node is a judgement and belongs somewhere it can be argued
%% with.
%%
%% ---------------------------------------------------------------------------
%% The format being read
%%
%% A crash dump is a flat list of sections. A section starts with a line whose
%% first character is `=', and the rest of that line is a tag, then optionally a
%% colon and an id. Everything up to the next such line is the body. That is the
%% whole structure, and it is the same split crashdump_viewer does, one
%% character at a time, at
%% lib/observer/src/crashdump_viewer.erl:1007@OTP-29.0.5.
%%
%% The tags are a fixed list, written out as macros at
%% lib/observer/src/crashdump_viewer.erl:127@OTP-29.0.5 so that a misspelling in
%% the viewer is a compile error rather than a section it quietly skips. Two of
%% them are spelled differently there than in the file, because `end' and `fun'
%% are reserved words: the viewer calls them `ende' and `fu'. This recorder
%% keeps the names the file uses and writes them as the quoted atoms 'end' and
%% 'fun', which read back through erl_parse the same as any other atom, so a
%% person reading the tape sees what is actually in the dump.
%%
%% The dump format has its own version, and the viewer refuses anything above
%% [0,5] at lib/observer/src/crashdump_viewer.erl:121@OTP-29.0.5. It is the
%% first thing on the first line, as `=erl_crash_dump:0.5'. The tape carries it
%% so that a dump written by some future release is a fact on the tape rather
%% than a parse that went quietly wrong.
%%
%% ---------------------------------------------------------------------------
%% Two kinds of section
%%
%% Most sections are a list of `Key: Value' lines and go on the tape as facts.
%% The rest are encoded memory, one line per term or per slot, in a form meant
%% for a decoder rather than for a person, and those go on the tape as a
%% summary. Which is which is a list here rather than a guess, and a test asserts
%% that the list still covers a stock dump.
%%
%% Nothing is dropped either way. A line in a fact section that is not shaped
%% like a fact still goes on the tape as a line, and there are three of those in
%% a stock dump: the date on the first line of the header, the `arity = 0' that
%% follows a program counter, and the stack trace the calling scheduler carries.

-module(bxtrace_post).

-export([record/2]).

%% Every tag, from the list in the viewer, with `end' and `fun' spelled the way
%% the file spells them. A tag not on this list still goes on the tape, as a
%% binary rather than an atom, and gets counted in the header's `unknown_kinds'.
%% Turning a name read out of a file into an atom is how an atom table fills up
%% with things nobody chose, so the list is the whole permission.
-define(KINDS, [
    abort,
    allocated_areas,
    allocator,
    atoms,
    binary,
    dirty_cpu_scheduler,
    dirty_cpu_run_queue,
    dirty_io_scheduler,
    dirty_io_run_queue,
    'end',
    erl_crash_dump,
    ets,
    'fun',
    hash_table,
    hidden_node,
    index_table,
    instr_data,
    internal_ets,
    literals,
    loaded_modules,
    memory,
    memory_map,
    memory_status,
    mod,
    no_distribution,
    node,
    not_connected,
    old_instr_data,
    persistent_terms,
    port,
    proc,
    proc_dictionary,
    proc_heap,
    proc_messages,
    proc_stack,
    scheduler,
    timer,
    visible_node
]).

%% The sections that are encoded memory rather than facts. Everything here is a
%% list of addresses and base64, and putting it on the tape would double the
%% size of the corpus to carry something no person reads.
-define(BLOBS, [atoms, binary, literals, persistent_terms, proc_dictionary, proc_heap, proc_messages, proc_stack]).

%% record(Path, Opts) reads a crash dump and writes the tape that indexes it.
%%
%%   #{by_whom => "tamnd",
%%     why     => "the fourteen causes figure",
%%     dump    => "corpora/dumps/out-of-memory.dump"}
record(Path, Opts) ->
    Dump = maps:get(dump, Opts),
    ByWhom = maps:get(by_whom, Opts),
    Why = maps:get(why, Opts),

    %% The whole file at once. A dump from a node that died with a hundred
    %% thousand processes can be gigabytes and this would be the wrong way to
    %% read it, but the specimens in corpora are a couple of megabytes each and
    %% a streaming parser here would be complexity bought with nothing.
    {ok, Raw} = file:read_file(Dump),
    Lines = binary:split(Raw, <<"\n">>, [global]),
    Sections = split(Lines),
    Sections =:= [] andalso error({bxtrace_post, {not_a_crash_dump, Dump}}),

    Header = maps:merge(
        bxtrace_tape:header(postmortem, ByWhom, Why),
        #{
            dump => list_to_binary(filename:basename(Dump)),
            dump_bytes => byte_size(Raw),
            dump_lines => length(Lines),
            sections => length(Sections),
            complete => complete(Lines),
            kinds => tally(Sections),
            unknown_kinds => lists:usort([K || {_, K, _, _, _} <- Sections, is_binary(K)]),
            %% What the dump says about the node that wrote it, which is not the
            %% node that is reading it. The rest of the header describes this
            %% machine, and mixing the two would produce a tape that claims a
            %% dead node's heap was measured in this node's word size.
            dumped => dumped(Sections)
        }
    ),
    {ok, Tape} = bxtrace_tape:open(Path, Header),
    Written = write_all(Tape, Sections),
    {ok, Path, Count} = bxtrace_tape:close(Written),
    {ok, #{
        path => Path,
        events => Count,
        sections => length(Sections),
        complete => maps:get(complete, Header),
        kinds => maps:get(kinds, Header),
        unknown_kinds => maps:get(unknown_kinds, Header),
        slogan => maps:get(slogan, maps:get(dumped, Header), unknown)
    }}.

%% ---------------------------------------------------------------------------
%% Splitting

%% Sections, in file order, as {At, Kind, Id, Line, Body}. `At' counts sections
%% and `Line' is where the section starts in the dump, because the two answer
%% different questions: one orders the tape and the other tells a reader where
%% to look in the file it came from.
%%
%% A line starting with `=' opens a section, and that is the only rule. It is
%% the rule the format itself relies on, so a body line that started with `='
%% would break the viewer as well as this.
split(Lines) ->
    {_, Sections} = lists:foldl(fun open/2, {1, []}, numbered(Lines)),
    finish(lists:reverse(Sections)).

open({N, <<$=, Rest/binary>>}, {At, Sections}) ->
    {Kind, Id} = tag(string:trim(Rest, trailing)),
    {At + 1, [{At, Kind, Id, N, []} | Sections]};
open({_, Line}, {At, [{SAt, Kind, Id, SLine, Body} | Rest]}) ->
    %% Blank lines carry nothing in either kind of section, and dropping them
    %% here keeps the line counts on the tape a count of content.
    case string:trim(Line) of
        <<>> -> {At, [{SAt, Kind, Id, SLine, Body} | Rest]};
        _ -> {At, [{SAt, Kind, Id, SLine, [Line | Body]} | Rest]}
    end;
open({_, _Line}, {At, []}) ->
    %% Anything before the first section header. A well formed dump has none.
    {At, []}.

finish(Sections) ->
    [{At, Kind, Id, Line, lists:reverse(Body)} || {At, Kind, Id, Line, Body} <- Sections].

%% The tag and the id, split at the first colon, which is what the viewer does.
%% A tag on the known list becomes an atom and anything else stays a binary.
tag(Rest) ->
    case binary:split(Rest, <<":">>) of
        [Name] -> {kind(Name), no_id};
        [Name, Id] -> {kind(Name), Id}
    end.

kind(Name) ->
    case [K || K <- ?KINDS, atom_to_binary(K) =:= Name] of
        [Known] -> Known;
        [] -> Name
    end.

%% A dump ends with `=end'. Anything else means the node died while writing, or
%% the disk filled, or somebody copied the file while it was still being
%% written. That is not an error and the recorder does not treat it as one: a
%% truncated dump is often the only dump there is, and the tape says so in the
%% header so a reader knows the last section is short rather than the process
%% being odd.
complete(Lines) ->
    case [L || L <- Lines, string:trim(L) =/= <<>>] of
        [] -> false;
        Kept -> string:trim(lists:last(Kept)) =:= <<"=end">>
    end.

tally(Sections) ->
    lists:foldl(
        fun({_, Kind, _, _, _}, Counts) -> maps:update_with(Kind, fun(N) -> N + 1 end, 1, Counts) end,
        #{},
        Sections
    ).

%% ---------------------------------------------------------------------------
%% What the dump says about itself
%%
%% The first section carries the version in its id, the time it was written on
%% its first line, and then the slogan, the system version, the taints, the atom
%% count and which thread was running when it happened, as facts.
%%
%% The keys stay as the binaries the file used. Making them atoms would read a
%% file we did not write and put its words in the atom table, and the atom table
%% is the one table with no way to take anything back out.
dumped(Sections) ->
    case [S || {_, erl_crash_dump, _, _, _} = S <- Sections] of
        [{_, _, Version, _, Body}] ->
            Facts = maps:from_list([{Key, Value} || Line <- Body, {fact, Key, Value} <- [fact(Line)]]),
            Facts#{
                version => id(Version),
                written => first_line(Body),
                slogan => maps:get(<<"Slogan">>, Facts, unknown)
            };
        _ ->
            #{version => unknown, written => unknown, slogan => unknown}
    end.

id(no_id) -> unknown;
id(Binary) -> Binary.

first_line([Line | _]) -> string:trim(Line);
first_line([]) -> unknown.

%% ---------------------------------------------------------------------------
%% Facts
%%
%% `Key: Value', where the colon is the first one on the line and is followed by
%% a space or by nothing. The first part matters because plenty of values hold
%% colons of their own, as in `Spawned as: proc_lib:init_p/5'. The second part
%% matters because plenty of lines hold a colon that is not a separator at all,
%% as in a stack trace line or in the date the dump was written.
fact(Line) ->
    Trimmed = string:trim(Line, trailing),
    case binary:match(Trimmed, <<":">>) of
        nomatch ->
            not_a_fact;
        {0, 1} ->
            not_a_fact;
        {At, 1} ->
            Key = binary:part(Trimmed, 0, At),
            case Trimmed of
                <<_:At/binary, ":">> -> {fact, Key, <<>>};
                <<_:At/binary, ": ", Value/binary>> -> {fact, Key, string:trim(Value)};
                _ -> not_a_fact
            end
    end.

%% ---------------------------------------------------------------------------
%% Writing
%%
%% One section row, then whatever that section is made of. A reader folding the
%% tape sees the section before the things in it, which is what lets a widget
%% build the tree in one pass.
write_all(Tape, Sections) ->
    lists:foldl(fun section/2, Tape, Sections).

section({At, Kind, Id, Line, Body}, Tape) ->
    Row = {section, At, Kind, id(Id), Line, length(Body)},
    contents(bxtrace_tape:write(Tape, Row), At, Kind, Body).

contents(Tape, At, Kind, Body) ->
    case lists:member(Kind, ?BLOBS) of
        true -> bxtrace_tape:write(Tape, blob(At, Body));
        false -> lists:foldl(fun(Line, Acc) -> content(Acc, At, Line) end, Tape, numbered(Body))
    end.

content(Tape, At, {N, Line}) ->
    case fact(Line) of
        {fact, Key, Value} -> bxtrace_tape:write(Tape, {fact, At, Key, Value});
        not_a_fact -> bxtrace_tape:write(Tape, {line, At, N, string:trim(Line)})
    end.

%% What a blob section gets instead of its contents. The digest is what makes
%% the summary worth having: two dumps whose heaps differ entirely produce the
%% same line count and the same byte count often enough that a tape without one
%% would say they matched.
blob(At, Body) ->
    Joined = iolist_to_binary(lists:join($\n, Body)),
    {blob, At, length(Body), byte_size(Joined), binary:encode_hex(crypto:hash(sha256, Joined), lowercase)}.

numbered(Items) -> lists:zip(lists:seq(1, length(Items)), Items).
