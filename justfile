# Everything CI does, runnable locally with the same command. If a gate only
# exists in a workflow file then CI is the first place a contributor meets it,
# which is the slowest possible feedback loop.

set shell := ["bash", "-uc"]

# The full set, same order as ci.yml
default: check

check: prose ledger blueprints bpc-check citations corpus bake-offline site-check
    @echo "all checks passed"

# House style. Catches the em dash, the banned words, sentences wrapped across
# lines, and citations missing their tag.
prose *paths:
    python3 -m tools.lintprose {{ paths }}

# Every claim has an evidence class and the caps are respected.
ledger:
    python3 -m tools.ledger

# Blueprints have their nine sections, in order, and do not lean on a lesson.
blueprints:
    python3 -m tools.bplint

# Regenerate the blueprint regions that come from the VM's own tables. Needs the
# pinned tree, and does nothing without it.
bpc:
    python3 -m tools.bpc

# Same, but compares instead of writing, so a hand edited region fails.
bpc-check:
    python3 -m tools.bpc --check

# Every artefact in corpora has provenance, the provenance matches the bytes on
# disk, and a tape agrees with the manifest row that claims to describe it.
corpus:
    python3 -m tools.corpus

# Citation shape, and resolution when the pinned tree is checked out.
citations:
    python3 -m tools.refcheck

# Same, but fails when the pinned tree is missing rather than skipping.
citations-strict:
    python3 -m tools.refcheck --strict

# Both of the gates that need the pinned tree, which is what the deep CI job
# runs. Run `just pin` first.
deep: citations-strict
    python3 -m tools.bpc --check --strict

# Stage the book into the site directory and regenerate the navigation.
site-stage:
    python3 -m tools.sitebuild

site-check:
    python3 -m tools.sitebuild --check

site-serve: site-stage
    mkdocs serve --config-file site/mkdocs.yml

site-build: site-stage
    mkdocs build --strict --config-file site/mkdocs.yml

# Run every cell of every lesson the way Livebook runs them, and compare what
# came out against the recordings in each lesson's `expected/`. Needs a release
# on the path, same as `conformance`, so it is not part of `check`.
bake *lessons:
    python3 -m tools.bake {{ lessons }}

# The same run, but the recordings are rewritten from it instead of compared
# against. Read the diff before you commit it. A number that moved is either a
# lesson that needs a new sentence or a release that changed underneath one.
bake-write *lessons:
    python3 -m tools.bake --write {{ lessons }}

# The half that needs no Erlang, which is why it can live in `check`. Every
# elixir cell is accounted for in meta.toml, every compared cell has a
# recording, and the output printed inside the lesson matches that recording.
bake-offline:
    python3 -m tools.bake --offline

# The filters a lesson can name in `[bake.normalised]`, and what each one
# erases. A cell that prints a pid or a duration needs one of these before its
# output can be compared against a recording.
filters:
    python3 -m tools.normalise

# A disassembly tape, printed as the memory layout it is. Needs no runtime,
# which is the point: the tape was recorded once on an emulator built
# `--disable-jit', because a stock release ships the JIT and cannot produce it.
dis tape="corpora/dis/l1.tape.gz":
    python3 -m tools.dis {{ tape }}

# The conformance suites, against whatever release is on the path. Needs an
# Erlang release and nothing else, which is the whole design of the runner. Not
# part of `check`, because `check` has to run on a machine with no Erlang.
conformance *suites:
    ./conformance/run.escript {{ suites }}

# What exists, without running any of it.
conformance-list:
    ./conformance/run.escript --list

# The tests for the tape recorders. Also needs a release and nothing else. Kept
# apart from `conformance` because a failure here is news about our code and a
# failure there is news about Erlang.
bxtrace-test *modules:
    ./bxtrace/test.escript {{ modules }}

# Make one of the recordings that go in corpora, and print the manifest entry
# to paste next to it. `just record --list` says what there is.
record *names:
    ./bxtrace/record.escript {{ names }}

# What is on a tape, without drawing any of it. Header, provenance, and a count
# per event tag.
tape +paths:
    ./bxtrace/tape.escript {{ paths }}

# Render one animation and its still. The still lands where the scene file says
# it belongs, which is next to the lesson that shows it. Needs the anim extra,
# which is not installed by `just setup` because Manim is large and no gate
# needs it.
anim scene:
    python3 -m tools.figures {{ scene }}

# Just the still, which takes seconds rather than a minute.
anim-still scene:
    python3 -m tools.figures {{ scene }} --still-only

# Every scene, which is what you run after changing the vocabulary.
anim-all:
    python3 -m tools.figures

# Read upstream and report what has moved away from the pin. Exits 1 when
# something has, which is what the weekly job turns into an issue.
drift:
    python3 -m tools.drift

# The checkers themselves
lint:
    ruff check tools tests
    ruff format --check tools tests

fmt:
    ruff format tools tests

test:
    pytest

# Workflow files, the two things that go wrong with them
lint-workflows:
    yamllint .github .yamllint.yml site/mkdocs.base.yml
    zizmor --persona=regular .github/workflows

# Install everything a contributor needs
setup:
    python3 -m pip install -e ".[dev,site]"

# Manim, separately, because it is large and only needed for drawing.
setup-anim:
    python3 -m pip install -e ".[anim]"

# Fetch the pinned OTP tree. Large, and only needed for citations-strict.
pin:
    git submodule update --init --recursive

# Push the label set to GitHub. Additive, it does not delete labels that are not
# listed, so removing one is a deliberate act rather than a side effect.
labels:
    python3 -m tools.labels --apply

labels-check:
    python3 -m tools.labels
