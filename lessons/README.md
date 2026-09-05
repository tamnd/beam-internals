# Lessons

One directory per lesson, named by its stable id. Ids never change and never get renumbered, because they end up in urls, in blueprint cross references, in the claim ledger and in other people's notes. A deleted lesson leaves a tombstone page rather than a dead link.

The id carries the pass it belongs to. `o` is orientation, `t` is the tourist pass, `m` is the mechanic pass, `s` is surgery, and `ca`, `cb` and `cc` are the three capstone tracks.

## What a lesson directory holds

```
lessons/07-scheduling/m34/
  lesson.livemd      the lesson, plain markdown, hand written
  meta.toml          id, title, part, env, duration, deps, blueprint, boss
  boss.exs           the boss fight grader
  expected/          committed output, one file per cell, written by `just bake`
  files/             figures and helper modules, under the name Livebook uses
```

`lesson.livemd` opens in Livebook Desktop with none of this repository present. Nothing in the build pipeline is needed to read or run a lesson, which is why the format was chosen.

## How a cell gets compared

Every elixir cell in a notebook goes in one of three lists in `meta.toml`, and `just bake` refuses a cell that is in none of them.

```toml
[bake]
# Compared byte for byte. The output is the same on every machine.
deterministic = ["sizes", "order", "boss"]

# Run so that a cell which stops compiling is caught, and nothing more.
not_compared = ["fairness"]

# Compared once the noise has been filtered out. The recording holds the
# filtered form and the lesson page holds what a real machine printed.
[bake.normalised]
banner = ["build-flags"]
```

The third list is the interesting one. A cell that prints a pid, a port, a reference, a duration, a path or a node name prints something different every time and is still saying the same thing, so `python3 -m tools.normalise` will list the filters that erase those shapes.

Filters are named per cell and never applied to everything, because the shape that is noise in one lesson is the answer in the next. `m55` decodes a pid for the node `a@b` out of a binary literal and prints the node name it got, so the `nodes` filter would erase exactly what that cell exists to show.

Before reaching for a filter, ask whether the number you want to erase is the number the cell is about. If it is, the cell belongs in `not_compared` and the reason belongs in a comment next to it. A filter that erases the answer turns a green build into a lie, which is worse than not checking.

## What a lesson has to do

Ask the question a reader arrives with, in the words they would use before this lesson gave them better ones. Make them predict before they run anything. Show the answer with something they can execute rather than asserting it in prose. Say what is still not explained, and name the lesson that explains it.

Anything the lesson states about the runtime goes in the ledger with an evidence class. Open an issue with the lesson template before writing, so the question and the prediction gate get argued about while they are still cheap to change.
