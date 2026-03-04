#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/profiles/$(date +%Y%m%d-%H%M%S)-server"
PERF_DATA="${OUT_DIR}/perf-server.data"
PERF_SCRIPT="${OUT_DIR}/perf-server.script"
FOLDED="${OUT_DIR}/perf-server.folded"
SVG="${OUT_DIR}/server-flamegraph.svg"
SERVER_LOG="${OUT_DIR}/server.log"

PROFILE_MODE="${PROFILE_MODE:-full}"

case "${PROFILE_MODE}" in
  quick)
    DEFAULT_OPS=2000
    DEFAULT_WARMUP=200
    DEFAULT_CONCURRENCY=64
    DEFAULT_POOL_SIZE=64
    DEFAULT_KEYSPACE=3000
    ;;
  full)
    DEFAULT_OPS=10000
    DEFAULT_WARMUP=1000
    DEFAULT_CONCURRENCY=128
    DEFAULT_POOL_SIZE=128
    DEFAULT_KEYSPACE=10000
    ;;
  *)
    echo "Invalid PROFILE_MODE='${PROFILE_MODE}'. Use 'quick' or 'full'." >&2
    exit 1
    ;;
esac

BENCH_TESTS="${BENCH_TESTS:-exec-transfer,spacetime-transfer}"
BENCH_OPS="${BENCH_OPS:-${DEFAULT_OPS}}"
BENCH_WARMUP_OPS="${BENCH_WARMUP_OPS:-${DEFAULT_WARMUP}}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-${DEFAULT_CONCURRENCY}}"
BENCH_POOL_SIZE="${BENCH_POOL_SIZE:-${DEFAULT_POOL_SIZE}}"
BENCH_KEYSPACE="${BENCH_KEYSPACE:-${DEFAULT_KEYSPACE}}"
BENCH_BANK_INITIAL_BALANCE="${BENCH_BANK_INITIAL_BALANCE:-100000}"
BENCH_BANK_MIN_AMOUNT="${BENCH_BANK_MIN_AMOUNT:-1}"
BENCH_BANK_MAX_AMOUNT="${BENCH_BANK_MAX_AMOUNT:-100}"

mkdir -p "${OUT_DIR}"

"${ROOT_DIR}/scripts/get-flamegraph-tools.sh"

pushd "${ROOT_DIR}" >/dev/null
zig build -Doptimize=ReleaseFast

# Ensure no old instance keeps the port busy.
pkill -f "zig-out/bin/wormdb" 2>/dev/null || true
sleep 1

# Record server CPU samples and call stacks.
perf record -F 199 -g --call-graph dwarf,16384 -o "${PERF_DATA}" -- ./zig-out/bin/wormdb >"${SERVER_LOG}" 2>&1 &
PERF_PID=$!

cleanup() {
  kill -INT "${PERF_PID}" 2>/dev/null || true
  wait "${PERF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# Wait until WormDB is accepting TCP connections before running benchmarks.
ready=0
for _ in $(seq 1 100); do
  if (echo > /dev/tcp/127.0.0.1/6389) >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done

if [[ "${ready}" -ne 1 ]]; then
  echo "WormDB did not become ready within 10s. Server log:" >&2
  tail -50 "${SERVER_LOG}" >&2 || true
  exit 1
fi

pushd "${ROOT_DIR}/apps/bun" >/dev/null
echo "Profile mode: ${PROFILE_MODE}"
echo "Bench config: tests=${BENCH_TESTS} ops=${BENCH_OPS} warmup=${BENCH_WARMUP_OPS} conc=${BENCH_CONCURRENCY} pool=${BENCH_POOL_SIZE} keyspace=${BENCH_KEYSPACE}"
bun run bench \
  --tests "${BENCH_TESTS}" \
  --ops "${BENCH_OPS}" \
  --warmup-ops "${BENCH_WARMUP_OPS}" \
  --concurrency "${BENCH_CONCURRENCY}" \
  --pool-size "${BENCH_POOL_SIZE}" \
  --keyspace "${BENCH_KEYSPACE}" \
  --bank-initial-balance "${BENCH_BANK_INITIAL_BALANCE}" \
  --bank-min-amount "${BENCH_BANK_MIN_AMOUNT}" \
  --bank-max-amount "${BENCH_BANK_MAX_AMOUNT}" \
  --host 127.0.0.1 \
  --port 6389
popd >/dev/null

kill -INT "${PERF_PID}" 2>/dev/null || true
wait "${PERF_PID}" 2>/dev/null || true
trap - EXIT

perf script -i "${PERF_DATA}" > "${PERF_SCRIPT}"
"${ROOT_DIR}/.tools/FlameGraph/stackcollapse-perf.pl" "${PERF_SCRIPT}" > "${FOLDED}"
"${ROOT_DIR}/.tools/FlameGraph/flamegraph.pl" --title "WormDB Server CPU Flamegraph" "${FOLDED}" > "${SVG}"

popd >/dev/null

echo "Server flamegraph generated: ${SVG}"
