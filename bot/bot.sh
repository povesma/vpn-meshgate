#!/bin/sh

NTFY_URL="http://127.0.0.1:80"
CMD_TOPIC="${NTFY_CMD_TOPIC:-vpn-cmd}"
ALERT_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
IP_CHECK_URL="https://ifconfig.me"
SWITCH_REQUEST="/data/switch-request"
CONFIRM_FILE="/tmp/vpn-bot-confirm-mullvad"
RATE_FILE="/tmp/vpn-bot-last-cmd"
INSTANCES_JSON="/shared/vpn-instances.json"

log() { echo "[vpn-bot] $(date '+%H:%M:%S') $*"; }

validate_instance_name() {
    local name="$1"
    # Reject empty, non-alphanumeric+hyphen, and names starting/ending with hyphen
    case "${name}" in
        ""|-*|*-)   return 1 ;;
    esac
    # Only allow lowercase alphanumeric and hyphens
    case "${name}" in
        *[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

reply() {
    local title="$1" msg="$2" priority="${3:-default}"
    log "REPLY: ${title} - ${msg}"
    curl -sf -X POST "${NTFY_URL}/${CMD_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${msg}" 2>/dev/null || log "WARNING: Failed to send reply"
}

check_rate_limit() {
    local cmd="$1"
    if [ -f "${RATE_FILE}" ]; then
        local last_ts last_cmd now
        last_ts=$(cut -d' ' -f1 "${RATE_FILE}")
        last_cmd=$(cut -d' ' -f2- "${RATE_FILE}")
        now=$(date +%s)
        if [ "${last_cmd}" = "${cmd}" ] && [ $((now - last_ts)) -lt 60 ]; then
            reply "Rate Limited" "Command already processed, please wait"
            return 1
        fi
    fi
    echo "$(date +%s) ${cmd}" > "${RATE_FILE}"
    return 0
}

cleanup_confirm() {
    if [ -f "${CONFIRM_FILE}" ]; then
        local ts now
        ts=$(cat "${CONFIRM_FILE}")
        now=$(date +%s)
        if [ $((now - ts)) -ge 30 ]; then
            rm -f "${CONFIRM_FILE}"
        fi
    fi
}

mullvad_country_name() {
    case "$1" in
        us) echo "United States" ;;
        uk) echo "United Kingdom" ;;
        nl) echo "Netherlands" ;;
        de) echo "Germany" ;;
        fr) echo "France" ;;
        ch) echo "Switzerland" ;;
        se) echo "Sweden" ;;
        fi) echo "Finland" ;;
        be) echo "Belgium" ;;
        cy) echo "Cyprus" ;;
        ca) echo "Canada" ;;
        jp) echo "Japan" ;;
        sg) echo "Singapore" ;;
        th) echo "Thailand" ;;
        id) echo "Indonesia" ;;
        il) echo "Israel" ;;
        tr) echo "Turkey" ;;
        al) echo "Albania" ;;
        ua) echo "Ukraine" ;;
        za) echo "South Africa" ;;
        ng) echo "Nigeria" ;;
        *)  echo "" ;;
    esac
}

cmd_ping() {
    local uptime
    uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo "unknown")
    reply "Pong" "uptime: ${uptime}s"
}

cmd_status() {
    local mullvad_status="UP"
    local public_ip
    public_ip=$(curl -sf --max-time 10 "${IP_CHECK_URL}" 2>/dev/null | grep -o '[0-9.]*' | head -1)

    if [ -z "${public_ip}" ]; then
        mullvad_status="DOWN (timeout)"
    elif [ -n "${VPS_PUBLIC_IP}" ] && [ "${public_ip}" = "${VPS_PUBLIC_IP}" ]; then
        mullvad_status="DOWN (kill switch)"
    else
        mullvad_status="UP (${public_ip})"
    fi

    local instances_status=""
    if [ -f "${INSTANCES_JSON}" ]; then
        for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
            local name check_ip container inst_status
            name=$(echo "$row" | jq -r '.name')
            check_ip=$(echo "$row" | jq -r '.check_ip')
            container=$(echo "$row" | jq -r '.container')
            if [ -n "${check_ip}" ] && [ "${check_ip}" != "" ]; then
                if ping -c 1 -W 5 "${check_ip}" >/dev/null 2>&1; then
                    inst_status="UP (${check_ip})"
                else
                    inst_status="DOWN (${check_ip})"
                fi
            else
                inst_status="NO CHECK IP"
            fi
            instances_status="${instances_status}
${name}: ${inst_status}"
        done
    else
        instances_status="
(no vpn-instances.json)"
    fi

    reply "VPN Status" "Mullvad: ${mullvad_status}${instances_status}"
}

