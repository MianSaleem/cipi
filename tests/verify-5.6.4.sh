#!/bin/bash
# Local regression checks for 5.6.4 — cipi.yml auto-apply on webhook deploys,
# the sudoers rule kept in step with yml_auto, and the JSON outputs and
# sudoers entries the panel API (cipi/api 1.35.0) relies on.
#
# The functions under test are extracted from their files and run against
# stubs and a temporary sudoers directory, so nothing outside ${TMP} is
# touched and bash 3.2 (macOS) is enough.
# Run from repo root: bash tests/verify-5.6.4.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cipi-verify-564.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# The text of one top-level function of a file ("name() {" … "}").
fn() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

echo "=== Cipi 5.6.4 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.6.4" ]] \
    && pass "version.md is 5.6.4" || fail "version.md is not 5.6.4"
grep -q '^## \[5.6.4\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.6.4 entry" || fail "CHANGELOG has no 5.6.4 entry"
for f in "${LIB}/yml.sh" "${LIB}/cipi-app-deploy.sh" "${LIB}/sync.sh" "${LIB}/app.sh" "${LIB}/common.sh" \
         "${LIB}/cipi-api-sudoers.sh" "${LIB}/completion.sh" "${LIB}/migrations/5.6.4.sh" "${ROOT}/cipi"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") does not parse"
done

# ── 1. webhook wrapper ───────────────────────────────────────
echo "-- webhook deploy (cipi-app-deploy)"
WRAP="${LIB}/cipi-app-deploy.sh"
grep -q 'test -f "/etc/sudoers.d\|\[\[ -f "/etc/sudoers.d' "$WRAP" \
    && fail "wrapper still looks into /etc/sudoers.d (0750: invisible to the app user)" \
    || pass "wrapper no longer looks into /etc/sudoers.d"
grep -q 'sudo -n -l /usr/local/bin/cipi yml apply "$APP" --yes --auto' "$WRAP" \
    && grep -q 'sudo -n /usr/local/bin/cipi yml apply "$APP" --yes --auto' "$WRAP" \
    && pass "wrapper probes with sudo -n -l and applies with sudo -n" || fail "wrapper probe/apply"
# The probe must ask for exactly the command line the rule allows.
grep -q 'NOPASSWD: /usr/local/bin/cipi yml apply ${app} --yes --auto$' "${LIB}/yml.sh" \
    && pass "probe and sudoers rule name the same command line" || fail "rule and probe differ"

block=$(awk '/^YML_LINE=""$/ {on=1} /^# Allowlisted post-deploy steps/ {exit} on {print}' "$WRAP")
[[ -n "$block" ]] && pass "cipi.yml block extracted" || fail "cipi.yml block not found"
cat > "${TMP}/wrap.sh" <<'EOS'
APP=shop LOG="$1" PROBE="$2" CALLS="$3"
sudo() {
    echo "$*" >> "$CALLS"
    if [[ "$1 $2" == "-n -l" ]]; then return "$PROBE"; fi
    echo "cipi.yml-result: applied=2"
}
EOS
printf '%s\n%s\n' "$block" 'echo "LINE=${YML_LINE}"' >> "${TMP}/wrap.sh"

: > "${TMP}/log"; : > "${TMP}/calls"
out=$(bash "${TMP}/wrap.sh" "${TMP}/log" 0 "${TMP}/calls" 2>/dev/null)
[[ "$out" == *"LINE=applied 2 change(s)"* ]] \
    && pass "auto-apply on: the webhook deploy applies cipi.yml" || fail "auto-apply on: ${out}"
grep -qx -- '-n -l /usr/local/bin/cipi yml apply shop --yes --auto' "${TMP}/calls" \
    && grep -qx -- '-n /usr/local/bin/cipi yml apply shop --yes --auto' "${TMP}/calls" \
    && pass "probe and apply run the allowed command line" || fail "sudo calls: $(cat "${TMP}/calls")"

: > "${TMP}/log"; : > "${TMP}/calls"
out=$(bash "${TMP}/wrap.sh" "${TMP}/log" 1 "${TMP}/calls" 2>/dev/null)
[[ "$out" == "LINE=" && "$(wc -l < "${TMP}/calls" | tr -d ' ')" == "1" ]] \
    && pass "auto-apply off: nothing applied, nothing logged" || fail "auto-apply off: ${out} / $(cat "${TMP}/calls")"
grep -q 'cipi.yml apply' "${TMP}/log" && fail "auto-apply off still logs a cipi.yml step" \
    || pass "auto-apply off leaves the deploy log alone"

