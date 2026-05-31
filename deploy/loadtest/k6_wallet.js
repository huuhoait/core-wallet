// =============================================================================
// loadtest/k6_wallet.js — HTTP/end-to-end load test through the Go service
// =============================================================================
// Prereqs:
//   1. Seed wallets:   SETUP=1 bash loadtest/run.sh 1 1 1   (or psql -f setup.sql)
//      (do NOT teardown — k6 needs the LT* wallets + LTG* merchant groups to exist)
//   2. Start service:  DB_DSN=... HTTP_ADDR=:8099 go run ./cmd/server   (in wallet-service/)
//   3. Run k6:         k6 run -e BASE_URL=http://localhost:8099 loadtest/k6_wallet.js
//      tune:           k6 run -e NWALLET=200 -e NGROUP=20 -e PEAK=500 loadtest/k6_wallet.js
//
// Mix — mirrors the pgbench DB/SP tier (deploy/loadtest/run.sh) 1:1 so the HTTP
// and DB tiers are directly comparable (weights /100):
//   topup 16 / transfer 16 / withdraw 10 / reversal 10 / withdraw_reversal 10 /
//   merchant_topup 10 / merchant_withdraw 10 / restraint 6 / onboard 7 / kyc_update 5
//
// Multi-call flows post an original then act on it (2 HTTP calls, like the matching
// *.sql), so the second call always finds a SUCCESS original:
//   - reversal          → transfer + POST /finance/reverse                  (reversal.sql)
//   - withdraw_reversal → withdraw + POST /treasury/withdrawals/:ext/reverse (withdraw_reversal.sql)
//   - merchant_topup    → consumer→settlement transfer LT→LTGS              (merchant_topup.sql)
//   - restraint         → POST /finance/restraints + /:id/release           (restraint.sql)
//
// Onboarding (OTP-free, US-1.1/1.2):
//   - onboard    → POST /v1/onboard — creates a NEW client + KYC + zero-balance
//                  wallet. Unique phone/global_id per (VU,iter). GROWS the DB
//                  (new C* client + 9701* wallet per call — re-init between heavy runs).
//   - kyc_update → POST /v1/clients/LTC*/kyc — refresh eKYC + tier on a seeded LT
//                  consumer (no growth; exercises the UPDATE audit path).
//
// VERSION_CONFLICT surfaces as HTTP 409 (the Go layer does not auto-retry today);
// it is counted as `conflict`, not a hard failure — a real client should retry.
// =============================================================================
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

const BASE = __ENV.BASE_URL || 'http://localhost:8099';
const NW   = parseInt(__ENV.NWALLET || '10000');
const NG   = parseInt(__ENV.NGROUP  || '20');    // merchant groups (LTG01..LTGnn)
const PEAK = parseInt(__ENV.PEAK    || '100');   // peak target TPS
const DUR  = parseInt(__ENV.DURATION || '0');    // DURATION=N → short N-second run (2s ramp + hold at PEAK) instead of the 90s staged ramp

// Business outcomes (409 conflict, 422 insufficient/limit, 423 restrained) are
// valid fast responses, not infra failures — mark them "expected" so
// http_req_failed and the latency threshold reflect only real errors.
http.setResponseCallback(http.expectedStatuses(200, 201, 409, 422, 423));

// outcome counts every response tagged by its business code (success status
// field, e.g. SUCCESS/DUPLICATE, or the error envelope `code`). The end-of-test
// summary renders a per-code breakdown (see handleSummary below).
const outcome = new Counter('outcome');

