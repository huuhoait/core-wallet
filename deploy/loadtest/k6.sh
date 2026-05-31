#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/k6.sh — run the k6 HTTP load test, then ALWAYS write a markdown
# result report to deploy/loadtest/reports/k6_*.md:
#   latency (p90/p95/p99 + avg/med/min/max) · throughput (reqs, iters + rates) ·
#   reliability (http_req_failed%, checks%) · response codes by business code ·
#   WLT_TRAN_HIST rows generated this run (by TRAN_TYPE).
#
# Usage:
#   bash deploy/loadtest/k6.sh                       # PEAK=100, BASE_URL=:8099 (k6 defaults)
#   bash deploy/loadtest/k6.sh -e PEAK=700           # forward ANY k6 -e flags through
#   BASE_URL=http://host:8099 bash deploy/loadtest/k6.sh -e PEAK=300
#   REPORT=path.md bash deploy/loadtest/k6.sh ...    # override the report path
#
# Attribution: WLT_TRAN_HIST.SEQ_NO is a monotonic IDENTITY. We snapshot
# MAX(SEQ_NO) before the run; every row above that mark belongs to this run
# (one posting writes 2-5 history rows — fee/VAT/reversal/sweep legs — so ledger
# rows ≫ HTTP transactions).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

CTN=wallet-postgres
PW="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
BASE="${BASE_URL:-http://localhost:8099}"
TS="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="deploy/loadtest/reports"
JSON="$(mktemp -t k6sum.XXXXXX)"
REPORT="${REPORT:-$REPORT_DIR/k6_${TS}.md}"
mkdir -p "$REPORT_DIR"
q() { docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -tAc "$1"; }
f2() { printf "%.2f" "${1:-0}"; }

s0="$(q "SELECT COALESCE(MAX(SEQ_NO),0) FROM WLT_TRAN_HIST;")"
echo "▶ WLT_TRAN_HIST high-water SEQ_NO before run: $s0"

# Run k6. SUMMARY_OUT makes k6_wallet.js dump the full metrics JSON for the report;
# --summary-trend-stats injects p(99); --out json streams every per-request point
# (with our op/ep/payload tags) so we can rank the slowest requests. Don't let a
# threshold-breach non-zero exit skip the report — capture it and re-raise after.
PTS="$(mktemp -t k6pts.XXXXXX)"
START_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"
k6_rc=0
k6 run -e BASE_URL="$BASE" -e SUMMARY_OUT="$JSON" \
  --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" \
  --out json="$PTS" \
  "$@" deploy/loadtest/k6_wallet.js || k6_rc=$?
END_AT="$(date '+%Y-%m-%d %H:%M:%S %z')"

# Top-10 slowest HTTP requests by http_req_duration, carrying the op / endpoint /
# payload tags set by post() in k6_wallet.js. Tab-separated: ms<TAB>op<TAB>ep<TAB>payload.
TAB="$(printf '\t')"
# `|| true`: head closes the pipe early → SIGPIPE upstream under pipefail would
# otherwise abort the script (set -e) before the report is written.
top10="$( { grep '"metric":"http_req_duration"' "$PTS" 2>/dev/null \
  | jq -rc 'select(.type=="Point") | [.data.value, (.data.tags.op // "?"), (.data.tags.ep // "?"), (.data.tags.payload // "")] | @tsv' 2>/dev/null \
  | sort -t"$TAB" -k1 -rn | head -10; } || true)"
rm -f "$PTS"

# ── ledger rows attributable to this run (SEQ_NO > s0) ──
hist_total="$(q "SELECT count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0;")"
hist_rows="$(q "SELECT TRAN_TYPE||'|'||count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0 GROUP BY TRAN_TYPE ORDER BY count(*) DESC;")"

if [ ! -s "$JSON" ]; then
  echo "✗ k6 summary JSON not produced ($JSON) — report skipped (k6 rc=$k6_rc)"
  rm -f "$JSON"; exit "$k6_rc"
fi

# ── parse latency / throughput / reliability from the k6 JSON ──
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
codes_total="$(jq -r '.metrics.outcome.values.count // 0' "$JSON")"
codes_tbl="$(jq -r '
  [ .metrics | to_entries[]
    | select(.key | test("^outcome\\{code:"))
    | { code: (.key | capture("code:(?<c>.+)\\}").c), n: (.value.values.count // 0) }
    | select(.n > 0) ] | sort_by(-.n)[] | "\(.code)|\(.n)"' "$JSON")"

# ── assemble the markdown report ──
{
  echo "# Load Test Report (k6 HTTP)"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Generated | ${TS} |"
  echo "| Started | ${START_AT} |"
  echo "| Ended | ${END_AT} |"
  echo "| Tier | k6 HTTP (through the Go service) |"
  echo "| Target | ${BASE} |"
  echo "| k6 args | ${*:-(none — defaults)} |"
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
  echo "## Response codes — total ${codes_total} responses, by business code"
  echo
  echo "| Code | Count | Share |"
  echo "|---|---:|---:|"
  while IFS='|' read -r code n; do
    [ -z "$code" ] && continue
    pct=$(awk -v n="$n" -v t="$codes_total" 'BEGIN{ printf "%.2f", (t>0)? 100*n/t : 0 }')
    echo "| ${code} | ${n} | ${pct}% |"
  done <<< "$codes_tbl"
  echo
  echo "## Top 10 slowest requests (http_req_duration)"
  echo
  echo "| # | Latency (ms) | Type | URL | Payload |"
  echo "|--:|---:|---|---|---|"
  i=0
  while IFS="$TAB" read -r ms op ep payload; do
    [ -z "$ms" ] && continue
    i=$((i+1))
    payload="${payload//|/\\|}"   # escape pipes so the markdown table stays intact
    printf '| %d | %.2f | %s | `%s` | `%s` |\n' "$i" "$ms" "$op" "$ep" "$payload"
  done <<< "$top10"
  [ "$i" -eq 0 ] && echo "| — | — | — | — | (no per-request points captured) |"
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

rm -f "$JSON"
echo
echo "▶ Report written to: $REPORT"
exit "$k6_rc"
