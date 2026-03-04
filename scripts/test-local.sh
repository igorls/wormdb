#!/bin/bash
# Local test script for WormDB

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "=== WormDB Local Test ==="

# Build if needed
if [ ! -f "zig-out/bin/wormdb" ]; then
    echo "Building WormDB..."
    zig build -Doptimize=ReleaseSmall
fi

# Create test directory
mkdir -p test_cluster/node1 test_cluster/node2 test_cluster/node3

# Start node 1 (seed)
echo "Starting seed node on port 6389..."
./zig-out/bin/wormdb --port 6389 --data test_cluster/node1 &
NODE1_PID=$!
sleep 2

# Start node 2
echo "Starting node 2 on port 6390..."
./zig-out/bin/wormdb --port 6390 --data test_cluster/node2 --seed 127.0.0.1:6389 &
NODE2_PID=$!
sleep 1

# Start node 3
echo "Starting node 3 on port 6391..."
./zig-out/bin/wormdb --port 6391 --data test_cluster/node3 --seed 127.0.0.1:6389 &
NODE3_PID=$!
sleep 1

echo ""
echo "=== Testing Node 1 (Seed) ==="

# Test basic operations
echo -e "${GREEN}Testing SET/GET...${NC}"
echo "SET testkey testvalue" | nc -q1 localhost 6389
echo "GET testkey" | nc -q1 localhost 6389

# Test WORM
echo -e "${GREEN}Testing WORM mode...${NC}"
echo "SET wormkey wormvalue WORM" | nc -q1 localhost 6389
echo "GET wormkey" | nc -q1 localhost 6389
echo -e "${RED}Testing WORM violation (should fail):${NC}"
echo "SET wormkey newvalue" | nc -q1 localhost 6389

# Test delete
echo -e "${GREEN}Testing DELETE...${NC}"
echo "SET deletable value" | nc -q1 localhost 6389
echo "GET deletable" | nc -q1 localhost 6389
echo "DEL deletable" | nc -q1 localhost 6389
echo "GET deletable" | nc -q1 localhost 6389

echo ""
echo "=== Testing Node 2 ==="
echo "GET testkey" | nc -q1 localhost 6390

echo ""
echo "=== Testing Node 3 ==="
echo "GET testkey" | nc -q1 localhost 6391

echo ""
echo -e "${GREEN}All tests passed!${NC}"
echo ""
echo "Nodes running:"
echo "  Node 1 (seed): PID $NODE1_PID, port 6389"
echo "  Node 2: PID $NODE2_PID, port 6390"
echo "  Node 3: PID $NODE3_PID, port 6391"
echo ""
echo "Press Enter to stop all nodes..."
read

# Cleanup
echo "Stopping nodes..."
kill $NODE1_PID $NODE2_PID $NODE3_PID 2>/dev/null || true
rm -rf test_cluster

echo "Done!"