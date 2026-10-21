#!/bin/bash
#############################################
# Cipi Migration 5.6.3
#
# PHP security release of 2026-10-21: 8.5.12, 8.4.27, 8.3.36 and 8.2.35 fix
# two unauthenticated RCEs in every web SAPI (CVE-2026-109618, OOM
# corruption; CVE-2026-109619, request state that outlives its memory).
#
#  1. Rewrites every PHP-FPM pool Cipi owns with the advisory's mitigations
#     (fpm_pool_hardening): session.upload_progress.enabled off, and on 8.5
#     fatal_error_backtraces off. App and Node webhook pools are rendered
#     again by their generators. The panel pools (cipi-api, cipi-gui) get the
#     lines appended instead: their generators also empty the panel logs.
#     Each PHP version's pools are kept in a backup and put back if
#     `php-fpm -t` refuses the result.
#  2. Moves the `cipi php upgrade` cron from weekly to daily.
#  3. Moves the PHP packages from the Launchpad ondrej PPA to
#     packages.sury.org where sury.org has the suite. Same maintainer and
#     packages, but sury.org had the fixed builds for noble while the PPA
#     was still building them. The PPA goes only once sury.org is in place.
#  4. Runs `cipi php upgrade` now: the patched packages go in as soon as the
#     repository has them, and the run prints each version's patch level
#     and the PHP inside each Octane app's FrankenPHP binary.
#  5. Restarts every PHP-FPM service: the hardening needs it, and the
#     advisory asks for every worker to be replaced.
#
# Each step tolerates failure and says so: a migration that aborts pins the
# server on the old release and retries every night.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

echo "Migration 5.6.3 — PHP security release (CVE-2026-109618, CVE-2026-109619)..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/php.sh"

versions=""
for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
    php_is_installed "$v" && [[ -d "/etc/php/${v}/fpm/pool.d" ]] && versions="${versions} ${v}"
done

if [[ -z "$versions" ]]; then
    echo "Migration 5.6.3 complete (no PHP-FPM installed)"
    exit 0
fi

# ── 1. FPM pools ─────────────────────────────────────────────
backup_dir="/var/lib/cipi/fpm-pool-backup-5.6.3"
for v in $versions; do
    mkdir -p "${backup_dir}/${v}" 2>/dev/null || true
    cp -p /etc/php/"${v}"/fpm/pool.d/*.conf "${backup_dir}/${v}/" 2>/dev/null || true
done

apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi
if [[ -n "$apps" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/app.sh"
    # shellcheck source=/dev/null
    [[ -f "${CIPI_LIB}/node.sh" ]] && source "${CIPI_LIB}/node.sh"
fi

while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    id "$app" &>/dev/null || continue
    php_ver=$(app_get "$app" php 2>/dev/null || true)
    [[ -n "$php_ver" ]] || continue
    pool="/etc/php/${php_ver}/fpm/pool.d/${app}.conf"
    # Octane apps have no pool; an app without one is left as it is.
    [[ -f "$pool" ]] || continue
    if [[ "$(app_get "$app" runtime 2>/dev/null || true)" == "node" ]]; then
        if declare -f _node_webhook_pool >/dev/null && _node_webhook_pool "$app" "$php_ver" 2>/dev/null && [[ -s "$pool" ]]; then
            echo "  ${app}: webhook pool rewritten (php ${php_ver})"
        else
            echo "  WARNING: ${app}: could not rewrite the webhook pool"
        fi
    elif _create_fpm_pool "$app" "$php_ver" 2>/dev/null && [[ -s "$pool" ]]; then
        echo "  ${app}: FPM pool rewritten (php ${php_ver})"
    else
        echo "  WARNING: ${app}: could not rewrite the FPM pool"
    fi
done <<< "$apps"

for v in $versions; do
    for name in cipi-api cipi-gui; do
        pool="/etc/php/${v}/fpm/pool.d/${name}.conf"
        [[ -s "$pool" ]] || continue
        added=0
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            grep -qxF -- "$line" "$pool" && continue
            printf '%s\n' "$line" >> "$pool"
            added=$((added + 1))
        done < <(fpm_pool_hardening "$v")
        (( added > 0 )) && echo "  ${name}: ${added} hardening line(s) added (php ${v})"
    done
done

# A version whose pools no longer pass the config test gets its old ones
# back: a restart on a refused configuration leaves FPM down.
for v in $versions; do
    command -v "php-fpm${v}" &>/dev/null || continue
    "php-fpm${v}" -t &>/dev/null && continue
    echo "  WARNING: php ${v}: FPM configuration test failed — restoring the previous pools"
    for f in "${backup_dir}/${v}"/*.conf; do
        [[ -f "$f" ]] && cp -p "$f" "/etc/php/${v}/fpm/pool.d/" 2>/dev/null || true
    done
done

# ── 2. Daily PHP upgrade cron ────────────────────────────────
if _php_setup_upgrade_cron 2>/dev/null; then
    crontab -l 2>/dev/null | grep -F 'cipi php upgrade' | grep -q '^30 3 \* \* \* ' \
        && echo "  Root crontab: PHP upgrade check daily @ 03:30"
else
    echo "  WARNING: could not update the PHP upgrade cron"
fi

# ── 3. PHP package source: packages.sury.org ─────────────────
if [[ -f "${CIPI_LIB}/php-apt.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/php-apt.sh"
    codename="$(ubuntu_codename)"
    if php_sury_repo_configured; then
        echo "  PHP packages already from packages.sury.org"
    elif ! php_sury_repo_available "$codename"; then
        echo "  packages.sury.org has no '${codename}' suite — PHP stays on $(php_apt_source_label)"
    # Not php_setup_apt_sources: when sury.org fails it re-checks the PPA,
    # and a Launchpad hiccup (it answered 503 on release day) would remove a
    # PPA that works. Here a failure changes nothing.
    elif php_setup_sury_repo; then
        php_remove_ondrej_ppa_sources
        echo "  PHP packages now from packages.sury.org (ondrej PPA removed)"
    else
        rm -f /etc/apt/sources.list.d/php-sury.list 2>/dev/null || true
        echo "  WARNING: could not configure packages.sury.org — PHP stays on $(php_apt_source_label)"
    fi
else
    echo "  WARNING: ${CIPI_LIB}/php-apt.sh not found — PHP package source unchanged"
fi

# ── 4. PHP packages, now ─────────────────────────────────────
echo "  Running cipi php upgrade now..."
_php_upgrade || echo "  WARNING: a PHP version is still below the patched release, or the upgrade failed — run: cipi php upgrade"

# ── 5. Restart every PHP-FPM ─────────────────────────────────
for v in $versions; do
    systemd_unit_exists "php${v}-fpm" || continue
    if command -v "php-fpm${v}" &>/dev/null && ! "php-fpm${v}" -t &>/dev/null; then
        echo "  WARNING: php ${v}: FPM configuration test failed — not restarting (php-fpm${v} -t)"
        continue
    fi
    if systemctl restart "php${v}-fpm" 2>/dev/null; then
        echo "  php ${v}: FPM restarted"
    else
        echo "  WARNING: php ${v}: FPM restart failed — run: systemctl status php${v}-fpm"
    fi
done

echo "  Previous pools kept in ${backup_dir}"
echo "Migration 5.6.3 complete"
