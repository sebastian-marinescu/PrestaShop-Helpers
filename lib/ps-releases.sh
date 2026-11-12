#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are shared between the library files
# ------------------------------------------------------------------------------
# PrestaShop Upgrade Toolkit - releases (official distribution API), version
# selection menu, download & verification of release archives.
#
# Source: https://api.prestashop-project.org (the same API the Update Assistant
# uses). 8.x = open source edition, 9.x = "Classic Edition".
# ------------------------------------------------------------------------------

# Fetch (and cache for 60 min) an API endpoint into $PSU_HOME/releases/api-<name>.json
api_fetch() {
    local name="$1" url="$RELEASES_API_URL/$1"
    local cache="$PSU_HOME/releases/api-${name}.json"
    mkdir -p "$PSU_HOME/releases"
    if [ "${OPT_REFRESH:-0}" != "1" ] && [ -s "$cache" ] && [ -n "$(find "$cache" -mmin -60 2>/dev/null)" ]; then
        printf '%s' "$cache"
        return 0
    fi
    if curl -fsSL --max-time 60 --retry 2 -o "$cache.part" "$url" 2>/dev/null && [ -s "$cache.part" ]; then
        mv "$cache.part" "$cache"
    else
        rm -f "$cache.part"
        if [ -s "$cache" ]; then
            warn "Release-API nicht erreichbar ($url) – nutze Cache vom $(date -r "$cache" '+%Y-%m-%d %H:%M' 2>/dev/null)." >&2
        else
            die "Release-API nicht erreichbar: $url"
        fi
    fi
    printf '%s' "$cache"
}

# Sets REL_* variables for a version. Returns 1 if unknown.
release_info() {
    local version="$1" api line
    api="$(api_fetch prestashop)" || return 1
    line="$(tool release-info "$api" "$version")" || return 1
    IFS='|' read -r REL_VERSION REL_DIST REL_DISTVER REL_PHP_MIN REL_PHP_MAX REL_STABILITY REL_ZIP_URL REL_XML_URL REL_MD5 REL_NOTES <<< "$line"
    REL_DIR="$PSU_HOME/releases/${REL_VERSION}${REL_DISTVER:+-$REL_DISTVER}"
    REL_ZIP_NAME="prestashop_${REL_VERSION}.zip"
    REL_XML_NAME="prestashop_${REL_VERSION}.xml"
    return 0
}

# All releases newer than the current version (TSV, ascending)
releases_newer() {
    local api
    api="$(api_fetch prestashop)" || return 1
    tool releases "$api" "${OPT_INCLUDE_PRE:-0}" "$PS_VERSION"
}

version_type() {
    local cur="$1" new="$2"
    if [ "$(ver_major "$cur")" != "$(ver_major "$new")" ]; then printf 'major'
    elif [ "$(ver_minor "$cur")" != "$(ver_minor "$new")" ]; then printf 'minor'
    else printf 'patch'
    fi
}

# Resolve a --to spec (x.y.z | x.y | x | latest | latest-patch | latest-minor) to a version
resolve_target() {
    local spec="$1" list v candidate=""
    list="$(releases_newer | cut -d'|' -f1)"
    [ -n "$list" ] || return 1
    case "$spec" in
        latest) candidate="$(printf '%s\n' "$list" | tail -n 1)" ;;
        latest-patch)
            for v in $list; do [ "$(ver_minor "$v")" = "$(ver_minor "$PS_VERSION")" ] && candidate="$v"; done ;;
        latest-minor)
            for v in $list; do [ "$(ver_major "$v")" = "$(ver_major "$PS_VERSION")" ] && candidate="$v"; done ;;
        *)
            for v in $list; do
                if [ "$v" = "$spec" ]; then candidate="$v"; break; fi
                case "$v" in "$spec".*) candidate="$v" ;; esac
            done ;;
    esac
    [ -n "$candidate" ] || return 1
    printf '%s' "$candidate"
}

# ------------------------------------------------------------------------------
# Compatibility gate per target version (PHP range, theme, autoupgrade)
# Sets GATE_LEVEL (ok|warn|critical|block) and GATE_MSG
# ------------------------------------------------------------------------------

