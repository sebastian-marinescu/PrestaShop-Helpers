#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are shared between the library files
# ------------------------------------------------------------------------------
# PrestaShop Upgrade Toolkit - common functions
# (environment, detection, fail-safes, logging, database helpers)
#
# Portable: works with GNU and BSD userlands (Linux / FreeBSD).
# Author: Sebastian G. Marinescu
# ------------------------------------------------------------------------------

PSU_VERSION="1.0.0"

# ------------------------------------------------------------------------------
# Output & logging
# ------------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; ORANGE=$'\033[0;33m'; BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; ORANGE=''; BLUE=''; BOLD=''; DIM=''; NC=''
fi

CHECK_BLOCKERS=()
CHECK_CRITICAL=()
CHECK_WARNINGS=()
REPORT_FILE=""
LOG_FILE=""
RUN_RESULT="ABORTED"
RUN_FROM=""
RUN_TO=""
MAINTENANCE_ACTIVE=0
PSU_TMP=""
PSU_LOCK=""

info()   { printf '%s\n' "$*"; }
detail() { printf '%s%s%s\n' "$DIM" "$*" "$NC"; }
ok()     { printf '%s✅ %s%s\n' "$GREEN" "$*" "$NC"; }
warn()   { printf '%s⚠️  %s%s\n' "$ORANGE" "$*" "$NC"; }
err()    { printf '%s⛔ %s%s\n' "$RED" "$*" "$NC" >&2; }
step()   { printf '\n%s=== %s ===%s\n' "$BLUE$BOLD" "$*" "$NC"; rep ""; rep "## $*"; rep ""; }
die()    { err "$*"; RUN_RESULT="FAILED"; exit 1; }

# Append a line to the markdown report (if a report is active)
rep() {
    if [ -n "$REPORT_FILE" ]; then
        printf '%s\n' "$*" >> "$REPORT_FILE"
    fi
}

# Status line on console + checklist entry in the report.
# Usage: status <symbol> <message> [checkbox:1|0]
status() {
    local sym="$1" msg="$2" box="${3:-0}" color=""
    case "$sym" in
        "✅"|"🟢") color="$GREEN" ;;
        "🟠"|"⚠️") color="$ORANGE" ;;
        "🔴"|"⛔") color="$RED" ;;
        *) color="" ;;
    esac
    printf '%s%s %s%s\n' "$color" "$sym" "$msg" "$NC"
    if [ "$box" = "1" ]; then rep "- [ ] $sym $msg"; else rep "- $sym $msg"; fi
}

blocker()  { CHECK_BLOCKERS+=("$1");  status "⛔" "$1" 1; }
critical() { CHECK_CRITICAL+=("$1");  status "⛔" "$1 (bestätigungspflichtig)" 1; }
warning()  { CHECK_WARNINGS+=("$1");  status "⚠️" "$1" 1; }
passed()   { status "✅" "$1"; }

reset_check_counters() { CHECK_BLOCKERS=(); CHECK_CRITICAL=(); CHECK_WARNINGS=(); }

# Strip ANSI colors (portable awk, line-flushed) for the log file
strip_ansi() {
    awk -v e="$(printf '\033')" '{ gsub(e "\\[[0-9;]*[A-Za-z]", ""); print; fflush(); }'
}

# Start logging of the current run (console + log file without colors)
log_init() {
    local cmd="$1"
    mkdir -p "$PSU_HOME/logs" "$PSU_HOME/reports" "$PSU_HOME/state" || die "Kann $PSU_HOME nicht anlegen."
    RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="$PSU_HOME/logs/${RUN_STAMP}_${PS_ENV}_${cmd}.log"
    RUN_CMD="$cmd"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null
    exec > >(tee >(strip_ansi >> "$LOG_FILE")) 2>&1
    info "${DIM}PS-Upgrade-Toolkit v${PSU_VERSION} | $(date '+%Y-%m-%d %H:%M:%S') | Aufruf: $0 ${PSU_ARGS_STR}${NC}"
    info "${DIM}Log: ${LOG_FILE}${NC}"
}

# Start a markdown report for the current run
report_init() {
    local cmd="$1"
    REPORT_FILE="$PSU_HOME/reports/${RUN_STAMP}_${PS_ENV}_${cmd}.md"
    {
        printf '# PS-Upgrade-Toolkit – Report (%s)\n\n' "$cmd"
        printf -- '- Datum: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf -- '- Umgebung: %s (`%s`)\n' "$PS_ENV" "$PS_ROOT"
        printf -- '- Log: `%s`\n' "$LOG_FILE"
    } > "$REPORT_FILE"
}