cmd_ip() {
    local public_ip
    public_ip=$(curl -sf --max-time 10 "${IP_CHECK_URL}" 2>/dev/null | grep -o '[0-9.]*' | head -1)
    if [ -n "${public_ip}" ]; then
        reply "Public IP" "${public_ip}"
    else
        reply "Public IP" "Failed to retrieve IP"
    fi
}

cmd_help() {
    reply "VPN Bot Commands" "ping - check bot is alive
status - VPN tunnel status (per-instance)
ip - show public exit IP
restart <name> - restart a VPN instance
restart company - restart all VPN instances
restart mullvad - restart Mullvad (requires confirm)
disable <name> - stop a VPN instance (SSH to re-enable)
disable company - stop all VPN instances
mullvad <cc> - switch exit country (mullvad list for codes)
dns test - test DNS resolution
help - show this message" "low"
}

cmd_mullvad_list() {
    reply "Mullvad Countries" "us=United States  uk=United Kingdom  nl=Netherlands
de=Germany        fr=France          ch=Switzerland
se=Sweden         fi=Finland         be=Belgium
cy=Cyprus         ca=Canada          jp=Japan
sg=Singapore      th=Thailand        id=Indonesia
il=Israel         tr=Turkey          al=Albania
ua=Ukraine        za=South Africa    ng=Nigeria
Send: mullvad <code>" "low"
}

cmd_restart_instance() {
    local name="$1"
    if ! validate_instance_name "${name}"; then
        reply "Invalid Name" "Instance name must be lowercase alphanumeric and hyphens only."
        return
    fi
    local container="vpn-${name}"
    if [ -f "${INSTANCES_JSON}" ]; then
        if ! jq -e --arg n "${name}" '.[] | select(.name == $n)' "${INSTANCES_JSON}" >/dev/null 2>&1; then
            reply "Unknown Instance" "No VPN instance '${name}'. Send 'status' to see available instances."
            return
        fi
    fi
    reply "VPN Restart" "Restarting ${container}..." "high"
    if docker restart "${container}" >/dev/null 2>&1; then
        sleep 5
        reply "VPN Restarted" "${container} restarted" "high"
    else
        reply "VPN Restart" "Failed to restart ${container}" "urgent"
    fi
}

cmd_restart_company() {
    if [ -f "${INSTANCES_JSON}" ]; then
        local names
        names=$(jq -r '.[].container' "${INSTANCES_JSON}")
        reply "Company VPN" "Restarting all VPN instances..." "high"
        for container in ${names}; do
            docker restart "${container}" >/dev/null 2>&1 || \
                log "WARNING: failed to restart ${container}"
        done
        sleep 5
        reply "Company VPN Restarted" "All VPN instances restarted" "high"
    else
        reply "Company VPN" "No vpn-instances.json found" "urgent"
    fi
}

cmd_restart_mullvad() {
    echo "$(date +%s)" > "${CONFIRM_FILE}"
    reply "Restart Mullvad?" "This will restart the Mullvad tunnel and disconnect ALL VPN traffic for ~30s. Send 'confirm' within 30s to proceed." "urgent"
}

cmd_confirm() {
    if [ ! -f "${CONFIRM_FILE}" ]; then
        reply "Nothing to confirm" "No pending restart request"
        return
    fi
    local ts now
    ts=$(cat "${CONFIRM_FILE}")
    now=$(date +%s)
    if [ $((now - ts)) -ge 30 ]; then
        rm -f "${CONFIRM_FILE}"
        reply "Expired" "Confirmation window expired. Send 'restart mullvad' again."
        return
    fi
    rm -f "${CONFIRM_FILE}"
    reply "Mullvad Restart" "Initiating Mullvad restart... Bot will reconnect after recovery." "urgent"
    docker restart gluetun >/dev/null 2>&1
}

