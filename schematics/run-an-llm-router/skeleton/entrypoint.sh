#!/bin/sh
# Router bootstrap.
#
# Runs INSIDE the decrypted environment: compose starts the container with
# `sops exec-env <store> <this script>`, so every value in the encrypted store
# is already in this process's environment and nothing decrypted ever touches
# the filesystem (R-4).
#
# Its only job is to take this router's own credential from the store and
# hand it to the proxy software as its master key, then exec the proxy. (sops
# exec-env forked this script rather than exec'ing it, so the proxy becomes
# that child — see compose.yml.schema.) Provider keys are picked up from the
# environment by the proxy config (see skeleton/config.example.yaml).
set -e

MASTER_KEY_ENV="${ROUTER_MASTER_KEY_ENV:-ROUTER_MASTER_KEY}"
PORT="${ROUTER_PORT:-4000}"

# Fail loudly on a missing credential: never start the proxy with an empty or
# default master key (no silent fallback).
eval "MASTER_KEY=\${$MASTER_KEY_ENV:?$MASTER_KEY_ENV is missing from the decrypted store (P-7)}"
export LITELLM_MASTER_KEY="$MASTER_KEY"

echo "starting the router on 0.0.0.0:$PORT (credential read from $MASTER_KEY_ENV)"
exec litellm --config /opt/llm-router/config.yaml --host 0.0.0.0 --port "$PORT"
