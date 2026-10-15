#!/bin/bash
# Local regression checks for 5.6.1 — deploy.post artisan steps:
# the runner line is `/usr/bin/phpX.Y artisan …` (it was `/usr/bin/phpX.Yartisan`),
# and a failed step reports its real exit code, so post_on_failure: abort fails.
# Run from repo root: bash tests/verify-5.6.1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.6.1 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.6.1" ]] \
    && pass "version.md is 5.6.1" || fail "version.md is not 5.6.1"
grep -q '^## \[5.6.1\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.6.1 entry" || fail "CHANGELOG has no 5.6.1 entry"
bash -n "${LIB}/yml.sh" && pass "yml.sh parses" || fail "yml.sh does not parse"

if (( BASH_VERSINFO[0] < 4 )); then
    fail "bash ${BASH_VERSION} is too old for lib/yml.sh (mapfile, sequential local): run with bash 4+"
    echo
    echo "=== ${PASS} passed, ${FAIL} failed ==="
    exit 1
fi

# ── run the real functions against a fake home and a fake php ─
TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

APP="demoapp"
mkdir -p "${TMP}/home/${APP}/current" "${TMP}/bin"
touch "${TMP}/home/${APP}/current/artisan"
cat > "${TMP}/bin/php8.5" <<'PHP'
#!/bin/bash
echo "php-called: $*"
[[ "${2:-}" == "fail" ]] && exit 7
exit 0
PHP
chmod +x "${TMP}/bin/php8.5"

{
    sed -n '/^_yml_post_deploy_workdir() {/,/^}/p' "${LIB}/yml.sh"
    sed -n '/^_yml_post_deploy_is_custom() {/,/^}/p' "${LIB}/yml.sh"
    sed -n '/^_yml_post_deploy_exec() {/,/^}/p' "${LIB}/yml.sh"
    sed -n '/^_yml_post_deploy_run() {/,/^}/p' "${LIB}/yml.sh"
} | sed -e "s|/home/|${TMP}/home/|g" -e "s|/usr/bin/php|${TMP}/bin/php|g" > "${TMP}/funcs.sh"

grep -q '^_yml_post_deploy_exec() {' "${TMP}/funcs.sh" && grep -q '^_yml_post_deploy_run() {' "${TMP}/funcs.sh" \
    && pass "post-deploy functions extracted" || fail "could not extract the post-deploy functions"

STEPS='[]'
ON_FAIL='warn'
step() { :; }; warn() { :; }; error() { :; }
cipi_notify() { :; }
_yml_find_file() { echo "${TMP}/cipi.yml"; }
_yml_parse() { jq -n --argjson steps "$STEPS" --arg on "$ON_FAIL" '{ok: true, data: {deploy: {post: $steps, post_on_failure: $on}}}'; }

if command -v jq >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${TMP}/funcs.sh"

    out=$(_yml_post_deploy_exec self "$APP" 8.5 artisan optimize 2>&1)
    [[ "$out" == "php-called: artisan optimize" ]] \
        && pass "artisan step runs 'php8.5 artisan optimize'" || fail "artisan step ran: ${out}"

    out=$(_yml_post_deploy_exec self "$APP" 8.5 artisan reverb:restart 2>&1)
    [[ "$out" == "php-called: artisan reverb:restart" ]] \
        && pass "artisan step runs 'php8.5 artisan reverb:restart'" || fail "artisan step ran: ${out}"

    LOGF="${TMP}/deploy.log"
    STEPS='[{"run":"artisan","argv":["optimize"]},{"run":"artisan","argv":["reverb:restart"]}]'
    rc=0; summary=$(_yml_post_deploy_run "$APP" 8.5 "$LOGF" true self) || rc=$?
    [[ $rc -eq 0 && "$summary" == "2 step(s) OK" ]] \
        && pass "two artisan steps succeed (${summary})" || fail "two artisan steps: rc=${rc} summary=${summary}"
    ! grep -q 'No such file or directory' "$LOGF" \
        && pass "no 'No such file' in the deploy log" || fail "deploy log still has 'No such file'"

    : > "$LOGF"
    STEPS='[{"run":"artisan","argv":["fail"]}]'
    ON_FAIL='warn'
    rc=0; summary=$(_yml_post_deploy_run "$APP" 8.5 "$LOGF" true self) || rc=$?
    grep -q 'post-deploy FAILED (7): artisan fail' "$LOGF" \
        && pass "a failed step logs its real exit code" || fail "failed step log: $(grep FAILED "$LOGF")"
    [[ $rc -eq 1 && "$summary" == "1 of 1 failed (warn)" ]] \
        && pass "warn: returns 1 and says so" || fail "warn: rc=${rc} summary=${summary}"

    STEPS='[{"run":"artisan","argv":["fail"]},{"run":"artisan","argv":["optimize"]}]'
    ON_FAIL='abort'
    rc=0; summary=$(_yml_post_deploy_run "$APP" 8.5 "$LOGF" true self) || rc=$?
    [[ $rc -eq 7 && "$summary" == "1 of 2 failed (abort)" ]] \
        && pass "abort: stops at the failed step with its exit code" || fail "abort: rc=${rc} summary=${summary}"
else
    fail "jq is required to run the post-deploy checks"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