cmd_dns_test() {
    local results=""
    if [ -f "${INSTANCES_JSON}" ]; then
        for row in $(jq -c '.[]' "${INSTANCES_JSON}"); do
            local name domains
            name=$(echo "$row" | jq -r '.name')
            domains=$(echo "$row" | jq -r '.dns_domains[]' 2>/dev/null)
            for domain in ${domains}; do
                local result
                result=$(dig +short @127.0.0.1 "${domain}" 2>/dev/null)
                [ -z "${result}" ] && result="no result"
                results="${results}
${name} (${domain}): ${result}"
            done
        done
    fi
    local public_result
    public_result=$(dig +short @127.0.0.1 example.com 2>/dev/null)
    [ -z "${public_result}" ] && public_result="no result"
    results="${results}
Public (example.com): ${public_result}"

    reply "DNS Test" "${results}"
}

cmd_mullvad_switch() {
    local keyword="$1"
    local country
    country=$(mullvad_country_name "${keyword}")
    if [ -z "${country}" ]; then
        reply "Unknown Country" "Unknown country '${keyword}'. Send 'mullvad list' for available codes."
        return
    fi

    if [ ! -d /data ]; then
        reply "Switch Failed" "Switcher data volume not mounted. Check mullvad-switcher container." "urgent"
        return
    fi

    if [ -f "${SWITCH_REQUEST}" ]; then
        reply "Switch Busy" "A country switch is already in progress. Please wait." "default"
        return
    fi

    echo "${country}" > "${SWITCH_REQUEST}"
    reply "Switch Queued" "Switching to ${country}... mullvad-switcher will report back." "high"
}

cmd_disable_instance() {
    local name="$1"
    if ! validate_instance_name "${name}"; then
        reply "Invalid Name" "Instance name must be lowercase alphanumeric and hyphens only."
        return
    fi
    local container="vpn-${name}"
    if [ -f "${INSTANCES_JSON}" ]; then
        if ! jq -e --arg n "${name}" '.[] | select(.name == $n)' "${INSTANCES_JSON}" >/dev/null 2>&1; then
            reply "Unknown Instance" "No VPN instance '${name}'. Send 'status' to see available instances."
            return
        fi
    fi
    docker stop "${container}" >/dev/null 2>&1
    docker update --restart=no "${container}" >/dev/null 2>&1
    reply "VPN Disabled" "${container} stopped and restart disabled. Use SSH to re-enable." "urgent"
}

cmd_disable_company() {
    if [ -f "${INSTANCES_JSON}" ]; then
        for container in $(jq -r '.[].container' "${INSTANCES_JSON}"); do
            docker stop "${container}" >/dev/null 2>&1
            docker update --restart=no "${container}" >/dev/null 2>&1
        done
        reply "All VPN Disabled" "All VPN instances stopped. Use SSH to re-enable." "urgent"
    else
        reply "VPN Disabled" "No vpn-instances.json found" "urgent"
    fi
}

cmd_unknown() {
    reply "Unknown Command" "Unknown command: $1. Send 'help' for available commands."
}

handle_message() {
    local line="$1"
    local event msg cmd

    event=$(echo "${line}" | grep -o '"event":"[^"]*"' | head -1 | sed 's/"event":"//;s/"//')
    [ "${event}" != "message" ] && return

    # Ignore bot's own replies (they always have a title field)
    echo "${line}" | grep -q '"title":' && return

    msg=$(echo "${line}" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')
    [ -z "${msg}" ] && return

    cmd=$(echo "${msg}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    log "Received command: ${cmd}"

    cleanup_confirm
    check_rate_limit "${cmd}" || return

    case "${cmd}" in
        ping)               cmd_ping ;;
        status)             cmd_status ;;
        ip)                 cmd_ip ;;
        "mullvad list")     cmd_mullvad_list ;;
        mullvad\ *)         cmd_mullvad_switch "${cmd#mullvad }" ;;
        "restart company")  cmd_restart_company ;;
        "restart mullvad")  cmd_restart_mullvad ;;
        restart\ *)         cmd_restart_instance "${cmd#restart }" ;;
        "disable company")  cmd_disable_company ;;
        disable\ *)         cmd_disable_instance "${cmd#disable }" ;;
        "dns test")         cmd_dns_test ;;
        help)               cmd_help ;;
        confirm)            cmd_confirm ;;
        *)                  cmd_unknown "${cmd}" ;;
    esac
}

log "vpn-bot starting"
sleep 5

reply "VPN Bot Online" "VPN Bot is online and listening for commands. Send 'help' for available commands."

while true; do
    log "Connecting to command stream..."
    curl -sf --no-buffer "http://127.0.0.1:80/${CMD_TOPIC}/json" \
        | while IFS= read -r line; do
            handle_message "${line}"
        done
    log "Stream disconnected, reconnecting in 5s..."
    sleep 5
done
