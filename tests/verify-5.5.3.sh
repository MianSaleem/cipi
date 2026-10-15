#!/bin/bash
# Local regression checks for 5.5.3 — a database restore that does not complete
# is reported as failed: psql stops at the first failed statement
# (ON_ERROR_STOP=1) instead of wiping the schema, skipping the dump and printing
# "restored"; the client's first error is shown; a dump that does not even
# uncompress fails too; the preamble of a dump taken on a newer PostgreSQL is
# adapted to this server's settings (`SET transaction_timeout`) and nothing
# past the preamble is touched.
# Run from repo root: bash tests/verify-5.5.3.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.5.3 regression checks ==="

# Everything below is created, stubbed and removed under $TMP.
TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$TMP" && -d "$TMP" && "$TMP" != "/" ]] || { echo "no temp directory" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

# ── db restore ───────────────────────────────────────────────
echo "-- db restore"
bash -n "${LIB}/db.sh" && pass "db.sh parses" || fail "db.sh does not parse"
grep -q 'ON_ERROR_STOP=0' "${LIB}/db.sh" \
    && fail "a psql call still tolerates SQL errors (ON_ERROR_STOP=0)" || pass "no psql call tolerates SQL errors"
grep -q 'db_restore_database "$engine" "$name" "$file" || { error "Restore failed"; exit 1; }' "${LIB}/db.sh" \
    && pass "cipi db restore exits 1 on a failed restore" || fail "cipi db restore does not fail on a failed restore"

# db.sh against stubbed clients. psql answers the settings query with a fixed
# list, otherwise records what it was fed and fails when asked to.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/psql" <<EOS
#!/bin/bash
if [[ "\$*" == *pg_settings* ]]; then
    [[ -e "${TMP}/settings.off" ]] && exit 1
    printf 'statement_timeout\nlock_timeout\nclient_encoding\nstandard_conforming_strings\n'
    exit 0
fi
echo "\$*" > "${TMP}/psql.args"
cat > "${TMP}/psql.in"
if [[ -e "${TMP}/psql.fail" ]]; then echo 'ERROR:  relation "users" already exists' >&2; exit 3; fi
exit 0
EOS
cat > "${TMP}/bin/mariadb" <<EOS
#!/bin/bash
cat > "${TMP}/mariadb.in"
if [[ -e "${TMP}/mariadb.fail" ]]; then echo 'ERROR 1064 (42000) at line 2: You have an error in your SQL syntax' >&2; exit 1; fi
exit 0
EOS
chmod +x "${TMP}/bin/"*
cat > "${TMP}/rs.sh" <<EOS
set -u
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB="${LIB}"
info(){ :; }; warn(){ :; }; success(){ :; }; step(){ :; }
error(){ echo "\$*" >> "${TMP}/errors"; }
vault_read(){ echo '{}'; }
export PATH="${TMP}/bin:\$PATH"
source "${LIB}/db.sh"
# stubs after the source, which defines the real ones
db_get_root_password(){ echo pw; }
_db_pgsql_exec(){ echo "\$*" >> "${TMP}/pgexec"; }
db_restore_database "\$@"
EOS
restore() { rm -f "${TMP}/errors" "${TMP}/psql.in" "${TMP}/psql.args" "${TMP}/mariadb.in"; bash "${TMP}/rs.sh" "$@"; }

# A pg_dump 17 preamble (unknown transaction_timeout) and a body with traps:
# a COPY data line that looks like SET, and a SET past the preamble whose
# parameter the stubbed server does not know either (must stay).
cat > "${TMP}/dump.sql" <<'SQL'
--
-- PostgreSQL database dump
--

\restrict k3y

-- Dumped from database version 17.2
-- Dumped by pg_dump version 17.2

SET statement_timeout = 0;
SET lock_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);

--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (body text);

SET default_tablespace = '';

COPY public.notes (body) FROM stdin;
SET weird_param = 1;
\.

\unrestrict k3y
SQL
grep -v '^SET transaction_timeout = 0;$' "${TMP}/dump.sql" > "${TMP}/expected.sql"

