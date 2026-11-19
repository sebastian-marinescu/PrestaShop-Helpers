#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are shared between the library files
# ------------------------------------------------------------------------------
# PrestaShop Upgrade Toolkit - checks & reports
#   environment, PHP, disk space, git, autoupgrade, core integrity, overrides,
#   module compatibility, theme gate, child-theme overrides, theme modules
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Theme package index (ThemeForest downloads in $PSU_HOME/themes/*.zip)
# ------------------------------------------------------------------------------

THEME_INDEX_LOADED=0
THEME_INDEX=()

theme_index_load() {
    [ "$THEME_INDEX_LOADED" = "1" ] && return 0
    THEME_INDEX_LOADED=1
    THEME_INDEX=()
    mkdir -p "$PSU_HOME/themes"
    local line
    if ls "$PSU_HOME/themes/"*.zip >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -n "$line" ] && THEME_INDEX+=("$line")
        done < <(tool theme-index "$PSU_HOME/themes" "$PSU_HOME/themes/cache" "$PSU_HOME/themes/index.tsv" 2>/dev/null)
    fi
}

# Iterate index entries: prints "type<TAB>name<TAB>version<TAB>from<TAB>to<TAB>cachefile<TAB>source"
theme_index_entries() {
    local line
    for line in "${THEME_INDEX[@]}"; do
        printf '%s\n' "$line" | cut -d'|' -f2-
    done
}

# Best (highest) theme package for <name> whose compatibility.from major == <ps_major>
theme_package_for_major() {
    local name="$1" major="$2" type n v from to cache src best="" best_v=""
    while IFS='|' read -r type n v from to cache src; do
        [ "$type" = "theme" ] && [ "$n" = "$name" ] || continue
        [ -n "$from" ] && [ "$(ver_major "$from")" = "$major" ] || continue
        if [ -z "$best" ] || vercmp "$v" '>' "$best_v"; then best="$cache"; best_v="$v"; fi
    done < <(theme_index_entries)
    [ -n "$best" ] || return 1
    printf '%s|%s' "$best_v" "$best"
}

# Sets THEME_GATE (ok|warn|block) + THEME_GATE_MSG for a target version
theme_gate() {
    local target="$1" tmajor
    THEME_GATE="ok"; THEME_GATE_MSG=""
    [ -n "${THEME_PARENT:-}" ] && [ -n "${PARENT_VERSION:-}" ] || { THEME_GATE="warn"; THEME_GATE_MSG="Theme-Version unbekannt"; return; }
    tmajor="$(ver_major "$target")"

    local min_var="THEME_MIN_VERSION_FOR_PS${tmajor}"
    local min="${!min_var:-}"
    if [ -n "$min" ]; then
        if vercmp "$PARENT_VERSION" '<' "$min"; then
            THEME_GATE="block"; THEME_GATE_MSG="Theme '${THEME_PARENT}' ≥ ${min} erforderlich (installiert: ${PARENT_VERSION}, ${min_var})"
        fi
        return
    fi
    if [ -n "${PARENT_TO:-}" ] && vercmp "$target" '>' "$PARENT_TO"; then
        THEME_GATE="block"; THEME_GATE_MSG="Theme '${THEME_PARENT}' ${PARENT_VERSION} ist nur bis PrestaShop ${PARENT_TO} freigegeben"
        return
    fi
    if [ -n "${PARENT_FROM:-}" ] && [ "$tmajor" -gt "$(ver_major "$PARENT_FROM")" ] 2>/dev/null; then
        theme_index_load
        local pkg
        if pkg="$(theme_package_for_major "$THEME_PARENT" "$tmajor")"; then
            THEME_GATE="block"
            THEME_GATE_MSG="Theme '${THEME_PARENT}' ${pkg%%|*} (Linie für PS ${tmajor}) erforderlich – installiert: ${PARENT_VERSION}"
        else
            THEME_GATE="warn"
            THEME_GATE_MSG="Theme-Kompatibilität für PS ${tmajor} unbekannt (kein passendes Theme-ZIP in ${PSU_HOME}/themes)"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Environment checks
# ------------------------------------------------------------------------------

check_tools() {
    local t missing=()
    for t in "$MYSQL_BIN" "$MYSQLDUMP_BIN" tar gzip rsync curl awk sed find du df; do
        have "$t" || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        blocker "Fehlende CLI-Tools: ${missing[*]}"
    else
        passed "CLI-Tools vorhanden (mysql, mysqldump, tar, gzip, rsync, curl, ...)"
    fi
    have git || warning "git nicht gefunden – Git-Abgleich und Theme-Basis aus Git nicht möglich."
}

check_php() {
    info "PHP-Binaries auf dem Server:"
    rep "PHP-Binaries:"
    rep ""
    print_php_table
    rep ""
    if [ -n "$WEB_PHP_VERSION_USED" ]; then
        passed "Web-PHP: ${WEB_PHP_VERSION_USED} (Quelle: ${WEB_PHP_SOURCE})"
    else
        blocker "Web-PHP-Version unbekannt (env-check.php nicht erreichbar und WEB_PHP_VERSION nicht gesetzt)."
        return
    fi
    if [ -z "$PHP_SELECTED" ]; then
        blocker "Kein PHP-CLI-Binary mit Version $(ver_minor "$WEB_PHP_VERSION_USED") gefunden (PHP_BIN in der .env setzen)."
        return
    fi
    if [ "$(ver_minor "$PHP_SELECTED_VERSION")" != "$(ver_minor "$WEB_PHP_VERSION_USED")" ]; then
        critical "PHP_BIN ${PHP_SELECTED} (${PHP_SELECTED_VERSION}) passt nicht zur Web-PHP ${WEB_PHP_VERSION_USED}"
    else
        passed "PHP-CLI: ${PHP_SELECTED} (${PHP_SELECTED_VERSION}) – ${PHP_SELECT_SOURCE}"
    fi

    # Extensions: CLI vs web
    local required="${PHP_REQUIRED_EXTENSIONS:-curl dom fileinfo gd iconv intl json mbstring openssl pdo_mysql simplexml zip}"
    local cli_ext web_ext e miss_cli=() miss_web=()
    cli_ext=" $("$PHP_SELECTED" -r 'echo strtolower(implode(" ", get_loaded_extensions()));' 2>/dev/null) "
    for e in $required; do
        case "$cli_ext" in *" $e "*) ;; *) miss_cli+=("$e") ;; esac
    done
    if [ -n "${WEB_ENV_JSON:-}" ]; then
        web_ext=" $(tool json-get "$WEB_ENV_JSON" extensions 2>/dev/null | tr '[:upper:]' '[:lower:]') "
        for e in $required; do
            case "$web_ext" in *" $e "*) ;; *) miss_web+=("$e") ;; esac
        done
        local web_mem
        web_mem="$(tool json-get "$WEB_ENV_JSON" memory_limit 2>/dev/null)"
        detail "   Web: memory_limit=${web_mem:-?}, max_execution_time=$(tool json-get "$WEB_ENV_JSON" max_execution_time 2>/dev/null), upload_max_filesize=$(tool json-get "$WEB_ENV_JSON" upload_max_filesize 2>/dev/null)"
    fi
    if [ "${#miss_cli[@]}" -eq 0 ]; then passed "PHP-Extensions (CLI) vollständig"; else blocker "Fehlende PHP-Extensions (CLI): ${miss_cli[*]}"; fi
    if [ -n "${WEB_ENV_JSON:-}" ]; then
        if [ "${#miss_web[@]}" -eq 0 ]; then passed "PHP-Extensions (Web) vollständig"; else warning "Fehlende PHP-Extensions (Web): ${miss_web[*]}"; fi
    fi
}

check_db() {
    local v
    v="$(db_scalar "SELECT VERSION()")"
    if [ -z "$v" ]; then
        blocker "Datenbank '${DB_NAME}' nicht erreichbar."
        return 1
    fi
    passed "Datenbank erreichbar: ${DB_NAME} (Server ${v}, Prefix '${DB_PREFIX}')"
    if [ -n "$PS_VERSION_DB" ] && [ "$PS_VERSION_DB" != "$PS_VERSION" ]; then
        critical "Dateien (${PS_VERSION}) und Datenbank (PS_VERSION_DB=${PS_VERSION_DB}) haben unterschiedliche Versionen"
    fi
    [ "${SHOP_COUNT:-1}" -gt 1 ] 2>/dev/null && warning "Multistore mit ${SHOP_COUNT} aktiven Shops – alle Shops testen."
    return 0
}

check_git() {
    git_info
    if [ -z "$GIT_HEAD" ]; then
        warning "Kein Git-Repository – Git-Snapshot und Abgleich entfallen."
        return
    fi
    if [ "$GIT_DIRTY" = "0" ]; then
        passed "Git: Branch '${GIT_BRANCH}' sauber (${GIT_HEAD:0:10})"
    elif [ "${OPT_ALLOW_DIRTY:-0}" = "1" ]; then
        warning "Git: ${GIT_DIRTY} geänderte/neue Dateien (--allow-dirty)"
    else
        blocker "Git: ${GIT_DIRTY} geänderte/neue Dateien – bitte committen/aufräumen oder --allow-dirty nutzen"
        git -C "$PS_ROOT" status --short --ignore-submodules=all 2>/dev/null | head -n 15 | sed 's/^/     /'
    fi
}

check_autoupgrade() {
    autoupgrade_versions
    if [ -z "$AU_INSTALLED" ]; then
        blocker "Modul 'autoupgrade' (Update Assistant) fehlt in modules/autoupgrade (installieren: $0 autoupgrade-update)."
        return
    fi
    if [ -n "$AU_LATEST" ] && vercmp "$AU_INSTALLED" '<' "$AU_LATEST"; then
        warning "autoupgrade ${AU_INSTALLED} installiert, empfohlen ${AU_LATEST} (aktualisieren: $0 autoupgrade-update)"
    else
        passed "autoupgrade ${AU_INSTALLED} (empfohlen: ${AU_LATEST:-?})"
    fi
}

# check_disk [release_zip_bytes]
check_disk() {
    local zip_bytes="${1:-0}"
    info "Berechne Speicherbedarf (kann etwas dauern) ..."
    local root_kb db_kb zip_kb need_kb
    root_kb="$(root_size_kb)"
    db_kb="$(db_size_kb)"; db_kb="${db_kb:-0}"
    zip_kb=$(( zip_bytes / 1024 ))
    [ "$zip_kb" -gt 0 ] || zip_kb=$(( 150 * 1024 ))
    need_kb=$(( (root_kb + db_kb + zip_kb * 3) * 12 / 10 ))

    local df_backup df_root avail_kb quota_line q_used q_limit f_used f_limit q_avail="" f_avail=""
    mkdir -p "$PSU_HOME"
    df_backup="$(df -Pk "$PSU_HOME" 2>/dev/null | awk 'NR==2{print $4}')"
    df_root="$(df -Pk "$PS_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
    avail_kb="${df_backup:-0}"
    [ -n "$df_root" ] && [ "$df_root" -lt "$avail_kb" ] && avail_kb="$df_root"

    if have quota; then
        quota_line="$(quota 2>/dev/null | awk '$1 ~ /^\// { n=0; for (i=2;i<=NF;i++) { v=$i; gsub(/\*/,"",v); if (v ~ /^[0-9]+$/) { n++; a[n]=v } } if (n>=6) { print a[1], a[3], a[4], a[6]; exit } }')"
        if [ -n "$quota_line" ]; then
            read -r q_used q_limit f_used f_limit <<< "$quota_line"
            if [ "${q_limit:-0}" -gt 0 ]; then
                q_avail=$(( q_limit - q_used ))
                [ "$q_avail" -lt "$avail_kb" ] && avail_kb="$q_avail"
            fi
            if [ "${f_limit:-0}" -gt 0 ]; then f_avail=$(( f_limit - f_used )); fi
        fi
    fi

    detail "   Bedarf:   $(human_kb "$need_kb")  (Docroot ohne img $(human_kb "$root_kb") + DB $(human_kb "$db_kb") + Release ×3 $(human_kb $((zip_kb * 3))) + 20 %)"
    detail "   Frei:     $(human_kb "$avail_kb")  (df Backup/Docroot${q_avail:+, Quota-Rest $(human_kb "$q_avail")})"
    rep "    Bedarf: $(human_kb "$need_kb") | Frei: $(human_kb "$avail_kb")"
    if [ "$avail_kb" -lt "$need_kb" ]; then
        blocker "Zu wenig Speicherplatz: frei $(human_kb "$avail_kb"), benötigt ca. $(human_kb "$need_kb")"
    elif [ "$avail_kb" -lt $(( need_kb * 2 )) ]; then
        warning "Speicherplatz knapp: frei $(human_kb "$avail_kb"), benötigt ca. $(human_kb "$need_kb")"
    else
        passed "Speicherplatz ausreichend: frei $(human_kb "$avail_kb"), benötigt ca. $(human_kb "$need_kb")"
    fi
    if [ -n "$f_avail" ]; then
        local need_inodes=100000
        detail "   Inodes:   frei ${f_avail} (Quota), benötigt ca. ${need_inodes} (entpacktes Release)"
        if [ "$f_avail" -lt "$need_inodes" ]; then
            blocker "Zu wenige freie Inodes laut Quota: ${f_avail} (benötigt ca. ${need_inodes})"
        elif [ "$f_avail" -lt $(( need_inodes * 2 )) ]; then
            warning "Inodes knapp: ${f_avail} frei"
        else
            passed "Inodes ausreichend (${f_avail} frei)"
        fi
    fi
}