# Called on exit: summary line, cleanup
on_exit() {
    local code=$?
    if [ "$code" -eq 0 ] && [ "$RUN_RESULT" = "ABORTED" ]; then RUN_RESULT="OK"; fi
    if [ "$code" -ne 0 ] && [ "$RUN_RESULT" = "OK" ]; then RUN_RESULT="FAILED"; fi
    if [ "$MAINTENANCE_ACTIVE" = "1" ]; then
        printf '\n%s⚠️  Der Wartungsmodus ist noch AKTIV. Beenden mit: %s maintenance off%s\n' "$ORANGE" "$0" "$NC"
    fi
    if [ -n "$LOG_FILE" ]; then
        local transition=""
        if [ -n "$RUN_FROM" ] || [ -n "$RUN_TO" ]; then transition="${RUN_FROM} → ${RUN_TO}"; fi
        printf '%s | %-10s | %-14s | %-20s | %-8s | %s\n' \
            "$(date '+%Y-%m-%d %H:%M')" "$PS_ENV" "$RUN_CMD" "$transition" "$RUN_RESULT" "${LOG_FILE#"$PSU_HOME"/}" \
            >> "$PSU_HOME/ps-upgrade.log"
        if [ -n "$REPORT_FILE" ]; then
            printf '\n%sReport: %s%s\n' "$DIM" "$REPORT_FILE" "$NC"
        fi
        printf '%sLog:    %s%s\n' "$DIM" "$LOG_FILE" "$NC"
    fi
    [ -n "$PSU_TMP" ] && [ -d "$PSU_TMP" ] && rm -rf "$PSU_TMP"
    [ -n "$PSU_LOCK" ] && [ -d "$PSU_LOCK" ] && rmdir "$PSU_LOCK" 2>/dev/null
    # give the tee/awk log pipeline a moment to flush
    sleep 0.3 2>/dev/null || sleep 1
}

# ------------------------------------------------------------------------------
# Prompts
# ------------------------------------------------------------------------------

# confirm "Frage" -> 0 = yes. Honors --yes.
confirm() {
    local answer
    if [ "${OPT_YES:-0}" = "1" ]; then
        info "$1 [y/N] y (--yes)"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "Keine interaktive Eingabe möglich – '$1' wird mit Nein beantwortet."
        return 1
    fi
    read -r -p "$1 [y/N] " answer
    case "$answer" in y|Y|j|J|yes|ja|Ja) return 0 ;; *) return 1 ;; esac
}

# confirm_word "Frage" "WORT" -> user must type WORT (ignores --yes)
confirm_word() {
    local question="$1" word="$2" answer
    if [ ! -t 0 ]; then
        err "Bestätigung '$word' erforderlich, aber keine interaktive Eingabe möglich."
        return 1
    fi
    read -r -p "$question (tippe '$word'): " answer
    [ "$answer" = "$word" ]
}

# ------------------------------------------------------------------------------
# Small portable utilities
# ------------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

phys_path() {
    local p="$1"
    if [ -z "$p" ]; then return 1; fi
    if readlink -f "$p" >/dev/null 2>&1; then
        readlink -f "$p"
    elif [ -d "$p" ]; then
        (cd "$p" && pwd -P)
    else
        printf '%s\n' "$p"
    fi
}

file_size() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

human_kb() {
    awk -v kb="${1:-0}" 'BEGIN {
        split("KB MB GB TB", u, " "); i = 1; v = kb + 0;
        while (v >= 1024 && i < 4) { v /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), v, u[i]
    }'
}

human_bytes() { human_kb "$(( ${1:-0} / 1024 ))"; }

file_sha256() {
    local f="$1"
    if have sha256sum; then sha256sum "$f" | awk '{print $1}'
    elif have sha256; then sha256 -q "$f"
    elif have shasum; then shasum -a 256 "$f" | awk '{print $1}'
    else tool hash sha256 "$f"
    fi
}

file_md5() {
    local f="$1"
    if have md5sum; then md5sum "$f" | awk '{print $1}'
    elif have md5; then md5 -q "$f"
    else tool hash md5 "$f"
    fi
}

