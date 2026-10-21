#!/bin/bash
# Local regression checks for 5.6.3 — PHP security release of 2026-10-21
# (CVE-2026-109618, CVE-2026-109619): every Cipi FPM pool carries the
# advisory's mitigations, `cipi php upgrade` runs daily and reports each
# version's patch level, and Octane apps report the PHP inside FrankenPHP.
# Run from repo root: bash tests/verify-5.6.3.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.6.3 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.6.3" ]] \
    && pass "version.md is 5.6.3" || fail "version.md is not 5.6.3"
grep -q '^## \[5.6.3\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.6.3 entry" || fail "CHANGELOG has no 5.6.3 entry"
for f in common.sh php.sh php-apt.sh app.sh api.sh gui.sh node.sh migrations/5.6.3.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"

# ── every pool generator carries the hardening ───────────────
for spec in "app.sh:1" "api.sh:1" "gui.sh:1" "node.sh:1" "php.sh:2"; do
    f="${spec%%:*}"; want="${spec##*:}"
    n=$(grep -c '^\$(fpm_pool_hardening "\$v")$' "${LIB}/${f}" || true)
    [[ "$n" == "$want" ]] && pass "${f}: ${want} pool(s) emit fpm_pool_hardening" \
        || fail "${f}: ${n:-0} pool(s) emit fpm_pool_hardening, expected ${want}"
done

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

{
    extract common.sh version_at_least
    extract common.sh php_security_floor
    extract common.sh php_security_state
    extract common.sh fpm_pool_hardening
} > "${TMP}/common-funcs.sh"
# shellcheck source=/dev/null
source "${TMP}/common-funcs.sh"

# ── version_at_least ─────────────────────────────────────────
ok=true
version_at_least 8.5.12 8.5.12 || ok=false
version_at_least 8.5.13 8.5.12 || ok=false
version_at_least 8.5.100 8.5.12 || ok=false
version_at_least 8.5 8.5 || ok=false
version_at_least 8.10 8.5 || ok=false
version_at_least 8.5.11 8.5.12 && ok=false
version_at_least 8.4 8.5 && ok=false
version_at_least "" 8.5 && ok=false
[[ "$ok" == true ]] && pass "version_at_least orders dotted versions numerically" \
    || fail "version_at_least got a comparison wrong"

# ── fpm_pool_hardening ───────────────────────────────────────
h84=$(fpm_pool_hardening 8.4)
h85=$(fpm_pool_hardening 8.5)
[[ "$h84" == "php_admin_flag[session.upload_progress.enabled] = off" ]] \
    && pass "8.4 pool: upload progress off, no fatal_error_backtraces" \
    || fail "8.4 pool hardening is wrong: ${h84}"
[[ "$h85" == $'php_admin_flag[session.upload_progress.enabled] = off\nphp_admin_flag[fatal_error_backtraces] = off' ]] \
    && pass "8.5 pool: upload progress off and fatal_error_backtraces off" \
    || fail "8.5 pool hardening is wrong: ${h85}"
fpm_pool_hardening 8.3 >/dev/null && pass "fpm_pool_hardening returns 0 below 8.5" \
    || fail "fpm_pool_hardening returns non-zero below 8.5 (would trip set -e)"

# ── php_security_floor / php_security_state ──────────────────
[[ "$(php_security_floor 8.2)$(php_security_floor 8.3)$(php_security_floor 8.4)$(php_security_floor 8.5)" == "8.2.358.3.368.4.278.5.12" ]] \
    && pass "security floor matches the 2026-10-21 releases" || fail "security floor is wrong"
[[ -z "$(php_security_floor 8.1)" && -z "$(php_security_floor 7.4)" ]] \
    && pass "no floor for 8.1 and older" || fail "8.1 or older has a floor"

mkdir -p "${TMP}/bin"
# php8.X prints FAKE_PHP_<X>; dpkg-query prints FAKE_PKG_<X>.
for v in 8.1 8.3 8.4 8.5; do
    k="${v/./}"
    cat > "${TMP}/bin/php${v}" <<EOF
#!/bin/bash
printf '%s' "\${FAKE_PHP_${k}:-}"
EOF
    chmod +x "${TMP}/bin/php${v}"
