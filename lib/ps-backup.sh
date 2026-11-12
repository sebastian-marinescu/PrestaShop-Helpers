#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are shared between the library files
# ------------------------------------------------------------------------------
# PrestaShop Upgrade Toolkit - backup, rotation, listing & restore
#
# A backup set lives in $PSU_HOME/sets/<env>_<date>_<label>/ and contains:
#   files.tar.gz   document root WITHOUT img/, .git, var/cache, var/logs, ...
#   db.sql.gz      full database dump
#   manifest.json  versions, git state, checksums
# ------------------------------------------------------------------------------

# Paths (relative to PS_ROOT) that are never part of a backup / restore
backup_exclude_paths() {
    printf '%s\n' img .git var/cache var/logs var/sessions \
        "$ADMIN_DIR/autoupgrade/backup" "$ADMIN_DIR/autoupgrade/download" \
        "$ADMIN_DIR/autoupgrade/latest" "$ADMIN_DIR/autoupgrade/tmp" \
        "$PSU_REL/backups"
    local p
    for p in ${BACKUP_EXCLUDE_PATHS:-}; do printf '%s\n' "${p#/}"; done
    # never back up the toolkit home if it lies inside the document root
    case "$PSU_HOME/" in "$PS_ROOT"/*) printf '%s\n' "${PSU_HOME#"$PS_ROOT"/}" ;; esac
}

# Size of the document root in KB without the excluded paths (portable du)
root_size_kb() {
    local total=0 s e name
    local excludes
    excludes="$(backup_exclude_paths)"
    for e in "$PS_ROOT"/* "$PS_ROOT"/.[!.]*; do
        [ -e "$e" ] || continue
        name="${e##*/}"
        if printf '%s\n' "$excludes" | grep -qx "$name"; then continue; fi
        s="$(du -sk "$e" 2>/dev/null | awk '{print $1}')"
        total=$((total + ${s:-0}))
    done
    while IFS= read -r e; do
        case "$e" in */*) ;; *) continue ;; esac
        [ -d "$PS_ROOT/$e" ] || continue
        s="$(du -sk "$PS_ROOT/$e" 2>/dev/null | awk '{print $1}')"
        total=$((total - ${s:-0}))
    done <<< "$excludes"
    [ "$total" -lt 0 ] && total=0
    printf '%s' "$total"
}

db_size_kb() {
    db_scalar "SELECT ROUND(IFNULL(SUM(data_length + index_length),0)/1024) FROM information_schema.tables WHERE table_schema=DATABASE()"
}

git_info() {
    GIT_BRANCH=""; GIT_HEAD=""; GIT_DIRTY=""; GIT_ASSUME=""
    [ -d "$PS_ROOT/.git" ] || [ -f "$PS_ROOT/.git" ] || return 0
    have git || return 0
    GIT_BRANCH="$(git -C "$PS_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    GIT_HEAD="$(git -C "$PS_ROOT" rev-parse HEAD 2>/dev/null)"
    GIT_DIRTY="$(git -C "$PS_ROOT" status --porcelain --ignore-submodules=all 2>/dev/null | wc -l | tr -d ' ')"
    GIT_ASSUME="$(git -C "$PS_ROOT" ls-files -v 2>/dev/null | awk '/^[a-z] /{print $2}' | tr '\n' ' ')"
}

# backup_create <label>  -> sets BACKUP_SET_DIR
backup_create() {
    local label="$1"
    local name
    name="${PS_ENV}_$(date +%Y%m%d-%H%M%S)_${label}"
    BACKUP_SET_DIR="$PSU_HOME/sets/$name"
    mkdir -p "$BACKUP_SET_DIR" || die "Kann $BACKUP_SET_DIR nicht anlegen."
    chmod 700 "$BACKUP_SET_DIR" 2>/dev/null

    info "Backup-Set: $BACKUP_SET_DIR"

    # --- Files
    local excludes=() p
    while IFS= read -r p; do
        [ -n "$p" ] && excludes+=("--exclude=./$p")
    done < <(backup_exclude_paths)
    info "Sichere Dateien (ohne: img/, .git, var/cache, var/logs, autoupgrade-Arbeitsordner ...) ..."
    local t0 rc
    t0="$(date +%s)"
    (cd "$PS_ROOT" && tar -czf "$BACKUP_SET_DIR/files.tar.gz" "${excludes[@]}" .)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        if tar -tzf "$BACKUP_SET_DIR/files.tar.gz" >/dev/null 2>&1; then
            warn "tar meldete Warnungen (Code $rc, z.B. Dateien während des Lesens geändert) – Archiv ist lesbar."
        else
            die "Datei-Backup fehlgeschlagen (tar Code $rc)."
        fi
    fi
    ok "Dateien gesichert: $(human_bytes "$(file_size "$BACKUP_SET_DIR/files.tar.gz")") in $(( $(date +%s) - t0 ))s"

    # --- Database
    info "Sichere Datenbank '${DB_NAME}' ..."
    local dump_opts=(--single-transaction --quick --routines --triggers --hex-blob --default-character-set=utf8mb4)
    if "$MYSQLDUMP_BIN" --help 2>/dev/null | grep -q -- '--no-tablespaces'; then dump_opts+=(--no-tablespaces); fi
    t0="$(date +%s)"
    "$MYSQLDUMP_BIN" --defaults-extra-file="$DB_DEFAULTS" "${dump_opts[@]}" "$DB_NAME" | gzip -c > "$BACKUP_SET_DIR/db.sql.gz"
    local s1=${PIPESTATUS[0]} s2=${PIPESTATUS[1]}
    if [ "$s1" -ne 0 ] || [ "$s2" -ne 0 ]; then
        die "Datenbank-Backup fehlgeschlagen (mysqldump=$s1, gzip=$s2)."
    fi
    gzip -t "$BACKUP_SET_DIR/db.sql.gz" || die "Datenbank-Backup ist beschädigt."
    if ! gzip -dc "$BACKUP_SET_DIR/db.sql.gz" | tail -n 5 | grep -q 'Dump completed'; then
        die "Datenbank-Dump ist unvollständig (Abschlussmarke fehlt)."
    fi
    ok "Datenbank gesichert: $(human_bytes "$(file_size "$BACKUP_SET_DIR/db.sql.gz")") in $(( $(date +%s) - t0 ))s"

    # --- Maintenance originals (if the toolkit activated maintenance)
    if [ -f "$(maintenance_state_file)" ]; then
        cp -p "$(maintenance_state_file)" "$BACKUP_SET_DIR/maintenance.state"
    fi

    # --- Manifest
    git_info
    local files_sha db_sha
    files_sha="$(file_sha256 "$BACKUP_SET_DIR/files.tar.gz")"
    db_sha="$(file_sha256 "$BACKUP_SET_DIR/db.sql.gz")"
    tool json-write "$BACKUP_SET_DIR/manifest.json" \
        "set=$name" "toolkit_version=$PSU_VERSION" "created=$(date '+%Y-%m-%d %H:%M:%S')" \
        "env=$PS_ENV" "root=$PS_ROOT" "domain=${SHOP_DOMAIN:-}" "label=$label" \
        "ps_version=$PS_VERSION" "ps_version_db=${PS_VERSION_DB:-}" \
        "php_web=${WEB_PHP_VERSION_USED:-}" "php_cli=${PHP_SELECTED_VERSION:-}" \
        "theme=${THEME_NAME:-}" "theme_parent=${THEME_PARENT:-}" "theme_parent_version=${PARENT_VERSION:-}" \
        "admin_dir=$ADMIN_DIR" "db_name=$DB_NAME" "db_prefix=$DB_PREFIX" \
        "git_branch=$GIT_BRANCH" "git_head=$GIT_HEAD" "git_dirty_files=$GIT_DIRTY" "git_assume_unchanged=$GIT_ASSUME" \
        "maintenance_by_toolkit=$([ -f "$BACKUP_SET_DIR/maintenance.state" ] && echo 1 || echo 0)" \
        "files_sha256=$files_sha" "db_sha256=$db_sha" \
        "files_bytes=$(file_size "$BACKUP_SET_DIR/files.tar.gz")" "db_bytes=$(file_size "$BACKUP_SET_DIR/db.sql.gz")" \
        || die "Manifest konnte nicht geschrieben werden."
    ok "Manifest geschrieben (SHA256 files ${files_sha:0:12}…, db ${db_sha:0:12}…)."
    rep "- Backup-Set: \`$BACKUP_SET_DIR\`"

    backup_rotate
}

# Keep the newest BACKUP_KEEP sets of the current environment (only toolkit sets)
backup_rotate() {
    local sets=() d i=0
    [ -d "$PSU_HOME/sets" ] || return 0
    while IFS= read -r d; do
        [ -f "$d/manifest.json" ] && sets+=("$d")
    done < <(find "$PSU_HOME/sets" -mindepth 1 -maxdepth 1 -type d -name "${PS_ENV}_*" 2>/dev/null | sort -r)
    for d in "${sets[@]}"; do
        i=$((i + 1))
        if [ "$i" -gt "$BACKUP_KEEP" ]; then
            info "Rotation: lösche altes Backup-Set ${d##*/}"
            rm -rf "$d"
        fi
    done
}

