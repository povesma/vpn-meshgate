#!/bin/sh

NTFY_URL="http://127.0.0.1:80"
CMD_TOPIC="${NTFY_CMD_TOPIC:-vpn-cmd}"
ALERT_TOPIC="${NTFY_TOPIC:-vpn-alerts}"
IP_CHECK_URL="https://ifconfig.me"
SWITCH_REQUEST="/data/switch-request"
CONFIRM_FILE="/tmp/vpn-bot-confirm-mullvad"
RATE_FILE="/tmp/vpn-bot-last-cmd"

log() { echo "[vpn-bot] $(date '+%H:%M:%S') $*"; }

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
    local mullvad_status="UP" company_status="UP"
    local public_ip
    public_ip=$(curl -sf --max-time 10 "${IP_CHECK_URL}" 2>/dev/null | grep -o '[0-9.]*' | head -1)

    if [ -z "${public_ip}" ]; then
        mullvad_status="DOWN (timeout)"
    elif [ -n "${VPS_PUBLIC_IP}" ] && [ "${public_ip}" = "${VPS_PUBLIC_IP}" ]; then
        mullvad_status="DOWN (kill switch)"
    else
        mullvad_status="UP (${public_ip})"
    fi

    if [ -n "${L2TP_CHECK_IP}" ]; then
        if ping -c 1 -W 5 "${L2TP_CHECK_IP}" >/dev/null 2>&1; then
            company_status="UP (${L2TP_CHECK_IP} reachable)"
        else
            company_status="DOWN (${L2TP_CHECK_IP} unreachable)"
        fi
    else
        company_status="SKIP (no L2TP_CHECK_IP)"
    fi

    reply "VPN Status" "Mullvad: ${mullvad_status}
Company: ${company_status}"
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
status - VPN tunnel status
ip - show public exit IP
mullvad <cc> - switch exit country (mullvad list for codes)
restart company - restart L2TP tunnel
restart mullvad - restart Mullvad (requires confirm)
disable company - stop L2TP permanently (SSH to re-enable)
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

cmd_restart_company() {
    reply "Company VPN" "Restarting Company VPN..." "high"
    if docker restart l2tp-vpn >/dev/null 2>&1; then
        sleep 5
        local status="unknown"
        if ping -c 1 -W 5 "${L2TP_CHECK_IP}" >/dev/null 2>&1; then
            status="UP"
        else
            status="DOWN"
        fi
        reply "Company VPN Restarted" "L2TP container restarted. Status: ${status}" "high"
    else
        reply "Company VPN" "Failed to restart l2tp-vpn container" "urgent"
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
    local company_result public_result
    if [ -n "${COMPANY_DOMAIN}" ]; then
        company_result=$(dig +short @127.0.0.1 "${COMPANY_DOMAIN}" 2>/dev/null)
        [ -z "${company_result}" ] && company_result="no result"
    else
        company_result="SKIP (no COMPANY_DOMAIN)"
    fi
    public_result=$(dig +short @127.0.0.1 example.com 2>/dev/null)
    [ -z "${public_result}" ] && public_result="no result"

    reply "DNS Test" "Company (${COMPANY_DOMAIN:-n/a}): ${company_result}
Public (example.com): ${public_result}"
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
    reply "Switch Queued" "🕐 Switching to ${country}... mullvad-switcher will report back." "high"
}

# Re-enable via SSH only — prevents attacker with compromised Tailscale
# node from restoring corporate network access via ntfy
cmd_disable_company() {
    docker stop l2tp-vpn >/dev/null 2>&1
    docker update --restart=no l2tp-vpn >/dev/null 2>&1
    reply "Company VPN Disabled" "l2tp-vpn stopped and restart disabled. Use SSH to re-enable." "urgent"
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
        "disable company")  cmd_disable_company ;;
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
