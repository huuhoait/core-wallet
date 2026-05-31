#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/run.sh — drive the wallet SPs at a target TPS with pgbench.
#
# Usage:
#   ./run.sh [TPS] [DURATION_SEC] [CLIENTS]      # default 10 60 8
#   SETUP=1   ./run.sh ...   # (re)seed LT* data first
#   TEARDOWN=1 ./run.sh ...  # remove LT* data after the run
#   REPORT=path.md ./run.sh ...  # override the report path
#
# Mix (pgbench script weights, /100): topup 20 / transfer 18 / withdraw 12 /
#   reversal 10 / withdraw_reversal 10 / merchant_topup 12 / merchant_withdraw 10 /
#   restraint 8. Covers topup, transfer(+fee), reversal, withdraw(+fee), reversal
#   with fee, merchant topup (consumer→settlement), merchant withdraw, restraint add+remove.
# Runs INSIDE the postgres container (pgbench → local socket, no PgBouncer).
#
# Always writes a markdown result report to deploy/loadtest/reports/pgbench_*.md:
#   throughput (tps) · latency (avg/stddev) · failed% · retries · per-script table ·
#   WLT_TRAN_HIST rows generated this run (by TRAN_TYPE). Attribution uses the
#   monotonic SEQ_NO IDENTITY: rows above the pre-run MAX(SEQ_NO) belong to this run.
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

TS="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="deploy/loadtest/reports"
REPORT="${REPORT:-$REPORT_DIR/pgbench_${TPS}tps_${DUR}s_${TS}.md}"
OUT="$(mktemp -t pgbench.XXXXXX)"
mkdir -p "$REPORT_DIR"
q() { docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -tAc "$1"; }

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

# Snapshot the ledger high-water mark AFTER any seeding, so the report attributes
# only the load run's rows (not the seed's).
s0="$(q "SELECT COALESCE(MAX(SEQ_NO),0) FROM WLT_TRAN_HIST;")"

echo "▶ pgbench: target ${TPS} TPS, ${DUR}s, ${CLIENTS} clients (8-way mix) ${HOST:+via $HOST:$PORT}"
set +e
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
  --report-per-command 2>&1 | tee "$OUT"
pg_rc=${PIPESTATUS[0]}
set -e

# ── parse pgbench summary ──
g1() { grep -m1 -- "$1" "$OUT" | sed -E "s/.*$2//" ; }
proc="$(grep -m1 'transactions actually processed:' "$OUT" | grep -oE '[0-9]+$' || echo 0)"
failed="$(grep -m1 'number of failed transactions:' "$OUT" | sed -E 's/.*: //' || echo 'n/a')"
retried="$(grep -m1 'number of transactions retried:' "$OUT" | sed -E 's/.*: //' || echo '0 (0.000%)')"
lat_avg="$(grep -m1 'latency average =' "$OUT" | sed -E 's/.*= //' || echo 'n/a')"
lat_std="$(grep -m1 'latency stddev =' "$OUT" | sed -E 's/.*= //' || echo 'n/a')"
tps="$(grep -m1 '^tps =' "$OUT" | sed -E 's/^tps = ([0-9.]+).*/\1/' || echo 'n/a')"

# per-script table: name | txns | share | tps | failed
perscript="$(awk '
  /^SQL script [0-9]+:/ { name=$0; sub(/^SQL script [0-9]+: /,"",name) }
  /^ - [0-9]+ transactions \(/ {
    txns=$2; match($0,/[0-9.]+% of total/); share=substr($0,RSTART,RLENGTH-9);
    match($0,/tps = [0-9.]+/); tps=substr($0,RSTART+6,RLENGTH-6) }
  /^ - number of failed transactions:/ {
    f=$6" "$7; print name"|"txns"|"share"|"tps"|"f }
' "$OUT")"

# ── ledger rows attributable to this run (SEQ_NO > s0) ──
hist_total="$(q "SELECT count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0;")"
hist_rows="$(q "SELECT TRAN_TYPE||'|'||count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0 GROUP BY TRAN_TYPE ORDER BY count(*) DESC;")"

# ── assemble the markdown report ──
{
  echo "# Load Test Report (pgbench) — target ${TPS} TPS"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Generated | ${TS} |"
  echo "| Tier | pgbench (DB/SP, inside ${CTN}) ${HOST:+via $HOST:$PORT} |"
  echo "| Target rate / duration / clients | ${TPS} TPS · ${DUR}s · ${CLIENTS} clients |"
  echo "| Wallets / Groups | NWALLET=${NW} · NGROUP=${NG} |"
  echo "| Mix (/100) | topup 20 · transfer 18 · withdraw 12 · reversal 10 · withdraw_reversal 10 · merchant_topup 12 · merchant_withdraw 10 · restraint 8 |"
  echo "| pgbench exit code | ${pg_rc} (0 = ok) |"
  echo
  echo "## Throughput & reliability"
  echo
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Transactions processed | ${proc} |"
  echo "| Achieved tps | ${tps} |"
  echo "| Latency average | ${lat_avg} |"
  echo "| Latency stddev | ${lat_std} |"
  echo "| Failed transactions | ${failed} |"
  echo "| Retried (40001/40P01) | ${retried} |"
  echo
  echo "## Per-script breakdown"
  echo
  echo "| Script | Txns | Share | tps | Failed |"
  echo "|---|---:|---:|---:|---|"
  while IFS='|' read -r name txns share stps f; do
    [ -z "$name" ] && continue
    echo "| ${name} | ${txns} | ${share} | ${stps} | ${f} |"
  done <<< "$perscript"
  echo
  echo "## WLT_TRAN_HIST rows generated by this run (SEQ_NO > ${s0})"
  echo
  echo "| TRAN_TYPE | Rows |"
  echo "|---|---:|"
  while IFS='|' read -r tt n; do
    [ -z "$tt" ] && continue
    echo "| ${tt} | ${n} |"
  done <<< "$hist_rows"
  echo "| **— TOTAL (this run) —** | **${hist_total}** |"
} > "$REPORT"

rm -f "$OUT"
echo
echo "▶ Report written to: $REPORT"

if [[ "${TEARDOWN:-0}" == "1" ]]; then
  echo "▶ tearing down load-test data ..."
  docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -q -f /tmp/lt/teardown.sql
fi

exit "$pg_rc"