// Known outcome labels — listed in thresholds so k6 materialises a per-tag
// sub-metric for each (the `count>=0` guard always passes, it only forces the
// sub-metric to appear). Any label NOT here is still counted in the `outcome`
// aggregate and shown as "(other/unlisted)" in the breakdown.
const KNOWN_OUTCOMES = [
  // success
  'SUCCESS', 'DUPLICATE', 'BALANCE_OK', 'REVERSED', 'REVERSED_DUP', 'SETTLEMENT_SWEEP_REQUIRED',
  'RESTRAINT_ADDED', 'RESTRAINT_RELEASED', 'ONBOARDED', 'KYC_UPDATED',
  // onboarding validation (onboard_client / update_kyc)
  'PHONE_ALREADY_REGISTERED', 'ORG_FIELDS_REQUIRED', 'INVALID_PHONE_FORMAT', 'CLIENT_NOT_FOUND',
  // restraint validation (add_restraint, §4.9)
  'RESTRAINT_TYPE_INVALID', 'RESTRAINT_PURPOSE_INVALID', 'RESTRAINT_AMT_EXCEEDS_BALANCE',
  // business / errors
  'VERSION_CONFLICT', 'VERSION_CONFLICT_FROM', 'VERSION_CONFLICT_TO',
  'INSUFFICIENT_FUNDS', 'TIER_LIMIT_EXCEEDED',
  'WD_INVALID_STATE', 'WD_ALREADY_REVERSED', 'WD_ALREADY_COMPLETED', 'WD_NOT_FOUND',
  'DR_RESTRAINT_ACTIVE', 'CR_RESTRAINT_ACTIVE',
  'DUPLICATE_REFERENCE', 'ACCT_NOT_FOUND', 'INVALID_REQUEST', 'TIMEOUT', 'INTERNAL_ERROR',
];

export const options = {
  scenarios: {
    wallet: {
      executor: 'ramping-arrival-rate',
      startRate: 10, timeUnit: '1s',
      // preAllocatedVUs sized so the ramp never waits on runtime VU allocation
      // (that lag caused dropped_iterations at PEAK>=700). maxVUs gives headroom
      // when per-iteration latency rises — at 700 TPS the old cap of 300 was hit.
      preAllocatedVUs: 150, maxVUs: 600,
      stages: DUR ? [
        { target: PEAK, duration: '2s' },
        { target: PEAK, duration: (DUR > 2 ? DUR - 2 : 1) + 's' },
      ] : [
        { target: 10,   duration: '15s' },
        { target: 50,   duration: '15s' },
        { target: PEAK, duration: '30s' },
        { target: PEAK, duration: '20s' },
        { target: 0,    duration: '10s' },
      ],
    },
  },
  thresholds: Object.assign(
    {
      // 2xx-or-handled responses; conflicts/insufficient are business outcomes, not errors
      'checks': ['rate>0.99'],
      'http_req_duration{expected_response:true}': ['p(95)<200'],
    },
    // one always-passing sub-metric per known outcome so it shows in the summary
    KNOWN_OUTCOMES.reduce((acc, o) => { acc[`outcome{code:${o}}`] = ['count>=0']; return acc; }, {}),
  ),
};

const H = { headers: { 'Content-Type': 'application/json', 'X-Caller-Subject': 'k6', 'X-Channel': 'MOBILE' } };
const acct = (i) => 'LT' + String(i).padStart(10, '0');
const grp  = (i) => 'LTG' + String(i).padStart(2, '0');
const stl  = (i) => 'LTGS' + String(i).padStart(4, '0');   // group SETTLEMENT acct (8 chars — passes the HTTP acct_no validator; merchant_topup target)
const kyc  = (i) => 'LTC' + String(i).padStart(9, '0');    // seeded LT consumer client_no (update_kyc target)
const ref  = (p) => `${p}-${__VU}-${__ITER}-${Date.now()}`;

