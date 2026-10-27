#!/bin/bash
#############################################
# Cipi Migration 5.7.2
#
#  1. Makes /opt/cipi/lib/yml.sh readable by app users (0644, directories
#     0755). cipi-app-post-deploy runs as the app user and sources it for
#     the deploy.post steps of cipi.yml; installed 0700 until now, the
#     source failed and every webhook deploy ended with
#     "post-deploy summary:  (exit=127)".
#  2. Adds the PHP advisory lines of 2026-10-21 (php_fpm_ini_hardening:
#     session.upload_progress.enabled, fatal_error_backtraces) to
#     /etc/php/X.Y/fpm/conf.d/99-cipi.ini of every installed PHP, so that
#     the stock `www` pool and pools written by hand carry them too.
#  3. Renders the Node webhook pools again: file_uploads off, the receiver
#     reads JSON and nothing else. The previous pools are kept and put back
#     if `php-fpm -t` refuses the result.
#  4. Adds CIPI_DEPLOY_BRANCH to the shared/.env of every Laravel app that
#     lacks it: the webhook of cipi/agent then deploys a push to the
#     configured branch and ignores the others. A value already there is
#     left alone.
#  5. Restarts PHP-FPM where an ini or a pool changed.
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

echo "Migration 5.7.2 — post-deploy runner, PHP ini hardening, deploy branch..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

# ── 1. yml.sh readable by app users ──────────────────────────
if [[ -f "${CIPI_LIB}/yml.sh" ]]; then
    chmod 755 "$(dirname "$CIPI_LIB")" "$CIPI_LIB" 2>/dev/null || true
    if chmod 644 "${CIPI_LIB}/yml.sh" 2>/dev/null; then
        echo "  ${CIPI_LIB}/yml.sh readable by app users (cipi.yml deploy.post steps on webhook deploys)"
    else
        echo "  WARNING: could not chmod ${CIPI_LIB}/yml.sh — deploy.post steps keep failing on webhook deploys"
    fi
fi

# ── 2. fpm/conf.d/99-cipi.ini ────────────────────────────────
restart=""
for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
    php_is_installed "$v" || continue
    [[ -d "/etc/php/${v}/fpm/conf.d" ]] || continue
    ini="/etc/php/${v}/fpm/conf.d/99-cipi.ini"
    added=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="${line%% =*}"
        # Matched by key: a value someone set by hand is left as it is.
        grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$ini" 2>/dev/null && continue
        printf '%s\n' "$line" >> "$ini" || { echo "  WARNING: php ${v}: cannot write ${ini}"; break; }
        added=$((added + 1))
    done < <(php_fpm_ini_hardening)
    if (( added > 0 )); then
        echo "  php ${v}: ${added} hardening line(s) added to fpm/conf.d/99-cipi.ini"
        restart="${restart} ${v}"
    fi
done

# ── 3. Node webhook pools ────────────────────────────────────
apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi
backup_dir="/var/lib/cipi/fpm-pool-backup-5.7.2"
rewritten=""
if [[ -n "$apps" ]] && [[ -f "${CIPI_LIB}/node.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/node.sh"
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        id "$app" &>/dev/null || continue
        [[ "$(app_get "$app" runtime 2>/dev/null || true)" == "node" ]] || continue
        php_ver=$(app_get "$app" php 2>/dev/null || true)
        pool="/etc/php/${php_ver}/fpm/pool.d/${app}.conf"
        [[ -n "$php_ver" && -f "$pool" ]] || continue
        if grep -q '^php_admin_flag\[file_uploads\]' "$pool"; then
            echo "  ${app}: webhook pool already hardened"
            continue
        fi
        mkdir -p "${backup_dir}/${php_ver}" 2>/dev/null || true
        if ! cp -p "$pool" "${backup_dir}/${php_ver}/${app}.conf" 2>/dev/null; then
            echo "  WARNING: ${app}: could not back up ${pool} — pool left as it is"
            continue
        fi
        if declare -f _node_webhook_pool >/dev/null && _node_webhook_pool "$app" "$php_ver" 2>/dev/null && [[ -s "$pool" ]]; then
            echo "  ${app}: webhook pool rewritten (php ${php_ver}, file_uploads off)"
            rewritten="${rewritten} ${php_ver}:${app}"
            restart="${restart} ${php_ver}"
        else
            cp -p "${backup_dir}/${php_ver}/${app}.conf" "$pool" 2>/dev/null || true
            echo "  WARNING: ${app}: could not rewrite the webhook pool — previous pool kept"
        fi
    done <<< "$apps"
fi

# A version whose pools no longer pass the config test gets its old ones
# back: a restart on a refused configuration leaves FPM down.
for v in $(tr ' ' '\n' <<< "$restart" | grep -v '^$' | sort -u); do
    command -v "php-fpm${v}" &>/dev/null || continue
    "php-fpm${v}" -t &>/dev/null && continue
    echo "  WARNING: php ${v}: FPM configuration test failed — restoring the previous webhook pools"
    for entry in $rewritten; do
        [[ "${entry%%:*}" == "$v" ]] || continue
        cp -p "${backup_dir}/${v}/${entry#*:}.conf" "/etc/php/${v}/fpm/pool.d/${entry#*:}.conf" 2>/dev/null || true
    done
done

# ── 4. CIPI_DEPLOY_BRANCH ────────────────────────────────────
n_env=0
if [[ -n "$apps" ]]; then
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        id "$app" &>/dev/null || continue
        [[ "$(app_get "$app" runtime 2>/dev/null || true)" == "node" ]] && continue
        [[ "$(app_get "$app" custom 2>/dev/null || true)" == "true" ]] && continue
        env="/home/${app}/shared/.env"
        [[ -f "$env" ]] || continue
        grep -q '^CIPI_DEPLOY_BRANCH=' "$env" 2>/dev/null && continue
        branch=$(app_get "$app" branch 2>/dev/null || true)
        if app_env_set_deploy_branch "$app" "${branch:-main}" add; then
            n_env=$((n_env + 1))
        else
            echo "  WARNING: ${app}: could not write CIPI_DEPLOY_BRANCH to shared/.env"
        fi
    done <<< "$apps"
fi
(( n_env > 0 )) && echo "  ${n_env} Laravel app(s): CIPI_DEPLOY_BRANCH added to shared/.env (the webhook deploys that branch only)"

# ── 5. Restart PHP-FPM where something changed ───────────────
for v in $(tr ' ' '\n' <<< "$restart" | grep -v '^$' | sort -u); do
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

[[ -n "$rewritten" ]] && echo "  Previous webhook pools kept in ${backup_dir}"
echo "Migration 5.7.2 complete"
