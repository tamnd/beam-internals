# bxtrace

The tape recorders. Small programs that capture a real run and write it into `corpora/` with everything needed to say where it came from.

A recorder writes a manifest entry alongside its output, with the command, the build, the machine and the date. That is the difference between evidence and a file somebody found.

Recorders are deliberately dull. They set trace flags, they read counters, they write files. Anything clever belongs in `bxray`, where it can be inspected, or in a lesson, where it can be explained.
