#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# WormDB 3-Node Cluster Test — Full Orchestration
#
# Builds the Linux binary + Docker image, starts a 3-node cluster,
# runs the TypeScript replication test suite, then performs a failover
# test (stop a node, write to another, restart, verify anti-entropy
# catch-up sync), and tears everything down.
#
# Prerequisites:
#   - Zig 0.16+ installed and on PATH
#   - Docker + Docker Compose
#   - Bun installed and on PATH (for the TS test)
#   - git submodules initialized (deps/meshguard)
#
# Usage:
#   ./scripts/test-cluster.sh            # full: build + start + test + failover + cleanup
#   ./scripts/test-cluster.sh --no-build  # skip build (assumes image wormdb:latest exists)
#   ./scripts/test-cluster.sh --keep      # keep cluster running after tests
#   ./scripts/test-cluster.sh --only-ts   # run only the TS test (assumes cluster is up)
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

COMPOSE_FILE="docker-compose.cluster-test.yml"
NODE1="wormdb-test-node1"
NODE2="wormdb-test-node2"
NODE3="wormdb-test-node3"

pass() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; FAILED=1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

FAILED=0
DO_BUILD=true
KEEP=false
ONLY_TS=false

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=false ;;
    --keep)    KEEP=true ;;
    --only-ts) ONLY_TS=true; DO_BUILD=false ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

cleanup() {
  if [ "$KEEP" = true ]; then
    echo -e "\n${YELLOW}Keeping cluster running.${NC} Stop with: docker compose -f $COMPOSE_FILE down -v"
    return
  fi
  echo -e "\n${YELLOW}Tearing down cluster...${NC}"
  docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
}
trap cleanup EXIT

# ── Build ───────────────────────────────────────────────────────────
if [ "$DO_BUILD" = true ]; then
  echo "=== Building WormDB Linux binary ==="
  zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast -Dcrypto-backend=std
  pass "Linux binary built"

  echo -e "\n=== Building Docker image ==="
  docker build -t wormdb:latest .
  pass "Docker image built"
fi

if [ "$ONLY_TS" = true ]; then
  echo -e "\n=== Running TypeScript cluster test (cluster assumed running) ==="
  if bun run apps/bun/src/bin/cluster-test.ts; then
    pass "TypeScript cluster test passed"
  else
    fail "TypeScript cluster test failed"
    exit 1
  fi
  exit 0
fi

# ── Start cluster ───────────────────────────────────────────────────
echo -e "\n=== Starting 3-node cluster ==="
docker compose -f "$COMPOSE_FILE" up -d --wait
pass "3-node cluster started"
docker compose -f "$COMPOSE_FILE" ps

# Wait for SWIM convergence
info "Waiting for SWIM gossip convergence (15s)..."
sleep 15

# ── Run TypeScript test ─────────────────────────────────────────────
echo -e "\n=== Phase 1-5: TypeScript Cluster Replication Test ==="
if bun run apps/bun/src/bin/cluster-test.ts; then
  pass "TypeScript cluster test passed"
else
  fail "TypeScript cluster test failed"
fi

# ── Failover test ───────────────────────────────────────────────────
echo -e "\n=== Phase 6: Failover + Anti-Entropy Sync ==="

info "Stopping node2 (simulating node failure)..."
docker stop "$NODE2" > /dev/null 2>&1
pass "Node2 stopped"

info "Waiting for SWIM to detect node2 death (10s)..."
sleep 10

# Write to node1 while node2 is down (using the bun client CLI)
FAILOVER_KEY="ctest:failover:$(date +%s)"
FAILOVER_VAL="written-while-node2-down"
info "Writing to node1 while node2 is down..."
bun run apps/bun/src/bin/client.ts --host 127.0.0.1 --port 26389 SET "$FAILOVER_KEY" "$FAILOVER_VAL" > /dev/null
pass "Key written to node1: $FAILOVER_KEY"

# Verify node3 has the replicated key
info "Verifying replication to node3..."
NODE3_VAL=""
for i in $(seq 1 30); do
  NODE3_VAL=$(bun run apps/bun/src/bin/client.ts --host 127.0.0.1 --port 26391 GET "$FAILOVER_KEY" 2>/dev/null || echo "")
  if echo "$NODE3_VAL" | grep -q "$FAILOVER_VAL"; then
    break
  fi
  sleep 1
done
if echo "$NODE3_VAL" | grep -q "$FAILOVER_VAL"; then
  pass "Key replicated to node3 (while node2 was down)"
else
  fail "Key NOT replicated to node3"
fi

info "Restarting node2..."
docker start "$NODE2" > /dev/null 2>&1
pass "Node2 restarted"

info "Waiting for node2 to rejoin cluster and anti-entropy sync (up to 30s)..."
sleep 5

SYNCED=false
for i in $(seq 1 15); do
  VAL=$(bun run apps/bun/src/bin/client.ts --host 127.0.0.1 --port 26390 GET "$FAILOVER_KEY" 2>/dev/null || echo "")
  if echo "$VAL" | grep -q "$FAILOVER_VAL"; then
    SYNCED=true
    break
  fi
  sleep 2
done

if [ "$SYNCED" = true ]; then
  pass "Anti-entropy sync successful — node2 caught up after rejoin ✓"
else
  fail "Anti-entropy sync FAILED — node2 does not have the key after rejoin"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
if [ "$FAILED" = 0 ]; then
  echo -e "${GREEN}All cluster tests passed!${NC}"
else
  echo -e "${RED}Some tests FAILED.${NC}"
fi
echo "═══════════════════════════════════════════"

exit $FAILED
