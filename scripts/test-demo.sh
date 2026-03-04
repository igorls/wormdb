#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# WormDB Notepad Cluster Demo — Automated Test Script
#
# Tests the full replication flow:
# 1. Write to Node A → verify replicated to Node B
# 2. Stop Node A → write to Node B
# 3. Restart Node A → verify anti-entropy catch-up sync
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

NODE_A="http://localhost:3001"
NODE_B="http://localhost:3002"

pass() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

# ── Helpers ──
api_get() { curl -sf --max-time 10 "$1" 2>/dev/null; }
api_post() { curl -sf --max-time 10 -X POST "$1" -H "Content-Type: application/json" ${2:+-d "$2"} 2>/dev/null; }
api_put() { curl -sf --max-time 10 -X PUT "$1" -H "Content-Type: application/json" -d "$2" 2>/dev/null; }

wait_for() {
  local url="$1" retries=20
  for i in $(seq 1 $retries); do
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# Retry a GET until the response matches a pattern
retry_until() {
  local url="$1" pattern="$2" max_tries="${3:-15}" delay="${4:-2}"
  for i in $(seq 1 $max_tries); do
    local resp
    resp=$(curl -sf --max-time 5 "$url" 2>/dev/null || echo "")
    if echo "$resp" | grep -q "$pattern"; then
      echo "$resp"
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  WormDB Notepad Cluster Replication Demo ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: Verify both servers are up ──
info "Checking notepad servers..."
wait_for "$NODE_A/api/notes" || fail "Notepad A not responding"
pass "Notepad A up at $NODE_A"
wait_for "$NODE_B/api/notes" || fail "Notepad B not responding"
pass "Notepad B up at $NODE_B"

# Wait for cluster gossip to converge
info "Waiting for cluster gossip convergence (5s)..."
sleep 5

# ── Step 2: Create note on Node A ──
info "Creating note on Node A..."
NOTE_A=$(api_post "$NODE_A/api/notes")
NOTE_ID=$(echo "$NOTE_A" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$NOTE_ID" ] || fail "Failed to create note on Node A"
pass "Note created: $NOTE_ID"

# ── Step 3: Update the note ──
info "Updating note on Node A..."
api_put "$NODE_A/api/notes/$NOTE_ID" '{"title":"Hello from A","body":"Written on Node A","author":"TestA"}' > /dev/null
pass "Note updated with title 'Hello from A'"

# Wait for replication
sleep 2

# ── Step 4: Verify replication to Node B ──
info "Checking replication to Node B..."
NOTE_B=$(api_get "$NODE_B/api/notes/$NOTE_ID")
if echo "$NOTE_B" | grep -q "Hello from A"; then
  pass "Note replicated to Node B ✓"
else
  echo "  Response: $NOTE_B"
  fail "Note NOT found on Node B — replication failed"
fi

# ── Step 5: Stop Node A ──
info "Stopping Node A (simulating disconnect)..."
docker stop wormdb-demo-a > /dev/null 2>&1
pass "Node A stopped"

# Wait for SWIM to detect death (suspicion timeout = 5s + grace)
info "Waiting for SWIM to detect Node A death (15s)..."
sleep 15

# ── Step 6: Write to Node B while A is down ──
info "Creating second note on Node B (while A is down)..."
NOTE_B2=$(api_post "$NODE_B/api/notes")
NOTE_ID2=$(echo "$NOTE_B2" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$NOTE_ID2" ] || fail "Failed to create note on Node B"
pass "Note created on B: $NOTE_ID2"

api_put "$NODE_B/api/notes/$NOTE_ID2" '{"title":"Written while A down","body":"This was written on Node B while Node A was disconnected","author":"TestB"}' > /dev/null
pass "Note updated on B: 'Written while A down'"

# ── Step 7: Restart Node A ──
info "Restarting Node A..."
docker start wormdb-demo-a > /dev/null 2>&1
pass "Node A restarted"

# Wait for WormDB to bind and reconnect to cluster
info "Waiting for Node A to rejoin cluster..."
wait_for "$NODE_A/api/notes" || fail "Notepad A not responding after restart"
pass "Notepad A is back up"

# ── Step 8: Trigger sync by writing on B (this triggers replicateWrite + needs_sync) ──
info "Triggering anti-entropy sync..."
api_put "$NODE_B/api/notes/$NOTE_ID2" '{"title":"Written while A down","body":"This was written on Node B while Node A was disconnected - trigger sync","author":"TestB"}' > /dev/null 2>&1 || true
sleep 3

# ── Step 9: Verify catch-up sync on Node A ──
info "Checking if Node A caught up (retrying for up to 30s)..."
if retry_until "$NODE_A/api/notes/$NOTE_ID2" "Written while A down" 15 2; then
  pass "Anti-entropy sync successful — Node A has the note written while it was down ✓"
else
  echo "  Last response from Node A:"
  curl -sf --max-time 5 "$NODE_A/api/notes/$NOTE_ID2" 2>/dev/null || echo "    (empty/error)"
  fail "Anti-entropy sync FAILED — Node A does NOT have the note"
fi

echo ""
echo "═══════════════════════════════════════════"
echo -e "${GREEN}All tests passed!${NC}"
echo ""
echo "Open these URLs to see the live demo:"
echo "  Tab A: $NODE_A"
echo "  Tab B: $NODE_B"
echo ""
echo "To stop: docker compose -f docker-compose.demo.yml down -v"
echo "═══════════════════════════════════════════"