random_token() {
    od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

make_tmp() {
    if [ -z "$PSU_TMP" ] || [ ! -d "$PSU_TMP" ]; then
        PSU_TMP="$(mktemp -d "${TMPDIR:-/tmp}/psu.XXXXXX")" || die "Kann kein Temp-Verzeichnis anlegen."
        chmod 700 "$PSU_TMP"
    fi
}

# Version helpers (via PHP version_compare)
vercmp() { tool vercmp "$1" "$2" "$3"; }          # vercmp a op b
ver_major() { printf '%s' "${1%%.*}"; }
ver_minor() { local r="${1#*.}"; printf '%s.%s' "${1%%.*}" "${r%%.*}"; }  # "8.2"

# Run the PHP helper with the tool PHP binary
tool() {
    "${TOOL_PHP:-php}" "$PSU_DIR/lib/ps-tools.php" "$@"
}

# ------------------------------------------------------------------------------
# Environment / configuration
# ------------------------------------------------------------------------------

load_env() {
    ENV_FILE="$PSU_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$ENV_FILE"
    fi

    PS_ROOT="$(phys_path "${PS_ROOT:-$PSU_DIR/..}")"
    BACKUP_DIR="${BACKUP_DIR:-$(dirname "$PS_ROOT")/backups}"
    PSU_HOME="$(phys_path "$BACKUP_DIR" 2>/dev/null || printf '%s' "$BACKUP_DIR")/ps-upgrade"
    BACKUP_KEEP="${BACKUP_KEEP:-5}"
    RELEASES_API_URL="${RELEASES_API_URL:-https://api.prestashop-project.org}"
    UPGRADE_PRESERVE_FILES="${UPGRADE_PRESERVE_FILES:-.htaccess robots.txt img/.htaccess}"
    GIT_COMPARE_EXCLUDE="${GIT_COMPARE_EXCLUDE:-app/config/parameters.php .htaccess img/.htaccess robots.txt}"
    UPGRADE_BRANCH_PREFIX="${UPGRADE_BRANCH_PREFIX:-upgrade/ps-}"
    PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-2048M}"
    MYSQL_BIN="${MYSQL_BIN:-mysql}"
    MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
    PSU_REL="${PSU_DIR#"$PS_ROOT"/}"

    if [ -n "${PS_ENV:-}" ]; then
        PS_ENV_SOURCE=".env (PS_ENV)"
    elif [ -n "${PROD_DIR:-}" ] && [ "$(phys_path "$PROD_DIR")" = "$PS_ROOT" ]; then
        PS_ENV="production"; PS_ENV_SOURCE="PROD_DIR"
    elif [ -n "${STAGING_DIR:-}" ] && [ "$(phys_path "$STAGING_DIR")" = "$PS_ROOT" ]; then
        PS_ENV="staging"; PS_ENV_SOURCE="STAGING_DIR"
    else
        PS_ENV="production"; PS_ENV_SOURCE="nicht konfiguriert → Production (maximale Vorsicht)"
    fi
}

# Ensure a token for env-check.php exists (generated & appended to .env if missing)
ensure_env_check_token() {
    if [ -n "${ENV_CHECK_TOKEN:-}" ]; then return 0; fi
    ENV_CHECK_TOKEN="$(random_token)"
    if [ -z "$ENV_CHECK_TOKEN" ]; then return 1; fi
    {
        printf '\n# Auto-generated by ps-upgrade.sh (%s): token for helper/env-check.php\n' "$(date '+%Y-%m-%d')"
        printf 'ENV_CHECK_TOKEN=%s\n' "$ENV_CHECK_TOKEN"
    } >> "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null
    info "ENV_CHECK_TOKEN wurde erzeugt und in ${ENV_FILE} gespeichert."
}

acquire_lock() {
    mkdir -p "$PSU_HOME/state" || die "Kann $PSU_HOME/state nicht anlegen."
    PSU_LOCK="$PSU_HOME/state/${PS_ENV}.lock"
    if ! mkdir "$PSU_LOCK" 2>/dev/null; then
        PSU_LOCK=""
        die "Es läuft bereits ein Toolkit-Prozess für '${PS_ENV}' (Lock: $PSU_HOME/state/${PS_ENV}.lock). Falls nicht: Lock-Ordner löschen."
    fi
}

# ------------------------------------------------------------------------------
# PrestaShop configuration (parameters.php) & database
# ------------------------------------------------------------------------------