# ── 2. the rule follows yml_auto ─────────────────────────────
echo "-- yml_auto_sudoers_sync"
mkdir -p "${TMP}/sudoers.d"
{
    echo 'app_get() { [[ "$2" == yml_auto ]] && cat "${TMP}/flag-$1" 2>/dev/null; return 0; }'
    echo 'visudo() { return "${VISUDO_RC:-0}"; }'
    fn "${LIB}/yml.sh" yml_auto_sudoers_sync | sed "s#/etc/sudoers.d/#${TMP}/sudoers.d/#g"
} > "${TMP}/sync.sh"
run_sync() { ( export TMP VISUDO_RC="${2:-0}"; source "${TMP}/sync.sh"; yml_auto_sudoers_sync "$1" ); }

echo true > "${TMP}/flag-shop"
run_sync shop && [[ -f "${TMP}/sudoers.d/cipi-shop-yml" ]] \
    && pass "auto on: rule written" || fail "auto on: rule missing"
grep -qx 'shop ALL=(root) NOPASSWD: /usr/local/bin/cipi yml apply shop --yes --auto' "${TMP}/sudoers.d/cipi-shop-yml" \
    && grep -qx 'shop ALL=(root) NOPASSWD: /usr/local/bin/cipi yml node-sync shop \*' "${TMP}/sudoers.d/cipi-shop-yml" \
    && [[ "$(wc -l < "${TMP}/sudoers.d/cipi-shop-yml" | tr -d ' ')" == "2" ]] \
    && pass "rule allows exactly apply --auto and node-sync" || fail "rule content: $(cat "${TMP}/sudoers.d/cipi-shop-yml")"
mode=$(stat -f '%Lp' "${TMP}/sudoers.d/cipi-shop-yml" 2>/dev/null || stat -c '%a' "${TMP}/sudoers.d/cipi-shop-yml")
[[ "$mode" == "440" ]] && pass "rule is 0440" || fail "rule mode ${mode}"
if run_sync shop 1; then fail "a rule visudo rejects reports success"
else [[ ! -f "${TMP}/sudoers.d/cipi-shop-yml" ]] && pass "a rejected rule is removed and reported" || fail "rejected rule kept"; fi
run_sync shop
echo "" > "${TMP}/flag-shop"
run_sync shop && [[ ! -f "${TMP}/sudoers.d/cipi-shop-yml" ]] \
    && pass "auto off: rule removed" || fail "auto off: rule kept"

# ── 3. cipi yml auto ─────────────────────────────────────────
echo "-- cipi yml auto"
{
    fn "${LIB}/common.sh" parse_args
    cat <<'EOS'
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
info(){ :; }; warn(){ :; }; success(){ echo "OK $*"; }; error(){ echo "ERR $*" >&2; }; log_action(){ :; }
app_exists(){ [[ "$1" == shop ]]; }
app_get(){ case "$2" in yml_auto) cat "${TMP}/flag-$1" 2>/dev/null ;; runtime) echo laravel ;; esac; return 0; }
app_set(){ echo "$3" > "${TMP}/flag-$1"; }
app_unset(){ rm -f "${TMP}/flag-$1"; }
_yml_find_file(){ [[ -f "${TMP}/cipi.yml" ]] && { echo "${TMP}/cipi.yml"; return 0; }; return 1; }
visudo() { return "${VISUDO_RC:-0}"; }
EOS
    fn "${LIB}/yml.sh" yml_auto_sudoers_sync
    fn "${LIB}/yml.sh" _yml_env_label
    fn "${LIB}/yml.sh" _yml_auto_cmd
} | sed "s#/etc/sudoers.d/#${TMP}/sudoers.d/#g" > "${TMP}/auto.sh"
run_auto() { ( export TMP VISUDO_RC="${VISUDO_RC:-0}"; source "${TMP}/auto.sh"; _yml_auto_cmd "$@" ); }

rm -f "${TMP}/flag-shop" "${TMP}/cipi.yml" "${TMP}/sudoers.d/"*
o=$(run_auto shop status --json)
# 5.8.0 added env (production for an app without the key).
[[ "$(jq -c . <<< "$o")" == '{"app":"shop","env":"production","auto":false,"sudoers":false,"file":null}' ]] \
    && pass "status --json, auto off, no file" || fail "status --json: ${o}"
o=$(run_auto shop on) && [[ "$(cat "${TMP}/flag-shop")" == true && -f "${TMP}/sudoers.d/cipi-shop-yml" ]] \
    && pass "on: flag and rule" || fail "on: ${o}"