# Theme / PHP gate for the chosen target
check_target_gate() {
    local target="$1"
    gate_target "$target"
    release_info "$target"
    detail "   Ziel: PrestaShop ${target} (${REL_DIST}${REL_DISTVER:+ $REL_DISTVER}) – PHP offiziell ${REL_PHP_MIN} – ${REL_PHP_MAX}"
    case "$GATE_LEVEL" in
        ok) passed "Zielversion ${target}: PHP- und Theme-Kompatibilität ok" ;;
        warn) warning "Zielversion ${target}: ${GATE_MSG}" ;;
        *) blocker "Zielversion ${target}: ${GATE_MSG}" ;;
    esac
    if [ -n "${PARENT_VERSION:-}" ]; then
        detail "   Theme: ${THEME_NAME} → Parent ${THEME_PARENT} ${PARENT_VERSION} (compatibility: ${PARENT_FROM:-?} – ${PARENT_TO:-offen})"
    fi
}

check_autoupgrade_requirements() {
    [ -n "$PHP_SELECTED" ] && [ -n "$AU_INSTALLED" ] || return 0
    autoupgrade_stage_release
    info "Update Assistant: update:check-requirements ..."
    local out="$PSU_TMP/au-requirements.txt" rc
    autoupgrade_console update:check-requirements --channel=local --zip="$REL_ZIP_NAME" --xml="$REL_XML_NAME" "$ADMIN_DIR" > "$out" 2>&1
    rc=$?
    sed 's/^/     /' "$out"
    rep ""; rep '```text'; cat "$out" >> "$REPORT_FILE" 2>/dev/null; rep '```'
    if [ "$rc" -eq 0 ]; then
        passed "Update Assistant: Voraussetzungen erfüllt"
    elif grep -qi "PHP version isn't compatible" "$out" && [ "$GATE_LEVEL" = "warn" ]; then
        warning "Update Assistant meldet PHP außerhalb des offiziellen Bereichs (bekannt, siehe oben – kein Blocker für die CLI)"
    else
        critical "Update Assistant meldet Fehler bei den Voraussetzungen (Code $rc, siehe Ausgabe)"
    fi
}

