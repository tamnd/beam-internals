# The grader for t07. It does not hold the answers as constants, it measures
# them on the machine you are sitting at and compares your prediction against
# what the VM actually charged. A grader with the answer written in it would go
# stale the moment the accounting changed, which is the exact failure this
# lesson is about.

defmodule Boss.Target do
  def total(list), do: total(list, 0)
  defp total([], acc), do: acc
  defp total([h | t], acc), do: total(t, acc + h)

  def size([]), do: 0
  def size([_ | t]), do: 1 + size(t)
end

defmodule Boss.Grader do
  @elements 100_000

  def check(guesses) do
    list = Enum.to_list(1..@elements)
    baseline = measure(fn -> :ok end)

    results = [
      {:total, "total/1", measure(fn -> Boss.Target.total(list) end) - baseline},
      {:size, "size/1", measure(fn -> Boss.Target.size(list) end) - baseline}
    ]

    IO.puts("#{@elements} elements, on #{:erlang.system_info(:emu_flavor)}\n")

    outcomes =
      for {key, label, charged} <- results do
        actual = charged / @elements
        guess = Keyword.get(guesses, key)
        right = is_number(guess) and round(actual) == round(guess)

        IO.puts(
          "#{String.pad_trailing(label, 10)} " <>
            "you said #{inspect(guess)}, " <>
            "the VM charged #{charged} for #{@elements} elements, " <>
            "which is #{Float.round(actual, 3)} each  #{if right, do: "correct", else: "not this time"}"
        )

        right
      end

    IO.puts("")
    explain(outcomes)
  end

  defp explain([true, true]) do
    IO.puts("Both right.")
    IO.puts("total/1 is tail recursive, so each element costs one entry and nothing else.")
    IO.puts("size/1 has to come back to do the addition, so each element costs an entry and a return.")
    IO.puts("If your figures came out slightly above one and two, the remainder is garbage collection.")
    IO.puts("The collector charges the process whose stack it had to grow, so deep recursion pays for itself.")
    :passed
  end

  defp explain(_) do
    IO.puts("Not yet. Look at where the recursive call sits in each clause.")
    IO.puts("If it is the last thing the clause does, the frame is gone and there is no return to pay for.")
    IO.puts("If something is waiting to happen after it, the call has to come back, and coming back costs one.")
    :try_again
  end

  defp measure(fun) do
    parent = self()

    pid =
      spawn(fn ->
        {:reductions, before} = Process.info(self(), :reductions)
        fun.()
        {:reductions, after_} = Process.info(self(), :reductions)
        send(parent, {self(), after_ - before})
      end)

    receive do
      {^pid, delta} -> delta
    end
  end
end
