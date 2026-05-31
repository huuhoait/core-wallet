#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/peak_report.sh — run the k6 HTTP load test at a target PEAK
# (default 200 TPS; 90s staged ramp defined in k6_wallet.js) and emit a single
# consolidated report:
#
#   • latency      — http_req_duration p90 / p95 / p99 (+ avg/med/min/max)
#   • throughput   — http_reqs total + req/s, iterations + iter/s
#   • reliability  — http_req_failed %, checks pass %
#   • response codes — total responses grouped BY business code (SUCCESS, …)
#   • ledger       — WLT_TRAN_HIST rows THIS run generated, BY TRAN_TYPE + total
#
# Attribution: WLT_TRAN_HIST.SEQ_NO is a monotonic IDENTITY. We snapshot
# MAX(SEQ_NO) before the run; every row above that mark belongs to this run
# (one posting writes 2–5 history rows — fee/VAT/reversal legs — so ledger rows
# ≫ HTTP transactions).
#
# Usage:
#   bash deploy/loadtest/peak_report.sh                       # PEAK=200, :8080
#   PEAK=300 bash deploy/loadtest/peak_report.sh
#   BASE_URL=http://host:8080 NWALLET=2000 NGROUP=20 PEAK=200 \
#     bash deploy/loadtest/peak_report.sh
#
# Prereqs: DB stack up, wallet-service reachable at BASE_URL, and LT* wallets
# seeded (deploy/loadtest/setup.sql). NWALLET/NGROUP MUST match the seeded set
# or requests will hit non-existent accounts.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

PEAK="${PEAK:-200}"
DURATION="${DURATION:-0}"          # 0 = built-in 90s staged ramp; N = short N-second run (2s ramp + hold)
BASE="${BASE_URL:-http://localhost:8080}"
NWALLET="${NWALLET:-10000}"
NGROUP="${NGROUP:-20}"
CTN=wallet-postgres
PW="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
TS="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="deploy/loadtest/reports"
JSON="/tmp/k6_peak_${PEAK}_${TS}.json"
REPORT="${REPORT:-$REPORT_DIR/peak_${PEAK}_${TS}.md}"
mkdir -p "$REPORT_DIR"

q() { docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -tAc "$1"; }

s0="$(q "SELECT COALESCE(MAX(SEQ_NO),0) FROM WLT_TRAN_HIST;")"
echo "▶ PEAK=$PEAK  BASE=$BASE  NWALLET=$NWALLET NGROUP=$NGROUP"
echo "▶ WLT_TRAN_HIST high-water SEQ_NO before run: $s0"

# Run k6. --summary-trend-stats injects p(99) (default summary omits it).
# SUMMARY_OUT makes k6_wallet.js dump the full metrics JSON for us to parse.
k6_rc=0
k6 run \
  -e BASE_URL="$BASE" -e NWALLET="$NWALLET" -e NGROUP="$NGROUP" -e PEAK="$PEAK" \
  -e DURATION="$DURATION" -e SUMMARY_OUT="$JSON" \
  --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" \
  deploy/loadtest/k6_wallet.js || k6_rc=$?

[ -f "$JSON" ] || { echo "✗ k6 summary JSON not produced ($JSON) — aborting report"; exit "${k6_rc:-1}"; }

# ── Ledger rows attributable to this run ──
hist_total="$(q "SELECT count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0;")"
hist_rows="$(q "SELECT TRAN_TYPE||'|'||count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0 GROUP BY TRAN_TYPE ORDER BY count(*) DESC;")"
hist_grand="$(q "SELECT count(*) FROM WLT_TRAN_HIST;")"

