#!/bin/bash
# Local regression checks for 5.8.4 — `cipi deploy <app> --status` (is a deploy
# running right now, whoever started it), the "panel" trigger in the start
# banner, `cipi yml example` with its healthcheck commented out, `cipi health
# set` keeping an existing URL, and the hint printed when a post-deploy check
# fails. Pure bash 3.2 + jq: nothing outside the temp dir is touched.
# Run from repo root: bash tests/verify-5.8.4.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "=== Cipi 5.8.4 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.4" ]] \
    && pass "version.md is 5.8.4" || fail "version.md is not 5.8.4"
grep -q '^## \[5.8.4\]' "${ROOT}/CHANGELOG.md" && grep -q -- '--status' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.4 entry naming --status" || fail "CHANGELOG 5.8.4"
for f in deploy.sh health.sh yml.sh completion.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"

# ── 1. cipi deploy <app> --status ────────────────────────────
echo "--- deploy --status"
grep -q 'ARG_status:-}" == "true" \]\];.*_deploy_status "\$app"' "${LIB}/deploy.sh" \
    && pass "deploy_command dispatches --status" || fail "no --status dispatch"
grep -q 'cipi deploy <app> --status' "${ROOT}/cipi" && pass "help lists --status" || fail "help"
grep -q -- '--status --tail=' "${LIB}/completion.sh" && pass "completion offers --status and --tail=" || fail "completion"
grep -q -- '--status' "${ROOT}/README.md" && pass "README mentions --status" || fail "README"

HOME_D="${TMP}/home/demo"; LOG="${HOME_D}/logs/deploy.log"
mkdir -p "${HOME_D}/.dep" "${HOME_D}/logs"
FN="${TMP}/status.sh"
{
    echo 'BOLD=; NC=; DIM=; GREEN=; YELLOW=; RED=; error() { echo "[ERROR] $*" >&2; }'
    echo "deploy_app_home() { echo '${HOME_D}'; }; deploy_log_file() { echo '${LOG}'; }"
    extract deploy.sh _deploy_fmt_secs
    extract deploy.sh _deploy_epoch
    extract deploy.sh _deploy_iso
    extract deploy.sh _deploy_live_pids
    extract deploy.sh _deploy_status
} > "$FN"
# st <live-pids-body> [ARG…] → JSON on stdout
st() { local pids="$1"; shift; bash -c "set -euo pipefail; source '$FN'; _deploy_live_pids() { $pids; }; $* _deploy_status demo" 2>&1; }

out=$(st ':' ARG_json=true)
[[ "$(jq -r '.state + "/" + (.running|tostring) + "/" + (.last|tostring) + "/" + (.current|tostring)' <<< "$out")" == "idle/false/null/null" ]] \
    && pass "no log yet: idle, no last, no current" || fail "no log: $out"

cat > "$LOG" <<'LOGEOF'
[2026-10-28 18:30:00] ===== deploy start  app=demo trigger=cli branch=main from-release=61 =====
[2026-10-28 18:30:01] task deploy:info
[2026-10-28 18:31:10] ===== deploy OK  app=demo release=62 duration=70s exit=0 =====

[2026-10-28 18:32:49] ===== deploy start  app=demo trigger=webhook branch=main from-release=62 =====
[2026-10-28 18:32:50] task deploy:info
[2026-10-28 18:34:24] ===== deploy OK  app=demo release=63 duration=95s exit=0 =====

[2026-10-28 18:34:24]  → Post-deploy healthcheck: https://demo.test/up (expect 200)
LOGEOF
out=$(st ':' ARG_json=true)
[[ "$(jq -r '.state' <<< "$out")" == "idle" && "$(jq -r '.locked' <<< "$out")" == "false" ]] \
    && pass "finished log: idle, not locked" || fail "finished log state: $out"
[[ "$(jq -r '[.last.result,.last.kind,.last.release,(.last.duration|tostring),(.last.exit|tostring),.last.trigger,.last.branch,.last.from_release] | join(",")' <<< "$out")" == "ok,deploy,63,95,0,webhook,main,62" ]] \
    && pass "last run: result, kind, release, duration, exit, and its own start banner" || fail "last run: $out"
