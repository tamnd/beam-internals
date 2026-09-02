# Everything CI does, runnable locally with the same command. If a gate only
# exists in a workflow file then CI is the first place a contributor meets it,
# which is the slowest possible feedback loop.

set shell := ["bash", "-uc"]

# The full set, same order as ci.yml
default: check

check: prose ledger blueprints citations site-check
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

# Citation shape, and resolution when the pinned tree is checked out.
citations:
    python3 -m tools.refcheck

# Same, but fails when the pinned tree is missing rather than skipping.
citations-strict:
    python3 -m tools.refcheck --strict

# Stage the book into the site directory and regenerate the navigation.
site-stage:
    python3 -m tools.sitebuild

site-check:
    python3 -m tools.sitebuild --check

site-serve: site-stage
    mkdocs serve --config-file site/mkdocs.yml

site-build: site-stage
    mkdocs build --strict --config-file site/mkdocs.yml

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
