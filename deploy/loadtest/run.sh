#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/run.sh — drive the wallet SPs at a target TPS with pgbench.
#
# Usage:
#   ./run.sh [TPS] [DURATION_SEC] [CLIENTS]      # default 10 60 8
#   SETUP=1   ./run.sh ...   # (re)seed LT* data first
#   TEARDOWN=1 ./run.sh ...  # remove LT* data after the run
#
# Mix (pgbench script weights, /100): topup 20 / transfer 18 / withdraw 12 /
#   reversal 10 / withdraw_reversal 10 / merchant_topup 12 / merchant_withdraw 10 /
#   restraint 8. Covers topup, transfer(+fee), reversal, withdraw(+fee), reversal
#   with fee, merchant topup (consumer→settlement), merchant withdraw, restraint add+remove.
# Runs INSIDE the postgres container (pgbench → local socket, no PgBouncer).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

CTN=wallet-postgres
TPS="${1:-10}"
DUR="${2:-60}"
CLIENTS="${3:-8}"
NW=10000      # must match setup.sql consumer count
NG=20         # must match setup.sql merchant-group count
PW="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
# Route: direct PG socket (default) OR via PgBouncer to exceed max_connections:
#   HOST=wallet-pgbouncer PORT=5432 PROTO=simple bash deploy/loadtest/run.sh ...
HOST="${HOST:-}"; PORT="${PORT:-}"; PROTO="${PROTO:-prepared}"
CONN=""; [[ -n "$HOST" ]] && CONN="-h $HOST"; [[ -n "$PORT" ]] && CONN="$CONN -p $PORT"

echo "▶ copying scripts into $CTN ..."
docker exec "$CTN" mkdir -p /tmp/lt
for f in setup teardown topup transfer withdraw merchant_withdraw reversal \
         merchant_topup withdraw_reversal restraint; do
  docker cp "deploy/loadtest/$f.sql" "$CTN:/tmp/lt/$f.sql"
done

if [[ "${SETUP:-0}" == "1" ]]; then
  echo "▶ seeding load-test data ..."
  docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -q -f /tmp/lt/setup.sql
fi

echo "▶ pgbench: target ${TPS} TPS, ${DUR}s, ${CLIENTS} clients (8-way mix) ${HOST:+via $HOST:$PORT}"
docker exec -e PGPASSWORD="$PW" "$CTN" pgbench $CONN -U postgres -d wallet \
  --no-vacuum --protocol="$PROTO" --max-tries=10 \
  --rate="$TPS" --time="$DUR" --client="$CLIENTS" --jobs=4 \
  --define=nwallet=$NW --define=ngroup=$NG \
  --file=/tmp/lt/topup.sql@20 \
  --file=/tmp/lt/transfer.sql@18 \
  --file=/tmp/lt/withdraw.sql@12 \
  --file=/tmp/lt/reversal.sql@10 \
  --file=/tmp/lt/withdraw_reversal.sql@10 \
  --file=/tmp/lt/merchant_topup.sql@12 \
  --file=/tmp/lt/merchant_withdraw.sql@10 \
  --file=/tmp/lt/restraint.sql@8 \
  --report-per-command

if [[ "${TEARDOWN:-0}" == "1" ]]; then
  echo "▶ tearing down load-test data ..."
  docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -q -f /tmp/lt/teardown.sql
fi