[[ "$(jq -r '.last.started_at' <<< "$out")" == 2026-10-28T18:32:49* && "$(jq -r '.last.finished_at' <<< "$out")" == 2026-10-28T18:34:24* ]] \
    && pass "timestamps are ISO 8601 with an offset" || fail "timestamps: $(jq -c '.last' <<< "$out")"
[[ "$(jq -r 'has("tail")' <<< "$out")" == "false" ]] && pass "no tail unless asked" || fail "tail present without --tail"

printf '[2026-10-28 18:40:00] ===== deploy start  app=demo trigger=webhook branch=main from-release=63 =====\n' >> "$LOG"
: > "${HOME_D}/.dep/deploy.lock"
out=$(st "printf '4242\tdep\n4243\twrapper\n'" ARG_json=true ARG_tail=2)
[[ "$(jq -r '[.state,.phase,(.running|tostring),(.locked|tostring)] | join(",")' <<< "$out")" == "running,deploy,true,true" ]] \
    && pass "open banner + live Deployer: running, phase deploy, locked" || fail "running: $out"
[[ "$(jq -r '[.current.trigger,.current.branch,.current.from_release,(.current.pids|join(" "))] | join(",")' <<< "$out")" == "webhook,main,63,4242 4243" ]] \
    && pass "current run: trigger, branch, previous release, pids" || fail "current: $out"
[[ "$(jq -r '.current.elapsed | type' <<< "$out")" == "number" && "$(jq -r '.current.started_at' <<< "$out")" == 2026-10-28T18:40:00* ]] \
    && pass "current run: started_at and elapsed" || fail "elapsed: $out"
[[ "$(jq -r '.last.release' <<< "$out")" == "63" ]] && pass "last finished run still reported while one runs" || fail "last while running"
[[ "$(jq -r '.tail | length' <<< "$out")" == "2" && "$(jq -r '.tail[1]' <<< "$out")" == *"deploy start"* ]] \
    && pass "--tail=2 returns the last two lines" || fail "tail: $(jq -c '.tail' <<< "$out")"
out=$(st "printf '4243\twrapper\n'" ARG_json=true)
[[ "$(jq -r '.phase' <<< "$out")" == "post-deploy" ]] && pass "only the wrapper alive: phase post-deploy" || fail "phase: $out"
out=$(st ':' ARG_json=true)
[[ "$(jq -r '[.state,(.running|tostring),.current.trigger,(.locked|tostring)] | join(",")' <<< "$out")" == "interrupted,false,webhook,true" ]] \
    && pass "open banner, nothing alive: interrupted, still locked" || fail "interrupted: $out"
out=$(st ':')
[[ "$out" == *"Deploy status — demo"* && "$out" == *"interrupted"* && "$out" == *"cipi deploy demo --unlock"* && "$out" == *"release 63 in 1m35s"* ]] \
    && pass "text output names the state, the stuck lock and the last run" || fail "text: $out"
: > "${HOME_D}/.deploy-trigger"
out=$(st "printf '4242\tdep\n'" ARG_json=true)
[[ "$(jq -r '[.state,(.queued|tostring)] | join(",")' <<< "$out")" == "running,true" ]] \
    && pass "a push waiting while a run is live: running, queued=true" || fail "queued while running: $out"
rm -f "${HOME_D}/.dep/deploy.lock"
printf '[2026-10-28 18:41:00] ===== deploy FAILED  app=demo release=63 duration=60s exit=1 =====\n' >> "$LOG"
out=$(st ':' ARG_json=true)
[[ "$(jq -r '[.state,(.queued|tostring),.last.result,(.last.exit|tostring),(.current|tostring)] | join(",")' <<< "$out")" == "queued,true,failed,1,null" ]] \
    && pass "trigger file alone: queued; last run failed with its exit code" || fail "queued: $out"
rm -f "${HOME_D}/.deploy-trigger"
printf '[2026-10-28 18:45:00] ===== deploy start  app=demo trigger=rollback branch=main from-release=63 =====\n[2026-10-28 18:45:03] ===== deploy ROLLBACK OK  app=demo release=62 duration=3s exit=0 =====\n' >> "$LOG"
out=$(st ':' ARG_json=true)
[[ "$(jq -r '[.state,.last.kind,.last.result,.last.release,.last.trigger] | join(",")' <<< "$out")" == "idle,rollback,ok,62,rollback" ]] \
    && pass "a rollback banner is reported as kind rollback" || fail "rollback: $out"
