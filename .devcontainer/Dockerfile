# The container a contributor works in, not the one a reader learns in.
#
# A reader gets Livebook Desktop and a browser, and needs neither this file nor
# the repository. This image is for the people writing lessons, running the
# checkers and building the site.
#
# The OTP version here tracks the pin in refcheck.toml. When the pin moves, this
# moves with it, and the drift watcher is what notices that they have separated.

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG OTP_VERSION=29.0.5
ARG ELIXIR_VERSION=1.20.4
ARG LIVEBOOK_VERSION=0.19.9

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Building the emulator from source is a Part 5 exercise, so the build
# dependencies are here rather than being something a reader discovers halfway
# through a lesson. The list is what erts actually needs, not a guess.
RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf \
      build-essential \
      ca-certificates \
      curl \
      git \
      libncurses-dev \
      libssl-dev \
      unixodbc-dev \
      libwxgtk3.2-dev \
      libgl1-mesa-dev \
      libglu1-mesa-dev \
      libpng-dev \
      libsctp-dev \
      xsltproc \
      fop \
      openjdk-21-jdk-headless \
      python3 \
      python3-pip \
      python3-venv \
      just \
    && rm -rf /var/lib/apt/lists/*

# asdf, so that the OTP version in the container is the pinned one rather than
# whatever the distribution happens to ship this month.
USER vscode
ENV ASDF_DIR=/home/vscode/.asdf
ENV PATH=$ASDF_DIR/bin:$ASDF_DIR/shims:$PATH

RUN git clone --depth 1 --branch v0.16.7 https://github.com/asdf-vm/asdf.git $ASDF_DIR \
    && . $ASDF_DIR/asdf.sh \
    && asdf plugin add erlang \
    && asdf plugin add elixir \
    && KERL_BUILD_DOCS=yes asdf install erlang $OTP_VERSION \
    && asdf install elixir $ELIXIR_VERSION \
    && asdf set -u erlang $OTP_VERSION \
    && asdf set -u elixir $ELIXIR_VERSION

RUN . $ASDF_DIR/asdf.sh \
    && mix local.hex --force \
    && mix local.rebar --force \
    && mix escript.install --force hex livebook $LIVEBOOK_VERSION

ENV PATH=/home/vscode/.mix/escripts:$PATH
