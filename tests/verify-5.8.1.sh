#!/bin/bash
# Local regression checks for 5.8.1 — `cipi deploy` exits 0 after a successful
# deploy (the trailing `[[ … ]] && return` made it exit 1 since 5.2.3), and the
# post-deploy heading, steps and verdict reach the terminal instead of the
# captured summary.
# Run from repo root: bash tests/verify-5.8.1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "=== Cipi 5.8.1 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.1" ]] \
    && pass "version.md is 5.8.1" || fail "version.md is not 5.8.1"
grep -q '^## \[5.8.1\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.1 entry" || fail "CHANGELOG has no 5.8.1 entry"
for f in deploy.sh yml.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done

# ── 1. The exit code of a deploy that published ──────────────
echo "--- cipi deploy exit code"
! grep -q '\[\[ \$post_rc -ne 0 \]\] && return' "${LIB}/deploy.sh" \
    && pass "_deploy_run no longer ends on '[[ … ]] && return'" || fail "_deploy_run still ends on '[[ … ]] && return'"

# The real _deploy_run with every dependency stubbed: Deployer (sudo) succeeds
# unless a case says otherwise, the post-deploy steps are whatever the case
# sets, and the function runs under `set -e` as `cipi` runs it.
DEPFN="${TMP}/deploy-run.sh"
mkdir -p "${TMP}/home/demo/.deployer"; : > "${TMP}/home/demo/.deployer/deploy.php"
{
    echo 'app_get() { case "$2" in php) echo 8.4 ;; branch) echo main ;; *) echo "" ;; esac; }'
    echo 'info() { echo "[INFO] $*"; }; success() { echo "✓ $*"; }; warn() { echo "[WARN] $*"; }'
    echo 'error() { echo "[ERROR] $*" >&2; }; step() { echo "→ $*"; }'
    echo 'log_action() { :; }; cipi_notify() { :; }; _deploy_release_details() { :; }'
    echo "deploy_log_file() { echo '${TMP}/deploy.log'; }"
    echo 'deploy_log_open() { :; }; deploy_log_close() { :; }; deploy_log_tee() { cat; }'
    echo 'deploy_current_release() { echo 4; }'
    echo '_deploy_assert_php_compat() { :; }; ensure_app_logs_permissions() { :; }'
    echo '_deploy_predeploy_snapshot() { return 0; }; _deploy_apply_yml() { :; }'
    echo '_deploy_health_check() { echo ok; }'
    echo 'sudo() { echo "Successfully deployed!"; }'
    extract deploy.sh _deploy_run | sed "s|\"/home/|\"${TMP}/home/|"
} > "$DEPFN"

out=$(bash -c "set -euo pipefail; source '$DEPFN'; _deploy_run_post_deploy() { echo 'none declared'; return 0; }; _deploy_run demo; echo rc=0" 2>&1)
[[ "$out" == *"Deploy completed"* && "$out" == *"rc=0"* ]] \
    && pass "a deploy with no post-deploy steps exits 0" || fail "deploy exit (no steps): ${out}"
out=$(bash -c "set -euo pipefail; source '$DEPFN'; _deploy_run_post_deploy() { echo '2 step(s) OK'; return 0; }; _deploy_run demo; echo rc=0" 2>&1)
[[ "$out" == *"rc=0"* && "$out" != *"Post-deploy steps failed"* ]] \
    && pass "a deploy whose post-deploy steps passed exits 0" || fail "deploy exit (steps ok): ${out}"
out=$(bash -c "set -euo pipefail; source '$DEPFN'; _deploy_run_post_deploy() { echo '1 of 2 failed (warn)'; return 1; }; _deploy_run demo || echo rc=\$?" 2>&1)
[[ "$out" == *"Deploy completed"* && "$out" == *"Post-deploy steps failed"* && "$out" == *"rc=1"* ]] \
    && pass "a failed post-deploy step still ends the deploy with its code" || fail "deploy exit (step failed): ${out}"