gate_target() {
    local target="$1"
    GATE_LEVEL="ok"; GATE_MSG=""
    release_info "$target" || { GATE_LEVEL="block"; GATE_MSG="Version unbekannt"; return; }
    local php_min="$REL_PHP_MIN" php_max="$REL_PHP_MAX"

    # --- PHP of the web server vs. official range of the target
    if [ -n "${WEB_PHP_VERSION_USED:-}" ]; then
        local web_mm
        web_mm="$(ver_minor "$WEB_PHP_VERSION_USED")"
        if vercmp "$web_mm" '<' "$(ver_minor "$php_min")"; then
            GATE_LEVEL="block"; GATE_MSG="PHP ${web_mm} < Minimum ${php_min}"; return
        fi
        if vercmp "$web_mm" '>' "$(ver_minor "$php_max")"; then
            # Already outside the official range today? Then it's no regression.
            local cur_max=""
            if release_info "$PS_VERSION"; then cur_max="$REL_PHP_MAX"; fi
            release_info "$target"
            if [ -n "$cur_max" ] && vercmp "$web_mm" '>' "$(ver_minor "$cur_max")"; then
                GATE_LEVEL="warn"; GATE_MSG="PHP ${web_mm} offiziell nur bis ${php_max} (läuft heute schon so)"
            else
                GATE_LEVEL="block"; GATE_MSG="PHP ${web_mm} > Maximum ${php_max}"; return
            fi
        fi
    fi

    # --- Theme gate
    theme_gate "$target"
    case "$THEME_GATE" in
        block) GATE_LEVEL="block"; GATE_MSG="$THEME_GATE_MSG"; return ;;
        warn) [ "$GATE_LEVEL" = "ok" ] && GATE_LEVEL="warn"; GATE_MSG="${GATE_MSG:+$GATE_MSG; }$THEME_GATE_MSG" ;;
    esac
}

# ------------------------------------------------------------------------------
# Interactive version menu
# ------------------------------------------------------------------------------

select_target_interactive() {
    local rows=() v type shown=() recommended="" i=0 choice
    local -A best_per_line=()

    while IFS='|' read -r v _; do
        [ -n "$v" ] || continue
        rows+=("$v")
        best_per_line["$(ver_minor "$v")"]="$v"
    done < <(releases_newer)

    if [ "${#rows[@]}" -eq 0 ]; then
        ok "Keine neuere PrestaShop-Version verfügbar (installiert: ${PS_VERSION})."
        return 1
    fi

    for v in "${rows[@]}"; do
        if [ "${OPT_ALL:-0}" = "1" ] || [ "${best_per_line[$(ver_minor "$v")]}" = "$v" ]; then
            shown+=("$v")
        fi
    done

    printf '\n%sShop:%s %s (%s) | PS %s | PHP Web %s (CLI: %s %s)\n' "$BOLD" "$NC" \
        "${SHOP_DOMAIN:-?}" "$PS_ENV" "$PS_VERSION" "${WEB_PHP_VERSION_USED:-?}" "${PHP_SELECTED##*/}" "${PHP_SELECTED_VERSION:-?}"
    printf '%sTheme:%s %s → Parent: %s %s\n\n' "$BOLD" "$NC" "${THEME_NAME:-?}" "${THEME_PARENT:-?}" "${PARENT_VERSION:-?}"
    printf '  %-3s %-10s %-6s %s\n' "#" "Version" "Typ" "Status"

    local selectable=()
    for v in "${shown[@]}"; do
        i=$((i + 1))
        type="$(version_type "$PS_VERSION" "$v")"
        gate_target "$v"
        local label
        case "$GATE_LEVEL" in
            ok) label="${GREEN}✅ ok${NC}" ;;
            warn) label="${ORANGE}⚠️  ${GATE_MSG}${NC}" ;;
            *) label="${RED}⛔ ${GATE_MSG}${NC}" ;;
        esac
        if [ "$GATE_LEVEL" != "block" ]; then
            selectable[$i]="$v"
            if [ -z "$recommended" ] && [ "$type" = "patch" ]; then recommended="$i"; fi
        fi
        if [ "$recommended" = "$i" ]; then label="$label ${GREEN}(empfohlen)${NC}"; fi
        printf '  %-3s %-10s %-6s %s\n' "$i)" "$v" "$type" "$label"
    done
    if [ "${OPT_ALL:-0}" != "1" ]; then
        detail "  (Es wird je Minor-Linie nur die neueste Version gezeigt – alle Versionen: --all)"
    fi
    if [ "${OPT_LIST_ONLY:-0}" = "1" ]; then
        return 0
    fi
    if [ -z "$recommended" ]; then
        for ((choice = 1; choice <= i; choice++)); do
            if [ -n "${selectable[$choice]:-}" ]; then recommended="$choice"; break; fi
        done
    fi
    if [ -z "$recommended" ]; then
        err "Keine der Versionen ist aktuell auswählbar (siehe Status)."
        return 1
    fi
    printf '\n'
    if [ ! -t 0 ] || [ "${OPT_YES:-0}" = "1" ]; then
        choice="$recommended"
        info "Auswahl: $choice (automatisch)"
    else
        read -r -p "Auswahl [${recommended}]: " choice
        choice="${choice:-$recommended}"
    fi
    if [ -z "${selectable[$choice]:-}" ]; then
        err "Ungültige oder gesperrte Auswahl: '$choice'"
        return 1
    fi
    TARGET_VERSION="${selectable[$choice]}"
}

