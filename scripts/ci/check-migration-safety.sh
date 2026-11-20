#!/usr/bin/env bash
# Starter migration safety gate.
#
# Fails on obviously destructive migration patterns unless explicitly allowed:
#   ALLOW_DESTRUCTIVE_MIGRATIONS=true

set -euo pipefail

ALLOW_DESTRUCTIVE_MIGRATIONS="${ALLOW_DESTRUCTIVE_MIGRATIONS:-false}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/ci/check-migration-safety.sh

Environment:
  ALLOW_DESTRUCTIVE_MIGRATIONS=true   # bypass destructive checks (not recommended)
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 2
fi

if git rev-parse --verify --quiet origin-https/dev >/dev/null 2>&1; then
  base_ref="$(git merge-base HEAD origin-https/dev)"
else
  base_ref="${GIT_PREVIOUS_SUCCESSFUL_COMMIT:-HEAD~1}"
fi

changed_migrations="$(
  git diff --name-only "${base_ref}"...HEAD -- \
    'db/migrate/*.rb' \
    'modules/*/db/migrate/*.rb' \
  || true
)"

if [[ -z "${changed_migrations}" ]]; then
  echo "Migration safety: no migration changes detected."
  exit 0
fi

echo "Migration safety: checking changed migrations"
printf '%s\n' "${changed_migrations}"

destructive_hits=()
while IFS= read -r file; do
  [[ -n "${file}" ]] || continue
  [[ -f "${file}" ]] || continue

  if grep -Eq '\b(drop_table|remove_column|remove_reference|rename_column|change_column_null\s+.*,\s*false\b|execute\s+.*DROP\s+|remove_index)\b' "${file}"; then
    destructive_hits+=("${file}")
  fi
done <<< "${changed_migrations}"

if [[ ${#destructive_hits[@]} -eq 0 ]]; then
  echo "Migration safety: PASS (no destructive patterns found)."
  exit 0
fi

echo "Migration safety: potential destructive migration patterns detected:" >&2
printf ' - %s\n' "${destructive_hits[@]}" >&2

if [[ "${ALLOW_DESTRUCTIVE_MIGRATIONS}" == "true" ]]; then
  echo "Migration safety: override enabled (ALLOW_DESTRUCTIVE_MIGRATIONS=true)." >&2
  exit 0
fi

echo "Migration safety: FAIL. Use expand/migrate/contract or explicitly override." >&2
exit 1
