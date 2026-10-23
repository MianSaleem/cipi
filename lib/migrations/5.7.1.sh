#!/bin/bash
#############################################
# Cipi Migration 5.7.1
#
# PHP advisory of 2026-10-23 (CVE-2026-115560, no fix released yet): set
# session.upload_progress.enabled=0 until the next PHP release. 5.6.3 put it
# in every FPM pool, but Octane apps answer from FrankenPHP, which runs its
# own PHP and never reads a pool.
#
#  1. Writes /etc/php/cipi-octane.d/99-cipi-hardening.ini
#     (octane_php_ini_ensure): upload progress off, fatal_error_backtraces
#     off, the 5.6.3 settings for CVE-2026-109619.
#  2. Renders each Octane app's Supervisor program again
#     (_create_supervisor_octane), which now points PHP_INI_SCAN_DIR at it.
#     The old file is kept and put back if Supervisor refuses the new one.
#  3. Restarts each rewritten Octane program: the settings load at startup.
#     A program that was stopped stays stopped.
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

echo "Migration 5.7.1 — PHP hardening for Octane apps (CVE-2026-115560)..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null \
        | jq -r 'to_entries[] | select(.value.octane == "frankenphp") | .key' 2>/dev/null || true)
fi
if [[ -z "$apps" ]]; then
    echo "Migration 5.7.1 complete (no Octane apps)"
    exit 0
fi

# ── 1. ini file ──────────────────────────────────────────────
if octane_php_ini_ensure; then
    echo "  ${OCTANE_INI_DIR}/99-cipi-hardening.ini written"
else
    echo "  WARNING: could not write ${OCTANE_INI_DIR} — Octane apps left as they are"
    echo "Migration 5.7.1 complete"
    exit 0
fi

# ── 2. Supervisor programs ───────────────────────────────────
backup_dir="/var/lib/cipi/supervisor-backup-5.7.1"
rewritten=""
while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    id "$app" &>/dev/null || continue
    conf="/etc/supervisor/conf.d/${app}.conf"
    # No program yet: the app was never set up for Octane on this server.
    grep -qxF "[program:${app}-octane]" "$conf" 2>/dev/null || continue
    if awk -v p="[program:${app}-octane]" '$0==p{s=1;next}/^\[program:/{s=0}s' "$conf" \
        | grep -q '^environment=.*PHP_INI_SCAN_DIR'; then
        echo "  ${app}: Octane program already hardened"
        continue
    fi
    php_ver=$(app_get "$app" php 2>/dev/null || true)
    port=$(app_get "$app" octane_port 2>/dev/null || true)
    if [[ -z "$php_ver" || -z "$port" ]]; then
        echo "  WARNING: ${app}: no PHP version or Octane port in apps.json — program left as it is"
        continue
    fi
    mkdir -p "$backup_dir" 2>/dev/null || true
    if ! cp -p "$conf" "${backup_dir}/${app}.conf" 2>/dev/null; then
        echo "  WARNING: ${app}: could not back up ${conf} — program left as it is"
        continue
    fi
    _supervisor_remove_program "$app" "${app}-octane"
    _create_supervisor_octane "$app" "$php_ver" "$port"
    rewritten="${rewritten}${app}"$'\n'
    echo "  ${app}: Octane program rewritten (PHP_INI_SCAN_DIR)"
done <<< "$apps"

if [[ -z "$rewritten" ]]; then
    echo "Migration 5.7.1 complete"
    exit 0
fi

# A configuration Supervisor refuses would stop every program on the next
# update: put the old files back instead.
if ! supervisorctl reread >/dev/null 2>&1; then
    echo "  WARNING: supervisorctl reread failed — restoring the previous programs"
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        cp -p "${backup_dir}/${app}.conf" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null || true
    done <<< "$rewritten"
    supervisorctl reread >/dev/null 2>&1 || true
    echo "Migration 5.7.1 complete"
    exit 0
fi

# ── 3. Restart ───────────────────────────────────────────────
while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    prog="${app}-octane"
    was=$(supervisorctl status "$prog" 2>/dev/null | awk '{ print $2 }' || true)
    # `update <group>` replaces the process with the new environment.
    if ! supervisorctl update "$prog" >/dev/null 2>&1; then
        echo "  WARNING: ${app}: supervisorctl update failed — run: supervisorctl update ${prog}"
        continue
    fi
    if [[ "$was" == "STOPPED" ]]; then
        supervisorctl stop "$prog" >/dev/null 2>&1 || true
        echo "  ${app}: Octane was stopped and stays stopped (starts with the new settings)"
    else
        echo "  ${app}: Octane restarted"
    fi
done <<< "$rewritten"

echo "  Previous Supervisor files kept in ${backup_dir}"
echo "Migration 5.7.1 complete"
