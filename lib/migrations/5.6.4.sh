#!/bin/bash
#############################################
# Cipi Migration 5.6.4
#
# cipi.yml auto-apply works on webhook deploys, and the panel API can drive it
# (cipi/api ≥ 1.35.0).
#
#  1. Installs the fixed /usr/local/bin/cipi-app-deploy. The webhook wrapper
#     looked for /etc/sudoers.d/cipi-<app>-yml with `test -f`, but it runs as
#     the app user and /etc/sudoers.d is 0750 root:root: the test was always
#     false, so a push never applied cipi.yml even with `cipi yml auto on`.
#     It now asks sudo (`sudo -n -l`) whether the rule is there.
#  2. Regenerates the panel API sudoers so www-data may run `cipi yml plan *`,
#     `cipi yml apply *` and `cipi yml auto *`.
#  3. Brings every app's cipi.yml sudoers rule in line with yml_auto in
#     apps.json: written where auto-apply is on but the rule is missing (an app
#     brought over with `cipi sync import`), removed where it is off.
#  4. Removes the rules of apps that no longer exist: `cipi app delete` left
#     /etc/sudoers.d/cipi-<app>-yml behind, and a new app with the same name
#     would have inherited it.
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

echo "Migration 5.6.4 — cipi.yml auto-apply on webhook deploys, panel API..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/yml.sh"

# ── 1. webhook wrapper ───────────────────────────────────────
if [[ -f "${CIPI_LIB}/cipi-app-deploy.sh" ]]; then
    if cp "${CIPI_LIB}/cipi-app-deploy.sh" /usr/local/bin/cipi-app-deploy 2>/dev/null; then
        chmod 755 /usr/local/bin/cipi-app-deploy 2>/dev/null || true
        chown root:root /usr/local/bin/cipi-app-deploy 2>/dev/null || true
        echo "  installed /usr/local/bin/cipi-app-deploy"
    else
        echo "  WARNING: could not write /usr/local/bin/cipi-app-deploy — webhook deploys still skip cipi.yml"
    fi
fi

# ── 2. panel API sudoers ─────────────────────────────────────
if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if type write_cipi_api_sudoers &>/dev/null; then
        write_cipi_api_sudoers
        if command -v visudo >/dev/null 2>&1; then
            if visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
                echo "  wrote /etc/sudoers.d/cipi-api (yml plan, yml apply, yml auto)"
            else
                echo "  WARN: cipi-api sudoers did not validate — check visudo -cf /etc/sudoers.d/cipi-api"
            fi
        else
            echo "  wrote /etc/sudoers.d/cipi-api (yml; visudo not available)"
        fi
    fi
else
    echo "  WARN: ${CIPI_LIB}/cipi-api-sudoers.sh not found"
fi

# ── 3. per-app rules follow apps.json ────────────────────────
# Steps 3 and 4 delete rules, so they run only on an apps.json that was read:
# an unreadable vault must not look like a server without apps.
apps="" apps_ok=false
if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps_ok=true
elif apps_json=$(vault_read apps.json 2>/dev/null) && jq -e 'type == "object"' <<< "$apps_json" >/dev/null 2>&1; then
    apps=$(jq -r 'keys[]' <<< "$apps_json")
    apps_ok=true
else
    echo "  WARNING: apps.json could not be read — cipi.yml sudoers rules left as they are"
fi

while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    rule="/etc/sudoers.d/cipi-${app}-yml"
    had=false; [[ -f "$rule" ]] && had=true
    if [[ "$(app_get "$app" yml_auto 2>/dev/null || true)" == "true" ]]; then
        if ! id "$app" &>/dev/null; then
            echo "  WARNING: ${app}: auto-apply is on but the user does not exist — rule not written"
            continue
        fi
        if yml_auto_sudoers_sync "$app"; then
            [[ "$had" == "true" ]] || echo "  ${app}: cipi.yml auto-apply sudoers rule restored"
        else
            echo "  WARNING: ${app}: cipi.yml sudoers rule rejected — run: cipi yml auto ${app} on"
        fi
    elif [[ "$had" == "true" ]]; then
        rm -f "$rule"
        echo "  ${app}: removed a cipi.yml sudoers rule left without auto-apply"
    fi
done <<< "$apps"

# ── 4. rules of deleted apps ─────────────────────────────────
for rule in /etc/sudoers.d/cipi-*-yml; do
    [[ "$apps_ok" == "true" ]] || break
    [[ -f "$rule" ]] || continue
    app="${rule#/etc/sudoers.d/cipi-}"; app="${app%-yml}"
    grep -qx "$app" <<< "$apps" && continue
    rm -f "$rule"
    echo "  removed ${rule} (app '${app}' no longer exists)"
done

echo "Migration 5.6.4 complete"
