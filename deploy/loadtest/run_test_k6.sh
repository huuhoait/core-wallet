#!/usr/bin/env bash
# Convenience wrapper around k6.sh. MUST run under bash (k6.sh uses process
# substitution / here-strings / pipefail) — `sh k6.sh` fails to parse on macOS
# where /bin/sh is bash in POSIX mode. Absolute paths so it works from any cwd.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

PEAK="${PEAK:-200}"
DURATION="${DURATION:-720}"

# Initialize the load test data
#bash "$DIR/init_k6_data.sh"

export BASE_URL="${BASE_URL:-http://localhost:8019}"
export REPORT="$DIR/reports/k6__$(date +%Y%m%d_%H%M%S)_${PEAK}peak_${DURATION}s.md"

bash "$DIR/k6.sh" -e PEAK="$PEAK" -e DURATION="$DURATION"
# NOTE: the PII DEK is no longer set DB-side via `ALTER DATABASE ... SET app.pii_dek`.
# The wallet-service holds it (env PII_DEK) and sets it per-TX; docker-compose.yml
# injects a dev PII_DEK into the wallet-service container for the load-test stack.