# ------------------------------------------------------------------------------
# Core integrity (checksum XML of the CURRENT version)
# ------------------------------------------------------------------------------

check_integrity() {
    current_release_xml
    if [ -z "$CURRENT_XML" ]; then
        warning "Checksum-XML der aktuellen Version ${PS_VERSION} nicht verfügbar – Integritätscheck übersprungen."
        return
    fi
    info "Vergleiche Core-Dateien mit PrestaShop ${PS_VERSION} (Checksummen, Zeilenenden werden ignoriert) ..."
    local out="$PSU_TMP/integrity.tsv"
    tool integrity "$CURRENT_XML" "$PS_ROOT" "$ADMIN_DIR" > "$out" || { warning "Integritätscheck fehlgeschlagen."; return; }
    local total eol core_mod=() core_miss=() mod_count=0 theme_count=0 st path
    total="$(awk -F'|' '$1=="TOTAL"{print $2}' "$out")"
    eol="$(awk -F'|' '$1=="EOL_ONLY"{print $2}' "$out")"
    local -A mod_modules=()
    while IFS='|' read -r st path; do
        case "$st" in MODIFIED|MISSING) ;; *) continue ;; esac
        case "$path" in
            install/*|"$ADMIN_DIR"/autoupgrade/*|docs/*|app/config/parameters.php) continue ;;
            modules/*/*) mod_count=$((mod_count + 1)); local mm="${path#modules/}"; mod_modules["${mm%%/*}"]=1; continue ;;
            modules/*) continue ;;
            themes/*) theme_count=$((theme_count + 1)); continue ;;
        esac
        if [ "$st" = "MODIFIED" ]; then core_mod+=("$path"); else core_miss+=("$path"); fi
    done < "$out"
    detail "   ${total} Dateien geprüft, ${eol:-0} unterscheiden sich nur durch Zeilenenden (ignoriert)."
    if [ "${#core_mod[@]}" -eq 0 ]; then
        passed "Keine veränderten Core-Dateien"
    else
        warning "${#core_mod[@]} veränderte Core-Dateien – werden vom Upgrade ÜBERSCHRIEBEN"
        local f i=0
        for f in "${core_mod[@]}"; do
            i=$((i + 1))
            [ "$i" -le 40 ] || [ "${OPT_VERBOSE:-0}" = "1" ] && printf '     %s\n' "$f"
            rep "    - \`$f\`"
        done
        [ "$i" -gt 40 ] && [ "${OPT_VERBOSE:-0}" != "1" ] && detail "     … und $((i - 40)) weitere (vollständige Liste im Report)"
    fi
    if [ "${#core_miss[@]}" -gt 0 ]; then
        warning "${#core_miss[@]} Core-Dateien fehlen (werden vom Upgrade ggf. wieder angelegt)"
        local f i=0
        for f in "${core_miss[@]}"; do
            i=$((i + 1))
            [ "$i" -le 20 ] || [ "${OPT_VERBOSE:-0}" = "1" ] && printf '     %s\n' "$f"
            rep "    - \`$f\`"
        done
    fi
    if [ "$mod_count" -gt 0 ]; then
        detail "   Info: ${mod_count} Dateien in nativen Modulen weichen ab (meist Modul-Updates): ${!mod_modules[*]}"
        rep "    - Info: abweichende native Module: ${!mod_modules[*]}"
    fi
    [ "$theme_count" -gt 0 ] && detail "   Info: ${theme_count} Dateien im Standard-Theme weichen ab."
}

# ------------------------------------------------------------------------------
# Class / controller overrides
# ------------------------------------------------------------------------------

check_overrides() {
    local core_dir="$1"
    [ -d "$PS_ROOT/override" ] || { passed "Keine Overrides vorhanden"; return; }
    info "Analysiere Overrides gegen PrestaShop ${TARGET_VERSION} ..."
    local out="$PSU_TMP/overrides.tsv"
    tool override-report "$PS_ROOT" "$core_dir" > "$out" || { warning "Override-Analyse fehlgeschlagen."; return; }
    local st file class member msg n_ok=0 n_changed=0 n_sig=0 n_removed=0 n_info=0
    rep ""
    while IFS='|' read -r st file class member msg; do
        case "$st" in
            OK) n_ok=$((n_ok + 1)); [ "${OPT_VERBOSE:-0}" = "1" ] && status "🟢" "${file} → ${class}::${member}" ;;
            NEW_METHOD) n_info=$((n_info + 1)); [ "${OPT_VERBOSE:-0}" = "1" ] && status "ℹ️" "${file} → ${class}::${member} (${msg})" ;;
            CHANGED|PROP_CHANGED) n_changed=$((n_changed + 1)); status "🟠" "${file} → ${class}::${member} – ${msg}" 1 ;;
            SIG|CLASS_REMOVED) n_sig=$((n_sig + 1)); status "⛔" "${file} → ${class}${member:+::$member} – ${msg}" 1 ;;
            REMOVED|PROP_REMOVED) n_removed=$((n_removed + 1)); status "🔴" "${file} → ${class}::${member} – ${msg}" 1 ;;
            DUPLICATE|CORE_NOT_FOUND|NOCLASS) status "⚠️" "${file} – ${msg}" 1; CHECK_WARNINGS+=("Override ${file}: ${msg}") ;;
            MODULE|IGNORED) n_info=$((n_info + 1)); [ "${OPT_VERBOSE:-0}" = "1" ] && status "ℹ️" "${file} – ${msg}" ;;
        esac
    done < "$out"
    local mod_overrides ignored
    mod_overrides="$(awk -F'|' '$1=="MODULE"' "$out" | wc -l | tr -d ' ')"
    ignored="$(awk -F'|' '$1=="IGNORED"' "$out" | wc -l | tr -d ' ')"
    detail "   Methoden: ${n_ok} unverändert 🟢, ${n_changed} Core geändert 🟠, ${n_removed} entfernt 🔴, ${n_sig} Signatur/Klasse ⛔ | Modul-Overrides: ${mod_overrides} | ignorierte Dateien: ${ignored}"
    if [ "$n_sig" -gt 0 ]; then
        critical "${n_sig} Override(s) mit geänderter Signatur/entfernter Klasse – führen nach dem Upgrade sehr wahrscheinlich zu Fatal Errors"
    elif [ "$n_changed" -gt 0 ] || [ "$n_removed" -gt 0 ]; then
        warning "Overrides: ${n_changed} geänderte und ${n_removed} entfernte Core-Methoden manuell prüfen"
    else
        passed "Overrides kompatibel zur Zielversion"
    fi
}

# ------------------------------------------------------------------------------
# Module compatibility (ps_versions_compliancy) for active non-native modules
# ------------------------------------------------------------------------------

check_modules() {
    local target="$1" xml="$2"
    local native=" " m
    if [ -n "$xml" ] && [ -f "$xml" ]; then
        native=" $(tool xml-dirs "$xml" modules | tr '\n' ' ') "
    fi
    theme_index_load
    local active new_incompat=() staged_updates=() already=() missing=() checked=0
    active="$(db_query "SELECT name FROM ${DB_PREFIX}module WHERE active=1 ORDER BY name" 2>/dev/null)"
    for m in $active; do
        case "$native" in *" $m "*) continue ;; esac
        [ "$m" = "autoupgrade" ] && continue
        checked=$((checked + 1))
        local main="$PS_ROOT/modules/$m/$m.php"
        if [ ! -f "$main" ]; then missing+=("$m"); continue; fi
        local max="" inst=""
        inst="$(tool module-info "$main" | sed -n 's/^version=//p')"
        max="$(tool module-info "$main" | sed -n 's/^max=//p')"
        [ -z "$max" ] || [ "$max" = "_PS_VERSION_" ] && continue
        if vercmp "$target" '>' "$max"; then
            local type n v from to cache src pkg_v="" pkg_src=""
            while IFS='|' read -r type n v from to cache src; do
                [ "$type" = "module" ] && [ "$n" = "$m" ] || continue
                [ -n "$from" ] && vercmp "$target" '<' "$from" && continue
                [ -n "$to" ] && [ "$to" != "_PS_VERSION_" ] && vercmp "$target" '>' "$to" && continue
                if [ -z "$inst" ] || vercmp "$v" '>' "$inst"; then
                    pkg_v="$v"; pkg_src="$src"; break
                fi
            done < <(theme_index_entries)
            if [ -n "$pkg_v" ]; then
                staged_updates+=("$m (${inst:-?} → ${pkg_v}, max ${max} → kompatibles Paket in themes/: ${pkg_src})")
            elif vercmp "$PS_VERSION" '>' "$max"; then
                already+=("$m (max ${max})")
            else
                new_incompat+=("$m (max ${max})")
            fi
        fi
    done
    detail "   ${checked} aktive Nicht-Core-Module geprüft."
    if [ "${#staged_updates[@]}" -gt 0 ]; then
        for m in "${staged_updates[@]}"; do status "🟢" "Modul ${m}" 1; done
    fi
    if [ "${#new_incompat[@]}" -gt 0 ]; then
        warning "${#new_incompat[@]} Module sind laut ps_versions_compliancy NICHT für ${target} freigegeben"
        for m in "${new_incompat[@]}"; do status "🟠" "Modul ${m}" 1; done
    else
        passed "Keine Module, die durch das Upgrade neu aus ihrer Freigabe fallen"
    fi
    if [ "${#already[@]}" -gt 0 ]; then
        status "ℹ️" "${#already[@]} Module laufen schon heute außerhalb ihrer Freigabe: ${already[*]}"
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        warning "Aktive Module ohne Modulordner: ${missing[*]}"
    fi
}

check_autoupgrade_modules() {
    [ -n "$PHP_SELECTED" ] && [ -n "$AU_INSTALLED" ] || return 0
    info "Update Assistant: update:check-modules ..."
    local out="$PSU_TMP/au-modules.txt"
    autoupgrade_console update:check-modules --channel=local --zip="$REL_ZIP_NAME" --xml="$REL_XML_NAME" "$ADMIN_DIR" > "$out" 2>&1
    sed 's/^/     /' "$out" | head -n 60
    rep ""; rep '```text'; cat "$out" >> "$REPORT_FILE" 2>/dev/null; rep '```'
}

# ------------------------------------------------------------------------------
# Child theme overrides & theme modules
# ------------------------------------------------------------------------------

# Commit in which the installed parent theme version was introduced (base for theme-module changes)
theme_base_ref() {
    local ref=""
    if have git && [ -e "$PS_ROOT/.git" ] && [ -n "${PARENT_VERSION:-}" ]; then
        ref="$(git -C "$PS_ROOT" log --reverse --format=%H -S"version: ${PARENT_VERSION}" -- "themes/${THEME_PARENT}/config/theme.yml" 2>/dev/null | head -n 1)"
    fi
    printf '%s' "${ref:-HEAD}"
}

# Prepare old/new sources for the child theme report.
#   OLD: installed files (default) | --theme-old=<zip> (dir) | --theme-old=<git-ref> (git)
#   NEW: new theme package (dependencies/modules for theme modules) + release archive (native modules)
prepare_theme_sources() {
    local target_major="$1"
    THEME_OLD_KIND="installed"; THEME_OLD_REF=""; THEME_OLD_DIR=""; THEME_NEW_DIR=""; THEME_NEW_VERSION=""
    THEME_BASE_REF="$(theme_base_ref)"
    if [ -n "${OPT_THEME_OLD:-}" ] && [ -f "$OPT_THEME_OLD" ]; then
        THEME_OLD_KIND="dir"
        THEME_OLD_DIR="$PSU_HOME/themes/extracted/old-$(file_sha256 "$OPT_THEME_OLD" | cut -c1-12)"
        [ -d "$THEME_OLD_DIR" ] || tool zip-extract "$OPT_THEME_OLD" "$THEME_OLD_DIR" || die "Konnte $OPT_THEME_OLD nicht entpacken."
    elif [ -n "${OPT_THEME_OLD:-}" ]; then
        git -C "$PS_ROOT" rev-parse --verify -q "${OPT_THEME_OLD}^{commit}" >/dev/null || die "--theme-old: '$OPT_THEME_OLD' ist weder Datei noch Git-Ref."
        THEME_OLD_KIND="git"; THEME_OLD_REF="$OPT_THEME_OLD"
    fi

    local new_zip=""
    if [ -n "${OPT_THEME_NEW:-}" ]; then
        [ -f "$OPT_THEME_NEW" ] || die "--theme-new: Datei nicht gefunden: $OPT_THEME_NEW"
        new_zip="$OPT_THEME_NEW"
        THEME_NEW_VERSION="$(tool theme-info "$new_zip" | sed -n 's/^version=//p')"
    else
        theme_index_load
        local pkg=""
        if [ -n "$target_major" ]; then pkg="$(theme_package_for_major "$THEME_PARENT" "$target_major")"; fi
        if [ -z "$pkg" ] && [ -n "${PARENT_FROM:-}" ]; then pkg="$(theme_package_for_major "$THEME_PARENT" "$(ver_major "$PARENT_FROM")")"; fi
        if [ -n "$pkg" ]; then
            THEME_NEW_VERSION="${pkg%%|*}"
            new_zip="${pkg#*|}"
        fi
    fi
    if [ -n "$new_zip" ]; then
        THEME_NEW_DIR="$PSU_HOME/themes/extracted/${THEME_PARENT}-${THEME_NEW_VERSION}"
        if [ ! -f "$THEME_NEW_DIR/.complete" ]; then
            rm -rf "$THEME_NEW_DIR"
            tool zip-extract "$new_zip" "$THEME_NEW_DIR" || die "Konnte $new_zip nicht entpacken."
            touch "$THEME_NEW_DIR/.complete"
        fi
    fi
}

# Path of a logical file in a source; prints the path (or git spec) – no existence check
#   logical: parent:<rel> | module:<M>/<sub>
theme_src_path() {
    local which="$1" logical="$2" rel mod
    case "$logical" in
        parent:*) rel="${logical#parent:}" ;;
        module:*) rel="${logical#module:}"; mod="${rel%%/*}" ;;
    esac
    if [ "$which" = "old" ]; then
        case "$THEME_OLD_KIND:$logical" in
            installed:parent:*) printf '%s/themes/%s/%s' "$PS_ROOT" "$THEME_PARENT" "$rel" ;;
            installed:module:*) printf '%s/modules/%s' "$PS_ROOT" "$rel" ;;
            dir:parent:*) printf '%s/%s' "$THEME_OLD_DIR" "$rel" ;;
            dir:module:*) printf '%s/dependencies/modules/%s' "$THEME_OLD_DIR" "$rel" ;;
            git:parent:*) printf 'git:%s:themes/%s/%s' "$THEME_OLD_REF" "$THEME_PARENT" "$rel" ;;
            git:module:*) printf 'git:%s:modules/%s' "$THEME_OLD_REF" "$rel" ;;
        esac
    else
        case "$logical" in
            parent:*) [ -n "$THEME_NEW_DIR" ] && printf '%s/%s' "$THEME_NEW_DIR" "$rel" ;;
            module:*)
                if [ -n "$THEME_NEW_DIR" ] && [ -d "$THEME_NEW_DIR/dependencies/modules/$mod" ]; then
                    printf '%s/dependencies/modules/%s' "$THEME_NEW_DIR" "$rel"
                elif [ -n "${RELEASE_MODULES_DIR:-}" ] && [ -d "$RELEASE_MODULES_DIR/modules/$mod" ]; then
                    printf '%s/modules/%s' "$RELEASE_MODULES_DIR" "$rel"
                fi ;;
        esac
    fi
}

# Copies a logical file of a source to <outfile>. Returns 1 if it does not exist.
theme_src_file() {
    local which="$1" logical="$2" outfile="$3" path
    path="$(theme_src_path "$which" "$logical")"
    [ -n "$path" ] || return 1
    case "$path" in
        git:*)
            local spec="${path#git:}"
            git -C "$PS_ROOT" show "$spec" > "$outfile" 2>/dev/null || { rm -f "$outfile"; return 1; } ;;
        *)
            [ -f "$path" ] || return 1
            cp "$path" "$outfile" ;;
    esac
    return 0
}

# Is a NEW source available for this logical file at all?
theme_new_known() {
    [ -n "$(theme_src_path new "$1")" ]
}

theme_src_label() {
    local path
    path="$(theme_src_path "$1" "$2")"
    case "$path" in
        git:*) local spec="${path#git:}"; printf '<(git -C %s show %s)' "$PS_ROOT" "$spec" ;;
        *) printf '%s' "$path" ;;
    esac
}

# Native module sources of the target release (for module template overrides), cached
release_modules_dir() {
    local dir="$REL_DIR/modules-src"
    if [ ! -f "$dir/.complete" ]; then
        rm -rf "$dir"
        tool release-extract "$RELEASE_ZIP" "$dir" modules/ >/dev/null || { warn "Konnte modules/ des Releases nicht entpacken."; return 1; }
        touch "$dir/.complete"
    fi
    printf '%s' "$dir"
}

report_child_theme() {
    local target_major="$1"
    if [ -z "${THEME_NAME:-}" ] || [ "$THEME_NAME" = "$THEME_PARENT" ]; then
        status "ℹ️" "Kein Child-Theme aktiv – kein Override-Report nötig."
        return
    fi
    prepare_theme_sources "$target_major"
    RELEASE_MODULES_DIR="$(release_modules_dir 2>/dev/null)"
    case "$THEME_OLD_KIND" in
        installed) detail "   Alt: installierte Dateien (themes/${THEME_PARENT}, modules/)" ;;
        git) detail "   Alt: Git-Stand ${THEME_OLD_REF}" ;;
        dir) detail "   Alt: ${OPT_THEME_OLD}" ;;
    esac
    if [ -n "$THEME_NEW_DIR" ]; then
        detail "   Neu: ${THEME_PARENT} ${THEME_NEW_VERSION} (${THEME_NEW_DIR})"
    else
        warning "Kein neues Theme-ZIP gefunden (${PSU_HOME}/themes/) – Parent-Overrides werden nur aufgelistet."
    fi
    [ -n "$RELEASE_MODULES_DIR" ] && detail "   Native Module: PrestaShop ${TARGET_VERSION} (${RELEASE_MODULES_DIR})"
    rep ""
    rep "Alt: ${THEME_OLD_KIND} ${THEME_OLD_REF}${OPT_THEME_OLD:-} | Neu: \`${THEME_NEW_DIR:-–}\` | Native Module: \`${RELEASE_MODULES_DIR:-–}\`"
    rep ""

    local child_dir="$PS_ROOT/themes/$THEME_NAME" rel logical mod sub
    local n_green=0 n_orange=0 n_red=0 n_own=0 n_unknown=0
    local old_f="$PSU_TMP/theme_old" new_f="$PSU_TMP/theme_new"
    while IFS= read -r rel; do
        rel="${rel#./}"
        case "$rel" in
            templates/*) logical="parent:$rel" ;;
            modules/*/*)
                mod="${rel#modules/}"; mod="${mod%%/*}"; sub="${rel#modules/"$mod"/}"
                logical="parent:$rel"
                # Parent theme overrides this module template? Otherwise compare with the module itself.
                if ! theme_src_file old "$logical" "$old_f" && ! theme_src_file new "$logical" "$new_f"; then
                    logical="module:$mod/$sub"
                fi ;;
            *) continue ;;
        esac
        rm -f "$old_f" "$new_f"
        local has_old=0 has_new=0 what="Parent" cmp_logical="$logical" loc_note=""
        theme_src_file old "$logical" "$old_f" && has_old=1
        theme_src_file new "$logical" "$new_f" && has_new=1
        case "$logical" in module:*) what="Modul-Template (${mod})" ;; esac

        # Localized module mails (mails/<iso>/...) or legacy translation files (translations/<iso>.php):
        # PrestaShop release archives only ship mails/en/... in native modules.
        if [ "$has_new" = "0" ]; then
            case "$logical" in
                module:*/mails/*/*)
                    local mail_rest="${sub#mails/}" mail_iso="" mail_file="" en_logical=""
                    mail_iso="${mail_rest%%/*}"
                    mail_file="${mail_rest#*/}"
                    if [ -n "$mail_iso" ] && [ "$mail_iso" != "en" ] && [ -n "$mail_file" ]; then
                        en_logical="module:${mod}/mails/en/${mail_file}"
                        if theme_src_file new "$en_logical" "$new_f"; then
                            has_new=1
                            cmp_logical="$en_logical"
                            loc_note=" (lokalisierte Mail-Vorlage, Referenz: mails/en/${mail_file})"
                            rm -f "$old_f"
                            has_old=0
                            theme_src_file old "$en_logical" "$old_f" && has_old=1
                        fi
                    fi
                    ;;
                module:*/translations/*.php)
                    if theme_new_known "$logical"; then
                        n_green=$((n_green + 1))
                        status "🟢" "${rel} – ${what} (lokalisierte Übersetzungsdatei)"
                        continue
                    fi
                    ;;
            esac
        fi

        if [ "$has_old" = "0" ] && [ "$has_new" = "0" ]; then
            n_own=$((n_own + 1)); [ "${OPT_VERBOSE:-0}" = "1" ] && status "⚪" "${rel} – eigene Datei (kein Gegenstück)"
            continue
        fi
        if ! theme_new_known "$logical"; then
            n_unknown=$((n_unknown + 1))
            case "$logical" in
                module:*) status "⚪" "${rel} – ${what}: Modul weder im Theme- noch im Release-Paket → bei Modul-Updates prüfen" 1 ;;
                *) status "🟠" "${rel} – ${what}: manuell prüfen (kein neues Theme-ZIP)" 1 ;;
            esac
            continue
        fi
        if [ "$has_old" = "1" ] && [ "$has_new" = "1" ]; then
            if tool files-equal "$old_f" "$new_f"; then
                n_green=$((n_green + 1)); status "🟢" "${rel} – ${what} unverändert${loc_note}"
            else
                local merge_hint="" merge_cmd=""
                if [ -z "$loc_note" ] && have git && [ -f "$child_dir/$rel" ]; then
                    local mc="$PSU_TMP/m_child" mo="$PSU_TMP/m_old" mn="$PSU_TMP/m_new"
                    tr -d '\r' < "$child_dir/$rel" > "$mc" 2>/dev/null
                    tr -d '\r' < "$old_f" > "$mo" 2>/dev/null
                    tr -d '\r' < "$new_f" > "$mn" 2>/dev/null
                    if git merge-file -p "$mc" "$mo" "$mn" >/dev/null 2>&1; then
                        merge_hint=" [3-Wege-Merge konfliktfrei möglich]"
                        merge_cmd="git merge-file $child_dir/$rel $(theme_src_label old "$cmp_logical") $(theme_src_label new "$cmp_logical")"
                    else
                        merge_hint=" [3-Wege-Merge hat Konflikte – manuell prüfen]"
                    fi
                    rm -f "$mc" "$mo" "$mn"
                fi
                n_orange=$((n_orange + 1)); status "🟠" "${rel} – ${what} geändert${loc_note} → manuell prüfen${merge_hint}" 1
                local cmd diff_out
                cmd="diff -u --strip-trailing-cr $(theme_src_label old "$cmp_logical") $(theme_src_label new "$cmp_logical")"
                detail "     Diff:  $cmd"
                rep "    \`$cmd\`"
                if [ -n "$merge_cmd" ]; then
                    detail "     Merge: $merge_cmd"
                    rep "    \`$merge_cmd\`"
                fi
                diff_out="$(diff -u --strip-trailing-cr -L "old/${cmp_logical}" -L "new/${cmp_logical}" "$old_f" "$new_f" 2>/dev/null | head -n 120 || true)"
                if [ -n "$diff_out" ]; then
                    rep "    <details><summary>Diff im Parent/Modul anzeigen (${cmp_logical})</summary>"
                    rep ""
                    rep '    ```diff'
                    while IFS= read -r dline; do
                        rep "    $dline"
                    done <<< "$diff_out"
                    rep '    ```'
                    rep "    </details>"
                fi
            fi
        elif [ "$has_old" = "1" ]; then
            n_red=$((n_red + 1)); status "🔴" "${rel} – ${what} in der neuen Version ENTFERNT → Override verwaist" 1
        else
            n_orange=$((n_orange + 1)); status "🟠" "${rel} – ${what} NEU in der neuen Version → manuell prüfen" 1
        fi
    done < <(cd "$child_dir" && find templates modules -type f 2>/dev/null | sort)
    detail "   Child-Overrides: ${n_green} 🟢 | ${n_orange} 🟠 | ${n_red} 🔴 | ${n_unknown} ohne Vergleich | ${n_own} eigene Dateien (ohne Gegenstück)"
    if [ "$n_orange" -gt 0 ] || [ "$n_red" -gt 0 ] || [ "$n_unknown" -gt 0 ]; then
        warning "Child-Theme: $((n_orange + n_red + n_unknown)) Override(s) manuell prüfen (Liste oben / im Report)"
    else
        passed "Child-Theme-Overrides: keine Änderungen im Parent"
    fi
}

report_theme_modules() {
    [ -n "${THEME_PARENT:-}" ] || return
    local mods="$PARENT_MODULES" new_mods=""
    if [ -n "$THEME_NEW_DIR" ] && [ -f "$THEME_NEW_DIR/config/theme.yml" ]; then
        new_mods="$(tool theme-info "$THEME_NEW_DIR/config/theme.yml" | sed -n 's/^modules=//p')"
    fi
    local all m
    all="$(printf '%s\n' $mods $new_mods | awk 'NF && !seen[$0]++' | sort)"
    [ -n "$all" ] || { status "ℹ️" "Keine Theme-Module bekannt (THEME_MODULES setzen)."; return; }
    local n_changed=0
    for m in $all; do
        local inst="" newv="" changes="" untracked="" label=""
        [ -f "$PS_ROOT/modules/$m/$m.php" ] && inst="$(tool module-info "$PS_ROOT/modules/$m/$m.php" | sed -n 's/^version=//p')"
        [ -n "$THEME_NEW_DIR" ] && [ -f "$THEME_NEW_DIR/dependencies/modules/$m/$m.php" ] && \
            newv="$(tool module-info "$THEME_NEW_DIR/dependencies/modules/$m/$m.php" | sed -n 's/^version=//p')"
        label="${inst:-–}${newv:+ → $newv}"
        if [ -z "$inst" ] && [ -n "$newv" ]; then
            status "🆕" "${m}: neu im Theme-Paket ${THEME_NEW_VERSION} (${newv})" 1; continue
        fi
        if [ -n "$THEME_NEW_DIR" ] && [ -n "$inst" ] && [ -z "$newv" ] && [ -n "$new_mods" ]; then
            status "⚠️" "${m}: nicht mehr im Theme-Paket ${THEME_NEW_VERSION} enthalten (${label})" 1
        fi
        if have git && [ -n "${THEME_BASE_REF:-}" ] && [ -d "$PS_ROOT/modules/$m" ]; then
            changes="$(git -C "$PS_ROOT" diff --ignore-space-at-eol --shortstat "$THEME_BASE_REF" -- "modules/$m" ":!modules/$m/config_*.xml" 2>/dev/null | sed 's/^ *//')"
            untracked="$(git -C "$PS_ROOT" ls-files --others --exclude-standard -- "modules/$m" ":!modules/$m/config_*.xml" 2>/dev/null | wc -l | tr -d ' ')"
        fi
        if [ -n "$changes" ] || [ "${untracked:-0}" != "0" ]; then
            n_changed=$((n_changed + 1))
            status "🟠" "${m} (${label}): lokal geändert seit ${THEME_BASE_REF:0:10} (Theme-Installation) – ${changes:-}$([ "${untracked:-0}" != "0" ] && printf " (+%s neue Dateien)" "$untracked")" 1
            detail "     git -C $PS_ROOT diff --ignore-space-at-eol --stat ${THEME_BASE_REF:0:10} -- modules/$m ':!modules/$m/config_*.xml'"
            rep "    \`git -C $PS_ROOT diff --ignore-space-at-eol --stat ${THEME_BASE_REF:0:10} -- modules/$m ':!modules/$m/config_*.xml'\`"
        else
            status "🟢" "${m} (${label}): keine lokalen Änderungen"
        fi
    done
    if [ "$n_changed" -gt 0 ]; then
        warning "${n_changed} Theme-Module wurden lokal angepasst – ein Theme-Update überschreibt diese Änderungen"
    fi
}

