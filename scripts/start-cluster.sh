#!/bin/sh
# Quick start script for WormDB cluster

set -e

echo "=== WormDB Cluster Quick Start ==="

# Build if needed
if [ ! -f "zig-out/bin/wormdb" ]; then
    echo "Building WormDB..."
    zig build -Doptimize=ReleaseSmall
fi

# Build Docker image
echo "Building Docker image..."
docker build -t wormdb:latest .

# Start cluster
echo "Starting 3-node cluster..."
docker compose up -d

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
sleep 3

# Show status
echo ""
echo "=== Cluster Status ==="
docker compose ps

echo ""
echo "=== Connection Info ==="
echo "Node 1: localhost:6389"
echo "Node 2: localhost:6390"
echo "Node 3: localhost:6391"
echo ""
echo "Quick test:"
echo "  echo 'SET testkey testvalue' | nc localhost 6389"
echo "  echo 'GET testkey' | nc localhost 6389"
echo ""
echo "WORM mode test:"
echo "  echo 'SET immutable data WORM' | nc localhost 6389"
echo "  echo 'SET immutable newvalue' | nc localhost 6389  # Should fail"
echo ""
echo "To stop:"
echo "  docker compose down"