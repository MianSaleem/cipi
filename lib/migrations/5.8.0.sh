#!/bin/bash
#############################################
# Cipi Migration 5.8.0
#
#  1. Widens the nginx deny of cipi.yml on every app vhost so that the
#     per-environment files (cipi-<env>.yml / .yaml, read before cipi.yml
#     since 5.8.0) are kept off the web too. The previous vhosts are kept
#     in /var/lib/cipi/vhost-backup-5.8.0 and put back if `nginx -t`
#     refuses the result.
#  2. Adds CIPI_ENV=<label> to the shared/.env of every Laravel and Node app
#     that lacks it — the label from apps.json, production when there is
#     none. The post-deploy runner runs as the app user, cannot read
#     apps.json, and reads this key to pick the environment's cipi.yml. A
#     value already there is left alone, and APP_ENV is not touched.
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

echo "Migration 5.8.0 — per-environment cipi.yml..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi

# ── 1. nginx: deny cipi-<env>.yml as well ────────────────────
# The exact line _nginx_cipi_yml_deny_block wrote from 5.2.3 to 5.7.2, and
# the one it writes now. Replaced line by line, so the certbot-cloned :443
# server block is covered like the :80 one.
YML_DENY_OLD='location ~* /cipi\.ya?ml$ { deny all; }'
YML_DENY_NEW='location ~* /cipi(-[a-z0-9_-]+)?\.ya?ml$ { deny all; }'

# $1 = vhost. 0 when it was rewritten, 1 when there was nothing to do (or the
# rewrite could not be trusted: the vhost is then left as it was).
_widen_cipi_yml_deny() {
    local vhost="$1" tmp line mode
    grep -qF "$YML_DENY_OLD" "$vhost" 2>/dev/null || return 1
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "${line/"$YML_DENY_OLD"/$YML_DENY_NEW}"
    done < "$vhost" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! grep -qF "$YML_DENY_NEW" "$tmp" || grep -qF "$YML_DENY_OLD" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mode=$(stat -c '%a' "$vhost" 2>/dev/null || echo 644)
    chmod "$mode" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$vhost" || { rm -f "$tmp"; return 1; }
    return 0
}

if [[ -n "$apps" ]] && command -v nginx &>/dev/null && [[ -d /etc/nginx/sites-available ]]; then
    backup_dir="/var/lib/cipi/vhost-backup-5.8.0"
    rewrote=""
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        vhost="/etc/nginx/sites-available/${app}"
        [[ -f "$vhost" ]] || continue
        grep -qF "$YML_DENY_OLD" "$vhost" 2>/dev/null || continue
        mkdir -p "$backup_dir" 2>/dev/null || true
        cp "$vhost" "${backup_dir}/${app}" 2>/dev/null || continue
        if _widen_cipi_yml_deny "$vhost"; then
            rewrote="${rewrote} ${app}"
            echo "  ${app}: nginx now denies /cipi-<env>.yml too"
        else
            echo "  WARNING: ${app}: vhost left as it was — run: cipi app edit ${app} --domain=$(app_get "$app" domain 2>/dev/null || echo '<domain>')"
        fi
    done <<< "$apps"

    if [[ -n "$rewrote" ]]; then
        if nginx -t &>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
            echo "  nginx: reloaded (previous vhosts kept in ${backup_dir})"
        else
            for app in $rewrote; do
                cp "${backup_dir}/${app}" "/etc/nginx/sites-available/${app}" 2>/dev/null || true
            done
            echo "  WARNING: nginx test failed after widening the cipi.yml deny — every vhost was restored from ${backup_dir}"
        fi
    fi
fi

# ── 2. CIPI_ENV in shared/.env ───────────────────────────────
n_env=0
if [[ -n "$apps" ]]; then
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        env="/home/${app}/shared/.env"
        [[ -f "$env" ]] || continue
        grep -q '^CIPI_ENV=' "$env" 2>/dev/null && continue
        label=$(app_env_label "$app")
        if app_env_set_environment "$app" "$label" add; then
            n_env=$((n_env + 1))
        else
            echo "  WARNING: ${app}: could not write CIPI_ENV to shared/.env"
        fi
    done <<< "$apps"
fi
(( n_env > 0 )) && echo "  ${n_env} app(s): CIPI_ENV added to shared/.env (the post-deploy runner picks cipi-<env>.yml from it)"

echo "Migration 5.8.0 complete."
