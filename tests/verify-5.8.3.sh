#!/bin/bash
# Local regression checks for 5.8.3 — the panel API's daily maintenance
# prunes the jobs whose output holds a password (app-create, db-create,
# db-password) after one day instead of fourteen, and migration 5.8.3
# rewrites that script on servers with the API. The maintenance helper is
# extracted from lib/api.sh and run against a temporary SQLite database, so
# nothing outside the temp dir is touched and bash 3.2 (macOS) is enough.
# Run from repo root: bash tests/verify-5.8.3.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.8.3 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.3" ]] \
    && pass "version.md is 5.8.3" || fail "version.md is not 5.8.3"
grep -q '^## \[5.8.3\]' "${ROOT}/CHANGELOG.md" && grep -q 'cipi/api 1.36.1' "${ROOT}/CHANGELOG.md" \
    && grep -q 'kept one day, not fourteen' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.3 entry naming cipi/api 1.36.1 and the one-day retention" || fail "CHANGELOG 5.8.3"

bash -n "${LIB}/api.sh" && pass "api.sh parses" || fail "api.sh syntax"
bash -n "${LIB}/migrations/5.8.3.sh" && pass "migration 5.8.3 parses" || fail "migration 5.8.3 syntax"
grep -q '_api_setup_cron' "${LIB}/migrations/5.8.3.sh" && grep -q 'sudo -u www-data /usr/local/bin/cipi-api-maintain' "${LIB}/migrations/5.8.3.sh" \
    && pass "migration rewrites the cron and runs the maintenance as www-data" || fail "migration body"
grep -q "type IN ('app-create','db-create','db-password') AND created_at < datetime('now','-1 day')" "${LIB}/api.sh" \
    && pass "maintenance helper prunes the three credential job types after a day" || fail "api.sh prune line"

# --- migration without the API: a no-op that exits 0 -------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "${tmp}/etc"
out=$(CIPI_LIB="$LIB" CIPI_CONFIG="${tmp}/etc" CIPI_API_ROOT="${tmp}/no-api" bash "${LIB}/migrations/5.8.3.sh" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'not installed' <<< "$out" \
    && pass "migration without the panel API: nothing to do, exit 0" || fail "migration no-op (rc=$rc): $out"

# --- the maintenance helper against a temp SQLite panel database --------------
if ! command -v sqlite3 >/dev/null 2>&1 || [[ ! -x /usr/bin/sqlite3 ]]; then
    echo "  SKIP: sqlite3 not available — maintenance run not exercised"
else
    api_root="${tmp}/api"
    mkdir -p "${api_root}/database"
    db="${api_root}/database/database.sqlite"
    printf 'APP_NAME=cipi-api\nDB_CONNECTION=sqlite\nDB_DATABASE=%s\n' "$db" > "${api_root}/.env"
    sqlite3 "$db" "CREATE TABLE cipi_jobs (id TEXT PRIMARY KEY, type TEXT, params TEXT, status TEXT, output TEXT, exit_code INTEGER, created_at TEXT, updated_at TEXT);"
    ins() { sqlite3 "$db" "INSERT INTO cipi_jobs (id, type, status, output, created_at, updated_at) VALUES ('$1', '$2', '$3', 'x', datetime('now','$4'), datetime('now','$4'));"; }
    ins j1 db-password completed '-2 days'     # password, older than a day   → pruned
    ins j2 db-password completed '-2 hours'    # password, fresh              → kept
    ins j3 app-create  failed    '-3 days'     # SSH + DB password, old       → pruned
    ins j4 db-create   completed '-30 hours'   # password, older than a day   → pruned
    ins j5 app-deploy  completed '-3 days'     # no password, under 14 days   → kept
    ins j6 app-deploy  completed '-20 days'    # over 14 days                 → pruned (14-day rule)
    ins j7 db-password running   '-30 days'    # never touched while running  → kept
    ins j8 app-artisan completed '-13 days'    # under 14 days                → kept

    # The helper as _api_setup_cron writes it, pointed at the temp app.
    awk "/cat > \/usr\/local\/bin\/cipi-api-maintain <<'MAINTAIN'/{f=1;next} /^MAINTAIN\$/{f=0} f" "${LIB}/api.sh" > "${tmp}/maintain.raw"
    sed -e "s|^API_ROOT=\"/opt/cipi/api\"|API_ROOT=\"${api_root}\"|" "${tmp}/maintain.raw" > "${tmp}/maintain.sh"
    grep -q "^API_ROOT=\"${api_root}\"" "${tmp}/maintain.sh" && pass "maintenance helper extracted from api.sh" || fail "helper extraction"

    run_out=$(bash "${tmp}/maintain.sh" 2>&1); rc=$?
    [[ $rc -eq 0 ]] && pass "maintenance helper ran (exit 0)" || fail "maintenance helper exit $rc: $run_out"
    grep -q 'cipi_jobs pruned: 1' <<< "$run_out" && pass "14-day rule removed the one old deploy job" || fail "14-day count: $run_out"
    grep -q 'cipi_jobs with credentials pruned: 3' <<< "$run_out" && pass "one-day rule removed the three finished credential jobs" || fail "credential count: $run_out"
    left=$(sqlite3 "$db" "SELECT id FROM cipi_jobs ORDER BY id;" | tr '\n' ' ' | sed 's/ $//')
    [[ "$left" == "j2 j5 j7 j8" ]] && pass "kept: fresh password job, recent deploy, running job, 13-day artisan ($left)" || fail "remaining rows: $left"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