done
cat > "${TMP}/bin/dpkg-query" <<'EOF'
#!/bin/bash
pkg="${*: -1}"; v="${pkg#php}"; v="${v%-fpm}"; k="${v/./}"
var="FAKE_PKG_${k}"
printf '%s' "${!var:-}"
EOF
chmod +x "${TMP}/bin/dpkg-query"
OLDPATH="$PATH"
export PATH="${TMP}/bin:${PATH}"

export FAKE_PHP_85=8.5.12 FAKE_PKG_85="8.5.12-1+ubuntu24.04.1+deb.sury.org+1"
[[ "$(php_security_state 8.5)" == "patched 8.5.12" ]] && pass "8.5.12 is patched" \
    || fail "8.5.12: $(php_security_state 8.5)"
export FAKE_PHP_85=8.5.11 FAKE_PKG_85="8.5.11-1+ubuntu24.04.1+deb.sury.org+1"
[[ "$(php_security_state 8.5)" == "vulnerable 8.5.11" ]] && pass "8.5.11 from sury is vulnerable" \
    || fail "8.5.11: $(php_security_state 8.5)"
export FAKE_PHP_85=8.5.11 FAKE_PKG_85="8.5.11-1+0~20260924.25+ubuntu24.04~1.gbp1a3e8a"
[[ "$(php_security_state 8.5)" == "vulnerable 8.5.11" ]] && pass "8.5.11 from packages.sury.org is vulnerable, not distro" \
    || fail "8.5.11 sury.org: $(php_security_state 8.5)"
export FAKE_PHP_85=8.5.11 FAKE_PKG_85="8.5.11-1+ubuntu24.04.1+deb.sury.org+1"
[[ "$(php_security_state 8.5)" == "vulnerable 8.5.11" ]] && pass "8.5.11 from the ondrej PPA is vulnerable" \
    || fail "8.5.11 ondrej: $(php_security_state 8.5)"
export FAKE_PHP_83=8.3.6 FAKE_PKG_83="8.3.6-0ubuntu0.24.04.9"
[[ "$(php_security_state 8.3)" == "distro 8.3.6" ]] && pass "Ubuntu archive 8.3.6 is reported as distro, not vulnerable" \
    || fail "8.3.6 archive: $(php_security_state 8.3)"
export FAKE_PHP_84=8.4.30 FAKE_PKG_84="8.4.30-1+ubuntu24.04.1+deb.sury.org+1"
[[ "$(php_security_state 8.4)" == "patched 8.4.30" ]] && pass "8.4.30 is patched" \
    || fail "8.4.30: $(php_security_state 8.4)"
export FAKE_PHP_81=8.1.34
[[ "$(php_security_state 8.1)" == "eol 8.1.34" ]] && pass "8.1 is end of life" \
    || fail "8.1: $(php_security_state 8.1)"
[[ "$(php_security_state 8.2)" == "unknown -" ]] && pass "missing CLI is unknown" \
    || fail "missing php8.2: $(php_security_state 8.2)"

# ── _create_fpm_pool writes the hardening ────────────────────
mkdir -p "${TMP}/etc/php/8.5/fpm/pool.d" "${TMP}/etc/php/8.4/fpm/pool.d"
extract app.sh _fpm_pool_flag_keys > "${TMP}/pool-funcs.sh"
extract app.sh _create_fpm_pool | sed "s|/etc/php/|${TMP}/etc/php/|g" >> "${TMP}/pool-funcs.sh"
vault_read() { echo '{"demo":{"ini":{"max_input_vars":"5000"}}}'; }
_app_limit() { echo 5; }
# shellcheck source=/dev/null
source "${TMP}/pool-funcs.sh"
_create_fpm_pool demo 8.5 && _create_fpm_pool demo 8.4
p85="${TMP}/etc/php/8.5/fpm/pool.d/demo.conf"
p84="${TMP}/etc/php/8.4/fpm/pool.d/demo.conf"
grep -qxF 'php_admin_flag[session.upload_progress.enabled] = off' "$p85" \
    && grep -qxF 'php_admin_flag[fatal_error_backtraces] = off' "$p85" \
    && pass "app pool on 8.5 carries both lines" || fail "app pool on 8.5 misses a hardening line"