out=$(st "printf '77\tdep\n'" ARG_json=true)
[[ "$(jq -r '[.state,(.current.trigger|tostring),(.current.pids|join(" "))] | join(",")' <<< "$out")" == "running,null,77" ]] \
    && pass "Deployer alive without a banner (dep by hand): running, no trigger" || fail "dep by hand: $out"
out=$(bash -c "source '$FN'; ARG_tail=abc _deploy_status demo" 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"--tail must be"* ]] && pass "--tail=abc is refused" || fail "--tail validation (rc=$rc): $out"

# _deploy_live_pids: classify a fake process table
out=$(bash -c "source '$FN'; ps() { cat <<'PS'
  101 /usr/bin/php8.4 /usr/local/bin/dep deploy -f /home/demo/.deployer/deploy.php
  102 /bin/bash /usr/local/bin/cipi-app-deploy demo 8.4 webhook
  103 /bin/bash /usr/local/bin/cipi deploy demo
  104 sudo /usr/local/bin/cipi deploy demo --status --json
  105 /bin/bash /usr/local/bin/cipi deploy demo --log=200
  106 /bin/bash /usr/local/bin/cipi deploy demo2
  107 /usr/bin/php8.4 /usr/local/bin/dep deploy -f /home/demo2/.deployer/deploy.php
  108 /bin/bash /usr/local/bin/cipi deploy demo --snapshot
  109 /bin/bash /usr/local/bin/cipi deploy demo --rollback
  110 /bin/bash /usr/local/bin/cipi deploy demo --audit --json
  111 /usr/bin/php8.4 /usr/local/bin/dep rollback -f /home/demo/.deployer/deploy.php
PS
}; _deploy_live_pids demo" | tr '\t' = | tr '\n' ' ')
[[ "$out" == "101=dep 102=wrapper 103=cli 108=cli 109=cli 111=dep " ]] \
    && pass "live pids: Deployer, the wrapper and real runs; not --status/--log/--audit nor another app" || fail "live pids: $out"

# ── 2. The start banner says who started a CLI run ───────────
echo "--- start banner trigger"
grep -q 'SUDO_USER:-}" == "www-data" \]\] && trigger="panel"' "${LIB}/deploy.sh" \
    && grep -q 'deploy_log_open "\$app" "\$trigger" "\$branch_disp" "\$rel_before"' "${LIB}/deploy.sh" \
    && pass "_deploy_run writes trigger=panel when the API (www-data) started it, cli otherwise" || fail "panel trigger"

# ── 3. cipi yml example: the healthcheck is off until uncommented ──
echo "--- yml example"
ex=$(bash -c "RED=; NC=; error(){ :; }; validate_username(){ return 0; }; app_exists(){ return 1; }; source '${LIB}/yml.sh'; _yml_example shop" 2>/dev/null)
! grep -q '^health:' <<< "$ex" && grep -q '^# health:' <<< "$ex" && grep -q '^#   url: "https://example.com/up"' <<< "$ex" \
    && pass "the example's health: block is commented out" || fail "example health block"
grep -q 'catalogue' <<< "$ex" && grep -q 'delete the rest BEFORE you commit' <<< "$ex" \
    && pass "the example says it is a catalogue to prune before committing" || fail "example header"
grep -q 'Laravel serves /up only when' <<< "$ex" && pass "the example says /up needs the health route" || fail "example /up note"

# ── 4. cipi health set keeps what is already set ─────────────
echo "--- health set"
HS="${TMP}/health-set.sh"
{
    echo 'info() { :; }; warn() { :; }; success() { echo "✓ $*"; }; error() { echo "[ERROR] $*" >&2; }'
    echo 'app_exists() { return 0; }; domain_is_wildcard() { return 1; }; _health_ensure_cron() { :; }; log_action() { :; }'
    echo "app_set() { echo \"SET \$2=\$3\" >> '${TMP}/sets'; }; app_unset() { echo \"UNSET \$2\" >> '${TMP}/sets'; }"
    sed -n '/^parse_args() {/,/^}/p' "${LIB}/common.sh"
    extract health.sh _health_set
} > "$HS"
: > "${TMP}/sets"
bash -c "source '$HS'; app_get() { case \"\$2\" in health_url) echo https://demo.test/healthz ;; health_expect) echo 204 ;; domain) echo demo.test ;; esac; }; _health_set demo --no-postdeploy" >/dev/null 2>&1
grep -q 'SET health_url=https://demo.test/healthz' "${TMP}/sets" && grep -q 'SET health_expect=204' "${TMP}/sets" && grep -q 'SET health_postdeploy=false' "${TMP}/sets" \
    && pass "health set --no-postdeploy keeps the custom URL and status" || fail "health set keep: $(cat "${TMP}/sets")"