backup_list() {
    local d m found=0
    printf '%-46s %-10s %-10s %-10s %-10s\n' "Backup-Set" "PS" "Dateien" "DB" "Git"
    while IFS= read -r d; do
        m="$d/manifest.json"
        [ -f "$m" ] || continue
        found=1
        printf '%-46s %-10s %-10s %-10s %-10s\n' "${d##*/}" \
            "$(tool json-get "$m" ps_version 2>/dev/null)" \
            "$(human_bytes "$(tool json-get "$m" files_bytes 2>/dev/null)")" \
            "$(human_bytes "$(tool json-get "$m" db_bytes 2>/dev/null)")" \
            "$(tool json-get "$m" git_branch 2>/dev/null)"
    done < <(find "$PSU_HOME/sets" -mindepth 1 -maxdepth 1 -type d -name "${OPT_ALL_ENVS:+*}${OPT_ALL_ENVS:-${PS_ENV}_*}" 2>/dev/null | sort -r)
    [ "$found" = "1" ] || info "Keine Backup-Sets für '${PS_ENV}' in $PSU_HOME/sets."
}

resolve_backup_set() {
    local spec="$1" d
    if [ -z "$spec" ] || [ "$spec" = "latest" ]; then
        d="$(find "$PSU_HOME/sets" -mindepth 1 -maxdepth 1 -type d -name "${PS_ENV}_*" 2>/dev/null | sort -r | head -n 1)"
    elif [ -d "$spec" ]; then
        d="$(phys_path "$spec")"
    else
        d="$PSU_HOME/sets/$spec"
    fi
    [ -n "$d" ] && [ -f "$d/manifest.json" ] || die "Backup-Set nicht gefunden: '${spec:-latest}' (siehe: $0 list-backups)"
    printf '%s' "$d"
}