# Determine TARGET_VERSION from --to or menu
determine_target() {
    if [ -n "${OPT_TO:-}" ]; then
        TARGET_VERSION="$(resolve_target "$OPT_TO")" || die "Keine passende Version für --to=${OPT_TO} gefunden (installiert: ${PS_VERSION})."
    else
        select_target_interactive || return 1
    fi
    release_info "$TARGET_VERSION" || die "Release-Informationen für ${TARGET_VERSION} fehlen."
    RUN_FROM="$PS_VERSION"; RUN_TO="$TARGET_VERSION"
    return 0
}

# ------------------------------------------------------------------------------
# Download & verification
# ------------------------------------------------------------------------------

download_file() {
    local url="$1" target="$2"
    curl -fsSL --retry 3 --max-time 1800 -o "$target.part" "$url" || { rm -f "$target.part"; return 1; }
    mv "$target.part" "$target"
}

# Download & verify the release archive + checksum XML of REL_VERSION
release_download() {
    mkdir -p "$REL_DIR"
    local zip="$REL_DIR/$REL_ZIP_NAME" xml="$REL_DIR/$REL_XML_NAME" sums="$REL_DIR/SHA256SUMS"

    if [ ! -s "$xml" ]; then
        info "Lade Checksum-XML ${REL_VERSION} ..."
        download_file "$REL_XML_URL" "$xml" || die "Download fehlgeschlagen: $REL_XML_URL"
    fi
    if [ ! -s "$zip" ]; then
        info "Lade Release-Archiv ${REL_VERSION} (${REL_DIST} ${REL_DISTVER}) ..."
        download_file "$REL_ZIP_URL" "$zip" || die "Download fehlgeschlagen: $REL_ZIP_URL"
        rm -f "$sums"
    fi
    if [ ! -s "$sums" ]; then
        # First use of this archive: verify against the API checksum, then pin it with SHA256
        if [ -n "$REL_MD5" ]; then
            local md5
            md5="$(file_md5 "$zip")"
            if [ "$md5" != "$REL_MD5" ]; then
                mv "$zip" "$zip.corrupt"
                die "MD5 des Archivs stimmt nicht (erwartet $REL_MD5, erhalten $md5)."
            fi
            ok "MD5 des Archivs verifiziert (API)."
        else
            warn "Die API liefert keine MD5-Prüfsumme – Archiv wird nur strukturell geprüft."
        fi
        printf '%s  %s\n%s  %s\n' "$(file_sha256 "$zip")" "$REL_ZIP_NAME" "$(file_sha256 "$xml")" "$REL_XML_NAME" > "$sums"
    fi

    # Verify against the SHA256 recorded at first download (guarantees Staging == Production)
    if [ -s "$sums" ]; then
        local expected actual name
        while read -r expected name; do
            actual="$(file_sha256 "$REL_DIR/$name")"
            [ "$actual" = "$expected" ] || die "SHA256 von $name stimmt nicht mit dem Erst-Download überein!"
        done < "$sums"
        RELEASE_ZIP_SHA256="$(awk -v n="$REL_ZIP_NAME" '$2 == n {print $1}' "$sums")"
        ok "Release-Dateien verifiziert (SHA256 ${RELEASE_ZIP_SHA256:0:16}…)."
    fi

    local xml_version zip_info zip_version zip_vendor
    xml_version="$(tool xml-version "$xml")" || die "Checksum-XML ungültig: $xml"
    [ "$xml_version" = "$REL_VERSION" ] || die "Checksum-XML gehört zu ${xml_version}, erwartet ${REL_VERSION}."
    zip_info="$(tool zip-ps-version "$zip")" || die "Archiv enthält keine erkennbare PrestaShop-Version: $zip"
    IFS='|' read -r zip_version zip_vendor <<< "$zip_info"
    [ "$zip_version" = "$REL_VERSION" ] || die "Archiv enthält PrestaShop ${zip_version}, erwartet ${REL_VERSION}."
    [ "$zip_vendor" = "vendor" ] || die "Archiv enthält kein vendor/ – kein installierbares Release-Paket."
    ok "Archiv-Aufbau geprüft (PrestaShop ${zip_version}, inkl. vendor/)."
    RELEASE_ZIP="$zip"; RELEASE_XML="$xml"
}

