#!/bin/bash
#############################################
# Cipi — Default app (`cipi use`)
#
# `cipi use <app>` names the app the per-app commands act on when none is
# given: `cipi deploy`, `cipi app logs`, `cipi yml plan`, `cipi worker list`,
# `cipi ssl install` … run against it and say so on stderr. The default
# lives in /var/lib/cipi/default-app (server-wide, root only); the CIPI_APP
# environment variable overrides it for one shell.
#
# It is filled in only where the app is a required argument today, so no
# invocation that works changes meaning: a command for which a missing app
# means "every app" (cipi git refresh, cipi git check, cipi scan) keeps it.
# Destructive commands (app delete, reset-password, reset-db-password,
# convert, clone, db …) always want the name spelled out. The panel API
# runs as www-data through sudo and names every app: it never gets a
# default.
#############################################

[[ -z "${USE_DEFAULT_FILE:-}" ]] && readonly USE_DEFAULT_FILE="/var/lib/cipi/default-app"

# The default app, if any: CIPI_APP first, then the file. Status 1 and
# nothing printed when there is none (or the value is not an app name).
use_default_app() {
    local a="${CIPI_APP:-}"
    if [[ -z "$a" && -f "$USE_DEFAULT_FILE" ]]; then
        a=$(head -c 64 "$USE_DEFAULT_FILE" 2>/dev/null | tr -d '[:space:]')
    fi
    [[ "$a" =~ ^[a-z][a-z0-9]{2,31}$ ]] || return 1
    printf '%s\n' "$a"
}

# Position (1 = first word after the command) of the app argument of a
# command and sub-command that require one; nothing for every other command.
# Usage: _use_app_position <cmd> [sub] [sub2]
_use_app_position() {
    local cmd="$1" sub="${2:-}" sub2="${3:-}"
    case "$cmd" in
        deploy) echo 1 ;;
        app)
            case "$sub" in
                show|edit|artisan|tinker|run|env|limits|deploy-config|reverb|suspend|unsuspend) echo 2 ;;
                logs)    if [[ "$sub2" == "read" ]]; then echo 3; else echo 2; fi ;;
                webhook) [[ "$sub2" == "recreate" ]] && echo 3 ;;
            esac ;;
        alias)     case "$sub" in add|remove|list|ls) echo 2 ;; esac ;;
        www)       case "$sub" in add|force-to-root|force-from-root|clear|status) echo 2 ;; esac ;;
        redirect|redirects)
                   case "$sub" in set|enable|disable|unset|add|remove|rm|list|status|ls) echo 2 ;; esac ;;
        proxy)     case "$sub" in add|remove|rm|list|status|ls) echo 2 ;; esac ;;
        auth)      case "$sub" in create|edit|show) echo 2 ;; esac ;;
        basicauth) case "$sub" in enable|disable|status) echo 2 ;; esac ;;
        worker)    case "$sub" in add|list|ls|remove|stop|restart|edit) echo 2 ;; horizon) echo 3 ;; esac ;;
        schedule)  case "$sub" in status|on|off) echo 2 ;; esac ;;
        health)    case "$sub" in set|unset|check|postdeploy) echo 2 ;; esac ;;
        search)    case "$sub" in enable|disable) echo 2 ;; esac ;;
        node)      case "$sub" in status|restart|logs|log) echo 2 ;; esac ;;
        ssl)       case "$sub" in install|force) echo 2 ;; esac ;;
        yml|yaml)  case "$sub" in validate|check|plan|diff|apply|auto|post-deploy|postdeploy|generate|dump) echo 2 ;; esac ;;
        ssh)       if [[ "$sub" == "apps" ]]; then case "$sub2" in enable|disable) echo 3 ;; esac; fi ;;
        zt|zerotrust) [[ "$sub" == "origin-cert" ]] && echo 2 ;;
    esac
    return 0
}

