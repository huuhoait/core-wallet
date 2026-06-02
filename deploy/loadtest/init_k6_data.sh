#!/usr/bin/env bash
# =============================================================================
# deploy/loadtest/init_k6_data.sh — seed + verify load-test data for the k6
# (HTTP) tier, and check the seeded balances are enough for the planned run.
#
# Runs setup.sql INSIDE the postgres container (same data the pgbench tier uses
# — k6_wallet.js needs the LT* consumer wallets + LTG* merchant groups to exist).
# setup.sql is idempotent (NOT EXISTS guards + post_topup/post_transfer reference
# idempotency), so re-running never double-funds.
#
# Usage:
#   bash deploy/loadtest/init_k6_data.sh                 # seed + verify
#   PEAK=300 DURATION=7200 bash deploy/loadtest/init_k6_data.sh   # + headroom check for a 2h@300 run
#   PEAK=600 DURATION=7200 EXTRA_SETTLE_ROUNDS=3 bash ...         # top up each settlement +300M first
#
# Env:
#   PEAK                target k6 TPS you plan to run (default 100) — for the headroom check
#   DURATION            planned run length in seconds (default 7200 = 2h)
#   NG                  merchant groups k6 will hit (default 20 = k6_wallet.js NGROUP default).
#                       setup.sql seeds 50; the headroom check divides traffic over NG of them.
#   EXTRA_SETTLE_ROUNDS extra 100M consumer→settlement transfers per group to pre-fund (default 0)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

CTN=wallet-postgres
PEAK="${PEAK:-100}"
DURATION="${DURATION:-7200}"
NG="${NG:-20}"
EXTRA_SETTLE_ROUNDS="${EXTRA_SETTLE_ROUNDS:-0}"
SEED_GROUPS=50          # setup.sql seeds 50 merchant groups (LTG01..LTG50)
SETTLE_SEED=500000000   # each settlement seeded with 5×100M (setup.sql)
FEE_BLEED=24200         # net VND drained per merchant_withdraw: fee 22000 (floor) + 10% VAT

PW="$(grep -E '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
psqlc() { docker exec -e PGPASSWORD="$PW" "$CTN" psql -U postgres -d wallet "$@"; }
q()     { psqlc -tAc "$1"; }

# ── 0. container up? ──
if ! docker ps --format '{{.Names}}' | grep -qx "$CTN"; then
  echo "✗ container '$CTN' is not running. Start the stack first: docker compose up -d" >&2
  exit 1
fi
echo "▶ postgres container '$CTN' is up."

# ── 1. seed (idempotent) ──
echo "▶ seeding load-test data (setup.sql) ..."
docker exec "$CTN" mkdir -p /tmp/lt
docker cp deploy/loadtest/setup.sql "$CTN:/tmp/lt/setup.sql"
psqlc -q -f /tmp/lt/setup.sql

# ── 2. optional: pre-fund each settlement with extra 100M rounds ──
# Mirrors setup.sql's funding (consumer i → settlement, 100M/tx, TRFOUT cap 100M).
# Fixed reference per (group,round) → idempotent; bump EXTRA_SETTLE_ROUNDS to add more.
if (( EXTRA_SETTLE_ROUNDS > 0 )); then
  echo "▶ pre-funding ${SEED_GROUPS} settlements with +${EXTRA_SETTLE_ROUNDS}×100M each ..."
  q "
  DO \$\$
  DECLARE i int; r int;
  BEGIN
    PERFORM set_config('audit.actor','loadtest',true);
    PERFORM set_config('audit.channel','LOADTEST',true);
    FOR i IN 1..${SEED_GROUPS} LOOP
      FOR r IN 1..${EXTRA_SETTLE_ROUNDS} LOOP
        PERFORM post_transfer('LT'||lpad(i::text,10,'0'), 'LTGS'||lpad(i::text,4,'0'),
                              100000000, 'LT-XFUND-LTGS'||lpad(i::text,2,'0')||'-'||r,
                              'TRFOUT', '{}'::jsonb, 'LOADTEST', 'loadtest');
      END LOOP;
    END LOOP;
  END \$\$;" >/dev/null
fi

# ── 3. verify counts ──
echo "▶ verifying seeded data ..."
read -r CW MG SH <<<"$(q "SELECT
  (SELECT count(*) FROM WLT_ACCT WHERE acct_no LIKE 'LT%' AND acct_role='STANDALONE'),
  (SELECT count(*) FROM WLT_ACCT_GROUP WHERE group_id LIKE 'LTG%'),
  (SELECT count(*) FROM WLT_ACCT WHERE acct_role='SHARD' AND group_id LIKE 'LTG%');" | tr '|' ' ')"
MINSET="$(q "SELECT COALESCE(MIN(actual_bal),0)::bigint FROM WLT_ACCT WHERE acct_role='SETTLEMENT' AND group_id LIKE 'LTG%';")"

printf '    consumer wallets : %s\n' "$CW"
printf '    merchant groups  : %s\n' "$MG"
printf '    shards           : %s\n' "$SH"
printf '    min settlement   : %s VND\n' "$MINSET"

if (( CW < 50000 || MG < 50 )); then
  echo "✗ seed looks incomplete (expected 50000 consumers / 50 groups). Check setup.sql output above." >&2
  exit 1
fi

# ── 4. headroom check for the planned run ──
# Only the merchant SETTLEMENT pool is a real constraint: merchant_topup (CR) and
# merchant_withdraw (DR) run at equal 10% weight over the same 10k..500k range, so
# gross flow balances and the settlement only bleeds the withdraw fee (FEE_BLEED/op).
# Consumer wallets are funded 1e12 each — never a constraint. See CLAUDE.md + setup.sql.
WD_PER_GROUP=$(( PEAK * 10 * DURATION / 100 / NG ))     # merchant_withdraws per group over the run
DRAIN=$(( WD_PER_GROUP * FEE_BLEED ))                   # systematic net drain per group (VND)
echo "▶ settlement headroom check (PEAK=${PEAK} TPS · DURATION=${DURATION}s · NG=${NG} groups used):"
printf '    ~%s merchant-withdraws/group  →  ~%s VND fee bleed/group\n' "$WD_PER_GROUP" "$DRAIN"
printf '    available/group              :  %s VND\n' "$MINSET"
# warn at 70% — variance across groups (~2σ) adds headroom beyond the systematic mean.
THRESH=$(( MINSET * 70 / 100 ))
if (( DRAIN >= MINSET )); then
  ADD=$(( (DRAIN - MINSET) / 100000000 + 1 ))
  echo "    ✗ NOT ENOUGH — bleed exceeds the seed. Re-run with EXTRA_SETTLE_ROUNDS=$(( EXTRA_SETTLE_ROUNDS + ADD )) (or use NG=50)." >&2
elif (( DRAIN >= THRESH )); then
  echo "    ⚠ TIGHT — within 30% of the seed; some groups may hit INSUFFICIENT_FUNDS late in the run. Consider NG=50 or EXTRA_SETTLE_ROUNDS."
else
  echo "    ✓ ENOUGH — comfortable headroom for the planned run."
fi

echo
echo "✓ DB ready for k6. Run e.g.:"
echo "    PEAK=${PEAK} DURATION=${DURATION} bash deploy/loadtest/run_test_k6.sh"
