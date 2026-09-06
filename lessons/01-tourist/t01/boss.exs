# The grader for t01. It holds no answers as constants. It builds each pair on
# the machine you are sitting at, one side at a time, asks the VM whether the two
# ended up as the same word, and compares that against what you said. A grader
# with the answers written into it would be wrong the day a term stopped being
# immediate, and this lesson is about not trusting anything you have not asked
# the machine about.

defmodule Boss.Grader do
  defp pairs do
    [
      {:atom, ":ok twice", fn -> {:ok, String.to_atom("ok")} end},
      {:integer, "1000 twice", fn -> {String.to_integer("1000"), 500 + div(1000, 2)} end},
      {:list, "[:ok] twice", fn -> {[:ok], Enum.map([1], fn _ -> :ok end)} end},
      {:pid, "self() twice", fn -> {self(), self()} end}
    ]
  end

  def check(guesses) do
    IO.puts("on a #{:erlang.system_info(:wordsize) * 8} bit build\n")

    outcomes =
      for {key, label, build} <- pairs() do
        {one, two} = build.()
        actual = :erts_debug.same(one, two)
        guess = Keyword.get(guesses, key)
        right = actual == guess

        IO.puts(
          String.pad_trailing(label, 16) <>
            "you said #{String.pad_trailing(to_string(guess), 6)}" <>
            "the VM says #{String.pad_trailing(to_string(actual), 6)}" <>
            if(right, do: "correct", else: "not this time")
        )

        right
      end

    IO.puts("")
    explain(Enum.all?(outcomes))
  end

  defp explain(true) do
    IO.puts("All four.")
    IO.puts("The atom, the integer and the pid are immediates, so each pair is one word twice.")
    IO.puts("Being equal and being the same word are the same question for those three.")
    IO.puts("The list is two cells on the heap, built twice, so it is two objects that happen to match.")
    IO.puts("The pid is the one people get wrong. A process is a large living thing and its name is a number.")
    :passed
  end

  defp explain(false) do
    IO.puts("Not all of them.")
    IO.puts("For each pair, ask first whether the value fits in a word on its own.")
    IO.puts("If it does there is nothing else to allocate, so both sides have to be the same bits.")
    IO.puts("If it does not, each side got its own room on the heap and the addresses differ.")
    IO.puts("The lens cell near the top of the notebook says which side of that line each kind falls on.")
    :try_again
  end
end