// outcomeLabel derives a single business label from a response: the success
// `status` field (SUCCESS/DUPLICATE), a reversal result, a balance read, or the
// error envelope `code`. Falls back to HTTP_<status> when the body has neither.
function outcomeLabel(res) {
  let body = null;
  try { body = res.json(); } catch (_) { body = null; }
  if (res.status >= 200 && res.status < 300) {
    if (body && typeof body.status === 'string') return body.status;          // SUCCESS | DUPLICATE | SETTLEMENT_SWEEP_REQUIRED
    if (body && 'was_already_reversed' in body) return body.was_already_reversed ? 'REVERSED_DUP' : 'REVERSED';
    if (res.request && res.request.method === 'GET') return 'BALANCE_OK';
    return `HTTP_${res.status}`;
  }
  if (body && typeof body.code === 'string') return body.code;                // VERSION_CONFLICT | INSUFFICIENT_FUNDS | ...
  return `HTTP_${res.status}`;
}

function recordOutcome(res) {
  outcome.add(1, { code: outcomeLabel(res) });
}

// recordOutcomeAs labels a 2xx response with an explicit name (e.g. RESTRAINT_ADDED)
// and otherwise falls back to the error-envelope code — for flows whose success
// body carries no `status`/`code` of its own.
function recordOutcomeAs(res, okLabel) {
  outcome.add(1, { code: (res.status >= 200 && res.status < 300) ? okLabel : outcomeLabel(res) });
}

// classify a write/read response: SUCCESS(201) | DUPLICATE(200) | balance(200) |
// conflict(409) | insufficient/limit(422) | restrained(423) are all "handled"
// business outcomes (not infra failures).
function classify(res) {
  recordOutcome(res);
  const ok = check(res, { 'handled': (r) => [200, 201, 409, 422, 423].includes(r.status) });
  // Fresh writes (201) must carry the ISO 20022 transaction_status (errors §13.3).
  if (res.status === 201) {
    check(res, { 'tx_status present': (r) => {
      try { return typeof r.json().transaction_status === 'string'; } catch (_) { return false; }
    } });
  }
  return ok;
}

// reverse an original only if it actually SUCCESS (201); a 409/402 original is a
// handled business outcome with nothing to reverse.
function reverseIfPosted(origRes, reverseFn) {
  classify(origRes);
  if (origRes.status !== 201) return;
  const rev = reverseFn();
  recordOutcome(rev);
  check(rev, { 'reversed': (r) => r.status === 200 });
}

// addReleaseRestraint mirrors restraint.sql: place a DEBIT/PLEDGE hold on a random
// consumer wallet, then release it (balance-neutral). 2 HTTP calls. The add returns
// 201 with NO transaction_status (it is not a posting), so it skips classify().
function addReleaseRestraint() {
  const add = http.post(`${BASE}/v1/finance/restraints`, JSON.stringify({
    acct_no: acct(randomIntBetween(1, NW)), restraint_type: 'DEBIT', restraint_purpose: 'PLEDGE',
    pledged_amt: String(randomIntBetween(1000, 100000)), narrative: ref('K6RST'),
  }), H);
  recordOutcomeAs(add, 'RESTRAINT_ADDED');
  check(add, { 'handled': (r) => [201, 409, 422, 423].includes(r.status) });
  if (add.status !== 201) return;
  let id = null; try { id = add.json().restraint_id; } catch (_) { id = null; }
  if (!id) return;
  const rel = http.post(`${BASE}/v1/finance/restraints/${id}/release`, JSON.stringify({
    reason: 'k6 load-test release',
  }), H);
  recordOutcomeAs(rel, 'RESTRAINT_RELEASED');
  check(rel, { 'released': (r) => r.status === 200 });
}

// onboard mirrors onboard.sql (US-1.1): POST /v1/onboard creates a NEW client + KYC
// + zero-balance wallet. A per-(VU,iter) counter keeps phone + global_id unique
// within a run (cross-run reuse → 409 PHONE_ALREADY_REGISTERED, a handled outcome).
// The 201 carries no transaction_status (not a posting), so it skips classify().
function onboard() {
  const n = __VU * 1000000 + __ITER;
  const phone = '08' + String(n % 100000000).padStart(8, '0');
  const res = http.post(`${BASE}/v1/onboard`, JSON.stringify({
    client_name: 'K6 Onboard ' + n, client_type: 'IND', phone,
    global_id: 'LT-OB-K6-' + n, global_id_type: 'CCCD',
    birthdate: '1990-01-01', sex: 'M',
    extra_data: { surname: 'K6', given_name: 'Onboard' + n },
  }), H);
  recordOutcomeAs(res, 'ONBOARDED');
  check(res, { 'handled': (r) => [201, 400, 409, 422].includes(r.status) });
}