# Newer theme / module versions inside the uploaded theme packages
report_theme_package_updates() {
    theme_index_load
    [ "${#THEME_INDEX[@]}" -gt 0 ] || { status "ℹ️" "Keine Theme-Pakete in ${PSU_HOME}/themes/ hinterlegt."; return; }
    local type n v from to cache src inst found=0 seen=" "
    while IFS='|' read -r type n v from to cache src; do
        case "$seen" in *" ${type}:${n}:${v} "*) continue ;; esac
        if [ "$type" = "module" ] && [ -f "$PS_ROOT/modules/$n/$n.php" ]; then
            inst="$(tool module-info "$PS_ROOT/modules/$n/$n.php" | sed -n 's/^version=//p')"
            if [ -n "$inst" ] && [ -n "$v" ] && vercmp "$v" '>' "$inst"; then
                seen="${seen}${type}:${n}:${v} "
                found=1
                status "⚠️" "Modul-Update im Paket: ${n} ${inst} → ${v} (${src})" 1
                CHECK_WARNINGS+=("Modul-Update im Theme-Paket: ${n} ${inst} → ${v}")
            fi
        elif [ "$type" = "theme" ] && [ "$n" = "$THEME_PARENT" ] && [ -n "$PARENT_VERSION" ] && [ -n "$from" ] && [ -n "${PARENT_FROM:-}" ]; then
            if [ "$(ver_major "$from")" = "$(ver_major "$PARENT_FROM")" ] && vercmp "$v" '>' "$PARENT_VERSION"; then
                seen="${seen}${type}:${n}:${v} "
                found=1
                status "ℹ️" "Theme-Update in derselben Linie verfügbar: ${n} ${PARENT_VERSION} → ${v} (${src})" 1
            fi
        fi
    done < <(theme_index_entries)
    [ "$found" = "1" ] || passed "Theme-Pakete: keine neueren Versionen installierter Module/Themes in derselben Linie"
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