# The argument list with the default app filled in, as the USE_ARGV array;
# USE_FILLED holds the app when one was inserted, else it is empty.
# Usage: use_fill_args <cmd> [args...]
use_fill_args() {
    local cmd="$1"; shift
    USE_ARGV=("$@"); USE_FILLED=""
    local app pos n a before
    app=$(use_default_app) || return 0
    [[ "${SUDO_USER:-}" == "www-data" ]] && return 0
    for a in "$@"; do
        case "$a" in help|--help|-h) return 0 ;; esac
    done
    pos=$(_use_app_position "$cmd" "${1:-}" "${2:-}")
    [[ -n "$pos" ]] || return 0
    n=$#
    # Filled in only when the slot is empty or holds an option: a name that
    # is there is always the one meant.
    if (( n >= pos )); then
        a="${USE_ARGV[pos-1]}"
        [[ "$a" == --* ]] || return 0
    fi
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && ! app_exists "$app" 2>/dev/null; then
        echo -e "${YELLOW}[WARN]${NC} Default app '${app}' no longer exists — clear it: cipi use --clear" >&2
        return 0
    fi
    before=$((pos - 1))
    USE_ARGV=("${@:1:before}" "$app" "${@:pos}")
    # shellcheck disable=SC2034  # read by the caller (and the tests)
    USE_FILLED="$app"
    echo -e "${DIM}→ ${app} (default app — cipi use)${NC}" >&2
}

use_command() {
    local arg="${1:-}"
    case "$arg" in
        ""|status|show)            _use_show ;;
        --clear|clear|none|off|-)  _use_clear ;;
        help|--help|-h)            show_help use ;;
        --*) error "Usage: cipi use <app> | cipi use | cipi use --clear"; exit 1 ;;
        *)                         _use_set "$arg" ;;
    esac
}

_use_show() {
    local app saved=""
    [[ -f "$USE_DEFAULT_FILE" ]] && saved=$(tr -d '[:space:]' < "$USE_DEFAULT_FILE" 2>/dev/null)
    if app=$(use_default_app); then
        if [[ -n "${CIPI_APP:-}" ]]; then
            echo -e "Default app: ${CYAN}${app}${NC} ${DIM}(CIPI_APP in this shell${saved:+; saved on the server: ${saved}})${NC}"
        else
            echo -e "Default app: ${CYAN}${app}${NC} ${DIM}(${USE_DEFAULT_FILE})${NC}"
        fi
        app_exists "$app" || warn "'${app}' no longer exists — clear it: cipi use --clear"
        echo -e "${DIM}Used by the commands that need an app when none is given: cipi deploy, cipi app logs, cipi yml plan …${NC}"
    else
        echo -e "No default app ${DIM}— set one: cipi use <app>${NC}"
    fi
}

_use_set() {
    local app="$1"
    [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { error "Invalid app name: ${app}"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    local dir; dir=$(dirname "$USE_DEFAULT_FILE")
    mkdir -p "$dir" || { error "Cannot create ${dir}"; exit 1; }
    local tmp="${USE_DEFAULT_FILE}.tmp.$$"
    printf '%s\n' "$app" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$USE_DEFAULT_FILE" \
        || { rm -f "$tmp"; error "Cannot write ${USE_DEFAULT_FILE}"; exit 1; }
    success "Default app: ${app}"
    echo -e "${DIM}cipi deploy, cipi app logs, cipi yml plan … now act on '${app}' when no app is given. Undo: cipi use --clear${NC}"
    [[ -n "${CIPI_APP:-}" && "${CIPI_APP}" != "$app" ]] && warn "CIPI_APP=${CIPI_APP} is set in this shell and wins here: unset CIPI_APP"
    log_action "USE: $app"
}

_use_clear() {
    if [[ -f "$USE_DEFAULT_FILE" ]]; then
        rm -f "$USE_DEFAULT_FILE"
        success "Default app cleared"
        log_action "USE CLEAR"
    else
        info "No default app set"
    fi
    [[ -n "${CIPI_APP:-}" ]] && info "CIPI_APP=${CIPI_APP} is still set in this shell: unset CIPI_APP"
    return 0
}
