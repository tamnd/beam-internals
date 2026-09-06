# The grader for t02. It holds no answers as constants. It writes both modules
# to a temporary directory, compiles each one with the compiler that is running
# on your machine, counts the passes off the tape the compiler printed, and
# compares that against what you said. A grader with 33 written into it would be
# wrong the day somebody adds a pass, and this lesson is about a number that
# moves in every release.

defmodule Boss.Grader do
  @l1 """
  -module(l1).
  -export([add/2, fib/1]).
  add(A, B) -> A + B.
  fib(N) -> fib(N, 0, 1).
  fib(0, A, _) -> A;
  fib(N, A, B) -> fib(N - 1, B, A + B).
  """

  @big """
  -module(big).
  -export([f/1, g/2, h/1]).
  -record(r, {a, b = 0}).
  f(<<X:8, Rest/binary>>) -> [X | f(Rest)];
  f(<<>>) -> [].
  g(K, M) -> case maps:find(K, M) of {ok, V} -> V; error -> #r{a = K} end.
  h(#r{a = A, b = B}) -> try A + B catch _:_ -> 0 end.
  """

  defp capture(fun) do
    {:ok, device} = StringIO.open("")
    mine = Process.group_leader()
    Process.group_leader(self(), device)

    try do
      fun.()
    after
      Process.group_leader(self(), mine)
    end

    {:ok, {_input, output}} = StringIO.close(device)
    output
  end

  # The pass names off one compilation, in the order the compiler ran them.
  defp tape(name, source) do
    dir = Path.join(System.tmp_dir!(), "t02-boss")
    File.mkdir_p!(dir)
    file = Path.join(dir, name <> ".erl")
    File.write!(file, source)

    text =
      capture(fn ->
        :compile.file(String.to_charlist(file), [
          :time,
          :report,
          {:outdir, String.to_charlist(dir)}
        ])
      end)

    lines = String.split(text, "\n")

    {
      for(line <- lines, m = Regex.run(~r/^ (\w+)\s+:\s+\d/, line), do: Enum.at(m, 1)),
      for(line <- lines, m = Regex.run(~r/^    (\w+)\s*:\s+\d/, line), do: Enum.at(m, 1))
    }
  end

  def check(guesses) do
    {small_top, small_sub} = tape("l1", @l1)
    {big_top, big_sub} = tape("big", @big)

    IO.puts("l1 ran #{length(small_top)} top level passes and #{length(small_sub)} sub passes\n")

    answers = [
      {:top, "top level passes", length(big_top)},
      {:sub, "sub passes", length(big_sub)},
      {:same_order, "same list, in order", big_top == small_top}
    ]

    outcomes =
      for {key, label, actual} <- answers do
        guess = Keyword.get(guesses, key)
        right = actual == guess

        IO.puts(
          String.pad_trailing(label, 21) <>
            "you said " <>
            String.pad_trailing(to_string(guess), 8) <>
            "the answer is " <>
            String.pad_trailing(to_string(actual), 8) <>
            if(right, do: "correct", else: "not this time")
        )

        right
      end

    IO.puts("")
    explain(Enum.all?(outcomes))
  end

  defp explain(true) do
    IO.puts("All three.")
    IO.puts("The pipeline is a list in compile.erl and the list does not depend on the program.")
    IO.puts("Every module runs every pass, including the ones that find nothing to do.")
    IO.puts("A bigger module changes what each pass finds, not how many of them there are.")
    IO.puts("That is why the pass count is a fact about the compiler version and not about you.")
    :passed
  end

  defp explain(false) do
    IO.puts("Not all of them.")
    IO.puts("The pipeline is a list in compile.erl, chosen before your program is read.")
    IO.puts("A pass with nothing to do still runs, and expand_records in the shapes cell is one.")
    IO.puts("So the count is the same for both modules, and so is the order.")
    IO.puts("What a bigger module changes is how long each pass takes and how much it rewrites.")
    :try_again
  end
end
