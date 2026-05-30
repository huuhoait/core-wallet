#!/usr/bin/env bash
# =============================================================================
# truncate_operational_data.sh
#
# Wrapper around truncate_operational_data.sql. Shows row counts before/after,
# asks for an explicit "YES" confirmation, then runs the truncate.
# Preserves master/reference data; clears customers, postings, tran history,
# outbox, audit, balances, etc.  ⚠ DESTRUCTIVE — DEV / pre-prod only.
#
# Usage:
#   ./truncate_operational_data.sh                 # interactive confirm
#   FORCE=1 ./truncate_operational_data.sh         # skip the prompt (CI/scripts)
#   RESET_SEQUENCES=1 ./truncate_operational_data.sh   # also reset seq_client/acct_no/tfr
#
# Connection (defaults match the local docker stack):
#   DB=wallet  DB_USER=postgres   run via:  docker compose exec -T postgres psql
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/truncate_operational_data.sql"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"   # repo root (holds docker-compose.yml)

DB="${DB:-wallet}"
DB_USER="${DB_USER:-postgres}"
RESET_SEQUENCES="${RESET_SEQUENCES:-0}"
FORCE="${FORCE:-0}"

# psql runner — via docker compose by default.
run_psql() {
  ( cd "$COMPOSE_DIR" && docker compose exec -T postgres psql -U "$DB_USER" -d "$DB" "$@" )
}

# Base/parent tables that get truncated — kept in sync with the .sql file.
TRUNCATE_TABLES=(
  fm_client fm_client_indvl fm_client_identifiers fm_client_contact fm_client_banks
  wlt_client_kyc wlt_acct wlt_acct_group wlt_acct_bal wlt_restraints
  wlt_batch wlt_tran_hist wlt_outbox wlt_api_message wlt_withdraw_track
  wlt_client_audit_log wlt_sweep_log wlt_nostro_bal
)

count_query() {
  local q="" t
  for t in "${TRUNCATE_TABLES[@]}"; do
    q+="SELECT '${t}' AS table_name, count(*) AS rows FROM ${t} UNION ALL "
  done
  q="${q% UNION ALL }"
  echo "SELECT table_name, rows FROM (${q}) s ORDER BY rows DESC, table_name;"
}

echo "=== wallet DB — truncate operational data (DB=${DB}) ==="
echo "PRESERVED (master/reference): fm_currency, fm_gl_mast, fm_nos_vos,"
echo "                              wlt_acct_type, wlt_tran_def, wlt_gl_map, wlt_nostro_link"
[[ "$RESET_SEQUENCES" == "1" ]] && echo "App sequences (seq_client/seq_acct_no/seq_tfr): WILL RESET"
echo
echo "--- Row counts BEFORE ---"
run_psql -c "$(count_query)"

if [[ "$FORCE" != "1" ]]; then
  echo
  read -r -p "Type 'YES' to TRUNCATE all of the above on DB='${DB}': " ans
  [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
fi

ARGS=(-v confirm=YES)
[[ "$RESET_SEQUENCES" == "1" ]] && ARGS+=(-v reset_sequences=1)

# Stream the SQL file into the container's psql (reads from stdin via -f -).
run_psql "${ARGS[@]}" -f - < "$SQL_FILE"

echo
echo "--- Row counts AFTER ---"
run_psql -c "$(count_query)"
echo "Done."