grep -qxF 'php_admin_flag[session.upload_progress.enabled] = off' "$p84" \
    && ! grep -q 'fatal_error_backtraces' "$p84" \
    && pass "app pool on 8.4 carries upload progress only" || fail "app pool on 8.4 is wrong"
grep -qxF 'php_admin_value[max_input_vars] = 5000' "$p85" \
    && [[ "$(tail -1 "$p85")" == 'php_admin_value[max_input_vars] = 5000' ]] \
    && pass "per-app overrides still follow the pool body" || fail "per-app overrides lost or misplaced"
[[ "$(head -1 "$p85")" == "[demo]" ]] && pass "pool starts with its section" || fail "pool header broken"

# ── cron: weekly → daily ─────────────────────────────────────
CRONFILE="${TMP}/crontab"
crontab() { if [[ "${1:-}" == "-l" ]]; then cat "$CRONFILE"; else cat > "$CRONFILE"; fi; }
extract php.sh _php_setup_upgrade_cron | grep -v 'EUID' > "${TMP}/cron-funcs.sh"
# shellcheck source=/dev/null
source "${TMP}/cron-funcs.sh"
cat > "$CRONFILE" <<'EOF'
# === CIPI CRON JOBS ===
50 3 * * * /usr/local/bin/cipi-cron-notify self-update /usr/local/bin/cipi self-update >> /var/log/cipi/cipi.log 2>&1
# PHP security patch check (Sunday 3:30 AM)
30 3 * * 0 /usr/local/bin/cipi-cron-notify php-upgrade /usr/local/bin/cipi php upgrade >> /var/log/cipi/php-upgrade.log 2>&1
0 5 * * 0 apt-get clean && apt-get autoclean >> /var/log/cipi/updates.log 2>&1
EOF
_php_setup_upgrade_cron
grep -qxF '30 3 * * * /usr/local/bin/cipi-cron-notify php-upgrade /usr/local/bin/cipi php upgrade >> /var/log/cipi/php-upgrade.log 2>&1' "$CRONFILE" \
    && grep -qxF '# PHP security patch check (daily 3:30 AM)' "$CRONFILE" \
    && pass "weekly PHP upgrade line becomes daily" || fail "weekly line not converted: $(cat "$CRONFILE")"
grep -qF '0 5 * * 0 apt-get clean' "$CRONFILE" && [[ "$(wc -l < "$CRONFILE" | tr -d ' ')" == "5" ]] \
    && pass "other cron lines untouched" || fail "other cron lines changed"
_php_setup_upgrade_cron
[[ "$(grep -c 'cipi php upgrade' "$CRONFILE")" == "1" ]] && pass "second run is a no-op" || fail "second run duplicated the line"
printf '# === CIPI CRON JOBS ===\n15 2 * * 3 /usr/local/bin/cipi php upgrade\n' > "$CRONFILE"
_php_setup_upgrade_cron
grep -qxF '15 2 * * 3 /usr/local/bin/cipi php upgrade' "$CRONFILE" && pass "hand-edited schedule left alone" \
    || fail "hand-edited schedule rewritten"
printf '# === CIPI CRON JOBS ===\n' > "$CRONFILE"
_php_setup_upgrade_cron
grep -q '^30 3 \* \* \* .*cipi php upgrade' "$CRONFILE" && pass "missing line is added daily" || fail "missing line not added"
grep -q '^30 3 \* \* \* /usr/local/bin/cipi-cron-notify php-upgrade' "${ROOT}/setup.sh" \
    && ! grep -q '^30 3 \* \* 0 .*php upgrade' "${ROOT}/setup.sh" \
    && pass "setup.sh installs the daily line" || fail "setup.sh still installs the weekly line"

