import Bitwise

# The grader for m55. It is a differential oracle and nothing more. It has no
# expected bytes written into it. For every term in the corpus it asks the VM
# what the encoding is and asks your function what the encoding is, and if the
# two binaries differ it tells you where. A table of expected answers would go
# stale the first time the format grew a tag. The VM will not.
defmodule Boss.Grader do
  @shown 6

  defp corpus do
    [
      0,
      1,
      42,
      255,
      256,
      -1,
      -256,
      2_147_483_647,
      2_147_483_648,
      -2_147_483_649,
      576_460_752_303_423_487,
      12_345_678_901_234_567_890_123_456_789,
      1 <<< 3000,
      :ok,
      :"a longer atom",
      :"",
      true,
      false,
      nil,
      1.0,
      -0.5,
      3.14159,
      [],
      "",
      "alice",
      <<0, 255>>,
      {1, 2, 3},
      {},
      {:a},
      [1, 2, 3],
      [1, 2, 300],
      [:a, :b],
      [:a | :b],
      [1, 2 | 3],
      [[1], [2]],
      %{},
      %{a: 1},
      %{1 => :a, 2 => :b},
      %{"k" => [1, 2, 3]},
      %{:a => 1, 1 => :b, "s" => 2},
      {:user, "alice", [1, 2, 3], %{admin: true}},
      List.duplicate(7, 300),
      List.to_tuple(List.duplicate(:x, 300)),
      Map.new(1..40, fn i -> {i, i * i} end)
    ]
  end

  def check(encode) do
    results = Enum.map(corpus(), fn t -> {t, verdict(encode, t)} end)
    failures = Enum.reject(results, fn {_, v} -> v == :ok end)

    IO.puts("#{length(results)} terms in the corpus")
    IO.puts("#{length(results) - length(failures)} match the VM byte for byte")
    IO.puts("#{length(failures)} do not")

    if failures != [] do
      IO.puts("\n#{min(@shown, length(failures))} of them, spread across the corpus:")
      failures |> spread(@shown) |> Enum.each(&report/1)
    end

    if failures == [] do
      IO.puts("\nEvery term in the corpus, including the ones put there to catch you out.")
      IO.puts("The empty atom, the improper list, the bignum too long for a one byte size,")
      IO.puts("the list of bytes that has to be a string and the one that must not be,")
      IO.puts("the map whose keys are of three different types and have to come out in order.")
      IO.puts("Your encoder and the emulator now agree on all of it.")
      :passed
    else
      IO.puts("\nRead the byte where they first differ, look that tag up in the standard,")
      IO.puts("and fix one clause at a time. The oracle is not going anywhere.")
      :try_again
    end
  end

  # Taking the first few would show six integers and teach nothing. Walking the
  # list at a stride shows a failure of each kind the corpus has in it.
  defp spread(list, n) when length(list) <= n, do: list

  defp spread(list, n) do
    list |> Enum.take_every(div(length(list), n)) |> Enum.take(n)
  end

  defp verdict(encode, term) do
    real = :erlang.term_to_binary(term, [:deterministic])

    try do
      case encode.(term) do
        ^real -> :ok
        yours when is_binary(yours) -> {:differs, yours, real}
        other -> {:not_a_binary, other}
      end
    rescue
      e -> {:raised, e.__struct__}
    end
  end

  defp report({term, {:raised, kind}}) do
    IO.puts("  #{label(term)}  raised #{inspect(kind)}")
  end

  defp report({term, {:not_a_binary, other}}) do
    IO.puts("  #{label(term)}  returned #{inspect(other, limit: 3)}, which is not a binary")
  end

  defp report({term, {:differs, yours, real}}) do
    at = first_difference(yours, real, 0)
    IO.puts("  #{label(term)}  first differs at byte #{at}")
    IO.puts("      yours #{window(yours, at)}")
    IO.puts("      the VM #{window(real, at)}")
  end

  defp label(term), do: String.pad_trailing(inspect(term, limit: 4, printable_limit: 12), 28)

  defp first_difference(<<b, a::binary>>, <<b, c::binary>>, n),
    do: first_difference(a, c, n + 1)

  defp first_difference(_, _, n), do: n

  defp window(bin, at) do
    from = max(at - 2, 0)

    bin
    |> :binary.bin_to_list()
    |> Enum.drop(from)
    |> Enum.take(8)
    |> Enum.map_join(" ", &to_string/1)
    |> then(&(if from > 0, do: "... " <> &1, else: &1))
  end
end
