#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# PrestaShop Upgrade Toolkit
#
# Safe, reproducible PrestaShop core upgrades from the CLI:
# checks & reports, backups (without img/), restore, maintenance mode and the
# official Update Assistant (autoupgrade) as upgrade engine.
#
# Usage: ./ps-upgrade.sh <command> [options]    (./ps-upgrade.sh help)
# Docs:  ps-upgrade.md
# Author: Sebastian G. Marinescu
# ------------------------------------------------------------------------------

# Everything lives in functions, so bash parses the whole file before running
# (safe even if the file is replaced while running).

PSU_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$PSU_SOURCE" ]; do
    PSU_LINK_DIR="$(cd -P "$(dirname "$PSU_SOURCE")" && pwd)"
    PSU_SOURCE="$(readlink "$PSU_SOURCE")"
    case "$PSU_SOURCE" in /*) ;; *) PSU_SOURCE="$PSU_LINK_DIR/$PSU_SOURCE" ;; esac
done
PSU_DIR="$(cd -P "$(dirname "$PSU_SOURCE")" && pwd)"

# shellcheck source=lib/ps-common.sh
. "$PSU_DIR/lib/ps-common.sh"
# shellcheck source=lib/ps-releases.sh
. "$PSU_DIR/lib/ps-releases.sh"
# shellcheck source=lib/ps-maintenance.sh
. "$PSU_DIR/lib/ps-maintenance.sh"
# shellcheck source=lib/ps-backup.sh
. "$PSU_DIR/lib/ps-backup.sh"
# shellcheck source=lib/ps-reports.sh
. "$PSU_DIR/lib/ps-reports.sh"

usage() {
    cat <<EOF
${BOLD}PrestaShop Upgrade Toolkit v${PSU_VERSION}${NC}

${BOLD}Verwendung:${NC} $0 <befehl> [optionen]

${BOLD}Befehle:${NC}
  info                    Erkannte Umgebung anzeigen (Pfade, DB, Theme, PHP, ...)
  versions                Verfügbare PrestaShop-Versionen mit Kompatibilitäts-Status
  check                   Vorab-Prüfungen für eine Zielversion (ändert nichts)
  report                  Wie check + Child-Theme-, Theme-Modul- und Paket-Reports
  backup                  Backup erstellen (Dateien ohne img/ + Datenbank)
  list-backups            Backup-Sets anzeigen
  restore [set|latest]    Backup-Set wiederherstellen (Dateien + Datenbank)
  upgrade                 Upgrade durchführen (mit Checks, Backup, Wartung, Tests)
  smoke                   Smoke-Tests (HTTP-Status wichtiger Seiten) ausführen
  maintenance on|off|status   Wartungsmodus steuern
  autoupgrade-update      Update Assistant (autoupgrade) auf die empfohlene Version bringen
  theme-index             Hinterlegte Theme-Pakete (ZIPs) indizieren und anzeigen
  help                    Diese Hilfe

${BOLD}Optionen:${NC}
  --to=<version>          Zielversion: x.y.z | x.y | x | latest | latest-minor | latest-patch
  --all                   Im Menü alle Versionen zeigen (nicht nur die neueste je Linie)
  --include-prerelease    Beta-/RC-Versionen berücksichtigen
  --dry-run               Nur prüfen und anzeigen, nichts verändern
  --yes, -y               Normale Rückfragen automatisch bestätigen
  --production            Pflicht für verändernde Aktionen auf Production
  --confirm-domain=<d>    Domain-Bestätigung für Production ohne Eingabe
  --allow-dirty           Upgrade trotz uncommitteter Git-Änderungen
  --skip-backup           Kein Backup vor dem Upgrade (nur Staging!)
  --git-pre-merge=<ref>   Vor dem Upgrade 'git merge --ff-only <ref>' (z.B. Theme-Commit)
  --no-git                Keine Git-Aktionen (Branch/Commit/Abgleich)
  --theme-old=<zip|ref>   Basis für den Child-Theme-Report (Standard: Git-Commit der installierten Version)
  --theme-new=<zip>       Neues Theme-ZIP (Standard: automatisch aus ${BACKUP_DIR:-<BACKUP_DIR>}/ps-upgrade/themes)
  --set=<name>            Backup-Set für restore
  --refresh               Release-API-Cache ignorieren
  --verbose, -v           Ausführliche Ausgabe

Doku: ${PSU_DIR}/ps-upgrade.md
EOF
}

parse_args() {
    PSU_COMMAND=""
    PSU_POSITIONAL=()
    PSU_ARGS_STR="$*"
    local a
    for a in "$@"; do
        case "$a" in
            --to=*) OPT_TO="${a#*=}" ;;
            --all) OPT_ALL=1 ;;
            --include-prerelease) OPT_INCLUDE_PRE=1 ;;
            --dry-run|-d) OPT_DRY_RUN=1 ;;
            --yes|-y) OPT_YES=1 ;;
            --production) OPT_PRODUCTION=1 ;;
            --confirm-domain=*) OPT_CONFIRM_DOMAIN="${a#*=}" ;;
            --allow-dirty) OPT_ALLOW_DIRTY=1 ;;
            --skip-backup) OPT_SKIP_BACKUP=1 ;;
            --git-pre-merge=*) OPT_PRE_MERGE="${a#*=}" ;;
            --no-git) OPT_NO_GIT=1 ;;
            --theme-old=*) OPT_THEME_OLD="${a#*=}" ;;
            --theme-new=*) OPT_THEME_NEW="${a#*=}" ;;
            --set=*) OPT_SET="${a#*=}" ;;
            --refresh) OPT_REFRESH=1 ;;
            --verbose|-v) OPT_VERBOSE=1 ;;
            --help|-h) PSU_COMMAND="help" ;;
            -*) printf 'Unbekannte Option: %s\n' "$a" >&2; exit 2 ;;
            *) if [ -z "$PSU_COMMAND" ]; then PSU_COMMAND="$a"; else PSU_POSITIONAL+=("$a"); fi ;;
        esac
    done
    PSU_COMMAND="${PSU_COMMAND:-help}"
}

# ------------------------------------------------------------------------------
# Context
# ------------------------------------------------------------------------------

init_context() {
    detect_tool_php
    load_db_params
    failsafe_checks
    detect_admin_dir
    detect_ps_version
    detect_shop
    detect_theme
}

print_context() {
    step "Umgebung"
    printf '  %-22s %s\n' "Umgebung:" "${BOLD}${PS_ENV}${NC} (${PS_ENV_SOURCE})"
    printf '  %-22s %s\n' "Shop-Root:" "$PS_ROOT"
    printf '  %-22s %s\n' "Shop-URL:" "${SHOP_URL:-?}"
    printf '  %-22s %s\n' "PrestaShop:" "${PS_VERSION} (DB: ${PS_VERSION_DB:-?})"
    printf '  %-22s %s\n' "Admin-Ordner:" "$ADMIN_DIR"
    printf '  %-22s %s\n' "Datenbank:" "${DB_NAME} @ ${DB_HOST:-localhost} (Prefix '${DB_PREFIX}')"
    printf '  %-22s %s\n' "Theme:" "${THEME_NAME:-?}${THEME_VERSION:+ $THEME_VERSION} → Parent ${THEME_PARENT:-?} ${PARENT_VERSION:-}"
    printf '  %-22s %s\n' "Theme PS-Bereich:" "${PARENT_FROM:-?} – ${PARENT_TO:-offen}"
    printf '  %-22s %s\n' "Theme-Module:" "$(printf '%s\n' ${PARENT_MODULES:-} | grep -c .) (aus theme.yml / THEME_MODULES)"
    printf '  %-22s %s\n' "Toolkit-Daten:" "$PSU_HOME"
    rep "- Umgebung: ${PS_ENV} | PrestaShop ${PS_VERSION} | Theme ${THEME_NAME} → ${THEME_PARENT} ${PARENT_VERSION} | DB ${DB_NAME}"
}

# ------------------------------------------------------------------------------
# Commands
# ------------------------------------------------------------------------------

cmd_info() {
    print_context
    step "PHP"
    select_php
    print_php_table
    info "  Web-PHP: ${WEB_PHP_VERSION_USED:-?} (${WEB_PHP_SOURCE:-?})${WEB_REMOTE_IP:+ | Server-IP aus Sicht des Webservers: $WEB_REMOTE_IP}"
    step "Update Assistant"
    autoupgrade_versions
    info "  autoupgrade: installiert ${AU_INSTALLED:-–}, empfohlen ${AU_LATEST:-?}"
    step "Wartungsmodus"
    maintenance_status
}

cmd_versions() {
    print_context
    select_php
    step "Verfügbare Versionen"
    OPT_LIST_ONLY=1
    select_target_interactive || true
}

# Shared pre-checks (check / report / upgrade). Returns 1 if no target selected.
run_checks() {
    local mode="$1"
    reset_check_counters
    step "Umgebung & Werkzeuge"
    check_tools
    select_php
    check_php
    check_db
    check_git
    check_autoupgrade

    step "Zielversion"
    determine_target || return 1
    check_target_gate "$TARGET_VERSION"

    step "Release-Paket"
    release_download

    step "Speicherplatz"
    check_disk "$(file_size "$RELEASE_ZIP")"

    step "Update Assistant – Voraussetzungen"
    check_autoupgrade_requirements

    step "Core-Integrität (gegen PrestaShop ${PS_VERSION})"
    check_integrity

    step "Overrides (gegen PrestaShop ${TARGET_VERSION})"
    check_overrides "$(release_core_dir)"

    step "Modul-Kompatibilität"
    check_modules "$TARGET_VERSION" "$RELEASE_XML"

    if [ "$mode" = "report" ]; then
        step "Update Assistant – Module"
        check_autoupgrade_modules
        step "Child-Theme-Overrides (${THEME_NAME} → ${THEME_PARENT})"
        report_child_theme "$(ver_major "$TARGET_VERSION")"
        step "Theme-Module (${THEME_PARENT})"
        report_theme_modules
        step "Theme-Pakete"
        report_theme_package_updates
    fi
    print_check_summary
    return 0
}

cmd_check() {
    local mode="$1"
    report_init "$mode"
    print_context
    run_checks "$mode" || { RUN_RESULT="NO-TARGET"; return 0; }
    if [ "${#CHECK_BLOCKERS[@]}" -gt 0 ]; then
        RUN_RESULT="BLOCKED"
        return 1
    fi
    return 0
}

cmd_backup() {
    report_init backup
    print_context
    step "Speicherplatz"
    check_disk 0
    [ "${#CHECK_BLOCKERS[@]}" -eq 0 ] || die "Backup abgebrochen (Speicherplatz)."
    select_php >/dev/null 2>&1
    step "Backup"
    if [ "${OPT_DRY_RUN:-0}" = "1" ]; then
        info "[Dry-Run] Würde ein Backup nach $PSU_HOME/sets/ schreiben."
        return 0
    fi
    backup_create "${PS_VERSION}-manual"
    ok "Backup fertig: $BACKUP_SET_DIR"
}

cmd_restore() {
    require_production_flag restore
    acquire_lock
    report_init restore
    print_context
    select_php >/dev/null 2>&1
    local set
    set="$(resolve_backup_set "${OPT_SET:-${PSU_POSITIONAL[0]:-latest}}")" || exit 1
    RUN_FROM="$PS_VERSION"
    backup_restore "$set"
    [ "${OPT_DRY_RUN:-0}" = "1" ] && return 0
    step "Smoke-Tests"
    smoke_tests || warn "Smoke-Tests nicht vollständig erfolgreich – bitte manuell prüfen."
    finish_maintenance
}

cmd_list_backups() {
    print_context
    step "Backup-Sets (${PSU_HOME}/sets)"
    backup_list
}

cmd_maintenance() {
    local action="${PSU_POSITIONAL[0]:-status}"
    print_context
    step "Wartungsmodus"
    case "$action" in
        status) maintenance_status ;;
        on)
            require_production_flag "maintenance on"
            require_production_confirmation "maintenance on"
            select_php >/dev/null 2>&1
            maintenance_on
            MAINTENANCE_ACTIVE=0   # intentionally left active, no exit warning
            ;;
        off)
            require_production_flag "maintenance off"
            require_production_confirmation "maintenance off"
            maintenance_off ;;
        *) die "Unbekannte Aktion '$action' (on|off|status)" ;;
    esac
}

cmd_theme_index() {
    print_context
    step "Theme-Pakete in ${PSU_HOME}/themes"
    theme_index_load
    if [ "${#THEME_INDEX[@]}" -eq 0 ]; then
        info "Keine ZIPs gefunden. ThemeForest-Downloads unverändert nach ${PSU_HOME}/themes/ hochladen."
        return 0
    fi
    printf '  %-7s %-24s %-10s %-18s %s\n' "Typ" "Name" "Version" "PS-Kompatibilität" "Quelle"
    local type n v from to cache src
    while IFS='|' read -r type n v from to cache src; do
        printf '  %-7s %-24s %-10s %-18s %s\n' "$type" "$n" "$v" "${from:-?} – ${to:-offen}" "$src"
    done < <(theme_index_entries)
}

cmd_autoupgrade_update() {
    require_production_flag autoupgrade-update
    print_context
    step "Update Assistant (autoupgrade)"
    autoupgrade_versions
    info "Installiert: ${AU_INSTALLED:-–} | empfohlen: ${AU_LATEST:-?}"
    [ -n "$AU_LINK" ] || die "Keine Download-Information von der API erhalten."
    if [ -n "$AU_INSTALLED" ] && ! vercmp "$AU_INSTALLED" '<' "$AU_LATEST"; then
        ok "autoupgrade ist aktuell."
        return 0
    fi
    require_production_confirmation "autoupgrade-update"
    [ "${OPT_DRY_RUN:-0}" = "1" ] && { info "[Dry-Run] Würde autoupgrade ${AU_LATEST} installieren."; return 0; }
    confirm "autoupgrade ${AU_LATEST} jetzt nach modules/autoupgrade installieren?" || die "Abgebrochen."
    local zip="$PSU_HOME/releases/autoupgrade-v${AU_LATEST}.zip"
    mkdir -p "$PSU_HOME/releases"
    [ -s "$zip" ] || download_file "$AU_LINK" "$zip" || die "Download fehlgeschlagen: $AU_LINK"
    if [ -n "$AU_MD5" ] && [ "$(file_md5 "$zip")" != "$AU_MD5" ]; then
        rm -f "$zip"; die "MD5 von autoupgrade-v${AU_LATEST}.zip stimmt nicht."
    fi
    make_tmp
    tool zip-extract "$zip" "$PSU_TMP/au" || die "Entpacken fehlgeschlagen."
    [ -f "$PSU_TMP/au/autoupgrade/autoupgrade.php" ] || die "Unerwarteter ZIP-Aufbau (autoupgrade/autoupgrade.php fehlt)."
    if [ -d "$PS_ROOT/modules/autoupgrade" ]; then
        local bak
        bak="$PSU_HOME/tmp/autoupgrade-${AU_INSTALLED:-old}-$(date +%Y%m%d-%H%M%S).tar.gz"
        mkdir -p "$PSU_HOME/tmp"
        tar -czf "$bak" -C "$PS_ROOT/modules" autoupgrade && detail "Alte Version gesichert: $bak"
    fi
    rsync -a --delete "$PSU_TMP/au/autoupgrade/" "$PS_ROOT/modules/autoupgrade/" || die "Kopieren fehlgeschlagen."
    ok "autoupgrade ${AU_LATEST} installiert. (Änderung in Git committen!)"
}

# ------------------------------------------------------------------------------
# Smoke tests & error logs
# ------------------------------------------------------------------------------

smoke_url() {
    local name="$1" url="$2" body="$PSU_TMP/smoke.html" code auth=()
    [ -n "${SMOKE_HTTP_AUTH:-}" ] && auth=(-u "$SMOKE_HTTP_AUTH")
    code="$(curl -sS -k -L --max-time 90 "${auth[@]}" -o "$body" -w '%{http_code}' "$url" 2>/dev/null)"
    if grep -qiE 'Fatal error|Uncaught (Error|Exception)|Parse error|Whoops, looks like' "$body" 2>/dev/null; then
        status "⛔" "${name}: HTTP ${code} – PHP-Fehler im Seiteninhalt (${url})" 1
        return 1
    fi
    case "$code" in
        2??|3??) status "✅" "${name}: HTTP ${code}"; return 0 ;;
        401) status "⚠️" "${name}: HTTP 401 (Basic-Auth – SMOKE_HTTP_AUTH in der .env setzen) – übersprungen" 1; return 2 ;;
        503) status "⚠️" "${name}: HTTP 503 (Wartungsmodus – IP nicht freigegeben?)" 1; return 2 ;;
        *) status "⛔" "${name}: HTTP ${code:-000} (${url})" 1; return 1 ;;
    esac
}

smoke_tests() {
    make_tmp
    local fail=0 pid cid
    pid="$(db_scalar "SELECT p.id_product FROM ${DB_PREFIX}product p JOIN ${DB_PREFIX}product_shop s ON s.id_product=p.id_product AND s.id_shop=${SHOP_ID:-1} WHERE s.active=1 AND s.visibility IN ('both','catalog') ORDER BY p.id_product DESC LIMIT 1")"
    cid="$(db_scalar "SELECT c.id_category FROM ${DB_PREFIX}category c JOIN ${DB_PREFIX}category_shop s ON s.id_category=c.id_category AND s.id_shop=${SHOP_ID:-1} WHERE c.active=1 AND c.level_depth>=2 ORDER BY c.level_depth, c.id_category LIMIT 1")"
    smoke_url "Startseite" "${SHOP_URL}/" || [ $? -eq 2 ] || fail=1
    [ -n "$cid" ] && { smoke_url "Kategorie #$cid" "${SHOP_URL}/index.php?controller=category&id_category=${cid}" || [ $? -eq 2 ] || fail=1; }
    [ -n "$pid" ] && { smoke_url "Produkt #$pid" "${SHOP_URL}/index.php?controller=product&id_product=${pid}" || [ $? -eq 2 ] || fail=1; }
    smoke_url "Warenkorb" "${SHOP_URL}/index.php?controller=cart&action=show" || [ $? -eq 2 ] || fail=1
    smoke_url "Admin-Login" "${SHOP_URL}/${ADMIN_DIR}/index.php?controller=AdminLogin" || [ $? -eq 2 ] || fail=1
    return "$fail"
}

# Remember current sizes of log files (to show only NEW errors afterwards)
log_marker_save() {
    make_tmp
    LOG_MARKER="$PSU_TMP/logsizes"
    : > "$LOG_MARKER"
    local f
    for f in "$PS_ROOT"/var/logs/*.log "$PS_ROOT/error_log" "$PS_ROOT/$ADMIN_DIR/error_log"; do
        [ -f "$f" ] && printf '%s|%s\n' "$f" "$(file_size "$f")" >> "$LOG_MARKER"
    done
}

log_marker_report() {
    local f size new hits=0 old
    for f in "$PS_ROOT"/var/logs/*.log "$PS_ROOT/error_log" "$PS_ROOT/$ADMIN_DIR/error_log"; do
        [ -f "$f" ] || continue
        old="$(grep -F "$f|" "$LOG_MARKER" 2>/dev/null | tail -n 1 | cut -d'|' -f2)"
        size="${old:-0}"
        new="$(tail -c +"$((size + 1))" "$f" 2>/dev/null | grep -iE 'CRITICAL|Fatal|Parse error|Uncaught' | tail -n 10)"
        if [ -n "$new" ]; then
            hits=1
            status "⚠️" "Neue Fehler in ${f#"$PS_ROOT"/}:" 1
            printf '%s\n' "$new" | cut -c1-300 | sed 's/^/     /'
        fi
    done
    [ "$hits" = "1" ] && return 1
    passed "Keine neuen kritischen Einträge in den Logdateien"
    return 0
}

finish_maintenance() {
    [ "$MAINTENANCE_ACTIVE" = "1" ] || [ -f "$(maintenance_state_file)" ] || return 0
    step "Wartungsmodus"
    if confirm "Wartungsmodus jetzt beenden (Originalwerte wiederherstellen)?"; then
        maintenance_off
    else
        warn "Wartungsmodus bleibt aktiv. Beenden mit: $0 maintenance off${PS_ENV:+ $( [ "$PS_ENV" = production ] && echo --production)}"
        MAINTENANCE_ACTIVE=0
    fi
}

# ------------------------------------------------------------------------------
# Git helpers for the upgrade
# ------------------------------------------------------------------------------

git_enabled() {
    [ "${OPT_NO_GIT:-0}" != "1" ] && have git && [ -e "$PS_ROOT/.git" ]
}

git_exclude_pathspec() {
    local p
    for p in $GIT_COMPARE_EXCLUDE; do printf ':(exclude)%s\n' "$p"; done
}

git_reapply_assume_unchanged() {
    local f
    for f in $1; do git -C "$PS_ROOT" update-index --assume-unchanged "$f" 2>/dev/null; done
}

git_prepare_branch() {
    UPGRADE_BRANCH="${UPGRADE_BRANCH_PREFIX}${TARGET_VERSION}"
    git_info
    GIT_ASSUME_BEFORE="$GIT_ASSUME"
    GIT_BRANCH_BEFORE="$GIT_BRANCH"
    if [ -n "${OPT_PRE_MERGE:-}" ]; then
        info "Git: merge --ff-only ${OPT_PRE_MERGE} ..."
        git -C "$PS_ROOT" merge --ff-only "$OPT_PRE_MERGE" || die "git merge --ff-only ${OPT_PRE_MERGE} fehlgeschlagen."
        git_reapply_assume_unchanged "$GIT_ASSUME_BEFORE"
    fi
    [ "$PS_ENV" = "production" ] && return 0
    if [ "$GIT_BRANCH" = "$UPGRADE_BRANCH" ]; then
        info "Git: bereits auf Branch '${UPGRADE_BRANCH}'."
    elif git -C "$PS_ROOT" rev-parse --verify -q "refs/heads/$UPGRADE_BRANCH" >/dev/null; then
        if confirm "Branch '${UPGRADE_BRANCH}' existiert bereits – auf den aktuellen Stand (${GIT_HEAD:0:10}) zurücksetzen und auschecken?"; then
            git -C "$PS_ROOT" checkout -q -B "$UPGRADE_BRANCH" || die "git checkout -B fehlgeschlagen."
        else
            die "Abgebrochen (Branch existiert)."
        fi
    else
        git -C "$PS_ROOT" checkout -q -b "$UPGRADE_BRANCH" || die "git checkout -b fehlgeschlagen."
    fi
    git_reapply_assume_unchanged "$GIT_ASSUME_BEFORE"
    ok "Git: Branch '${UPGRADE_BRANCH}' (von '${GIT_BRANCH_BEFORE}' @ ${GIT_HEAD:0:10})"
}

git_after_upgrade_staging() {
    local changes
    changes="$(git -C "$PS_ROOT" status --porcelain --ignore-submodules=all | wc -l | tr -d ' ')"
    info "Git: ${changes} geänderte/neue/gelöschte Dateien durch das Upgrade."
    git -C "$PS_ROOT" status --short --ignore-submodules=all | head -n 25 | sed 's/^/     /'
    [ "$changes" -gt 25 ] && detail "     … (vollständig: git status)"
    [ "$changes" -gt 0 ] || return 0
    if [ "${OPT_ALLOW_DIRTY:-0}" = "1" ]; then
        warn "--allow-dirty aktiv: kein automatischer Commit (fremde Änderungen möglich). Bitte manuell committen."
        return 0
    fi
    if confirm "Upgrade-Ergebnis auf Branch '${UPGRADE_BRANCH}' committen?"; then
        git -C "$PS_ROOT" add -A && \
            git -C "$PS_ROOT" commit -q -m "Upgrade PrestaShop ${RUN_FROM} → ${TARGET_VERSION}" -m "Created by ps-upgrade.sh (release SHA256 ${RELEASE_ZIP_SHA256:-?})" \
            && ok "Commit erstellt: $(git -C "$PS_ROOT" rev-parse --short HEAD)" || warn "Commit fehlgeschlagen."
        git_reapply_assume_unchanged "$GIT_ASSUME_BEFORE"
        if confirm "Branch '${UPGRADE_BRANCH}' nach origin pushen?"; then
            git -C "$PS_ROOT" push -u origin "$UPGRADE_BRANCH" && ok "Gepusht." || warn "Push fehlgeschlagen."
        fi
    fi
}

git_after_upgrade_production() {
    local ref="origin/${UPGRADE_BRANCH_PREFIX}${TARGET_VERSION}"
    git -C "$PS_ROOT" fetch -q origin 2>/dev/null || warn "git fetch fehlgeschlagen."
    if ! git -C "$PS_ROOT" rev-parse --verify -q "$ref" >/dev/null; then
        warn "Kein getesteter Branch '${ref}' gefunden – kein Abgleich mit Staging möglich."
        return 0
    fi
    local idx excludes=() diff
    make_tmp
    idx="$PSU_TMP/git-index"
    while IFS= read -r p; do excludes+=("$p"); done < <(git_exclude_pathspec)
    GIT_INDEX_FILE="$idx" git -C "$PS_ROOT" read-tree HEAD
    GIT_INDEX_FILE="$idx" git -C "$PS_ROOT" add -A -- . "${excludes[@]}" 2>/dev/null
    diff="$(GIT_INDEX_FILE="$idx" git -C "$PS_ROOT" diff --cached --name-status "$ref" -- . "${excludes[@]}" 2>/dev/null)"
    if [ -n "$diff" ]; then
        warning "Production weicht vom getesteten Staging-Branch ${ref} ab ($(printf '%s\n' "$diff" | wc -l | tr -d ' ') Dateien):"
        printf '%s\n' "$diff" | head -n 40 | sed 's/^/     /'
        info "Git wurde NICHT verändert. Bitte die Unterschiede prüfen."
        return 0
    fi
    ok "Production ist identisch mit dem getesteten Branch ${ref} (ohne: ${GIT_COMPARE_EXCLUDE})."
    if git -C "$PS_ROOT" merge-base --is-ancestor HEAD "$ref"; then
        if confirm "Branch '${GIT_BRANCH_BEFORE}' per Fast-Forward auf ${ref} setzen (Arbeitsdateien bleiben unverändert)?"; then
            git -C "$PS_ROOT" reset -q --mixed "$ref" && ok "Git: ${GIT_BRANCH_BEFORE} → $(git -C "$PS_ROOT" rev-parse --short HEAD)"
            git_reapply_assume_unchanged "$GIT_ASSUME_BEFORE"
            if confirm "'${GIT_BRANCH_BEFORE}' nach origin pushen?"; then
                git -C "$PS_ROOT" push origin "HEAD:${GIT_BRANCH_BEFORE}" && ok "Gepusht." || warn "Push fehlgeschlagen."
            fi
        fi
    else
        warn "${ref} ist kein Nachfolger von HEAD – bitte manuell mergen."
    fi
}

# ------------------------------------------------------------------------------
# Upgrade
# ------------------------------------------------------------------------------

cmd_upgrade() {
    require_production_flag upgrade
    report_init upgrade
    print_context
    acquire_lock
    run_checks upgrade || { RUN_RESULT="NO-TARGET"; return 0; }

    if [ "${#CHECK_BLOCKERS[@]}" -gt 0 ]; then
        err "Upgrade abgebrochen: ${#CHECK_BLOCKERS[@]} Blocker (siehe Zusammenfassung)."
        RUN_RESULT="BLOCKED"
        exit 1
    fi

    step "Plan"
    info "  ${BOLD}${PS_ENV}${NC}: PrestaShop ${PS_VERSION} → ${BOLD}${TARGET_VERSION}${NC} (${REL_DIST}${REL_DISTVER:+ $REL_DISTVER})"
    info "  PHP-CLI: ${PHP_SELECTED} (${PHP_SELECTED_VERSION})"
    info "  1. Wartungsmodus an   2. Backup$([ "${OPT_SKIP_BACKUP:-0}" = "1" ] && echo ' (ÜBERSPRUNGEN)')   3. Git-Snapshot/Branch"
    info "  4. Update Assistant (lokales ZIP, Mails/Overrides/Module unverändert)   5. Nacharbeiten + Smoke-Tests"
    if [ "${OPT_DRY_RUN:-0}" = "1" ]; then
        ok "[Dry-Run] Prüfungen abgeschlossen – es wurde nichts verändert."
        RUN_RESULT="DRY-RUN"
        return 0
    fi

    if [ "${#CHECK_CRITICAL[@]}" -gt 0 ]; then
        confirm_word "Es gibt ${#CHECK_CRITICAL[@]} kritische Punkte. Trotzdem fortfahren?" "JA" || die "Abgebrochen."
    elif [ "${#CHECK_WARNINGS[@]}" -gt 0 ]; then
        confirm "Es gibt ${#CHECK_WARNINGS[@]} Warnungen. Upgrade trotzdem starten?" || die "Abgebrochen."
    else
        confirm "Upgrade ${PS_VERSION} → ${TARGET_VERSION} jetzt starten?" || die "Abgebrochen."
    fi
    require_production_confirmation "upgrade ${PS_VERSION} → ${TARGET_VERSION}"
    if [ "${OPT_SKIP_BACKUP:-0}" = "1" ] && [ "$PS_ENV" = "production" ]; then
        die "--skip-backup ist auf Production nicht erlaubt."
    fi

    # 1. Maintenance
    step "1. Wartungsmodus"
    maintenance_on

    # 2. Backup
    step "2. Backup"
    BACKUP_SET_DIR=""
    if [ "${OPT_SKIP_BACKUP:-0}" = "1" ]; then
        warn "Backup übersprungen (--skip-backup)."
    else
        backup_create "${PS_VERSION}-to-${TARGET_VERSION}"
    fi

    # 3. Git
    step "3. Git"
    if git_enabled; then git_prepare_branch; else info "Git übersprungen."; fi

    # Snapshots for the post-checks
    make_tmp
    mkdir -p "$PSU_TMP/preserve"
    local f
    for f in $UPGRADE_PRESERVE_FILES; do
        if [ -f "$PS_ROOT/$f" ]; then
            mkdir -p "$PSU_TMP/preserve/$(dirname "$f")"
            cp -p "$PS_ROOT/$f" "$PSU_TMP/preserve/$f"
        fi
    done
    db_query "SELECT name, version, active FROM ${DB_PREFIX}module ORDER BY name" > "$PSU_TMP/modules-before.tsv" 2>/dev/null
    log_marker_save

    # 4. Update Assistant
    step "4. Update Assistant: ${PS_VERSION} → ${TARGET_VERSION}"
    autoupgrade_stage_release
    local rc t0
    t0="$(date +%s)"
    autoupgrade_console update:start --channel=local --zip="$REL_ZIP_NAME" --xml="$REL_XML_NAME" \
        --disable-non-native-modules=0 --uninstall-incompatible-modules=0 \
        --regenerate-email-templates=0 --disable-all-overrides=0 "$ADMIN_DIR"
    rc=$?
    info "Update Assistant beendet mit Code ${rc} nach $(( $(date +%s) - t0 ))s."
    local failed=0
    [ "$rc" -eq 0 ] || { err "Der Update Assistant meldet einen Fehler (Code $rc)."; failed=1; }

    # 5. Post-processing
    step "5. Nacharbeiten"
    for f in $UPGRADE_PRESERVE_FILES; do
        [ -f "$PSU_TMP/preserve/$f" ] || continue
        if [ ! -f "$PS_ROOT/$f" ] || ! cmp -s "$PSU_TMP/preserve/$f" "$PS_ROOT/$f"; then
            if [ -f "$PS_ROOT/$f" ]; then
                cp -p "$PS_ROOT/$f" "$PSU_HOME/logs/${RUN_STAMP}_${f//\//_}.after-upgrade"
                diff -u "$PSU_TMP/preserve/$f" "$PS_ROOT/$f" | head -n 40 | sed 's/^/     /'
            fi
            cp -p "$PSU_TMP/preserve/$f" "$PS_ROOT/$f"
            warn "${f} wurde vom Upgrade verändert → ursprüngliche Version wiederhergestellt (neue Fassung: logs/${RUN_STAMP}_${f//\//_}.after-upgrade)."
        fi
    done
    clear_caches

    step "6. Prüfungen nach dem Upgrade"
    detect_ps_version
    PS_VERSION_DB="$(config_get PS_VERSION_DB)"
    if [ "$PS_VERSION" = "$TARGET_VERSION" ]; then passed "Dateien: PrestaShop ${PS_VERSION}"; else status "⛔" "Dateien: PrestaShop ${PS_VERSION} (erwartet ${TARGET_VERSION})" 1; failed=1; fi
    if [ "$PS_VERSION_DB" = "$TARGET_VERSION" ]; then passed "Datenbank: PS_VERSION_DB ${PS_VERSION_DB}"; else status "⛔" "Datenbank: PS_VERSION_DB ${PS_VERSION_DB} (erwartet ${TARGET_VERSION})" 1; failed=1; fi
    smoke_tests || failed=1
    log_marker_report || true
    db_query "SELECT name, version, active FROM ${DB_PREFIX}module ORDER BY name" > "$PSU_TMP/modules-after.tsv" 2>/dev/null
    local moddiff
    moddiff="$(diff "$PSU_TMP/modules-before.tsv" "$PSU_TMP/modules-after.tsv" | grep -E '^[<>]' )"
    if [ -n "$moddiff" ]; then
        info "Modul-Änderungen in der Datenbank (< vorher, > nachher):"
        printf '%s\n' "$moddiff" | sed 's/^/     /'
        rep '```text'; printf '%s\n' "$moddiff" >> "$REPORT_FILE"; rep '```'
    fi

    if [ "$failed" = "1" ]; then
        RUN_RESULT="FAILED"
        err "Das Upgrade ist NICHT sauber durchgelaufen. Der Shop bleibt im Wartungsmodus."
        if [ -n "$BACKUP_SET_DIR" ] && confirm "Jetzt automatisch auf das Backup ${BACKUP_SET_DIR##*/} zurücksetzen?"; then
            OPT_YES_SAVED="${OPT_YES:-0}"; OPT_YES=1
            backup_restore "$BACKUP_SET_DIR"
            OPT_YES="$OPT_YES_SAVED"
            smoke_tests || true
            RUN_RESULT="RESTORED"
            finish_maintenance
            return 1
        fi
        info "Manueller Restore später: $0 restore ${BACKUP_SET_DIR##*/}${PS_ENV:+ $( [ "$PS_ENV" = production ] && echo --production)}"
        MAINTENANCE_ACTIVE=1
        return 1
    fi
    ok "Upgrade auf PrestaShop ${TARGET_VERSION} erfolgreich."

    step "7. Git"
    if git_enabled; then
        if [ "$PS_ENV" = "production" ]; then git_after_upgrade_production; else git_after_upgrade_staging; fi
    fi

    step "Nächste Schritte"
    info "  • Shop im Browser testen (Checkout, Zahlarten, Konfiguratoren, Mails, PDFs, Back-Office)"
    info "  • Report abarbeiten: ${REPORT_FILE}"
    [ "$PS_ENV" != "production" ] && info "  • Danach auf Production: $0 upgrade --to=${TARGET_VERSION} --production"
    finish_maintenance
    RUN_RESULT="OK"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    parse_args "$@"
    if [ "$PSU_COMMAND" = "help" ]; then usage; exit 0; fi
    set -o pipefail
    load_env
    trap on_exit EXIT
    trap 'printf "\n"; err "Abbruch durch Benutzer."; RUN_RESULT="ABORTED"; exit 130' INT TERM
    log_init "$PSU_COMMAND"
    init_context
    case "$PSU_COMMAND" in
        info) cmd_info ;;
        versions) cmd_versions ;;
        check) cmd_check check ;;
        report) cmd_check report ;;
        backup) cmd_backup ;;
        list-backups) cmd_list_backups ;;
        restore) cmd_restore ;;
        upgrade) cmd_upgrade ;;
        smoke) print_context; step "Smoke-Tests"; smoke_tests ;;
        maintenance) cmd_maintenance ;;
        autoupgrade-update) cmd_autoupgrade_update ;;
        theme-index) cmd_theme_index ;;
        *) usage; die "Unbekannter Befehl: $PSU_COMMAND" ;;
    esac
}

main "$@"