get_param() {
    local key="$1" file="$2"
    awk -F"'" "/^[[:space:]]*'$key'[[:space:]]*=>/{print \$4; exit}" "$file"
}

load_db_params() {
    local params="$PS_ROOT/app/config/parameters.php"
    [ -f "$params" ] || die "app/config/parameters.php nicht gefunden in $PS_ROOT."
    DB_HOST="$(get_param database_host "$params")"
    DB_PORT="$(get_param database_port "$params")"
    DB_NAME="$(get_param database_name "$params")"
    DB_USER="$(get_param database_user "$params")"
    DB_PASS="$(get_param database_password "$params")"
    DB_PREFIX="$(get_param database_prefix "$params")"
    case "$DB_HOST" in
        *:[0-9]*) DB_PORT="${DB_HOST##*:}"; DB_HOST="${DB_HOST%:*}" ;;
    esac
    [ -n "$DB_NAME" ] || die "Datenbankname konnte nicht aus parameters.php gelesen werden."
    write_db_defaults
}

# Credentials in a private option file (never on the command line / in logs)
write_db_defaults() {
    make_tmp
    DB_DEFAULTS="$PSU_TMP/my.cnf"
    local pass="${DB_PASS//\\/\\\\}"
    pass="${pass//\"/\\\"}"
    {
        printf '[client]\n'
        printf 'host="%s"\n' "${DB_HOST:-localhost}"
        [ -n "$DB_PORT" ] && printf 'port=%s\n' "$DB_PORT"
        printf 'user="%s"\n' "$DB_USER"
        printf 'password="%s"\n' "$pass"
        printf 'default-character-set=utf8mb4\n'
    } > "$DB_DEFAULTS"
    chmod 600 "$DB_DEFAULTS"
}

db_query() {
    "$MYSQL_BIN" --defaults-extra-file="$DB_DEFAULTS" -N -B "$DB_NAME" -e "$1"
}

db_scalar() { db_query "$1" 2>/dev/null | head -n 1; }

sql_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\'/\'\'}"
}

config_get() {
    db_scalar "SELECT value FROM ${DB_PREFIX}configuration WHERE name='$(sql_escape "$1")' ORDER BY id_shop IS NULL DESC, id_configuration LIMIT 1"
}

# ------------------------------------------------------------------------------
# Detection
# ------------------------------------------------------------------------------

detect_admin_dir() {
    if [ -n "${ADMIN_DIR:-}" ]; then
        [ -d "$PS_ROOT/$ADMIN_DIR" ] || die "ADMIN_DIR '$ADMIN_DIR' existiert nicht in $PS_ROOT."
        return 0
    fi
    local d found=()
    for d in "$PS_ROOT"/*/; do
        d="${d%/}"
        if [ -f "$d/index.php" ] && [ -d "$d/themes/new-theme" ]; then
            found+=("${d##*/}")
        fi
    done
    if [ "${#found[@]}" -eq 1 ]; then
        ADMIN_DIR="${found[0]}"
    elif [ "${#found[@]}" -gt 1 ]; then
        die "Mehrere Admin-Ordner gefunden (${found[*]}). Bitte ADMIN_DIR in der .env setzen."
    else
        die "Admin-Ordner nicht gefunden. Bitte ADMIN_DIR in der .env setzen."
    fi
}

detect_ps_version() {
    local f v=""
    for f in "$PS_ROOT/src/Core/Version.php" "$PS_ROOT/app/AppKernel.php"; do
        if [ -f "$f" ]; then
            v="$(sed -n "s/.*const VERSION = '\([0-9][^']*\)'.*/\1/p" "$f" | head -n 1)"
            [ -n "$v" ] && break
        fi
    done
    if [ -z "$v" ] && [ -f "$PS_ROOT/config/settings.inc.php" ]; then
        v="$(sed -n "s/.*_PS_VERSION_'[^']*'\([0-9][^']*\)'.*/\1/p" "$PS_ROOT/config/settings.inc.php" | head -n 1)"
    fi
    PS_VERSION="$v"
    [ -n "$PS_VERSION" ] || die "PrestaShop-Version konnte nicht ermittelt werden."
}