# ── security report ──────────────────────────────────────────
GREEN=""; RED=""; YELLOW=""; NC=""
{
    extract php.sh _php_branch_eol
    extract php.sh _php_security_report
} > "${TMP}/report-funcs.sh"
# shellcheck source=/dev/null
source "${TMP}/report-funcs.sh"
INSTALLED="8.5"
php_is_installed() { [[ " ${INSTALLED} " == *" $1 "* ]]; }
export FAKE_PHP_85=8.5.12 FAKE_PKG_85="8.5.12-1+deb.sury.org+1"
out=$(_php_security_report); rc=$?
[[ $rc -eq 0 && "$out" == *"8.5.12"*"patched"* ]] && pass "report: patched server returns 0" || fail "report on patched: rc=${rc} ${out}"
export FAKE_PHP_85=8.5.11 FAKE_PKG_85="8.5.11-1+deb.sury.org+1"
out=$(_php_security_report); rc=$?
[[ $rc -eq 1 && "$out" == *"VULNERABLE"*"8.5.12"* ]] && pass "report: vulnerable server returns 1 and names the fix" || fail "report on vulnerable: rc=${rc} ${out}"
INSTALLED="8.1"
out=$(_php_security_report); rc=$?
[[ $rc -eq 0 && "$out" == *"END OF LIFE"* ]] && pass "report: EOL branch warns without failing the cron" || fail "report on 8.1: rc=${rc} ${out}"

# ── FrankenPHP report ────────────────────────────────────────
APPDIR="${TMP}/home/octo/current"
mkdir -p "$APPDIR"
cat > "${APPDIR}/frankenphp" <<'EOF'
#!/bin/bash
echo "FrankenPHP v1.9.1 PHP ${FAKE_FPHP} Caddy v2.10.2 h1:abc"
EOF
chmod +x "${APPDIR}/frankenphp"
extract php.sh _php_frankenphp_report | sed "s|/home/|${TMP}/home/|g" > "${TMP}/fphp-funcs.sh"
# shellcheck source=/dev/null
source "${TMP}/fphp-funcs.sh"
CIPI_CONFIG="${TMP}/cfg"; mkdir -p "$CIPI_CONFIG"; touch "${CIPI_CONFIG}/apps.json"
vault_read() { echo '{"octo":{"octane":"frankenphp"},"plain":{"php":"8.5"}}'; }
id() { return 0; }
runuser() { echo "$2" > "${TMP}/runuser-as"; shift 3; "$@"; }
timeout() { shift; "$@"; }
export FAKE_FPHP=8.4.26
out=$(_php_frankenphp_report); rc=$?
[[ $rc -eq 1 && "$out" == *"octo"*"8.4.26"*"VULNERABLE"*"8.4.27"* && "$out" != *"plain"* ]] \
    && pass "FrankenPHP on 8.4.26 is vulnerable; non-Octane apps skipped" || fail "FrankenPHP vulnerable: rc=${rc} ${out}"
[[ "$(cat "${TMP}/runuser-as" 2>/dev/null)" == "octo" ]] && pass "binary runs as the app user" || fail "binary did not run as the app user"
export FAKE_FPHP=8.5.12
out=$(_php_frankenphp_report); rc=$?
[[ $rc -eq 0 && "$out" == *"8.5.12"*"patched"* ]] && pass "FrankenPHP on 8.5.12 is patched" || fail "FrankenPHP patched: rc=${rc} ${out}"
rm -f "${APPDIR}/frankenphp"
out=$(_php_frankenphp_report); rc=$?
[[ $rc -eq 0 && "$out" == *"no FrankenPHP binary"* ]] && pass "missing binary is reported, not failed" || fail "missing binary: rc=${rc} ${out}"
grep -q 'runuser -u "\$app" --' "${LIB}/php.sh" && pass "php.sh runs the binary through runuser -u <app>" \
    || fail "php.sh does not drop to the app user"
export PATH="$OLDPATH"

