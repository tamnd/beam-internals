# The grader for m02. It holds no sizes as constants. It builds each term on the
# machine you are sitting at, asks the VM what that term cost, and compares your
# prediction against the answer. A grader with the words written into it would
# be wrong on a 32 bit build and stale the first time a representation changed,
# and this lesson is about not trusting numbers you have not measured.

defmodule Boss.Grader do
  defp targets do
    [
      {:tuple3, "{:a, :b, :c}", fn -> {:a, :b, :c} end},
      {:list3, "[:a, :b, :c]", fn -> [:a, :b, :c] end},
      {:big_binary, "a 65 byte binary", fn -> :binary.copy(<<0>>, 65) end},
      {:record, "the nested term", fn -> {:user, "alice", [1, 2, 3], %{admin: true}} end}
    ]
  end

  def check(guesses) do
    IO.puts("on a #{:erlang.system_info(:wordsize) * 8} bit build\n")

    outcomes =
      for {key, label, build} <- targets() do
        actual = :erts_debug.flat_size(build.())
        guess = Keyword.get(guesses, key)
        right = actual == guess

        IO.puts(
          String.pad_trailing(label, 18) <>
            "you said #{String.pad_leading(inspect(guess), 3)}, " <>
            "the VM says #{String.pad_leading(to_string(actual), 3)}   " <>
            if(right, do: "correct", else: "not this time")
        )

        right
      end

    IO.puts("")
    explain(Enum.all?(outcomes))
  end

  defp explain(true) do
    IO.puts("All four.")
    IO.puts("A tuple of three is a header and three slots, so four words.")
    IO.puts("A list of three is three cells of two words each, so six.")
    IO.puts("A 65 byte binary is off heap, so the process holds a reference and a view of it.")
    IO.puts("That reference is a fixed size no matter how much data is on the other end.")
    IO.puts("The nested term is the sum of the parts plus the tuple that holds them.")
    IO.puts("Five for the tuple, zero for the atom, three for the string, six for the list, six for the map.")
    :passed
  end

  defp explain(false) do
    IO.puts("Not all of them.")
    IO.puts("For the two small ones, count the header and count the slots.")
    IO.puts("For the binary, look again at where the 64 byte line falls and which side is cheaper.")
    IO.puts("For the nested term, size each field on its own first and add the container last.")
    IO.puts("The sizes cell near the top of the notebook has every part you need.")
    :try_again
  end
end
