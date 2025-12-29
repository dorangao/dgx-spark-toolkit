#!/usr/bin/env bash
set -euo pipefail

# Ensure the RoCE/200G interface has the expected IP and optionally persist it via NetworkManager.
# Defaults are host-aware but can be overridden via:
#   - env vars: FABRIC_IP, FABRIC_CIDR, FABRIC_IFACES, FABRIC_CONNECTION, FABRIC_PERSIST (1/0)
#   - config file: FABRIC_ENV, DGX_SPARK_NETWORK_CONFIG, ~/.config/dgx-spark-toolkit/fabric.env

load_overrides() {
    local -a candidates=()
    [[ -n "${FABRIC_ENV:-}" ]] && candidates+=("$FABRIC_ENV")
    [[ -n "${DGX_SPARK_NETWORK_CONFIG:-}" ]] && candidates+=("$DGX_SPARK_NETWORK_CONFIG")
    candidates+=("$HOME/.config/dgx-spark-toolkit/fabric.env" "$HOME/.dgx-spark-fabric" "$HOME/fabric.env")

    for cfg in "${candidates[@]}"; do
        [[ -f "$cfg" ]] || continue
        # shellcheck disable=SC1090
        source "$cfg"
        break
    done
}
load_overrides

# Defaults (auto-pick IP based on hostname)
case "$(hostname -s)" in
    spark-2959) DEFAULT_FABRIC_IP="10.10.10.1" ;;
    spark-ba63) DEFAULT_FABRIC_IP="10.10.10.2" ;;
    *) DEFAULT_FABRIC_IP="" ;;
esac

DEFAULT_FABRIC_IFACES=("enp1s0f1np1" "enP2p1s0f1np1")

if [[ -n "${FABRIC_IFACES:-}" ]]; then
    read -r -a FABRIC_IFACES_ARR <<<"$FABRIC_IFACES"
else
    FABRIC_IFACES_ARR=("${DEFAULT_FABRIC_IFACES[@]}")
fi

FABRIC_IP="${FABRIC_IP:-$DEFAULT_FABRIC_IP}"
FABRIC_CIDR="${FABRIC_CIDR:-${FABRIC_IP:+$FABRIC_IP/24}}"
FABRIC_CONNECTION="${FABRIC_CONNECTION:-}"
FABRIC_PERSIST="${FABRIC_PERSIST:-1}"

SUDO=""
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
fi

log() { printf '[%s] %s\n' "$1" "$2"; }

pick_iface() {
    local first=""
    for ifc in "${FABRIC_IFACES_ARR[@]}"; do
        [[ -d "/sys/class/net/$ifc" ]] || continue
        [[ -z "$first" ]] && first="$ifc"
        if [[ "$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null || echo 0)" == "1" ]]; then
            echo "$ifc"
            return 0
        fi
    done
    [[ -n "$first" ]] && { echo "$first"; return 0; }
    return 1
}

ensure_ip() {
    local ifc="$1" cidr="$2"
    local ip="${cidr%/*}"

    if ip -o -4 addr show dev "$ifc" | awk '{print $4}' | grep -q "^${ip}/"; then
        log INFO "IP $ip already present on $ifc"
        return 0
    fi

    log INFO "Adding $cidr to $ifc (runtime)"
    if $SUDO ip addr add "$cidr" dev "$ifc"; then
        log INFO "Added $cidr to $ifc"
    else
        log WARN "Failed to add $cidr to $ifc"
    fi
}

persist_nm() {
    local ifc="$1" cidr="$2" name="$3"
    command -v nmcli >/dev/null 2>&1 || { log WARN "nmcli not installed; skipping persistence"; return 1; }

    if [[ -z "$name" ]]; then
        name=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v i="$ifc" '$2==i {print $1; exit}')
        [[ -z "$name" ]] && name=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v i="$ifc" '$2==i {print $1; exit}')
    fi

    if [[ -z "$name" ]]; then
        log WARN "No NetworkManager connection found for $ifc; cannot persist"
        nmcli connection show | grep -E "NAME|ethernet" || true
        return 1
    fi

    if nmcli connection show "$name" | grep -q "$cidr"; then
        log INFO "$cidr already present in connection $name"
        return 0
    fi

    if nmcli connection modify "$name" +ipv4.addresses "$cidr"; then
        log INFO "Persisted $cidr into connection $name"
        nmcli connection up "$name" >/dev/null 2>&1 || true
    else
        log WARN "Failed to persist $cidr into connection $name"
    fi
}

main() {
    if [[ -z "$FABRIC_CIDR" ]]; then
        log ERROR "No FABRIC_IP/FABRIC_CIDR defined. Set FABRIC_IP (e.g. 10.10.10.2) or provide a fabric.env."
        exit 1
    fi

    ifc=$(pick_iface) || { log ERROR "No candidate interfaces found: ${FABRIC_IFACES_ARR[*]}"; exit 1; }
    log INFO "Using interface $ifc"

    if [[ "$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null || echo 0)" == "0" ]]; then
        log WARN "$ifc reports NO-CARRIER (check cable/port); proceeding anyway"
    fi

    ensure_ip "$ifc" "$FABRIC_CIDR"

    if [[ "$FABRIC_PERSIST" == "1" ]]; then
        persist_nm "$ifc" "$FABRIC_CIDR" "$FABRIC_CONNECTION" || true
    else
        log INFO "Skipping persistence (FABRIC_PERSIST=0)"
    fi

    ip -br addr show "$ifc" || true
    $SUDO ethtool "$ifc" | awk '/Speed:|Link detected:/'
}

main "$@"
