#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/setup-remote-bench-client.sh user@host

if [[ $# -ne 1 || -z "$1" || "$1" == -* ]]; then
  echo "Usage: $0 user@host" >&2
  exit 2
fi
REMOTE="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

echo "[1/3] Installing Bun on $REMOTE (if needed)..."
tailscale ssh "$REMOTE" 'command -v bun >/dev/null 2>&1 || (curl -fsSL https://bun.sh/install | bash)'

echo "[2/3] Syncing apps/bun to $REMOTE:~/zig-tests-client/apps/bun ..."
tar -czf - apps/bun | tailscale ssh "$REMOTE" 'mkdir -p ~/zig-tests-client && tar -xzf - -C ~/zig-tests-client'

echo "[3/3] Installing remote dependencies..."
tailscale ssh "$REMOTE" 'export PATH=$HOME/.bun/bin:$PATH; cd ~/zig-tests-client/apps/bun && bun install'

echo "Remote benchmark client setup complete on $REMOTE"
