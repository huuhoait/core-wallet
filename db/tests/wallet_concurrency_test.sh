#!/usr/bin/env bash
# =============================================================================
# wallet_concurrency_test.sh — functional concurrency probes (A#6)
# =============================================================================
# Exercises the posting engine under REAL concurrency (parallel psql clients =
# separate backend connections / transactions), proving the two properties the
# unit/SQL suites cannot:
#
#   T1  Overdraft race — N parallel withdraws on a wallet funded for ≤1 must
#       yield EXACTLY ONE success and never a negative balance (the deferred
#       fund-guard re-asserted in the atomic UPDATE closes the TOCTOU window).
#
#   T2  Deadlock probe — opposing A→B / B→A transfers fired concurrently must
#       produce ZERO deadlocks (40P01), because both legs lock in deterministic
#       INTERNAL_KEY order. Balances stay ≥ 0 and the ledger stays consistent.
#       (VERSION_CONFLICT/40001 under contention is expected without the Go
#       retry tier and is NOT a failure of this probe.)
#
# Self-seeding (accounts CCT*, references CONC-*) and self-cleaning. Run against
# the docker stack:  bash db/tests/wallet_concurrency_test.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

PSQL=(docker compose exec -T postgres psql -U postgres -d wallet -tAX)
q() { "${PSQL[@]}" -c "$1" 2>&1; }

VICTIM=CCT0000000000001   # T1 overdraft victim (funded for exactly one withdraw)
ACCT_A=CCT0000000000002   # T2 deadlock A
ACCT_B=CCT0000000000003   # T2 deadlock B
WORK=$(mktemp -d)
FAILS=0

