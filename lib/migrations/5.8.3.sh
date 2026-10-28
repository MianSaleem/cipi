#!/bin/bash
#############################################
# Cipi Migration 5.8.3
#
#  Rewrites the panel API's daily maintenance (/etc/cron.d/cipi-api and
#  /usr/local/bin/cipi-api-maintain) on servers with the API installed, so
#  that the jobs whose output holds a password — app-create, db-create,
#  db-password — are pruned after one day instead of fourteen, and runs it
#  once as www-data. The cipi/api 1.36.1 package itself (a job readable only
#  with the ability it was created under) arrives with the package update
#  that follows every self-update; nothing to do for it here.
#
#  No-op without the panel API. Never fails the update.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"
export CIPI_API_ROOT="${CIPI_API_ROOT:-/opt/cipi/api}"

echo "Migration 5.8.3 — panel API jobs with credentials kept one day..."

if [[ ! -f "${CIPI_CONFIG}/api.json" || ! -f "${CIPI_API_ROOT}/artisan" ]]; then
    echo "  Panel API not installed — nothing to do."
    echo "Migration 5.8.3 complete."
    exit 0
fi

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/api.sh"

if declare -f _api_setup_cron >/dev/null 2>&1 && _api_setup_cron; then
    echo "  /etc/cron.d/cipi-api and cipi-api-maintain rewritten (jobs with a password pruned after 24 hours)"
else
    echo "  WARNING: could not rewrite the API maintenance cron — run: cipi api update"
fi

# One run now, as the cron does (www-data: root must not touch the panel's
# SQLite files). Its log stays the cron's: a root-created file there would
# stop the nightly run from writing it.
if [[ -x /usr/local/bin/cipi-api-maintain ]] && command -v sqlite3 >/dev/null 2>&1; then
    if timeout 120 sudo -u www-data /usr/local/bin/cipi-api-maintain >/dev/null 2>&1; then
        echo "  maintenance run once: finished jobs older than a day that hold a password are gone"
    else
        echo "  maintenance run skipped (it runs nightly at 04:15)"
    fi
fi

echo "Migration 5.8.3 complete."
