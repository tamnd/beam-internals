# bxkino

The Livebook widgets. Kino components that render what `bxray` collects, so a reader sees a run queue or a heap rather than a list of tuples.

Every widget has a text fallback that prints the same information without a browser. A lesson that only works in a graphical environment is a lesson that excludes people, and it is also a lesson that cannot be checked in CI.

Widgets show recorded data the same way they show live data, which is what lets the whole book be read against `corpora/` by somebody with no runtime.