print_check_summary() {
    step "Zusammenfassung"
    local x
    if [ "${#CHECK_BLOCKERS[@]}" -gt 0 ]; then
        printf '%s⛔ %d Blocker:%s\n' "$RED" "${#CHECK_BLOCKERS[@]}" "$NC"
        for x in "${CHECK_BLOCKERS[@]}"; do printf '   - %s\n' "$x"; done
    fi
    if [ "${#CHECK_CRITICAL[@]}" -gt 0 ]; then
        printf '%s⛔ %d kritische Punkte (bestätigungspflichtig):%s\n' "$RED" "${#CHECK_CRITICAL[@]}" "$NC"
        for x in "${CHECK_CRITICAL[@]}"; do printf '   - %s\n' "$x"; done
    fi
    if [ "${#CHECK_WARNINGS[@]}" -gt 0 ]; then
        printf '%s⚠️  %d Warnungen:%s\n' "$ORANGE" "${#CHECK_WARNINGS[@]}" "$NC"
        for x in "${CHECK_WARNINGS[@]}"; do printf '   - %s\n' "$x"; done
    fi
    if [ "${#CHECK_BLOCKERS[@]}" -eq 0 ] && [ "${#CHECK_CRITICAL[@]}" -eq 0 ] && [ "${#CHECK_WARNINGS[@]}" -eq 0 ]; then
        ok "Alle Prüfungen bestanden."
    fi
    rep ""
    rep "**Ergebnis:** ${#CHECK_BLOCKERS[@]} Blocker, ${#CHECK_CRITICAL[@]} kritisch, ${#CHECK_WARNINGS[@]} Warnungen"
}