# Extract classes/ + controllers/ of the release (for the override report), cached
release_core_dir() {
    local dir="$REL_DIR/core"
    if [ ! -f "$dir/.complete" ]; then
        rm -rf "$dir"
        tool release-extract "$RELEASE_ZIP" "$dir" classes/ controllers/ >/dev/null || die "Konnte Core-Dateien nicht entpacken."
        touch "$dir/.complete"
    fi
    printf '%s' "$dir"
}

# Checksum XML of the CURRENT version (for the integrity check)
current_release_xml() {
    local saved_vars
    saved_vars="$REL_VERSION|$REL_DIST|$REL_DISTVER|$REL_PHP_MIN|$REL_PHP_MAX|$REL_STABILITY|$REL_ZIP_URL|$REL_XML_URL|$REL_MD5|$REL_NOTES|$REL_DIR|$REL_ZIP_NAME|$REL_XML_NAME"
    CURRENT_XML=""
    if release_info "$PS_VERSION"; then
        mkdir -p "$REL_DIR"
        if [ ! -s "$REL_DIR/$REL_XML_NAME" ]; then
            download_file "$REL_XML_URL" "$REL_DIR/$REL_XML_NAME" || true
        fi
        [ -s "$REL_DIR/$REL_XML_NAME" ] && CURRENT_XML="$REL_DIR/$REL_XML_NAME"
    fi
    IFS='|' read -r REL_VERSION REL_DIST REL_DISTVER REL_PHP_MIN REL_PHP_MAX REL_STABILITY REL_ZIP_URL REL_XML_URL REL_MD5 REL_NOTES REL_DIR REL_ZIP_NAME REL_XML_NAME <<< "$saved_vars"
}

# ------------------------------------------------------------------------------
# Update Assistant (autoupgrade) module
# ------------------------------------------------------------------------------

autoupgrade_versions() {
    AU_INSTALLED=""; AU_LATEST=""; AU_LINK=""; AU_MD5=""
    local cfg="$PS_ROOT/modules/autoupgrade/autoupgrade.php"
    if [ -f "$cfg" ]; then
        AU_INSTALLED="$(tool module-info "$cfg" | sed -n 's/^version=//p')"
    fi
    local api line
    api="$(api_fetch autoupgrade 2>/dev/null)" || return 0
    line="$(tool autoupgrade-info "$api" "$PS_VERSION" 2>/dev/null)" || return 0
    IFS='|' read -r AU_LATEST AU_LINK AU_MD5 <<< "$line"
}

# Run an autoupgrade console command with the selected PHP.
# A "php" shim is put first in PATH, because autoupgrade chains its own steps
# with a hardcoded "php" (which may be a different version than the web PHP!).
autoupgrade_console() {
    make_tmp
    local shim="$PSU_TMP/phpshim"
    if [ ! -x "$shim/php" ]; then
        mkdir -p "$shim"
        printf '#!/bin/sh\nexec "%s" -d memory_limit=%s "$@"\n' "$PHP_SELECTED" "$PHP_MEMORY_LIMIT" > "$shim/php"
        chmod 700 "$shim/php"
    fi
    (cd "$PS_ROOT" && PATH="$shim:$PATH" "$shim/php" "$PS_ROOT/modules/autoupgrade/bin/console" "$@")
}

# Copy release files into <admin>/autoupgrade/download (where autoupgrade expects them)
autoupgrade_stage_release() {
    local dl="$PS_ROOT/$ADMIN_DIR/autoupgrade/download"
    mkdir -p "$dl" || die "Kann $dl nicht anlegen."
    local f
    for f in "$RELEASE_ZIP" "$RELEASE_XML"; do
        if [ ! -f "$dl/${f##*/}" ] || [ "$(file_sha256 "$dl/${f##*/}")" != "$(file_sha256 "$f")" ]; then
            cp -f "$f" "$dl/${f##*/}" || die "Kann ${f##*/} nicht nach $dl kopieren."
        fi
    done
}
