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
  assets/            figures and helper modules for this lesson only
```

`lesson.livemd` opens in Livebook Desktop with none of this repository present. Nothing in the build pipeline is needed to read or run a lesson, which is why the format was chosen.

## What a lesson has to do

Ask the question a reader arrives with, in the words they would use before this lesson gave them better ones. Make them predict before they run anything. Show the answer with something they can execute rather than asserting it in prose. Say what is still not explained, and name the lesson that explains it.

Anything the lesson states about the runtime goes in the ledger with an evidence class. Open an issue with the lesson template before writing, so the question and the prediction gate get argued about while they are still cheap to change.
