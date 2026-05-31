#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/stress.sh — sweep target TPS to find the saturation point (DB/SP tier)
#
# Usage:  ./stress.sh                 # levels 20 50 100 200, 15s each, 16 clients
#         LEVELS="50 100 200 400" DUR=20 CLIENTS=32 ./stress.sh
#         MAX=1 ./stress.sh           # also run an uncapped max-throughput pass
#
# Reads "achieved tps", "latency avg", "schedule lag" and "failed%" per level.
# Saturation ≈ where achieved_tps stops tracking target and schedule-lag/latency
# climb sharply. Seeds LT* data once, tears down at the end.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
CTN=wallet-postgres
DUR="${DUR:-15}"; CLIENTS="${CLIENTS:-16}"
LEVELS="${LEVELS:-20 50 100 200}"
NW=10000; NG=20
PW="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
# Route via PgBouncer to exceed max_connections (transaction-mode → simple proto):
#   HOST=wallet-pgbouncer PORT=5432 PROTO=simple CLIENTS=200 LEVELS="100 200 400" bash deploy/loadtest/stress.sh
HOST="${HOST:-}"; PORT="${PORT:-}"; PROTO="${PROTO:-prepared}"
CONN=""; [[ -n "$HOST" ]] && CONN="-h $HOST"; [[ -n "$PORT" ]] && CONN="$CONN -p $PORT"

docker exec "$CTN" mkdir -p /tmp/lt
for f in setup teardown topup transfer withdraw merchant_withdraw reversal \
         merchant_topup withdraw_reversal restraint; do
  docker cp "deploy/loadtest/$f.sql" "$CTN:/tmp/lt/$f.sql"
done
echo "▶ seeding ..."; docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -q -f /tmp/lt/setup.sql >/dev/null

run() { # $1=rate-flag-or-empty  $2=label
  docker exec -e PGPASSWORD="$PW" "$CTN" pgbench $CONN -U postgres -d wallet \
    --no-vacuum --protocol="$PROTO" --max-tries=10 \
    $1 --time=$DUR --client=$CLIENTS --jobs=8 \
    --define=nwallet=$NW --define=ngroup=$NG \
    --file=/tmp/lt/topup.sql@20 --file=/tmp/lt/transfer.sql@18 \
    --file=/tmp/lt/withdraw.sql@12 --file=/tmp/lt/reversal.sql@10 \
    --file=/tmp/lt/withdraw_reversal.sql@10 --file=/tmp/lt/merchant_topup.sql@12 \
    --file=/tmp/lt/merchant_withdraw.sql@10 --file=/tmp/lt/restraint.sql@8 2>&1
}
report() { # $1=label  $2=output
  local tps lat lag failed
  tps=$(echo "$2"    | grep -oE 'tps = [0-9.]+' | head -1 | awk '{print $3}')
  lat=$(echo "$2"    | grep -oE 'latency average = [0-9.]+' | head -1 | awk '{print $4}')
  lag=$(echo "$2"    | grep -oE 'schedule lag: avg [0-9.]+'  | head -1 | awk '{print $4}')
  failed=$(echo "$2" | grep -E 'number of failed' | head -1 | grep -oE '\([0-9.]+%\)')
  printf "%-10s tps=%-10s lat_avg=%-9sms lag_avg=%-9s failed=%s\n" "$1" "${tps:-NA}" "${lat:-NA}" "${lag:-NA}ms" "${failed:-NA}"
}

echo "▶ sweep (DUR=${DUR}s, clients=${CLIENTS})"
for t in $LEVELS; do report "R=${t}" "$(run "--rate=$t" "$t")"; done
if [[ "${MAX:-0}" == "1" ]]; then report "UNCAPPED" "$(run "" max)"; fi

echo "▶ teardown ..."; docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -q -f /tmp/lt/teardown.sql >/dev/null