# ── Pull latency / throughput / reliability from the k6 JSON ──
read -r lat_p90 lat_p95 lat_p99 lat_avg lat_med lat_min lat_max < <(jq -r '
  .metrics.http_req_duration.values as $v
  | "\($v["p(90)"]) \($v["p(95)"]) \($v["p(99)"]) \($v.avg) \($v.med) \($v.min) \($v.max)"' "$JSON")
reqs_count="$(jq -r '.metrics.http_reqs.values.count // 0' "$JSON")"
reqs_rate="$(jq -r '.metrics.http_reqs.values.rate // 0'  "$JSON")"
iter_count="$(jq -r '.metrics.iterations.values.count // 0' "$JSON")"
iter_rate="$(jq -r '.metrics.iterations.values.rate // 0'  "$JSON")"
fail_rate="$(jq -r '(.metrics.http_req_failed.values.rate // 0) * 100' "$JSON")"
chk_rate="$(jq  -r '(.metrics.checks.values.rate // 0) * 100' "$JSON")"
chk_pass="$(jq  -r '.metrics.checks.values.passes // 0' "$JSON")"
chk_fail="$(jq  -r '.metrics.checks.values.fails // 0'  "$JSON")"

# ── Response codes grouped by business code (outcome{code:*}) ──
codes_total="$(jq -r '.metrics.outcome.values.count // 0' "$JSON")"
codes_tbl="$(jq -r '
  [ .metrics | to_entries[]
    | select(.key | test("^outcome\\{code:"))
    | { code: (.key | capture("code:(?<c>.+)\\}").c), n: (.value.values.count // 0) }
    | select(.n > 0) ]
  | sort_by(-.n)[]
  | "\(.code)|\(.n)"' "$JSON")"

f2() { printf "%.2f" "$1"; }

# ── Assemble the markdown report ──
{
  echo "# Load Test Report — PEAK=${PEAK} TPS"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Generated | ${TS} |"
  echo "| Target | ${BASE} |"
  echo "| Wallets / Groups | NWALLET=${NWALLET} · NGROUP=${NGROUP} |"
  if [ "$DURATION" -gt 0 ]; then
    echo "| Profile | k6_wallet.js — ${DURATION}s run (2s ramp + hold at ${PEAK} TPS) |"
  else
    echo "| Profile | k6_wallet.js — 90s staged ramp (10→50→${PEAK}→${PEAK}→0 TPS) |"
  fi
  echo "| k6 exit code | ${k6_rc} (0 = thresholds passed) |"
  echo
  echo "## Latency — http_req_duration (ms)"
  echo
  echo "| p90 | p95 | p99 | avg | med | min | max |"
  echo "|----:|----:|----:|----:|----:|----:|----:|"
  echo "| $(f2 "$lat_p90") | $(f2 "$lat_p95") | $(f2 "$lat_p99") | $(f2 "$lat_avg") | $(f2 "$lat_med") | $(f2 "$lat_min") | $(f2 "$lat_max") |"
  echo
  echo "## Throughput & reliability"
  echo
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| HTTP requests | ${reqs_count} ($(f2 "$reqs_rate") req/s) |"
  echo "| Iterations | ${iter_count} ($(f2 "$iter_rate") iter/s) |"
  echo "| http_req_failed | $(f2 "$fail_rate")% |"
  echo "| checks passed | $(f2 "$chk_rate")% (${chk_pass} ✓ / ${chk_fail} ✗) |"
  echo
  echo "## Response codes — total ${codes_total} responses, grouped by code"
  echo
  echo "| Code | Count | Share |"
  echo "|---|----:|----:|"
  while IFS='|' read -r code n; do
    [ -z "$code" ] && continue
    pct=$(awk -v n="$n" -v t="$codes_total" 'BEGIN{ printf (t>0)? "%.2f" : "0.00", (t>0)? 100*n/t : 0 }')
    echo "| ${code} | ${n} | ${pct}% |"
  done <<< "$codes_tbl"
  echo
  echo "## WLT_TRAN_HIST rows generated by this run (SEQ_NO > ${s0})"
  echo
  echo "| TRAN_TYPE | Rows |"
  echo "|---|----:|"
  while IFS='|' read -r tt n; do
    [ -z "$tt" ] && continue
    echo "| ${tt} | ${n} |"
  done <<< "$hist_rows"
  echo "| **— TOTAL (this run) —** | **${hist_total}** |"
  echo "| _grand total in table_ | _${hist_grand}_ |"
  echo
  echo "_Raw k6 summary JSON: ${JSON}_"
} | tee "$REPORT"

echo
echo "▶ Report written to: $REPORT"
exit "$k6_rc"