touch "${TMP}/cipi.yml"
o=$(run_auto shop --json)
[[ "$(jq -r '"\(.auto) \(.sudoers) \(.file)"' <<< "$o")" == "true true ${TMP}/cipi.yml" ]] \
    && pass "'cipi yml auto <app> --json' is the status" || fail "auto --json: ${o}"
rm -f "${TMP}/sudoers.d/cipi-shop-yml"
o=$(run_auto shop status)
[[ "$o" == *"sudoers rule missing"* ]] && pass "status warns when the rule is missing" || fail "status: ${o}"
run_auto shop on >/dev/null && [[ -f "${TMP}/sudoers.d/cipi-shop-yml" ]] \
    && pass "on again restores a missing rule" || fail "on again"
o=$(run_auto shop off) && [[ ! -f "${TMP}/flag-shop" && ! -f "${TMP}/sudoers.d/cipi-shop-yml" ]] \
    && pass "off: flag and rule gone" || fail "off: ${o}"
VISUDO_RC=1 run_auto shop on >/dev/null 2>&1 && fail "on with a rejected rule succeeds" \
    || { [[ ! -f "${TMP}/flag-shop" && ! -f "${TMP}/sudoers.d/cipi-shop-yml" ]] \
            && pass "on with a rejected rule leaves auto-apply off" || fail "rejected rule left state behind"; }
run_auto ghost status >/dev/null 2>&1 && fail "unknown app accepted" || pass "unknown app refused"

# ── 4. cipi yml plan --json ──────────────────────────────────
echo "-- cipi yml plan --json"
{
    cat <<'EOS'
error(){ echo "ERR $*" >&2; }
app_exists(){ [[ "$1" == shop ]]; }
app_get(){ [[ "$2" == yml_auto ]] && cat "${TMP}/flag-$1" 2>/dev/null; return 0; }
_yml_find_file(){ [[ -f "${TMP}/cipi.yml" ]] && { echo "${TMP}/cipi.yml"; return 0; }; return 1; }
_yml_parse(){ cat "${TMP}/parsed.json"; }
_yml_source_libs(){ echo "noise from a sourced lib"; }
_yml_build_plan(){
    echo "noise from the plan"
    _YML_ACTIONS=(); _YML_BLOCKERS=(); _YML_NOTES=()
    [[ -f "${TMP}/actions" ]] && while IFS= read -r l; do _YML_ACTIONS+=("$l"); done < "${TMP}/actions"
    [[ -f "${TMP}/blockers" ]] && while IFS= read -r l; do _YML_BLOCKERS+=("$l"); done < "${TMP}/blockers"
    return 0
}
EOS
    fn "${LIB}/yml.sh" _yml_file_arg_allowed
    fn "${LIB}/yml.sh" _yml_json_lines
    fn "${LIB}/yml.sh" _yml_plan_json
} > "${TMP}/plan.sh"
run_plan() { ( export TMP; source "${TMP}/plan.sh"; _yml_plan_json "$@" ); }

rm -f "${TMP}/cipi.yml" "${TMP}/actions" "${TMP}/blockers"
o=$(run_plan shop 2>/dev/null)
[[ "$(jq -c '[.file, .valid, .in_sync, .auto, .changes]' <<< "$o" 2>/dev/null)" == '[null,null,null,false,[]]' ]] \
    && pass "no file: file, valid and in_sync are null" || fail "no file: ${o}"

touch "${TMP}/cipi.yml"; echo true > "${TMP}/flag-shop"
echo '{"ok":false,"errors":["line 3: unknown key '"'"'foo'"'"'"],"warnings":["w1"]}' > "${TMP}/parsed.json"
o=$(run_plan shop 2>/dev/null)
[[ "$(jq -c '[.valid, .in_sync, .errors, .warnings, .auto]' <<< "$o" 2>/dev/null)" == "[false,null,[\"line 3: unknown key 'foo'\"],[\"w1\"],true]" ]] \
    && pass "invalid file: valid false with the parser errors" || fail "invalid: ${o}"

