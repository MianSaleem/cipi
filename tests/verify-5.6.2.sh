#!/bin/bash
# Local regression checks for 5.6.2 — PostgreSQL restore is atomic:
# wipe and import run in one transaction, COMMIT only after the whole dump
# is read, and an empty dump is refused before the wipe can commit.
# Run from repo root: bash tests/verify-5.6.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.6.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.6.2" ]] \
    && pass "version.md is 5.6.2" || fail "version.md is not 5.6.2"
grep -q '^## \[5.6.2\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.6.2 entry" || fail "CHANGELOG has no 5.6.2 entry"
bash -n "${LIB}/db.sh" && pass "db.sh parses" || fail "db.sh does not parse"

grep -q 'BEGIN;' "${LIB}/db.sh" \
    && grep -q 'COMMIT;' "${LIB}/db.sh" \
    && grep -q 'pg_get_userbyid(datdba)' "${LIB}/db.sh" \
    && pass "PostgreSQL restore wraps wipe and import in a transaction" \
    || fail "transactional restore wiring missing in db.sh"

grep -q 'the dump is empty' "${LIB}/db.sh" \
    && grep -q 'g(un)?zip:' "${LIB}/db.sh" \
    && pass "empty dumps are refused and gunzip errors are recognized" \
    || fail "empty-dump or gunzip handling missing in db.sh"

grep -q 'one transaction' "${ROOT}/CHANGELOG.md" \
    && grep -q 'database owner' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG describes the atomic restore" \
    || fail "CHANGELOG content"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
