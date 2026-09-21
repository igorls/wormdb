#!/usr/bin/env bash
set -euo pipefail

# Runs Bun benchmark from a remote Tailscale host against this machine.
#
# Usage:
#   scripts/run-remote-bench.sh user@host [extra bench args...]
#
# Example:
#   scripts/run-remote-bench.sh user@bench-host --test exec-transfer --ops 50000

if [[ $# -eq 0 || -z "$1" || "$1" == -* ]]; then
  echo "Usage: $0 user@host [extra bench args...]" >&2
  exit 2
fi
REMOTE="$1"
shift

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SERVER_IP="$(tailscale status --json 2>/dev/null | grep -Eo '"100\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"')"
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(tailscale ip -4 | head -1)"
fi

if [[ -z "$SERVER_IP" ]]; then
  echo "Could not determine local Tailscale IPv4 address" >&2
  exit 1
fi

DEFAULT_ARGS=(
  --host "$SERVER_IP"
  --test exec-transfer
  --ops 50000
  --warmup-ops 2000
  --concurrency 96
  --pool-size 96
  --inflight 64
  --keyspace 100000
  --bank-initial-balance 10000000
  --bank-min-amount 1
  --bank-max-amount 1
)

echo "Running remote benchmark from $REMOTE against $SERVER_IP:6389"

tailscale ssh "$REMOTE" "export PATH=\$HOME/.bun/bin:\$PATH; cd ~/zig-tests-client/apps/bun && bun run src/bin/bench.ts ${DEFAULT_ARGS[*]} $*"