detect_shop() {
    PS_VERSION_DB="$(config_get PS_VERSION_DB)"
    local default_shop
    default_shop="$(config_get PS_SHOP_DEFAULT)"
    default_shop="${default_shop:-1}"
    SHOP_ID="$default_shop"
    local domain="" uri=""
    IFS=$'\t' read -r domain uri < <(db_query "SELECT domain_ssl, physical_uri FROM ${DB_PREFIX}shop_url WHERE id_shop=${SHOP_ID} AND main=1 ORDER BY active DESC LIMIT 1" 2>/dev/null)
    SHOP_DOMAIN="$domain"
    [ -n "$uri" ] || uri="/"
    local ssl
    ssl="$(config_get PS_SSL_ENABLED)"
    if [ "$ssl" = "0" ]; then SHOP_SCHEME="http"; else SHOP_SCHEME="https"; fi
    SHOP_URL="${SHOP_SCHEME}://${SHOP_DOMAIN}${uri%/}"
    SHOP_COUNT="$(db_scalar "SELECT COUNT(*) FROM ${DB_PREFIX}shop WHERE active=1")"
}

detect_theme() {
    if [ -z "${THEME_NAME:-}" ]; then
        THEME_NAME="$(db_scalar "SELECT theme_name FROM ${DB_PREFIX}shop WHERE id_shop=${SHOP_ID:-1}")"
    fi
    THEME_YML="$PS_ROOT/themes/$THEME_NAME/config/theme.yml"
    if [ -z "$THEME_NAME" ] || [ ! -f "$THEME_YML" ]; then
        warn "Aktives Theme ('${THEME_NAME}') bzw. dessen theme.yml nicht gefunden."
        THEME_PARENT="${THEME_PARENT:-$THEME_NAME}"
        return 0
    fi
    local k v child_parent=""
    while IFS='=' read -r k v; do
        [ "$k" = "parent" ] && child_parent="$v"
        [ "$k" = "version" ] && THEME_VERSION="$v"
    done < <(tool theme-info "$THEME_YML")
    THEME_PARENT="${THEME_PARENT:-${child_parent:-$THEME_NAME}}"
    PARENT_YML="$PS_ROOT/themes/$THEME_PARENT/config/theme.yml"
    PARENT_VERSION=""; PARENT_FROM=""; PARENT_TO=""; PARENT_MODULES=""
    if [ -f "$PARENT_YML" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                version) PARENT_VERSION="$v" ;;
                from) PARENT_FROM="$v" ;;
                to) PARENT_TO="$v" ;;
                modules) PARENT_MODULES="$v" ;;
            esac
        done < <(tool theme-info "$PARENT_YML")
    fi
    if [ -n "${THEME_MODULES:-}" ]; then
        # explicit list or glob(s), e.g. "iqit*"
        local pattern list="" dir
        for pattern in $THEME_MODULES; do
            for dir in "$PS_ROOT"/modules/$pattern; do
                [ -d "$dir" ] && list="$list ${dir##*/}"
            done
        done
        PARENT_MODULES="${list# }"
    fi
}

# ------------------------------------------------------------------------------
# PHP detection (CLI binaries vs. web PHP)
# ------------------------------------------------------------------------------

php_candidates() {
    local seen=" " d f base real
    local dirs=()
    local IFS=':'
    for d in $PATH; do dirs+=("$d"); done
    unset IFS
    dirs+=(/usr/bin /usr/local/bin)
    for d in /usr/local/php*/bin /opt/php*/bin /opt/alt/php*/usr/bin; do
        [ -d "$d" ] && dirs+=("$d")
    done
    for d in "${dirs[@]}"; do
        for f in "$d"/php*; do
            [ -f "$f" ] && [ -x "$f" ] || continue
            base="${f##*/}"
            case "$base" in
                php-config*|phpize*|php-cgi*|php-fpm*|phpdbg*|*.ini|*.so) continue ;;
            esac
            real="$(phys_path "$f")"
            case "$seen" in *" $real "*) continue ;; esac
            seen="$seen$real "
            printf '%s\n' "$f"
        done
    done
}

# Determine TOOL_PHP early (any working PHP with zip + tokenizer + json)
detect_tool_php() {
    if [ -n "${PHP_BIN:-}" ] && [ -x "$PHP_BIN" ]; then TOOL_PHP="$PHP_BIN"; return 0; fi
    local f
    while IFS= read -r f; do
        if "$f" -r 'exit(class_exists("ZipArchive") && function_exists("token_get_all") && function_exists("json_decode") ? 0 : 1);' >/dev/null 2>&1; then
            TOOL_PHP="$f"
            return 0
        fi
    done < <(php_candidates)
    die "Kein PHP-CLI mit den Extensions zip/tokenizer/json gefunden."
}