out=$(bash -c "set -euo pipefail; source '$DEPFN'; sudo() { echo boom; return 3; }; _deploy_run demo || echo rc=\$?" 2>&1)
[[ "$out" == *"Deploy failed (exit 3)"* && "$out" == *"rc=3"* ]] \
    && pass "a failed Deployer run still ends with its code" || fail "deploy exit (deployer failed): ${out}"

# ── 2. _deploy_run_post_deploy: summary on stdout, the rest on stderr ──
echo "--- post-deploy output"
PDFN="${TMP}/post-deploy.sh"
{
    echo 'app_get() { echo 8.4; }; success() { echo "✓ $*"; }; step() { echo "→ $*"; }; error() { echo "[ERROR] $*" >&2; }'
    echo "deploy_log_file() { echo '${TMP}/deploy.log'; }; chown() { :; }"
    extract deploy.sh _deploy_run_post_deploy
} > "$PDFN"
out=$(bash -c "source '$PDFN'; _yml_post_deploy_run() { echo 'none declared'; }; _deploy_run_post_deploy demo" 2>"${TMP}/pd.err")
[[ "$out" == "none declared" ]] && pass "stdout carries the summary only" || fail "post-deploy stdout: ${out}"
grep -q 'Post-deploy steps (cipi.yml)' "${TMP}/pd.err" && grep -q '✓ Post-deploy: none declared' "${TMP}/pd.err" \
    && pass "the heading and the verdict go to stderr" || fail "post-deploy stderr: $(cat "${TMP}/pd.err")"
out=$(bash -c "source '$PDFN'; _yml_post_deploy_run() { echo '1 of 2 failed (warn)'; return 1; }; _deploy_run_post_deploy demo || echo \" rc=\$?\"" 2>"${TMP}/pd.err")
[[ "$out" == "1 of 2 failed (warn) rc=1" ]] && grep -q '\[ERROR\] Post-deploy: 1 of 2 failed (warn)' "${TMP}/pd.err" \
    && pass "a failed step keeps its code and the verdict is an error on stderr" || fail "post-deploy failure: ${out} / $(cat "${TMP}/pd.err")"

# ── 3. _yml_post_deploy_run: steps on stderr, summary on stdout ──
echo "--- post-deploy runner"
if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then
    YMLFN="${TMP}/yml-run.sh"
    {
        echo 'step() { echo "→ $*"; }; error() { echo "[ERROR] $*" >&2; }; cipi_notify() { :; }'
        echo '_yml_find_file() { echo cipi.yml; }'
        echo '_yml_parse() { echo "{\"ok\":true,\"data\":{\"deploy\":{\"post\":[{\"run\":\"php\",\"argv\":[\"artisan\",\"queue:restart\"]},{\"run\":\"php\",\"argv\":[\"-v\"]}]}}}"; }'
        extract yml.sh _yml_post_deploy_run
    } > "$YMLFN"
    out=$(bash -c "source '$YMLFN'; _yml_post_deploy_exec() { :; }; _yml_post_deploy_run demo 8.4 '${TMP}/run.log' false" 2>"${TMP}/yml.err")
    [[ "$out" == "2 step(s) OK" ]] && pass "runner stdout is the summary line" || fail "runner stdout: ${out}"
    grep -q 'Post-deploy \[1/2\]: php artisan queue:restart' "${TMP}/yml.err" \
        && pass "runner steps go to stderr" || fail "runner stderr: $(cat "${TMP}/yml.err")"
    grep -q 'post-deploy OK: php -v' "${TMP}/run.log" && ! grep -q 'post-deploy OK' "${TMP}/yml.err" \
        && pass "the log lines go to the deploy log only" || fail "runner log: $(cat "${TMP}/run.log")"
    out=$(bash -c "source '$YMLFN'; _yml_post_deploy_exec() { [[ \"\$5\" == '-v' ]] || return 7; }; _yml_post_deploy_run demo 8.4 '${TMP}/run.log' true; echo \" rc=\$?\"" 2>"${TMP}/yml.err")
    [[ "$out" == "1 of 2 failed (warn) rc=1" ]] && pass "a failed step in quiet mode: summary and rc=1" || fail "runner failure: ${out}"
else
    echo "  skip: runner checks need bash 4+ (found ${BASH_VERSION})"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