# backup_restore <set-dir>
backup_restore() {
    local set="$1" m="$1/manifest.json"
    local m_env m_root m_db m_branch m_head m_assume m_ps
    m_env="$(tool json-get "$m" env)"
    m_root="$(tool json-get "$m" root)"
    m_db="$(tool json-get "$m" db_name)"
    m_ps="$(tool json-get "$m" ps_version)"
    m_branch="$(tool json-get "$m" git_branch 2>/dev/null)"
    m_head="$(tool json-get "$m" git_head 2>/dev/null)"
    m_assume="$(tool json-get "$m" git_assume_unchanged 2>/dev/null)"

    step "Restore prüfen"
    info "Set:        ${set##*/}"
    info "Erstellt:   $(tool json-get "$m" created)  |  PS ${m_ps}  |  Git ${m_branch} ${m_head:0:10}"
    [ "$m_env" = "$PS_ENV" ] || die "Das Set gehört zur Umgebung '$m_env', aktuell ist '$PS_ENV'. Abbruch."
    [ "$m_db" = "$DB_NAME" ] || die "Das Set gehört zur Datenbank '$m_db', aktuell konfiguriert ist '$DB_NAME'. Abbruch."
    if [ "$m_root" != "$PS_ROOT" ]; then warn "Das Set wurde unter '$m_root' erstellt (aktuell: '$PS_ROOT')."; fi

    info "Prüfe Prüfsummen ..."
    [ "$(file_sha256 "$set/files.tar.gz")" = "$(tool json-get "$m" files_sha256)" ] || die "SHA256 von files.tar.gz stimmt nicht!"
    [ "$(file_sha256 "$set/db.sql.gz")" = "$(tool json-get "$m" db_sha256)" ] || die "SHA256 von db.sql.gz stimmt nicht!"
    ok "Prüfsummen ok."

    require_production_confirmation "restore ${set##*/}"
    if [ "${OPT_DRY_RUN:-0}" = "1" ]; then
        info "[Dry-Run] Würde Dateien (ohne img/) und Datenbank aus ${set##*/} wiederherstellen."
        return 0
    fi
    confirm "Dateien UND Datenbank von '${PS_ENV}' jetzt auf den Stand von ${set##*/} zurücksetzen?" || die "Abgebrochen."

    # Keep original maintenance values of the set (if the current session has none)
    if [ -f "$set/maintenance.state" ] && [ ! -f "$(maintenance_state_file)" ]; then
        mkdir -p "$PSU_HOME/state"
        cp -p "$set/maintenance.state" "$(maintenance_state_file)"
    fi
    step "Wartungsmodus"
    maintenance_on

    step "Dateien wiederherstellen"
    local work="$PSU_HOME/tmp/restore-$$"
    rm -rf "$work"; mkdir -p "$work"
    info "Entpacke Archiv ..."
    tar -xzf "$set/files.tar.gz" -C "$work" || die "Entpacken fehlgeschlagen."

    if [ -n "$m_branch" ] && [ "$m_branch" != "HEAD" ] && have git && [ -e "$PS_ROOT/.git" ]; then
        local cur_branch
        cur_branch="$(git -C "$PS_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        if [ "$cur_branch" != "$m_branch" ]; then
            info "Git: wechsle zurück auf Branch '${m_branch}' ..."
            git -C "$PS_ROOT" checkout -q -f "$m_branch" || warn "Konnte Branch '$m_branch' nicht auschecken."
        fi
        if [ -n "$m_head" ] && [ "$(git -C "$PS_ROOT" rev-parse HEAD 2>/dev/null)" != "$m_head" ]; then
            warn "Git-HEAD weicht vom Backup ab (Backup: ${m_head:0:10}). Dateien werden trotzdem exakt wiederhergestellt."
        fi
    fi

    local rs_ex=() p
    while IFS= read -r p; do
        [ -n "$p" ] && rs_ex+=("--exclude=/$p/" "--exclude=/$p")
    done < <(backup_exclude_paths; printf '%s\n' "$PSU_REL" "$ADMIN_DIR/autoupgrade")
    info "Synchronisiere Dateien (rsync --delete, img/ und ${PSU_REL}/ bleiben unberührt) ..."
    rsync -a --delete "${rs_ex[@]}" "$work/" "$PS_ROOT/" || die "rsync fehlgeschlagen."
    rm -rf "$work"
    ok "Dateien wiederhergestellt."

    if [ -n "$m_assume" ] && have git && [ -e "$PS_ROOT/.git" ]; then
        local f
        for f in $m_assume; do git -C "$PS_ROOT" update-index --assume-unchanged "$f" 2>/dev/null; done
    fi

    step "Datenbank wiederherstellen"
    load_db_params
    [ "$DB_NAME" = "$m_db" ] || die "parameters.php nach Restore zeigt auf '$DB_NAME' statt '$m_db'. Abbruch vor dem DB-Import."
    local drops tables views
    tables="$(db_query "SELECT CONCAT('\`', table_name, '\`') FROM information_schema.tables WHERE table_schema=DATABASE() AND table_type='BASE TABLE'" | paste -sd, -)"
    views="$(db_query "SELECT CONCAT('\`', table_name, '\`') FROM information_schema.tables WHERE table_schema=DATABASE() AND table_type='VIEW'" | paste -sd, -)"
    drops="SET FOREIGN_KEY_CHECKS=0;"
    [ -n "$views" ] && drops="$drops DROP VIEW IF EXISTS $views;"
    [ -n "$tables" ] && drops="$drops DROP TABLE IF EXISTS $tables;"
    drops="$drops SET FOREIGN_KEY_CHECKS=1;"
    info "Leere Datenbank '${DB_NAME}' (auch nach dem Backup neu angelegte Tabellen) ..."
    db_query "$drops" || die "Konnte die Tabellen nicht löschen."
    info "Importiere Dump ..."
    gzip -dc "$set/db.sql.gz" | "$MYSQL_BIN" --defaults-extra-file="$DB_DEFAULTS" "$DB_NAME"
    local s1=${PIPESTATUS[0]} s2=${PIPESTATUS[1]}
    [ "$s1" -eq 0 ] && [ "$s2" -eq 0 ] || die "DB-Import fehlgeschlagen (gzip=$s1, mysql=$s2). Der Shop bleibt im Wartungsmodus!"
    ok "Datenbank wiederhergestellt."

    # The dump may contain the maintenance values of the upgrade run: re-assert maintenance
    maintenance_on_quiet

    step "Caches"
    detect_ps_version
    clear_caches
    [ -n "$RUN_TO" ] || RUN_TO="$PS_VERSION"
    ok "Restore abgeschlossen: PrestaShop ${PS_VERSION} (Set ${set##*/})."
}