# Query helper/env-check.php through the web server
web_env_check() {
    WEB_ENV_JSON=""
    WEB_PHP_DETECTED=""
    WEB_REMOTE_IP=""
    [ -n "${SHOP_URL:-}" ] || return 1
    ensure_env_check_token || return 1
    make_tmp
    local url="${SHOP_URL}/${PSU_REL}/env-check.php?token=${ENV_CHECK_TOKEN}"
    local out="$PSU_TMP/env-check.json" code
    code="$(curl -sS -k -L --max-time 30 -o "$out" -w '%{http_code}' "$url" 2>/dev/null)"
    if [ "$code" = "200" ] && tool json-get "$out" php_version >/dev/null 2>&1; then
        WEB_ENV_JSON="$out"
        WEB_PHP_DETECTED="$(tool json-get "$out" php_version)"
        WEB_REMOTE_IP="$(tool json-get "$out" remote_ip 2>/dev/null)"
        return 0
    fi
    WEB_ENV_ERROR="HTTP ${code:-?} von ${SHOP_URL}/${PSU_REL}/env-check.php"
    return 1
}

# Select the PHP binary matching the web PHP version (major.minor)
select_php() {
    PHP_SELECTED=""
    PHP_SELECTED_VERSION=""
    WEB_PHP_VERSION_USED=""
    PHP_TABLE=()

    if web_env_check; then
        WEB_PHP_VERSION_USED="$WEB_PHP_DETECTED"
        WEB_PHP_SOURCE="env-check.php"
    elif [ -n "${WEB_PHP_VERSION:-}" ]; then
        WEB_PHP_VERSION_USED="$WEB_PHP_VERSION"
        WEB_PHP_SOURCE=".env (WEB_PHP_VERSION)"
        warn "Web-PHP-Check nicht erreichbar (${WEB_ENV_ERROR:-?}) – nutze WEB_PHP_VERSION=${WEB_PHP_VERSION} aus der .env."
    else
        warn "Web-PHP-Check nicht erreichbar (${WEB_ENV_ERROR:-?})."
        if [ -t 0 ] && [ "${OPT_YES:-0}" != "1" ]; then
            read -r -p "Welche PHP-Version nutzt die Website (z.B. 8.2)? " WEB_PHP_VERSION_USED
            WEB_PHP_SOURCE="manuelle Eingabe"
        fi
    fi
    local web_mm=""
    [ -n "$WEB_PHP_VERSION_USED" ] && web_mm="$(ver_minor "$WEB_PHP_VERSION_USED")"

    local f v best="" best_v=""
    while IFS= read -r f; do
        v="$("$f" -r 'echo PHP_VERSION;' 2>/dev/null)"
        [ -n "$v" ] || continue
        PHP_TABLE+=("$f|$v")
        if [ -n "$web_mm" ] && [ "$(ver_minor "$v")" = "$web_mm" ]; then
            if [ -z "$best" ] || vercmp "$v" '>' "$best_v"; then best="$f"; best_v="$v"; fi
        fi
    done < <(php_candidates)

    if [ -n "${PHP_BIN:-}" ]; then
        PHP_SELECTED="$PHP_BIN"
        PHP_SELECTED_VERSION="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)"
        PHP_SELECT_SOURCE=".env (PHP_BIN)"
    elif [ -n "$best" ]; then
        PHP_SELECTED="$best"
        PHP_SELECTED_VERSION="$best_v"
        PHP_SELECT_SOURCE="automatisch (passt zu Web-PHP ${web_mm})"
    fi
    if [ -n "$PHP_SELECTED" ]; then TOOL_PHP="$PHP_SELECTED"; fi
}

print_php_table() {
    local row f v mark web_mm=""
    [ -n "$WEB_PHP_VERSION_USED" ] && web_mm="$(ver_minor "$WEB_PHP_VERSION_USED")"
    for row in "${PHP_TABLE[@]}"; do
        f="${row%%|*}"; v="${row#*|}"; mark=""
        if [ "$f" = "$PHP_SELECTED" ]; then mark="← gewählt"
        elif [ -n "$web_mm" ] && [ "$(ver_minor "$v")" = "$web_mm" ]; then mark="(passt)"
        fi
        printf '   %-34s %-10s %s\n' "$f" "$v" "$mark"
        rep "    $f  $v  $mark"
    done
}

