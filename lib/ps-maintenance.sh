#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # globals are shared between the library files
# ------------------------------------------------------------------------------
# PrestaShop Upgrade Toolkit - maintenance mode with automatic IP whitelisting
# Original values are stored in $PSU_HOME/state/<env>-maintenance.state and
# restored by "maintenance off" (also after a crash / in a later session).
# ------------------------------------------------------------------------------

maintenance_state_file() { printf '%s/state/%s-maintenance.state' "$PSU_HOME" "$PS_ENV"; }

# IP of the current SSH session (= normally the public IP of your browser)
ssh_client_ip() {
    local ip="${SSH_CLIENT%% *}"
    [ -n "$ip" ] || ip="${SSH_CONNECTION%% *}"
    printf '%s' "$ip"
}

maintenance_status() {
    local enabled ips
    enabled="$(db_query "SELECT GROUP_CONCAT(DISTINCT IFNULL(value,'') SEPARATOR ',') FROM ${DB_PREFIX}configuration WHERE name='PS_SHOP_ENABLE'" 2>/dev/null)"
    ips="$(config_get PS_MAINTENANCE_IP)"
    case ",$enabled," in
        *,0,*) printf '%sWartungsmodus: AKTIV%s (PS_SHOP_ENABLE=%s)\n' "$ORANGE" "$NC" "$enabled" ;;
        *) printf '%sWartungsmodus: aus%s (PS_SHOP_ENABLE=%s)\n' "$GREEN" "$NC" "$enabled" ;;
    esac
    printf 'Freigegebene IPs (PS_MAINTENANCE_IP): %s\n' "${ips:-–}"
    if [ -f "$(maintenance_state_file)" ]; then
        detail "Vom Toolkit aktiviert – Originalwerte gespeichert in $(maintenance_state_file)"
    fi
}

# Merge comma separated IP lists (unique, order preserved)
merge_ips() {
    printf '%s' "$*" | tr ', ' '\n\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

maintenance_on() {
    local state
    state="$(maintenance_state_file)"
    mkdir -p "$PSU_HOME/state"

    if [ ! -f "$state" ]; then
        # Save originals (name, shop group, shop, value) – only once, never overwrite
        db_query "SELECT name, IFNULL(id_shop_group,'NULL'), IFNULL(id_shop,'NULL'), IFNULL(value,'') FROM ${DB_PREFIX}configuration WHERE name IN ('PS_SHOP_ENABLE','PS_MAINTENANCE_IP')" > "$state.tmp" \
            || die "Konnte die aktuelle Wartungs-Konfiguration nicht lesen."
        mv "$state.tmp" "$state"
    else
        detail "Originalwerte bereits gesichert (Toolkit-Wartungsmodus war schon aktiv)."
    fi

    local current ssh_ip ips extra
    current="$(config_get PS_MAINTENANCE_IP)"
    ssh_ip="$(ssh_client_ip)"
    ips="$(merge_ips "$current" "$ssh_ip" "${WEB_REMOTE_IP:-}" "${MAINTENANCE_IPS:-}")"

    info "Folgende IPs behalten während der Wartung Zugriff:"
    [ -n "$ssh_ip" ] && detail "  • ${ssh_ip}  (deine SSH-Sitzung)"
    [ -n "${WEB_REMOTE_IP:-}" ] && detail "  • ${WEB_REMOTE_IP}  (Server selbst – für die Smoke-Tests)"
    [ -n "${MAINTENANCE_IPS:-}" ] && detail "  • ${MAINTENANCE_IPS}  (.env MAINTENANCE_IPS)"
    [ -n "$current" ] && detail "  • ${current}  (bereits eingetragen)"
    detail "  Hinweis: Nutzt dein Browser IPv6 und SSH IPv4 (oder umgekehrt), trage die zweite IP in MAINTENANCE_IPS ein."
    if [ -t 0 ] && [ "${OPT_YES:-0}" != "1" ]; then
        read -r -p "Weitere IPs (kommagetrennt) oder Enter: " extra
        [ -n "$extra" ] && ips="$(merge_ips "$ips" "$extra")"
    fi
    MAINTENANCE_IP_LIST="$ips"
    maintenance_apply "$ips" || die "Konnte den Wartungsmodus nicht aktivieren."
    ok "Wartungsmodus aktiv (freigegeben: ${ips:-–})."
}

# Write PS_SHOP_ENABLE=0 and the IP whitelist
maintenance_apply() {
    local ips="$1"
    db_query "UPDATE ${DB_PREFIX}configuration SET value='0', date_upd=NOW() WHERE name='PS_SHOP_ENABLE'" || return 1
    if [ -n "$(db_scalar "SELECT id_configuration FROM ${DB_PREFIX}configuration WHERE name='PS_MAINTENANCE_IP' LIMIT 1")" ]; then
        db_query "UPDATE ${DB_PREFIX}configuration SET value='$(sql_escape "$ips")', date_upd=NOW() WHERE name='PS_MAINTENANCE_IP'" || return 1
    else
        db_query "INSERT INTO ${DB_PREFIX}configuration (id_shop_group, id_shop, name, value, date_add, date_upd) VALUES (NULL, NULL, 'PS_MAINTENANCE_IP', '$(sql_escape "$ips")', NOW(), NOW())" || return 1
    fi
    MAINTENANCE_ACTIVE=1
}

# Re-assert maintenance after a DB import (no prompts, originals are kept)
maintenance_on_quiet() {
    local ips
    ips="$(merge_ips "${MAINTENANCE_IP_LIST:-}" "$(config_get PS_MAINTENANCE_IP)" "$(ssh_client_ip)" "${WEB_REMOTE_IP:-}" "${MAINTENANCE_IPS:-}")"
    maintenance_apply "$ips" && detail "Wartungsmodus nach DB-Import erneut gesetzt."
}

maintenance_off() {
    local state name group shop value
    state="$(maintenance_state_file)"
    if [ -f "$state" ]; then
        while IFS=$'\t' read -r name group shop value; do
            [ -n "$name" ] || continue
            case "$group" in ''|NULL) group="NULL" ;; *[!0-9]*) continue ;; esac
            case "$shop" in ''|NULL) shop="NULL" ;; *[!0-9]*) continue ;; esac
            db_query "UPDATE ${DB_PREFIX}configuration SET value='$(sql_escape "$value")', date_upd=NOW() WHERE name='$(sql_escape "$name")' AND id_shop_group <=> ${group} AND id_shop <=> ${shop}" \
                || die "Konnte ${name} nicht zurücksetzen."
        done < "$state"
        rm -f "$state"
        MAINTENANCE_ACTIVE=0
        ok "Wartungsmodus beendet – Originalwerte (PS_SHOP_ENABLE / PS_MAINTENANCE_IP) wiederhergestellt."
    else
        warn "Keine gespeicherten Originalwerte gefunden (Wartung wurde nicht vom Toolkit aktiviert)."
        if confirm "Shop trotzdem aktivieren (PS_SHOP_ENABLE=1)?"; then
            db_query "UPDATE ${DB_PREFIX}configuration SET value='1', date_upd=NOW() WHERE name='PS_SHOP_ENABLE'"
            MAINTENANCE_ACTIVE=0
            ok "Shop aktiviert."
        fi
    fi
}