rm -f "${TMP}/psql.fail" "${TMP}/settings.off"
if restore pgsql shop "${TMP}/dump.sql"; then pass "pgsql restore succeeds"; else fail "pgsql restore failed (exit $?)"; fi
grep -q 'ON_ERROR_STOP=1' "${TMP}/psql.args" && pass "psql runs with ON_ERROR_STOP=1" || fail "psql args: $(cat "${TMP}/psql.args")"
grep -q 'DROP SCHEMA public CASCADE' "${TMP}/pgexec" && pass "public schema wiped before the import" || fail "schema not wiped"
if cmp -s "${TMP}/psql.in" "${TMP}/expected.sql"; then
    pass "preamble SET of a parameter this server lacks is dropped; the rest is untouched"
else
    fail "filtered dump differs: $(diff "${TMP}/expected.sql" "${TMP}/psql.in" | head -5 | tr '\n' '|')"
fi
grep -q '^SET weird_param = 1;$' "${TMP}/psql.in" && pass "COPY data line starting with SET goes through" || fail "COPY data line dropped"
grep -q "^SET default_tablespace = '';$" "${TMP}/psql.in" && pass "SET past the preamble goes through" || fail "body SET dropped"
grep -q '^\\restrict k3y$' "${TMP}/psql.in" && pass "\\restrict kept" || fail "\\restrict dropped"
[[ ! -e "${TMP}/errors" ]] && pass "no error printed on success" || fail "error printed on success: $(cat "${TMP}/errors")"

gzip -c "${TMP}/dump.sql" > "${TMP}/dump.sql.gz"
if restore pgsql shop "${TMP}/dump.sql.gz" && cmp -s "${TMP}/psql.in" "${TMP}/expected.sql"; then
    pass "gzipped dump restored through the same filter"
else fail "gzipped dump: exit $? / $(diff "${TMP}/expected.sql" "${TMP}/psql.in" | head -3 | tr '\n' '|')"; fi

touch "${TMP}/settings.off"
if restore pgsql shop "${TMP}/dump.sql" && cmp -s "${TMP}/psql.in" "${TMP}/dump.sql"; then
    pass "settings unreadable: the dump passes unchanged"
else fail "settings unreadable: dump altered or restore failed"; fi
rm -f "${TMP}/settings.off"

touch "${TMP}/psql.fail"
if restore pgsql shop "${TMP}/dump.sql"; then fail "a failed import reported as restored"
else pass "a failed import returns non-zero"; fi
grep -q 'PostgreSQL restore: ERROR: relation "users" already exists' "${TMP}/errors" 2>/dev/null \
    && pass "psql's first error is shown" || fail "error not shown: $(cat "${TMP}/errors" 2>/dev/null)"
rm -f "${TMP}/psql.fail"

printf 'this is not gzip\n' > "${TMP}/bad.sql.gz"
if restore pgsql shop "${TMP}/bad.sql.gz"; then fail "a dump that does not uncompress reported as restored"
else pass "a dump that does not uncompress fails"; fi
grep -qi 'gzip' "${TMP}/errors" 2>/dev/null && pass "gunzip's error is shown" || fail "gunzip error not shown: $(cat "${TMP}/errors" 2>/dev/null)"

printf 'CREATE TABLE t (id int);\n' > "${TMP}/m.sql"
rm -f "${TMP}/mariadb.fail"
if restore mariadb shop "${TMP}/m.sql" && cmp -s "${TMP}/mariadb.in" "${TMP}/m.sql"; then pass "mariadb restore feeds the dump"
else fail "mariadb restore"; fi
gzip -c "${TMP}/m.sql" > "${TMP}/m.sql.gz"
if restore mariadb shop "${TMP}/m.sql.gz" && cmp -s "${TMP}/mariadb.in" "${TMP}/m.sql"; then pass "mariadb gzipped restore"
else fail "mariadb gzipped restore"; fi
touch "${TMP}/mariadb.fail"
if restore mariadb shop "${TMP}/m.sql"; then fail "mariadb failed import reported as restored"
else pass "mariadb failed import returns non-zero"; fi
grep -q 'MariaDB restore: ERROR 1064' "${TMP}/errors" 2>/dev/null && pass "mariadb's error is shown" || fail "mariadb error not shown: $(cat "${TMP}/errors" 2>/dev/null)"
rm -f "${TMP}/mariadb.fail"

if restore sqlite shop "${TMP}/m.sql"; then fail "unknown engine accepted"; else pass "unknown engine refused"; fi

echo ""
echo "Passed: ${PASS}  Failed: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