# ── PHP source: packages.sury.org first ──────────────────────
APT_LOG="${TMP}/apt.log"; : > "$APT_LOG"
{
    extract php-apt.sh php_setup_apt_sources
    extract php-apt.sh php_sury_repo_configured
    extract php-apt.sh php_apt_source_label
} | sed "s|/etc/apt/|${TMP}/etc/apt/|g" > "${TMP}/apt-funcs.sh"
# shellcheck source=/dev/null
source "${TMP}/apt-funcs.sh"
mkdir -p "${TMP}/etc/apt/sources.list.d"
SL="${TMP}/etc/apt/sources.list.d"
ubuntu_codename() { echo noble; }
SURY_UP=true; SURY_SETUP_OK=true; PPA_UP=true
php_sury_repo_available() { [[ "$SURY_UP" == true ]]; }
php_ondrej_ppa_available() { [[ "$PPA_UP" == true ]]; }
php_setup_sury_repo() { echo setup-sury >> "$APT_LOG"; [[ "$SURY_SETUP_OK" == true ]] && touch "${SL}/php-sury.list"; [[ "$SURY_SETUP_OK" == true ]]; }
php_remove_sury_repo() { echo remove-sury >> "$APT_LOG"; rm -f "${SL}/php-sury.list"; }
php_remove_ondrej_ppa_sources() { echo remove-ppa >> "$APT_LOG"; rm -f "${SL}"/ondrej-ubuntu-php*; }
add-apt-repository() { echo add-ppa >> "$APT_LOG"; touch "${SL}/ondrej-ubuntu-php-noble.sources"; }

touch "${SL}/ondrej-ubuntu-php-noble.sources"
php_setup_apt_sources && [[ -f "${SL}/php-sury.list" && ! -e "${SL}/ondrej-ubuntu-php-noble.sources" ]] \
    && [[ "$(php_apt_source_label)" == "packages.sury.org" ]] \
    && pass "noble with sury.org up: sury.org configured, PPA removed" || fail "sury.org not preferred: $(cat "$APT_LOG")"
: > "$APT_LOG"; rm -f "${SL}"/*; SURY_SETUP_OK=false
php_setup_apt_sources && [[ ! -e "${SL}/php-sury.list" && -e "${SL}/ondrej-ubuntu-php-noble.sources" ]] \
    && [[ "$(php_apt_source_label)" == "ondrej/php PPA" ]] \
    && pass "sury.org keyring failure falls back to the PPA" || fail "no fallback to PPA: $(cat "$APT_LOG")"
: > "$APT_LOG"; rm -f "${SL}"/*; SURY_UP=false; SURY_SETUP_OK=true
php_setup_apt_sources && ! grep -q setup-sury "$APT_LOG" && [[ -e "${SL}/ondrej-ubuntu-php-noble.sources" ]] \
    && pass "no sury.org suite: PPA as before" || fail "PPA path broken: $(cat "$APT_LOG")"
: > "$APT_LOG"; rm -f "${SL}"/*; PPA_UP=false
php_setup_apt_sources; rc=$?
[[ $rc -eq 1 && "$(php_apt_source_label)" == "Ubuntu archive" ]] && pass "neither repo: Ubuntu archive, returns 1" || fail "archive path: rc=${rc}"

# migration switches the source before it upgrades, and keeps the PPA on failure
M="${LIB}/migrations/5.6.3.sh"
src_line=$(grep -n 'elif php_setup_sury_repo; then' "$M" | cut -d: -f1)
upg_line=$(grep -n '^_php_upgrade ||' "$M" | cut -d: -f1)
[[ -n "$src_line" && -n "$upg_line" && "$src_line" -lt "$upg_line" ]] \
    && pass "migration moves to sury.org before running cipi php upgrade" || fail "migration order wrong (${src_line:-?} vs ${upg_line:-?})"
awk -v l="$src_line" 'NR>l && NR<=l+2' "$M" | grep -q 'php_remove_ondrej_ppa_sources' \
    && ! awk -v l="$src_line" 'NR>l+2 && NR<=l+6' "$M" | grep -q 'php_remove_ondrej_ppa_sources' \
    && pass "migration removes the PPA only after sury.org is in place" || fail "migration PPA removal not gated"

# ── migration ────────────────────────────────────────────────
grep -q '^set -euo pipefail' "$M" && pass "migration uses strict mode" || fail "migration lacks set -euo pipefail"
grep -q '_php_upgrade ||' "$M" && pass "migration runs cipi php upgrade without aborting on failure" || fail "migration _php_upgrade not guarded"
grep -q '_php_setup_upgrade_cron' "$M" && pass "migration moves the cron to daily" || fail "migration does not touch the cron"
grep -q 'systemctl restart "php${v}-fpm"' "$M" && pass "migration restarts every FPM" || fail "migration does not restart FPM"
grep -q -- '-t &>/dev/null' "$M" && pass "migration tests the FPM config before restarting" || fail "migration skips php-fpm -t"

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