: > "${TMP}/sets"
bash -c "source '$HS'; app_get() { case \"\$2\" in health_url) echo https://demo.test/healthz ;; health_expect) echo 204 ;; domain) echo demo.test ;; esac; }; _health_set demo --url=https://demo.test/up --expect=200" >/dev/null 2>&1
grep -q 'SET health_url=https://demo.test/up' "${TMP}/sets" && grep -q 'SET health_expect=200' "${TMP}/sets" \
    && pass "health set --url/--expect still replaces them" || fail "health set replace: $(cat "${TMP}/sets")"
: > "${TMP}/sets"
bash -c "source '$HS'; app_get() { case \"\$2\" in domain) echo demo.test ;; esac; }; _health_set demo" >/dev/null 2>&1
grep -q 'SET health_url=https://demo.test/up' "${TMP}/sets" && grep -q 'SET health_expect=200' "${TMP}/sets" \
    && pass "a first health set defaults to https://<domain>/up and 200" || fail "health set defaults: $(cat "${TMP}/sets")"

# ── 5. A failed post-deploy check says where it came from ────
echo "--- post-deploy healthcheck verdict"
HP="${TMP}/health-pd.sh"
{
    echo 'HEALTH_PD_ATTEMPTS=1; HEALTH_PD_DELAY=0; HEALTH_STATE_DIR="'"${TMP}"'/health"'
    echo 'step() { echo "→ $*"; }; success() { echo "✓ $*"; }; warn() { echo "[WARN] $*"; }; info() { echo "[INFO] $*"; }; error() { echo "[ERROR] $*" >&2; }'
    echo 'log_action() { :; }; sleep() { :; }; _health_grace_for() { echo 0; }; hostname() { echo srv; }'
    echo "cipi_notify() { printf '%s\n' \"\$2\" > '${TMP}/mail'; }"
    echo 'app_get() { case "$2" in health_url) echo https://demo.test/up ;; health_expect) echo 200 ;; *) echo "" ;; esac; }'
    extract health.sh health_post_deploy
} > "$HP"
out=$(bash -c "source '$HP'; curl() { printf 404; }; health_post_deploy demo deploy; echo rc=\$?" 2>&1)
[[ "$out" == *"rc=1"* && "$out" == *"404 means the URL does not exist"* && "$out" == *"cipi health set demo --no-postdeploy"* && "$out" == *"cipi health unset demo"* && "$out" == *"a cipi.yml 'health:' block"* ]] \
    && pass "a 404 verdict explains /up, where the check comes from and how to turn it off" || fail "verdict: $out"
grep -q 'Skip it after deploys: cipi health set demo --no-postdeploy' "${TMP}/mail" && grep -q '404: the URL does not exist' "${TMP}/mail" \
    && pass "the alert email carries the same hints" || fail "mail: $(cat "${TMP}/mail")"
out=$(bash -c "source '$HP'; curl() { printf 500; }; health_post_deploy demo deploy; echo rc=\$?" 2>&1)
[[ "$out" == *"rc=1"* && "$out" != *"404 means"* && "$out" == *"--no-postdeploy"* ]] \
    && pass "a 500 verdict skips the /up note but keeps the hints" || fail "500 verdict: $out"
out=$(bash -c "source '$HP'; curl() { printf 200; }; health_post_deploy demo deploy; echo rc=\$?" 2>&1)
[[ "$out" == *"rc=0"* && "$out" == *"Healthcheck passed"* && "$out" != *"--no-postdeploy"* ]] \
    && pass "a passing check prints no hints" || fail "pass verdict: $out"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
