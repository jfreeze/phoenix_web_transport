#!/usr/bin/env bash
# Builds the two dependencies that need special handling:
#
#   quicer  - Erlang NIF around msquic. Needs cmake and OpenSSL 3. We link the
#             Homebrew libcrypto (QUICER_TLS_VER=sys) and fetch the quictls
#             submodule msquic still compiles for its TLS layer.
#   cowboy  - HTTP/3 and WebTransport are compiled only when the COWBOY_QUICER
#             macro is defined. Mix cannot pass rebar3 erl_opts to a dependency,
#             but the Erlang compiler honours ERL_COMPILER_OPTIONS.
#
# Run via `mix deps.quic` (part of `mix setup`).
set -euo pipefail
# Runs inside whichever Mix project invoked it (the library root or demo/).
DEPS_DIR="${DEPS_DIR:-deps}"; [ -d "$DEPS_DIR/quicer" ] || DEPS_DIR=../deps

export QUICER_TLS_VER=sys
export OPENSSL_ROOT_DIR="${OPENSSL_ROOT_DIR:-/opt/homebrew/opt/openssl@3}"
export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=1

command -v cmake >/dev/null || { echo "cmake is required: brew install cmake" >&2; exit 1; }
[ -d "$OPENSSL_ROOT_DIR" ] || { echo "OpenSSL 3 not found at $OPENSSL_ROOT_DIR: brew install openssl@3" >&2; exit 1; }

if [ -d "$DEPS_DIR/quicer/msquic" ] && [ ! -f "$DEPS_DIR/quicer/msquic/submodules/quictls/Configure" ]; then
  (cd "$DEPS_DIR/quicer/msquic" && git submodule update --init --depth 1 submodules/quictls)
fi

mix deps.compile snabbkaffe quicer
ERL_COMPILER_OPTIONS="[{d,'COWBOY_QUICER',1}]" mix deps.compile cowboy --force

echo "quicer NIF: $(ls "$DEPS_DIR/../_build/${MIX_ENV:-dev}/lib/quicer/priv/libquicer_nif.so" 2>/dev/null || ls "$DEPS_DIR/quicer/priv/libquicer_nif.so")"
