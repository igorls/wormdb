#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_MODE=quick "${ROOT_DIR}/scripts/profile-server-flamegraph.sh"
