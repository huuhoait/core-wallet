#!/usr/bin/env bash
# =============================================================================
# scripts/clean-branches.sh — delete ALL local and remote branches except master
# (plus any names in KEEP). DRY-RUN by default; nothing is deleted without --yes.
#
# Usage:
#   bash scripts/clean-branches.sh                 # dry run — list what WOULD be deleted
#   bash scripts/clean-branches.sh --yes           # delete local + remote branches != master
#   bash scripts/clean-branches.sh --yes --local   # local branches only
#   bash scripts/clean-branches.sh --yes --remote  # remote branches only
#   KEEP="master develop" bash scripts/clean-branches.sh --yes   # protect extra branches
#   REMOTE=upstream       bash scripts/clean-branches.sh --yes   # target a different remote
#
# ⚠  DESTRUCTIVE & IRREVERSIBLE for unmerged work:
#   - `git branch -D` force-deletes local branches even if not merged.
#   - Deleting a REMOTE branch that has an OPEN PULL REQUEST will CLOSE that PR.
#   Review the dry-run output before re-running with --yes.
# =============================================================================
set -euo pipefail

REMOTE="${REMOTE:-origin}"
KEEP="${KEEP:-master}"        # space-separated branch names that are never deleted
APPLY=0 DO_LOCAL=1 DO_REMOTE=1

for a in "$@"; do
  case "$a" in
    -y|--yes)        APPLY=1 ;;
    --local)         DO_REMOTE=0 ;;
    --remote)        DO_LOCAL=0 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a (try --help)" >&2; exit 2 ;;
  esac
done

protected() { local b=$1 k; for k in $KEEP; do [ "$b" = "$k" ] && return 0; done; return 1; }

echo "▶ remote=$REMOTE   protected(KEEP)=\"$KEEP\"   mode=$([ $APPLY = 1 ] && echo APPLY || echo DRY-RUN)"
echo

n_local=0 n_remote=0

# ── Local branches ────────────────────────────────────────────────────────
if [ "$DO_LOCAL" = 1 ]; then
  # git refuses to delete the checked-out branch → move to master first (apply mode).
  cur="$(git symbolic-ref --quiet --short HEAD || echo '')"
  if [ -n "$cur" ] && ! protected "$cur"; then
    echo "• current branch '$cur' is not protected → will switch to master first"
    [ "$APPLY" = 1 ] && git checkout master >/dev/null 2>&1
  fi

  echo "== LOCAL branches to delete =="
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    protected "$b" && continue
    n_local=$((n_local+1))
    if [ "$APPLY" = 1 ]; then git branch -D "$b"; else echo "  would delete  $b"; fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
  [ "$n_local" -eq 0 ] && echo "  (none)"
  echo
fi

# ── Remote branches ─────────────────────────────────────────────────────────
if [ "$DO_REMOTE" = 1 ]; then
  echo "== REMOTE ($REMOTE) branches to delete =="
  # Authoritative list straight from the remote (not stale tracking refs).
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    [ "$b" = "HEAD" ] && continue
    protected "$b" && continue
    n_remote=$((n_remote+1))
    if [ "$APPLY" = 1 ]; then git push "$REMOTE" --delete "$b"; else echo "  would delete  $REMOTE/$b"; fi
  done < <(git ls-remote --heads "$REMOTE" | sed -E 's#.*refs/heads/##')
  [ "$n_remote" -eq 0 ] && echo "  (none)"
  echo
fi

if [ "$APPLY" = 1 ]; then
  echo "✓ done — deleted $n_local local + $n_remote remote branch(es). Pruning stale tracking refs…"
  git remote prune "$REMOTE" >/dev/null 2>&1 || true
else
  echo "(DRY RUN) $n_local local + $n_remote remote branch(es) match. Re-run with --yes to delete."
fi
