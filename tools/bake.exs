# The half of `just bake` that needs a real VM.
#
# tools/bake.py does the parsing, the comparing and the reporting. This reads a
# directory of numbered cell files, runs them the way Livebook runs them, and
# writes down what each one printed. It is deliberately small. Everything that
# needs an opinion lives on the Python side, where it can be tested on a machine
# with no Erlang on it.
#
# Called as: elixir tools/bake.exs <work dir> <lesson dir>

defmodule Bake do
  def main([work, lesson]) do
    # The cells run as if they were the notebook itself, because two of them
    # call `Code.require_file("boss.exs", __DIR__)` and `__DIR__` comes from the
    # file the code says it came from. Point it anywhere else and the boss
    # fights cannot find their graders.
    file = Path.expand(Path.join(lesson, "lesson.livemd"))
    out = Path.join(work, "out")
    File.mkdir_p!(out)

    start = {[], Code.env_for_eval(file: file)}

    work
    |> Path.join("cells")
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(start, fn name, {binding, env} ->
      code = File.read!(Path.join([work, "cells", name]))
      {text, carried} = evaluate(name, code, binding, env, file)
      File.write!(Path.join(out, Path.rootname(name) <> ".txt"), text)
      carried
    end)
  end

  # This is Livebook's own evaluation, copied rather than approximated. See
  # `eval_elixir/3` in lib/livebook/runtime/evaluator.ex: it parses with the
  # notebook as the file, evaluates with `prune_binding: true`, and carries the
  # binding and the environment into the next cell.
  #
  # The detail that matters is `prune_binding`, and it is not a detail. An
  # anonymous function built in an evaluated cell captures the binding around
  # it, so how much binding survives changes how many heap words that function
  # costs, and m02 is a lesson about how many heap words things cost. Evaluate
  # without the flag and the recordings are of a session no reader will ever
  # have.
  defp evaluate(name, code, binding, env, file) do
    {:ok, capture} = StringIO.open("")
    mine = Process.group_leader()
    Process.group_leader(self(), capture)

    try do
      quoted = Code.string_to_quoted!(code, file: file)
      {value, fresh, env} = Code.eval_quoted_with_env(quoted, binding, env, prune_binding: true)

      printed = StringIO.flush(capture)
      # Livebook shows you what the cell printed, and when it printed nothing it
      # shows the value the cell evaluated to.
      text = if printed == "", do: inspect(value) <> "\n", else: printed

      {text, {carry(binding, fresh), env}}
    catch
      kind, reason ->
        # Written to stderr, which is a device of its own rather than the group
        # leader we swapped out a moment ago, so this lands on the terminal
        # instead of in a capture nobody will read.
        IO.puts(:stderr, "cell #{name} did not survive its own run\n")
        IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
        System.halt(1)
    after
      Process.group_leader(self(), mine)
    end
  end

  # `merge_binding/2` from the same file. Pruning drops variables the cell did
  # not use, and a reader still expects one they bound three cells ago to be
  # there, so anything the new binding does not mention is carried forward.
  defp carry(previous, fresh) do
    named = Map.new(fresh)
    fresh ++ Enum.reject(previous, fn {var, _} -> Map.has_key?(named, var) end)
  end
end

Bake.main(System.argv())