echo '{"ok":true,"data":{},"warnings":[]}' > "${TMP}/parsed.json"
printf 'php|8.4|PHP 8.3 → 8.4\nalias-add|www.shop.test|add alias www.shop.test\n' > "${TMP}/actions"
echo 'PHP 8.5 is not installed — run: cipi php install 8.5' > "${TMP}/blockers"
o=$(run_plan shop 2>/dev/null)
jq -e . <<< "$o" >/dev/null 2>&1 && pass "plan noise stays off stdout: the output is one JSON document" || fail "not JSON: ${o}"
[[ "$(jq -c '.changes' <<< "$o" 2>/dev/null)" == '[{"kind":"php","summary":"PHP 8.3 → 8.4"},{"kind":"alias-add","summary":"add alias www.shop.test"}]' ]] \
    && pass "changes carry kind and summary" || fail "changes: ${o}"
[[ "$(jq -c '[.valid, .in_sync, .blockers]' <<< "$o" 2>/dev/null)" == '[true,false,["PHP 8.5 is not installed — run: cipi php install 8.5"]]' ]] \
    && pass "blockers listed, not in sync" || fail "blockers: ${o}"
rm -f "${TMP}/actions" "${TMP}/blockers"
o=$(run_plan shop 2>/dev/null)
[[ "$(jq -c '[.in_sync, .changes, .blockers, .notes]' <<< "$o" 2>/dev/null)" == '[true,[],[],[]]' ]] \
    && pass "nothing to do: in_sync true, empty lists" || fail "in sync: ${o}"
run_plan ghost >/dev/null 2>&1 && fail "plan --json accepts an unknown app" || pass "plan --json refuses an unknown app"

o=$( ( export TMP SUDO_USER=www-data ARG_file=/etc/shadow; source "${TMP}/plan.sh"; _yml_plan_json shop ) 2>&1 ); r=$?
[[ $r -ne 0 && "$o" == *"--file is not available"* ]] \
    && pass "--file refused for www-data" || fail "--file for www-data (exit ${r}: ${o})"
o=$( ( export TMP SUDO_USER=cipi ARG_file="${TMP}/cipi.yml"; source "${TMP}/plan.sh"; _yml_plan_json shop ) 2>/dev/null ); r=$?
[[ $r -eq 0 && "$(jq -r .file <<< "$o")" == "${TMP}/cipi.yml" ]] \
    && pass "--file still works for an admin" || fail "--file for cipi (exit ${r}: ${o})"
grep -A3 '^_yml_resolve() {' "${LIB}/yml.sh" | grep -q '_yml_file_arg_allowed' \
    && pass "plan, apply and validate share the --file guard" || fail "_yml_resolve has no --file guard"

# ── 5. other paths keep flag and rule together ───────────────
echo "-- delete, orphan purge, sync"
grep -q 'rm -f "/etc/sudoers.d/cipi-${app}" "/etc/sudoers.d/cipi-${app}-yml"' "${LIB}/app.sh" \
    && pass "app delete removes the cipi.yml rule" || fail "app delete leaves the cipi.yml rule"
grep -q 'rm -f "/etc/sudoers.d/cipi-${u}" "/etc/sudoers.d/cipi-${u}-yml"' "${LIB}/common.sh" \
    && pass "orphan purge removes the cipi.yml rule" || fail "orphan purge leaves the cipi.yml rule"
[[ "$(grep -c '^    _sync_yml_auto_sudoers "$app"$' "${LIB}/sync.sh")" == "2" ]] \
    && pass "sync import and sync update write the rule" || fail "sync paths"
fn "${LIB}/sync.sh" _sync_yml_auto_sudoers | grep -q 'yml_auto_sudoers_sync "$app"' \
    && pass "sync goes through yml_auto_sudoers_sync" || fail "sync helper"

# ── 6. panel API sudoers ─────────────────────────────────────
echo "-- panel API sudoers"
SUD="${LIB}/cipi-api-sudoers.sh"
for c in 'yml plan \*' 'yml apply \*' 'yml auto \*'; do
    grep -q "/usr/local/bin/cipi ${c}, \\\\$" "$SUD" && pass "API sudoers: cipi ${c//\\/}" || fail "API sudoers lacks cipi ${c//\\/}"
done
[[ "$(grep -c '/usr/local/bin/cipi yml ' "$SUD")" == "3" ]] \
    && pass "no other yml command for www-data (generate, post-deploy, node-sync stay root/app-only)" || fail "extra yml entries"

