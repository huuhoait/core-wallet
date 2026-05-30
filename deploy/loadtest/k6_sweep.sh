#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/k6_sweep.sh — sweep the k6 HTTP load test across PEAK target-TPS
# levels and write a side-by-side Markdown comparison (ONE COLUMN PER LEVEL)
# to claudedocs/. Each level also reports the WLT_TRAN_HIST rows it generated.
#
# Usage:
#   bash deploy/loadtest/k6_sweep.sh                       # LEVELS="100 200 300 400 500 600 700"
#   LEVELS="100 300 500 700" bash deploy/loadtest/k6_sweep.sh
#   BASE_URL=http://host:8099 OUT=docs/specs/k6_sweep.md bash deploy/loadtest/k6_sweep.sh
#
# Requires: the Go service running on BASE_URL, the LT*/LTG* seed present, and jq.
# Per-level run = the 90s ramp in k6_wallet.js (PEAK reached mid-run).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.."

CTN=wallet-postgres
PW="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
BASE="${BASE_URL:-http://localhost:8099}"
LEVELS="${LEVELS:-100 200 300 400 500 600 700}"
OUT="${OUT:-docs/specs/k6_sweep.md}"
TMP=/tmp/k6_sweep; mkdir -p "$TMP"
q() { docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet -tAc "$1"; }

mkdir -p "$(dirname "$OUT")"
echo "▶ sweep LEVELS=[$LEVELS]  BASE=$BASE  → $OUT"

# Total wall-clock of one ramp (15+15+30+20+10). Throughput is derived as
# count/RAMP_SEC rather than k6's .rate, which a single mis-measured request can
# skew badly (the metric window stretches to that outlier's timestamp).
RAMP_SEC=90

declare -a COLS=()
for p in $LEVELS; do
  sumf="$TMP/sum_$p.json"
  if [[ "${REBUILD:-0}" == "1" ]]; then
    [[ -s "$sumf" ]] || { echo "  ! REBUILD: no saved summary for PEAK=$p — skipped"; continue; }
    rows="$(grep '^hist=' "$TMP/m_$p.env" 2>/dev/null | cut -d= -f2)"; rows="${rows:-0}"
    echo "── PEAK=$p : rebuild from saved summary"
  else
    echo "── PEAK=$p : running ${RAMP_SEC}s ramp ..."
    s0="$(q "SELECT COALESCE(MAX(SEQ_NO),0) FROM WLT_TRAN_HIST;")"
    SUMMARY_OUT="$sumf" k6 run -e BASE_URL="$BASE" -e PEAK="$p" deploy/loadtest/k6_wallet.js >/dev/null 2>&1 || true
    rows="$(q "SELECT count(*) FROM WLT_TRAN_HIST WHERE SEQ_NO > $s0")"
    if [[ ! -s "$sumf" ]]; then echo "  ! no summary for PEAK=$p — skipped"; continue; fi
  fi

  jq -r --arg rows "$rows" --argjson ramp "$RAMP_SEC" '
    .metrics as $m
    | def val(metric; key): ($m[metric].values[key] // 0);
      def r2(x): ((x*100)|round)/100;
      "req_s="    + (((val("http_reqs";"count"))/$ramp|round)|tostring),
      "iter_s="   + (((val("iterations";"count"))/$ramp|round)|tostring),
      "p95="      + (r2(val("http_req_duration";"p(95)"))|tostring),
      "p90="      + (r2(val("http_req_duration";"p(90)"))|tostring),
      "max="      + (r2(val("http_req_duration";"max"))|tostring),
      "checks="   + (r2(val("checks";"rate")*100)|tostring),
      "failed="   + (r2(val("http_req_failed";"rate")*100)|tostring),
      "dropped="  + ((val("dropped_iterations";"count"))|round|tostring),
      "vusmax="   + ((val("vus_max";"max"))|round|tostring),
      "success="  + ((val("outcome{code:SUCCESS}";"count"))|round|tostring),
      "reversed=" + ((val("outcome{code:REVERSED}";"count"))|round|tostring),
      "balance="  + ((val("outcome{code:BALANCE_OK}";"count"))|round|tostring),
      "vc="       + ((val("outcome{code:VERSION_CONFLICT}";"count"))|round|tostring),
      "vcf="      + ((val("outcome{code:VERSION_CONFLICT_FROM}";"count"))|round|tostring),
      "vct="      + ((val("outcome{code:VERSION_CONFLICT_TO}";"count"))|round|tostring),
      "hist="     + $rows
  ' "$sumf" > "$TMP/m_$p.env"
  COLS+=("$p")
  # compact progress line
  src() { grep -E "^$1=" "$TMP/m_$p.env" | cut -d= -f2; }
  echo "   done: req/s=$(src req_s) p95=$(src p95)ms dropped=$(src dropped) hist=$rows"
done

if [[ ${#COLS[@]} -eq 0 ]]; then echo "✗ no levels completed"; exit 1; fi

# mval KEY PEAK → metric value from $TMP/m_$PEAK.env (Bash 3.2-safe, no assoc array)
mval() { grep -E "^$1=" "$TMP/m_$2.env" 2>/dev/null | head -1 | cut -d= -f2; }

# row order: key|label
ROWS=(
  "req_s|Throughput đạt (req/s)"
  "iter_s|Iterations/s"
  "p95|Latency p95 (ms)"
  "p90|Latency p90 (ms)"
  "max|Latency max (ms)"
  "checks|Checks pass (%)"
  "failed|HTTP failed (%)"
  "dropped|Dropped iterations"
  "vusmax|VUs max allocated"
  "success|SUCCESS"
  "reversed|REVERSED"
  "balance|BALANCE_OK"
  "vc|VERSION_CONFLICT (409)"
  "vcf|VERSION_CONFLICT_FROM (500)"
  "vct|VERSION_CONFLICT_TO (500)"
  "hist|WLT_TRAN_HIST rows phát sinh"
)

# ── write markdown ──
{
  echo "# k6 Load-Test Sweep — kết quả so sánh theo PEAK"
  echo
  echo "- Generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- Endpoint: \`$BASE\`  | Mỗi đợt: ramp 90s (10→50→PEAK giữ→0), VU 150/600"
  echo "- Mix: topup 18% / transfer 18% / withdraw 12% / balance 10% / merchant-withdraw 12% / +reversal (transfer 12% · topup 10% · withdraw 8%)"
  echo
  # header
  printf "| Metric |"; for p in "${COLS[@]}"; do printf " PEAK=%s |" "$p"; done; echo
  printf "|:--|";       for _ in "${COLS[@]}"; do printf '%s' "--:|"; done; echo
  for row in "${ROWS[@]}"; do
    key="${row%%|*}"; label="${row##*|}"
    printf "| %s |" "$label"
    for p in "${COLS[@]}"; do v="$(mval "$key" "$p")"; printf " %s |" "${v:-—}"; done
    echo
  done
  echo
  echo "> Ghi chú: \`req/s\` là trung bình toàn ramp 90s (PEAK chỉ giữ ~50s), nên < PEAK là bình thường."
  echo "> \`dropped\` > 0 hoặc \`p95\` tăng vọt ⇒ điểm bắt đầu bão hoà. \`*_FROM/_TO\` (HTTP 500) là xung đột phiên bản chưa map về 409."
} > "$OUT"

echo "✓ sweep done → $OUT"
cat "$OUT"