# ------------------------------------------------------------------------------
# Fail-safes
# ------------------------------------------------------------------------------

failsafe_checks() {
    if [ "$PS_ENV" = "staging" ]; then
        if [ -n "${PROD_DIR:-}" ]; then
            local prod_phys prod_db
            prod_phys="$(phys_path "$PROD_DIR")"
            [ "$prod_phys" != "$PS_ROOT" ] || die "STAGING und PROD zeigen auf denselben Pfad ($PS_ROOT)."
            if [ -f "$prod_phys/app/config/parameters.php" ]; then
                prod_db="$(get_param database_name "$prod_phys/app/config/parameters.php")"
                [ "$prod_db" != "$DB_NAME" ] || die "Die Staging-Datenbank ('$DB_NAME') ist identisch mit der Production-Datenbank! Abbruch."
            fi
        fi
        if [ -n "${STAGING_DB_MUST_CONTAIN:-}" ]; then
            case "$(printf '%s' "$DB_NAME" | tr '[:upper:]' '[:lower:]')" in
                *"$(printf '%s' "$STAGING_DB_MUST_CONTAIN" | tr '[:upper:]' '[:lower:]')"*) ;;
                *) die "Staging-Datenbank '$DB_NAME' enthält nicht '$STAGING_DB_MUST_CONTAIN' (STAGING_DB_MUST_CONTAIN). Abbruch." ;;
            esac
        fi
    fi
}

# Fail fast: destructive actions on production need --production (dry-runs are allowed)
require_production_flag() {
    [ "$PS_ENV" = "production" ] || return 0
    [ "${OPT_DRY_RUN:-0}" = "1" ] && return 0
    [ "${OPT_PRODUCTION:-0}" = "1" ] || die "'$1' auf PRODUCTION erfordert die Option --production (oder --dry-run)."
}

# Production guard for destructive actions
require_production_confirmation() {
    local action="$1"
    [ "$PS_ENV" = "production" ] || return 0
    if [ "${OPT_PRODUCTION:-0}" != "1" ]; then
        die "'$action' auf PRODUCTION erfordert die Option --production."
    fi
    local expected="${SHOP_DOMAIN:-production}"
    if [ -n "${OPT_CONFIRM_DOMAIN:-}" ]; then
        [ "$OPT_CONFIRM_DOMAIN" = "$expected" ] || die "--confirm-domain='$OPT_CONFIRM_DOMAIN' passt nicht zu '$expected'."
        warn "PRODUCTION bestätigt per --confirm-domain."
        return 0
    fi
    printf '\n%s%s!!! ACHTUNG: PRODUCTION (%s) – Aktion: %s !!!%s\n' "$RED" "$BOLD" "$expected" "$action" "$NC"
    confirm_word "Zur Bestätigung die Domain eintippen" "$expected" || die "Bestätigung fehlgeschlagen – Abbruch."
}

# ------------------------------------------------------------------------------
# Caches
# ------------------------------------------------------------------------------

clear_caches() {
    local env_dir old pids=()
    for env_dir in prod dev; do
        if [ -d "$PS_ROOT/var/cache/$env_dir" ]; then
            old="$PS_ROOT/var/cache/${env_dir}_old_$(date +%s)"
            if mv "$PS_ROOT/var/cache/$env_dir" "$old" 2>/dev/null; then
                rm -rf "$old" &
                pids+=("$!")
            fi
        fi
    done
    # wait only for our own jobs (a plain "wait" would also wait for the log tee process)
    [ "${#pids[@]}" -gt 0 ] && wait "${pids[@]}" 2>/dev/null
    mkdir -p "$PS_ROOT/var/cache/prod" "$PS_ROOT/var/cache/dev"
    if [ -f "$PS_ROOT/$PSU_REL/reset_opcache.php" ] && [ -n "${SHOP_URL:-}" ]; then
        curl -sS -k -L --max-time 30 -o /dev/null "${SHOP_URL}/${PSU_REL}/reset_opcache.php" 2>/dev/null \
            && detail "OPcache-Reset aufgerufen." || warn "OPcache-Reset nicht erreichbar."
    fi
    ok "Symfony-Cache geleert."
}