// kyc_update mirrors update_kyc.sql (US-1.2): refresh eKYC + tier on a seeded LT
// consumer (LTC*). 200, no transaction_status → custom check, not classify().
function updateKyc() {
  const res = http.post(`${BASE}/v1/clients/${kyc(randomIntBetween(1, NW))}/kyc`, JSON.stringify({
    kyc_tier: String(randomIntBetween(1, 3)), status: 'A', risk_level: 'M',
    ekyc_provider: 'VNG', ekyc_ref: ref('K6KYC'), face_match_score: 0.97, liveness_result: 'PASS',
    extra_data: { occupation_code: 'ENG' },
  }), H);
  recordOutcomeAs(res, 'KYC_UPDATED');
  check(res, { 'handled': (r) => [200, 404, 422].includes(r.status) });
}

// 10-way mix, weights identical to the pgbench tier (deploy/loadtest/run.sh).
export default function () {
  const r = Math.random() * 100;

  if (r < 16) {
    // topup (16%)
    classify(http.post(`${BASE}/v1/finance/topup`, JSON.stringify({
      acct_no: acct(randomIntBetween(1, NW)), amount: String(randomIntBetween(10000, 1000000)), reference: ref('K6TU'),
    }), H));

  } else if (r < 32) {
    // transfer — TRFOUT, consumer → consumer (16%)
    const a = randomIntBetween(1, NW); const b = (a % NW) + 1;
    classify(http.post(`${BASE}/v1/finance/transfer`, JSON.stringify({
      from_acct_no: acct(a), to_acct_no: acct(b), amount: String(randomIntBetween(1000, 500000)),
      reference: ref('K6TR'), tran_type: 'TRFOUT',
    }), H));

  } else if (r < 42) {
    // withdraw — fee + VAT (10%)
    classify(http.post(`${BASE}/v1/finance/withdraw`, JSON.stringify({
      acct_no: acct(randomIntBetween(1, NW)), amount: String(randomIntBetween(50000, 500000)),
      reference: ref('K6WD'), ext_payout_ref: ref('K6EXT'), beneficiary_bank: 'BIDV', beneficiary_acct: '9990000000',
    }), H));

  } else if (r < 52) {
    // reversal — transfer + reverse (10%)  [reversal.sql]
    const a = randomIntBetween(1, NW); const b = (a % NW) + 1;
    const reference = ref('K6RVT');
    const orig = http.post(`${BASE}/v1/finance/transfer`, JSON.stringify({
      from_acct_no: acct(a), to_acct_no: acct(b), amount: String(randomIntBetween(1000, 100000)),
      reference, tran_type: 'TRFOUT',
    }), H);
    reverseIfPosted(orig, () => http.post(`${BASE}/v1/finance/reverse`, JSON.stringify({
      reference, reason: 'k6 load-test reversal', initiator: 'OPS_MANUAL',
    }), H));

  } else if (r < 62) {
    // withdraw_reversal — withdraw + treasury-failed roll-back (10%)  [withdraw_reversal.sql]
    const reference = ref('K6RVW'); const ext = ref('K6RVWEXT');
    const orig = http.post(`${BASE}/v1/finance/withdraw`, JSON.stringify({
      acct_no: acct(randomIntBetween(1, NW)), amount: String(randomIntBetween(50000, 300000)),
      reference, ext_payout_ref: ext, beneficiary_bank: 'BIDV', beneficiary_acct: '9990000000',
    }), H);
    reverseIfPosted(orig, () => http.post(`${BASE}/v1/treasury/withdrawals/${ext}/reverse`, JSON.stringify({
      fail_code: 'NAPAS_TIMEOUT', fail_reason: 'k6 load-test withdraw reversal', initiator: 'TREASURY_FAILED',
    }), H));

  } else if (r < 72) {
    // merchant_topup — a consumer pays a merchant: consumer → group SETTLEMENT (10%)  [merchant_topup.sql]
    classify(http.post(`${BASE}/v1/finance/transfer`, JSON.stringify({
      from_acct_no: acct(randomIntBetween(1, NW)), to_acct_no: stl(randomIntBetween(1, NG)),
      amount: String(randomIntBetween(10000, 500000)), reference: ref('K6MTU'), tran_type: 'TRFOUT',
    }), H));

  } else if (r < 82) {
    // merchant_withdraw — hot-shard sweep + settlement (10%)
    classify(http.post(`${BASE}/v1/finance/merchant-withdraw`, JSON.stringify({
      group_id: grp(randomIntBetween(1, NG)), amount: String(randomIntBetween(50000, 2000000)), reference: ref('K6MW'),
    }), H));

  } else if (r < 88) {
    // restraint — add a DEBIT/PLEDGE hold then release it (6%)  [restraint.sql]
    addReleaseRestraint();

  } else if (r < 95) {
    // onboard — OTP-free client + KYC + wallet (7%)  [onboard.sql]
    onboard();

  } else {
    // kyc_update — refresh eKYC + tier on a seeded consumer (5%)  [update_kyc.sql]
    updateKyc();
  }
}

