# Everything CI does, runnable locally with the same command. If a gate only
# exists in a workflow file then CI is the first place a contributor meets it,
# which is the slowest possible feedback loop.

set shell := ["bash", "-uc"]

# The full set, same order as ci.yml
default: check

check: prose ledger blueprints bpc-check citations site-check
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

# The conformance suites, against whatever release is on the path. Needs an
# Erlang release and nothing else, which is the whole design of the runner. Not
# part of `check`, because `check` has to run on a machine with no Erlang.
conformance *suites:
    ./conformance/run.escript {{ suites }}

# What exists, without running any of it.
conformance-list:
    ./conformance/run.escript --list

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

# Fetch the pinned OTP tree. Large, and only needed for citations-strict.
pin:
    git submodule update --init --recursive

# Push the label set to GitHub. Additive, it does not delete labels that are not
# listed, so removing one is a deliberate act rather than a side effect.
labels:
    python3 -m tools.labels --apply

labels-check:
    python3 -m tools.labels