# ── 7. migration ─────────────────────────────────────────────
echo "-- migration 5.6.4"
M="${TMP}/m"
mkdir -p "${M}/lib/migrations" "${M}/bin" "${M}/sudoers.d" "${M}/conf"
cp "${WRAP}" "${M}/lib/cipi-app-deploy.sh"
cat > "${M}/lib/common.sh" <<'EOS'
vault_read() { [[ -n "${VAULT_FAIL:-}" ]] && return 1; cat "${CIPI_CONFIG}/$1"; }
app_get() { vault_read apps.json | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }
EOS
fn "${LIB}/yml.sh" yml_auto_sudoers_sync > "${M}/lib/yml.sh"
cp "$SUD" "${M}/lib/cipi-api-sudoers.sh"
sed -i.bak "s#/etc/sudoers.d/#${M}/sudoers.d/#g" "${M}/lib/yml.sh" "${M}/lib/cipi-api-sudoers.sh"
sed -e "s#/etc/sudoers.d/#${M}/sudoers.d/#g" -e "s#/usr/local/bin/cipi-app-deploy#${M}/bin/cipi-app-deploy#g" \
    -e 's#^set -euo pipefail$#set -euo pipefail\nid() { [[ "$1" == shop || "$1" == blog ]]; }\nvisudo() { return 0; }\nchown() { :; }#' \
    "${LIB}/migrations/5.6.4.sh" > "${M}/lib/migrations/5.6.4.sh"
echo '{"shop":{"yml_auto":"true"},"blog":{"domain":"blog.test"}}' > "${M}/conf/apps.json"
reset_rules() { rm -f "${M}/sudoers.d/"*; touch "${M}/sudoers.d/cipi-blog-yml" "${M}/sudoers.d/cipi-ghost-yml" "${M}/sudoers.d/cipi-blog"; }
run_mig() { CIPI_LIB="${M}/lib" CIPI_CONFIG="${M}/conf" CIPI_LOG="${M}" bash "${M}/lib/migrations/5.6.4.sh" 2>&1; }

reset_rules
o=$(run_mig); r=$?
[[ $r -eq 0 ]] && pass "migration runs" || fail "migration exit ${r}: ${o}"
[[ -x "${M}/bin/cipi-app-deploy" ]] && pass "migration installs the fixed wrapper" || fail "wrapper not installed"
grep -q '/usr/local/bin/cipi yml auto \*' "${M}/sudoers.d/cipi-api" && pass "migration rewrites the API sudoers" || fail "API sudoers not written"
[[ -f "${M}/sudoers.d/cipi-shop-yml" ]] && pass "auto on, rule missing → written" || fail "shop rule not restored: ${o}"
[[ ! -f "${M}/sudoers.d/cipi-blog-yml" ]] && pass "auto off, rule present → removed" || fail "blog rule kept"
[[ ! -f "${M}/sudoers.d/cipi-ghost-yml" ]] && pass "rule of a deleted app → removed" || fail "ghost rule kept"
[[ -f "${M}/sudoers.d/cipi-blog" ]] && pass "the app's main sudoers file is left alone" || fail "cipi-blog removed"
ls "${M}/sudoers.d" | grep -q '\.' && fail "temporary rule files left behind" || pass "no temporary rule files left behind"
# write_cipi_api_sudoers rewrites its 0440 file in place, which root may do and this run may not.
chmod u+w "${M}/sudoers.d/cipi-api"
o=$(run_mig); r=$?
[[ $r -eq 0 && "$o" != *"restored"* && "$o" != *"removed"* && "$o" != *"denied"* ]] && pass "migration is idempotent" || fail "second run: ${o}"

reset_rules
o=$(VAULT_FAIL=1 run_mig); r=$?
[[ $r -eq 0 && -f "${M}/sudoers.d/cipi-blog-yml" && -f "${M}/sudoers.d/cipi-ghost-yml" && "$o" == *"could not be read"* ]] \
    && pass "unreadable apps.json: no rule is removed" || fail "unreadable apps.json (exit ${r}): ${o}"

# ── 8. help, completion, docs ────────────────────────────────
echo "-- help and docs"
grep -q 'cipi yml plan <app> \[--json\]' "${ROOT}/cipi" && grep -q 'cipi yml auto <app> status --json' "${ROOT}/cipi" \
    && pass "help documents --json" || fail "help"
grep -q 'plan|diff) sub="--json"' "${LIB}/completion.sh" && pass "completion offers --json" || fail "completion"
grep -q 'GET /api/apps/{name}/yml' "${ROOT}/README.md" && grep -q 'yml-manage' "${ROOT}/README.md" \
    && pass "README documents the API endpoints" || fail "README"
grep -q '0750 root:root' "${ROOT}/CHANGELOG.md" && grep -q 'lib/migrations/5.6.4.sh' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG explains the fix and the migration" || fail "CHANGELOG content"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