// handleSummary appends a per-code breakdown table to the standard k6 summary.
// Each `outcome{code:*}` sub-metric (materialised via thresholds) is listed with
// its count and share; labels not in KNOWN_OUTCOMES roll up into "(other)".
export function handleSummary(data) {
  const rows = [];
  let listed = 0;
  for (const key of Object.keys(data.metrics)) {
    const m = key.match(/^outcome\{code:(.+)\}$/);
    if (!m) continue;
    const c = (data.metrics[key].values && data.metrics[key].values.count) || 0;
    listed += c;
    if (c > 0) rows.push([m[1], c]);
  }
  const total = (data.metrics.outcome && data.metrics.outcome.values.count) || 0;
  const other = total - listed;
  if (other > 0) rows.push(['(other/unlisted)', other]);
  rows.sort((a, b) => b[1] - a[1]);

  const ERR = new Set([
    'VERSION_CONFLICT', 'VERSION_CONFLICT_FROM', 'VERSION_CONFLICT_TO', 'INSUFFICIENT_FUNDS',
    'TIER_LIMIT_EXCEEDED', 'WD_INVALID_STATE', 'WD_ALREADY_REVERSED', 'WD_ALREADY_COMPLETED',
    'WD_NOT_FOUND', 'DR_RESTRAINT_ACTIVE', 'CR_RESTRAINT_ACTIVE',
    'DUPLICATE_REFERENCE', 'ACCT_NOT_FOUND', 'INVALID_REQUEST', 'TIMEOUT', 'INTERNAL_ERROR',
  ]);

  let t = `\n  █ RESPONSE CODE BREAKDOWN  (${total} responses)\n\n`;
  for (const [code, cnt] of rows) {
    const pct = total ? (100 * cnt / total).toFixed(2) : '0.00';
    const mark = ERR.has(code) || code.startsWith('HTTP_') || code === '(other/unlisted)' ? '✗' : '✓';
    t += `    ${mark} ${code.padEnd(26)} ${String(cnt).padStart(8)}   ${pct.padStart(6)}%\n`;
  }
  const out = { stdout: textSummary(data, { indent: ' ', enableColors: true }) + '\n' + t };
  // Emit the raw metrics JSON for the sweep harness (loadtest/k6_sweep.sh) to parse.
  if (__ENV.SUMMARY_OUT) out[__ENV.SUMMARY_OUT] = JSON.stringify(data);
  return out;
}
