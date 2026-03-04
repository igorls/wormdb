#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="${ROOT_DIR}/.tools/FlameGraph"

if [[ -x "${TOOLS_DIR}/flamegraph.pl" && -x "${TOOLS_DIR}/stackcollapse-perf.pl" ]]; then
  echo "FlameGraph tools already present at ${TOOLS_DIR}"
  exit 0
fi

mkdir -p "${TOOLS_DIR}"

curl -fsSL "https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl" -o "${TOOLS_DIR}/flamegraph.pl"
curl -fsSL "https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl" -o "${TOOLS_DIR}/stackcollapse-perf.pl"

chmod +x "${TOOLS_DIR}/flamegraph.pl" "${TOOLS_DIR}/stackcollapse-perf.pl"

echo "Installed FlameGraph tools at ${TOOLS_DIR}"