cleanup() {
  q "DELETE FROM WLT_WITHDRAW_TRACK WHERE EXT_PAYOUT_REF LIKE 'CONC-%';
     DELETE FROM WLT_BATCH         WHERE REFERENCE LIKE 'CONC-%';
     DELETE FROM WLT_TRAN_HIST     WHERE REFERENCE LIKE 'CONC-%';
     DELETE FROM WLT_API_MESSAGE   WHERE OBJECT_REF_ID LIKE 'CONC-%';
     DELETE FROM WLT_OUTBOX        WHERE PARTITION_KEY LIKE 'CCT%';
     DELETE FROM WLT_ACCT_BAL      WHERE INTERNAL_KEY IN (SELECT INTERNAL_KEY FROM WLT_ACCT WHERE ACCT_NO LIKE 'CCT%');
     DELETE FROM WLT_ACCT          WHERE ACCT_NO LIKE 'CCT%';" >/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

seed_acct() { # $1=acct_no  $2=fund_amount  $3=ref
  q "INSERT INTO WLT_ACCT(ACCT_NO,CLIENT_NO,ACCT_TYPE,CCY)
     SELECT '$1', CLIENT_NO, ACCT_TYPE, CCY FROM WLT_ACCT WHERE ACCT_ROLE='STANDALONE' LIMIT 1;" >/dev/null
  q "SELECT status FROM post_topup('$1', $2, '$3', '{}'::jsonb, 'SYS', 'conc');" >/dev/null
}

bal() { q "SELECT ACTUAL_BAL FROM WLT_ACCT WHERE ACCT_NO='$1';"; }
pass() { echo "  ✅ PASS | $1"; }
fail() { echo "  ❌ FAIL | $1"; FAILS=$((FAILS+1)); }

echo "============================================================"
echo " wallet concurrency test (A#6)"
echo "============================================================"
# clear any leftovers from a prior aborted run
q "DELETE FROM WLT_WITHDRAW_TRACK WHERE EXT_PAYOUT_REF LIKE 'CONC-%';
   DELETE FROM WLT_BATCH WHERE REFERENCE LIKE 'CONC-%';
   DELETE FROM WLT_TRAN_HIST WHERE REFERENCE LIKE 'CONC-%';
   DELETE FROM WLT_API_MESSAGE WHERE OBJECT_REF_ID LIKE 'CONC-%';
   DELETE FROM WLT_ACCT_BAL WHERE INTERNAL_KEY IN (SELECT INTERNAL_KEY FROM WLT_ACCT WHERE ACCT_NO LIKE 'CCT%');
   DELETE FROM WLT_ACCT WHERE ACCT_NO LIKE 'CCT%';" >/dev/null

# ─────────────────────────────────────────────────────────────────────────
# T1 — overdraft race
# ─────────────────────────────────────────────────────────────────────────
# Fund 1,000,000; each withdraw 600,000 (+11,000 fee = 611,000). One fits,
# two cannot (1,222,000 > 1,000,000) → exactly one success regardless of fee.
seed_acct "$VICTIM" 1000000 "CONC-FUND-V"
N=10
for i in $(seq 1 $N); do
  ( q "SELECT status FROM post_withdraw('$VICTIM',600000,'CONC-WD-$i','CONC-EXT-$i','BIDV','12345678901234','{}'::jsonb,'MOBILE','conc');" \
      > "$WORK/wd-$i.out" ) &
done
wait

succ=$(grep -l 'SUCCESS' "$WORK"/wd-*.out 2>/dev/null | wc -l | tr -d ' ')
insf=$(grep -l 'INSUFFICIENT_FUNDS' "$WORK"/wd-*.out 2>/dev/null | wc -l | tr -d ' ')
vcon=$(grep -lE 'VERSION_CONFLICT|40001' "$WORK"/wd-*.out 2>/dev/null | wc -l | tr -d ' ')
vbal=$(bal "$VICTIM")
echo "T1 overdraft race: $N parallel withdraws of 600000 on a 1,000,000 wallet"
echo "    success=$succ  insufficient=$insf  version_conflict=$vcon  final_balance=$vbal"
[ "$succ" = "1" ] && pass "exactly ONE withdraw succeeded" || fail "expected 1 success, got $succ"
awk "BEGIN{exit !($vbal>=0)}" && pass "balance never negative ($vbal)" || fail "balance negative: $vbal"
[ "$vbal" = "389000.00" ] && pass "balance == 389000.00 (1,000,000 − 611,000, one withdraw applied)" \
                           || fail "unexpected balance $vbal (want 389000.00)"

# ─────────────────────────────────────────────────────────────────────────
# T2 — deadlock probe (opposing transfers)
# ─────────────────────────────────────────────────────────────────────────
seed_acct "$ACCT_A" 5000000 "CONC-FUND-A"
seed_acct "$ACCT_B" 5000000 "CONC-FUND-B"
M=10  # M each direction, fired together
for i in $(seq 1 $M); do
  ( q "SELECT status FROM post_transfer('$ACCT_A','$ACCT_B',100000,'CONC-AB-$i','TRFOUT','{}'::jsonb,'MOBILE','conc');" \
      > "$WORK/ab-$i.out" ) &
  ( q "SELECT status FROM post_transfer('$ACCT_B','$ACCT_A',100000,'CONC-BA-$i','TRFOUT','{}'::jsonb,'MOBILE','conc');" \
      > "$WORK/ba-$i.out" ) &
done
wait

dead=$(grep -lEi 'deadlock|40P01' "$WORK"/ab-*.out "$WORK"/ba-*.out 2>/dev/null | wc -l | tr -d ' ')
tsucc=$(grep -l 'SUCCESS' "$WORK"/ab-*.out "$WORK"/ba-*.out 2>/dev/null | wc -l | tr -d ' ')
tconf=$(grep -lE 'VERSION_CONFLICT|40001' "$WORK"/ab-*.out "$WORK"/ba-*.out 2>/dev/null | wc -l | tr -d ' ')
balA=$(bal "$ACCT_A"); balB=$(bal "$ACCT_B")
echo "T2 deadlock probe: $((M*2)) opposing transfers (A↔B, 100000 each)"
echo "    deadlocks=$dead  success=$tsucc  version_conflict=$tconf  balA=$balA balB=$balB"
[ "$dead" = "0" ] && pass "ZERO deadlocks (deterministic INTERNAL_KEY lock order)" \
                  || fail "deadlocks detected: $dead"
awk "BEGIN{exit !($balA>=0 && $balB>=0)}" && pass "no negative balance (A=$balA B=$balB)" \
                                          || fail "negative balance A=$balA B=$balB"
# Per-account ledger consistency: actual_bal == Σledger for the test accounts.
drift=$(q "SELECT count(*) FROM (
  SELECT a.ACCT_NO,
         a.ACTUAL_BAL AS bal,
         COALESCE(SUM(CASE WHEN h.CR_DR_MAINT_IND='CR' THEN h.TRAN_AMT
                           WHEN h.CR_DR_MAINT_IND='DR' THEN -h.TRAN_AMT END),0) AS ledger
    FROM WLT_ACCT a LEFT JOIN WLT_TRAN_HIST h ON h.INTERNAL_KEY=a.INTERNAL_KEY
   WHERE a.ACCT_NO IN ('$ACCT_A','$ACCT_B')
   GROUP BY a.ACCT_NO, a.ACTUAL_BAL
) t WHERE bal <> ledger;")
[ "$drift" = "0" ] && pass "actual_bal == Σledger for both accounts (no half-applied state)" \
                    || fail "ledger drift on $drift account(s)"

echo "============================================================"
[ "$FAILS" = "0" ] && echo " OVERALL: ✅ ALL PASS" || echo " OVERALL: ❌ $FAILS check(s) FAILED"
echo "============================================================"
exit "$FAILS"
