#!/usr/bin/env bash
# ============================================================
#  DNS Tunnel Kit — Multi-Tunnel Setup Script
#  Supports: MasterDnsVPN + Slipstream + dnstt
#  Credits : https://github.com/mrvcoder
# ============================================================

set -euo pipefail

# ════════════════════════════════════════════════════════════
#  DEFAULTS (overridable via env vars or interactive menu)
# ════════════════════════════════════════════════════════════

SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"

TUNNEL_USER="${TUNNEL_USER:-}"
TUNNEL_PASS="${TUNNEL_PASS:-}"

MDNS_DOMAIN="${MDNS_DOMAIN:-a.example.com}"
SLIP_DOMAIN="${SLIP_DOMAIN:-b.example.com}"
DNSTT_DOMAIN="${DNSTT_DOMAIN:-c.example.com}"

MDNS_INSTALL_DIR="/opt/masterdnsvpn"
MDNS_PORT="5312"
MDNS_ENCRYPTION="2"   # 2=ChaCha20

SLIP_CERT_DIR="/etc/dnstm/tunnels/slip-socks"
SLIP_PORT="5310"

DNSTT_PORT="5311"
DNSTT_KEY_DIR="/opt/dnstt"

SOCKS_PORT="58077"
SOCKS_NOAUTH_PORT="58078"

DNSTM_CONFIG="/etc/dnstm/config.json"
MDNS_GH_BASE="https://github.com/masterking32/MasterDnsVPN/releases/latest/download"

# Derived after input (set by wizard or env)
SOCKS_USER="${TUNNEL_USER:-}"
SOCKS_PASS="${TUNNEL_PASS:-}"

# ════════════════════════════════════════════════════════════
#  COLORS & UI HELPERS
# ════════════════════════════════════════════════════════════

C_RESET="\e[0m"
C_BOLD="\e[1m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_BLUE="\e[34m"
C_CYAN="\e[36m"
C_WHITE="\e[97m"
C_DIM="\e[2m"

info()    { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
error()   { echo -e "${C_RED}[-]${C_RESET} $*"; exit 1; }
section() { echo -e "\n${C_CYAN}${C_BOLD}━━━ $* ━━━${C_RESET}"; }
hr()      { echo -e "${C_DIM}────────────────────────────────────────────────────${C_RESET}"; }
require() { command -v "$1" >/dev/null 2>&1 || error "Missing: $1. Install it first."; }

# ask VAR "Prompt" "default"
ask() {
    local var="$1" prompt="$2" default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${C_DIM}[${default}]${C_RESET}"
    echo -en "  ${C_WHITE}${prompt}${C_RESET}${display_default}: "
    local val
    read -r val
    [[ -z "$val" ]] && val="$default"
    printf -v "$var" '%s' "$val"
}

# ask_pass VAR "Prompt"
ask_pass() {
    local var="$1" prompt="$2"
    echo -en "  ${C_WHITE}${prompt}${C_RESET}: "
    local val
    read -rs val
    echo ""
    printf -v "$var" '%s' "$val"
}

# ask_yn "Question" → returns 0=yes 1=no
ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint
    [[ "$default" == "y" ]] && hint="${C_GREEN}Y${C_RESET}/n" || hint="y/${C_GREEN}N${C_RESET}"
    echo -en "  ${C_WHITE}${prompt}${C_RESET} [${hint}]: "
    local ans
    read -r ans
    [[ -z "$ans" ]] && ans="$default"
    [[ "${ans,,}" == "y" ]]
}

# numbered menu: pick_menu RESULT_VAR "Title" "opt1" "opt2" ...
pick_menu() {
    local var="$1"; shift
    local title="$1"; shift
    local options=("$@")
    echo ""
    echo -e "  ${C_CYAN}${C_BOLD}${title}${C_RESET}"
    echo ""
    local i=1
    for opt in "${options[@]}"; do
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n" "$i" "$opt"
        ((i++))
    done
    echo ""
    local choice
    while true; do
        echo -en "  ${C_WHITE}Choose [1-${#options[@]}]${C_RESET}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf -v "$var" '%s' "${options[$((choice-1))]}"
            break
        fi
        echo -e "  ${C_RED}Invalid choice. Enter a number between 1 and ${#options[@]}.${C_RESET}"
    done
}

draw_banner() {
    clear
    echo -e "${C_CYAN}${C_BOLD}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║          DNS TUNNEL KIT  —  Setup & Manager          ║
  ║   MasterDnsVPN  ·  Slipstream  ·  dnstt              ║
  ║   Credits: github.com/mrvcoder                        ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${C_RESET}"
}

press_enter() {
    echo ""
    echo -en "  ${C_DIM}Press Enter to continue...${C_RESET}"
    read -r
}

# ════════════════════════════════════════════════════════════
#  INSTALL HELPERS
# ════════════════════════════════════════════════════════════

install_deps() {
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y curl wget unzip python3 openssl 2>/dev/null || true
}

install_bundled_binaries() {
    section "Installing bundled binaries"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local bin_dir="${script_dir}/bin"
    for bin in dnstm microsocks slipstream-server dnstt-server; do
        if [[ -f "${bin_dir}/${bin}" ]]; then
            install -m 0755 "${bin_dir}/${bin}" "/usr/local/bin/${bin}"
            info "Installed: ${bin}"
        else
            warn "Not found in bin/: ${bin} (skip)"
        fi
    done
}

# ════════════════════════════════════════════════════════════
#  MASTERDNSVPN
# ════════════════════════════════════════════════════════════

download_masterdnsvpn() {
    section "Downloading MasterDnsVPN Server"
    local arch; arch=$(uname -m)
    local asset asset_legacy
    case "$arch" in
        x86_64)  asset="MasterDnsVPN_Server_Linux_AMD64.tar.gz"
                 asset_legacy="MasterDnsVPN_Server_Linux-Legacy_AMD64.tar.gz" ;;
        aarch64) asset="MasterDnsVPN_Server_Linux_ARM64.tar.gz"
                 asset_legacy="MasterDnsVPN_Server_Linux-Legacy_ARM64.tar.gz" ;;
        *)       error "Unsupported architecture: $arch" ;;
    esac

    info "Fetching latest release info from GitHub..."
    local api_url="https://api.github.com/repos/masterking32/MasterDnsVPN/releases/latest"
    local release_json
    release_json=$(curl -sf --connect-timeout 15 --max-time 30 \
        -H "Accept: application/vnd.github+json" "$api_url") \
        || { warn "GitHub API unreachable — using fallback URL"; release_json=""; }

    get_asset_url() {
        local name="$1"
        [[ -z "$release_json" ]] && return
        echo "$release_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    if a['name'] == '${name}':
        print(a['browser_download_url']); break
" 2>/dev/null
    }

    local url; url=$(get_asset_url "$asset")
    [[ -z "$url" ]] && url="${MDNS_GH_BASE}/${asset}"

    mkdir -p "$MDNS_INSTALL_DIR"
    local tmp; tmp=$(mktemp -d)

    info "Downloading ${asset} (~42MB)..."
    if ! curl -L --retry 3 --retry-delay 3 --connect-timeout 30 --max-time 600 \
              --progress-bar -o "${tmp}/server.tar.gz" "$url"; then
        warn "Trying legacy build..."
        local url_legacy; url_legacy=$(get_asset_url "$asset_legacy")
        [[ -z "$url_legacy" ]] && url_legacy="${MDNS_GH_BASE}/${asset_legacy}"
        curl -L --retry 3 --retry-delay 3 --connect-timeout 30 --max-time 600 \
             --progress-bar -o "${tmp}/server.tar.gz" "$url_legacy" \
             || { rm -rf "$tmp"; error "Download failed"; }
    fi

    info "Extracting..."
    tar xf "${tmp}/server.tar.gz" -C "${tmp}"
    local bin; bin=$(find "${tmp}" -type f -name 'MasterDnsVPN_Server*' \
        ! -name '*.gz' ! -name '*.zip' ! -name '*.toml' ! -name '*.txt' | head -1)
    [[ -z "$bin" ]] && error "Server binary not found in archive"

    mv "$bin" "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server"
    chmod +x "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server"
    rm -rf "$tmp"
    info "MasterDnsVPN installed ($(du -sh "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server" | cut -f1))"
}

write_masterdnsvpn_config() {
    section "Writing MasterDnsVPN config"
    local key_file="${MDNS_INSTALL_DIR}/encrypt_key.txt"
    local enc_key
    if [[ -f "$key_file" ]]; then
        enc_key=$(cat "$key_file")
        info "Reusing existing encrypt key."
    else
        enc_key=$(openssl rand -hex 32)
        echo "$enc_key" > "$key_file"
        chmod 600 "$key_file"
        info "Generated new encrypt key → ${key_file}"
    fi

    local socks5_auth socks5_user socks5_pass
    if [[ -n "${TUNNEL_USER}" ]]; then
        socks5_auth="true"
        socks5_user="${TUNNEL_USER}"
        socks5_pass="${TUNNEL_PASS}"
    else
        socks5_auth="false"
        socks5_user="admin"
        socks5_pass="unused"
    fi

    cat > "${MDNS_INSTALL_DIR}/server_config.toml" << TOML
# MasterDnsVPN Server Config — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")

UDP_HOST = "127.0.0.1"
UDP_PORT = ${MDNS_PORT}
DOMAIN = ["${MDNS_DOMAIN}"]

PROTOCOL_TYPE = "SOCKS5"
USE_EXTERNAL_SOCKS5 = false
FORWARD_IP = "127.0.0.1"
FORWARD_PORT = 1080
SOCKS5_AUTH = ${socks5_auth}
SOCKS5_USER = "${socks5_user}"
SOCKS5_PASS = "${socks5_pass}"
SOCKS_HANDSHAKE_TIMEOUT = 120.0

DATA_ENCRYPTION_METHOD = ${MDNS_ENCRYPTION}
SUPPORTED_UPLOAD_COMPRESSION_TYPES   = [0, 1, 2, 3]
SUPPORTED_DOWNLOAD_COMPRESSION_TYPES = [0, 1, 2, 3]

ARQ_WINDOW_SIZE         = 256
ARQ_INITIAL_RTO         = 0.4
ARQ_MAX_RTO             = 1.2
ARQ_CONTROL_INITIAL_RTO = 0.4
ARQ_CONTROL_MAX_RTO     = 1.2
ARQ_CONTROL_MAX_RETRIES = 200

SESSION_TIMEOUT          = 300
SESSION_CLEANUP_INTERVAL = 30
MAX_SESSIONS             = 255
MAX_CONCURRENT_REQUESTS  = 500
CPU_WORKER_THREADS       = 0
MAX_PACKETS_PER_BATCH    = 1000
SOCKET_BUFFER_SIZE       = 8388608

LOG_LEVEL      = "INFO"
CONFIG_VERSION = 3.0
TOML
    info "Config written → ${MDNS_INSTALL_DIR}/server_config.toml"
}

install_masterdnsvpn_service() {
    cat > /etc/systemd/system/masterdnsvpn.service << UNIT
[Unit]
Description=MasterDnsVPN Server (${MDNS_DOMAIN})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${MDNS_INSTALL_DIR}
ExecStart=${MDNS_INSTALL_DIR}/MasterDnsVPN_Server
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=${MDNS_INSTALL_DIR}

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

setup_masterdnsvpn() {
    install_deps
    download_masterdnsvpn
    write_masterdnsvpn_config
    install_masterdnsvpn_service
    systemctl enable --now masterdnsvpn
    sleep 2
    systemctl is-active --quiet masterdnsvpn \
        && info "masterdnsvpn ✓ running" \
        || warn "Check logs: journalctl -u masterdnsvpn -n 30"
}

# ════════════════════════════════════════════════════════════
#  SLIPSTREAM
# ════════════════════════════════════════════════════════════

setup_slipstream() {
    section "Setting up Slipstream (${SLIP_DOMAIN})"
    require slipstream-server
    require microsocks

    mkdir -p "$SLIP_CERT_DIR"
    # Generate or load reset-seed (32 hex chars = 16 bytes — must persist across reinstalls)
    local seed_file="${SLIP_CERT_DIR}/reset-seed"
    if [[ -f "$seed_file" ]]; then
        SLIP_RESET_SEED="$(cat "$seed_file")"
    else
        SLIP_RESET_SEED="$(openssl rand -hex 16)"
        echo "$SLIP_RESET_SEED" > "$seed_file"
        chmod 600 "$seed_file"
    fi
    if [[ ! -f "${SLIP_CERT_DIR}/cert.pem" ]]; then
        info "Generating self-signed TLS cert..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "${SLIP_CERT_DIR}/key.pem" -out "${SLIP_CERT_DIR}/cert.pem" \
            -days 3650 -nodes -subj "/CN=${SLIP_DOMAIN}" 2>/dev/null
        chmod 600 "${SLIP_CERT_DIR}/key.pem"
        info "Cert → ${SLIP_CERT_DIR}/cert.pem"
    else
        info "Reusing existing cert."
    fi

    local slip_user="${TUNNEL_USER:-barzin}"
    local slip_pass="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"

    cat > /etc/systemd/system/microsocks-slip.service << UNIT
[Unit]
Description=microsocks SOCKS5 — Slipstream backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_PORT} -u ${slip_user} -P ${slip_pass}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/dnstm-slip-socks.service << UNIT
[Unit]
Description=Slipstream DNS Tunnel (${SLIP_DOMAIN})
After=network-online.target microsocks-slip.service

[Service]
Type=simple
ExecStart=/usr/local/bin/slipstream-server \\
    -d ${SLIP_DOMAIN} \\
    --dns-listen-host 127.0.0.1 \\
    --dns-listen-port ${SLIP_PORT} \\
    -c ${SLIP_CERT_DIR}/cert.pem \\
    -k ${SLIP_CERT_DIR}/key.pem \\
    -a 127.0.0.1:${SOCKS_PORT} \\
    --reset-seed ${SLIP_RESET_SEED} \\
    --idle-timeout-seconds 1200
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now microsocks-slip
    systemctl enable --now dnstm-slip-socks
    sleep 2
    systemctl is-active --quiet dnstm-slip-socks \
        && info "Slipstream ✓ running" \
        || warn "Check logs: journalctl -u dnstm-slip-socks -n 30"
}

# ════════════════════════════════════════════════════════════
#  DNSTT
# ════════════════════════════════════════════════════════════

setup_dnstt() {
    section "Setting up dnstt (${DNSTT_DOMAIN})"
    require dnstt-server
    require microsocks

    mkdir -p "$DNSTT_KEY_DIR"
    if [[ ! -f "${DNSTT_KEY_DIR}/server.key" ]]; then
        info "Generating dnstt keypair..."
        dnstt-server -gen-key \
            -privkey-file "${DNSTT_KEY_DIR}/server.key" \
            -pubkey-file  "${DNSTT_KEY_DIR}/server.pub"
        chmod 600 "${DNSTT_KEY_DIR}/server.key"
    else
        info "Reusing existing dnstt keypair."
    fi

    local pubkey; pubkey=$(cat "${DNSTT_KEY_DIR}/server.pub")
    local dnstt_socks_port

    if [[ -n "${TUNNEL_USER}" ]]; then
        dnstt_socks_port="${SOCKS_PORT}"
        info "Auth enabled — dnstt backend on :${SOCKS_PORT}"
        cat > /etc/systemd/system/microsocks-noauth.service << UNIT
[Unit]
Description=microsocks SOCKS5 (auth) — dnstt backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_PORT} -u ${TUNNEL_USER} -P ${TUNNEL_PASS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    else
        dnstt_socks_port="${SOCKS_NOAUTH_PORT}"
        info "No auth — dnstt backend on :${SOCKS_NOAUTH_PORT}"
        cat > /etc/systemd/system/microsocks-noauth.service << UNIT
[Unit]
Description=microsocks SOCKS5 no-auth — dnstt backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_NOAUTH_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    fi

    cat > /etc/systemd/system/dnstm-dnstt.service << UNIT
[Unit]
Description=dnstt DNS Tunnel (${DNSTT_DOMAIN})
After=network-online.target microsocks-noauth.service

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server \\
    -udp 127.0.0.1:${DNSTT_PORT} \\
    -privkey-file ${DNSTT_KEY_DIR}/server.key \\
    ${DNSTT_DOMAIN} 127.0.0.1:${dnstt_socks_port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now microsocks-noauth
    systemctl enable --now dnstm-dnstt
    sleep 2
    systemctl is-active --quiet dnstm-dnstt \
        && info "dnstt ✓ running  pubkey: ${pubkey}" \
        || warn "Check logs: journalctl -u dnstm-dnstt -n 30"
}

# ════════════════════════════════════════════════════════════
#  DNSTM ROUTER
# ════════════════════════════════════════════════════════════

setup_dnstm() {
    section "Configuring dnstm DNS router"
    require dnstm
    mkdir -p /etc/dnstm

    cat > "$DNSTM_CONFIG" << JSON
{
  "listen": "0.0.0.0:53",
  "tunnels": [
    {
      "tag": "mdns-forward",
      "enabled": true,
      "transport": "forward",
      "domain": "${MDNS_DOMAIN}",
      "port": ${MDNS_PORT},
      "forward": { "address": "127.0.0.1:${MDNS_PORT}" }
    },
    {
      "tag": "slip-socks",
      "enabled": true,
      "transport": "slipstream",
      "domain": "${SLIP_DOMAIN}",
      "port": ${SLIP_PORT},
      "cert": "${SLIP_CERT_DIR}/cert.pem",
      "backend": "127.0.0.1:${SOCKS_PORT}"
    },
    {
      "tag": "dnstt-tunnel",
      "enabled": true,
      "transport": "forward",
      "domain": "${DNSTT_DOMAIN}",
      "port": ${DNSTT_PORT},
      "forward": { "address": "127.0.0.1:${DNSTT_PORT}" }
    }
  ],
  "route": { "mode": "multi" }
}
JSON

    cat > /etc/systemd/system/dnstm-dnsrouter.service << UNIT
[Unit]
Description=dnstm DNS Traffic Router
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstm -config ${DNSTM_CONFIG}
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warn "Disabling systemd-resolved stub on :53..."
        mkdir -p /etc/systemd/resolved.conf.d
        printf '[Resolve]\nDNSStubListener=no\n' \
            > /etc/systemd/resolved.conf.d/no-stub.conf
        systemctl restart systemd-resolved
    fi

    systemctl daemon-reload
    systemctl enable --now dnstm-dnsrouter
    sleep 2
    systemctl is-active --quiet dnstm-dnsrouter \
        && info "dnstm-dnsrouter ✓ running on :53" \
        || warn "Check logs: journalctl -u dnstm-dnsrouter -n 30"
}

# ════════════════════════════════════════════════════════════
#  STATUS
# ════════════════════════════════════════════════════════════

show_status() {
    draw_banner
    section "Service Status"

    local services=(
        "masterdnsvpn:🔵 MasterDnsVPN   :${MDNS_PORT} (${MDNS_DOMAIN})"
        "dnstm-slip-socks:🟢 Slipstream     :${SLIP_PORT} (${SLIP_DOMAIN})"
        "microsocks-slip|microsocks-slip-public|microsocks:   microsocks auth  :${SOCKS_PORT}"
        "dnstm-dnstt:🟡 dnstt           :${DNSTT_PORT} (${DNSTT_DOMAIN})"
        "microsocks-noauth:   microsocks noauth :${SOCKS_NOAUTH_PORT}"
        "dnstm-dnsrouter:⚙️  dnstm router    :53"
    )

    echo ""
    for entry in "${services[@]}"; do
        local svcs="${entry%%:*}" label="${entry#*:}"
        local running=false active_svc="${svcs%%|*}"
        IFS='|' read -ra svc_list <<< "$svcs"
        for s in "${svc_list[@]}"; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                running=true; active_svc="$s"; break
            fi
        done
        if $running; then
            printf "  ${C_GREEN}●${C_RESET} %-30s  %s\n" "$active_svc" "$label"
        else
            printf "  ${C_RED}○${C_RESET} %-30s  ${C_DIM}%s${C_RESET}\n" "${svc_list[0]}" "$label"
        fi
    done

    echo ""
    echo -e "  ${C_DIM}DNS router :53 →${C_RESET}"
    ss -lnup sport = :53 2>/dev/null | grep -v Netid | \
        awk '{print "    " $5 "  " $NF}' | head -3 || true
    echo ""
}

# ════════════════════════════════════════════════════════════
#  CLIENT CONFIGS
# ════════════════════════════════════════════════════════════

print_client_configs() {
    section "Client Configurations"

    local mdns_key
    mdns_key=$(cat "${MDNS_INSTALL_DIR}/encrypt_key.txt" 2>/dev/null \
        || echo "run: cat ${MDNS_INSTALL_DIR}/encrypt_key.txt")
    local dnstt_pub
    dnstt_pub=$(cat "${DNSTT_KEY_DIR}/server.pub" 2>/dev/null \
        || echo "run: cat ${DNSTT_KEY_DIR}/server.pub")

    local cred_note
    if [[ -n "${TUNNEL_USER}" ]]; then
        cred_note="user=${TUNNEL_USER}  pass=${TUNNEL_PASS}"
    else
        cred_note="(no auth)"
    fi

    hr
    echo -e "\n  ${C_BLUE}${C_BOLD}🔵 MasterDnsVPN${C_RESET}  ${C_DIM}${MDNS_DOMAIN}${C_RESET}"
    echo "  Download: https://github.com/masterking32/MasterDnsVPN/releases/latest"
    echo ""
    echo "  client_config.toml:"
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ SOCKS5_HOST = \"127.0.0.1\""
    echo "  │ SOCKS5_PORT = 1080"
    [[ -n "${TUNNEL_USER}" ]] && {
        echo "  │ SOCKS5_AUTH = true"
        echo "  │ SOCKS5_USER = \"${TUNNEL_USER}\""
        echo "  │ SOCKS5_PASS = \"${TUNNEL_PASS}\""
    }
    echo "  │ DOMAINS = [\"${MDNS_DOMAIN}\"]"
    echo "  │ DATA_ENCRYPTION_METHOD = ${MDNS_ENCRYPTION}  # ChaCha20"
    echo "  │ ENCRYPT_KEY = \"${mdns_key}\""
    echo "  │ ARQ_WINDOW_SIZE = 256"
    echo "  │ PROTOCOL_TYPE = \"SOCKS5\""
    echo "  └─────────────────────────────────────────────────"
    echo "  Commands:  ./MasterDnsVPN_Client --scan"
    echo "             ./MasterDnsVPN_Client"
    echo -e "  SOCKS5:    ${C_GREEN}127.0.0.1:1080${C_RESET}  ${C_DIM}${cred_note}${C_RESET}"

    hr
    echo -e "\n  ${C_GREEN}${C_BOLD}🟢 Slipstream${C_RESET}  ${C_DIM}${SLIP_DOMAIN}${C_RESET}"
    echo "  Client: SlipNet Android app — profile type: SLIPSTREAM_SSH"
    echo ""
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ Domain  : ${SLIP_DOMAIN}"
    echo "  │ Cert    : ${SLIP_CERT_DIR}/cert.pem  (copy to device)"
    echo -e "  │ SOCKS5  : ${C_GREEN}127.0.0.1:1080${C_RESET}  ${C_DIM}${cred_note}${C_RESET}"
    echo "  └─────────────────────────────────────────────────"

    hr
    echo -e "\n  ${C_YELLOW}${C_BOLD}🟡 dnstt${C_RESET}  ${C_DIM}${DNSTT_DOMAIN}${C_RESET}"
    echo "  Clients: dnstt-client, NoizDNS, SlipNet (NoizDNS profile)"
    echo ""
    echo "  ┌─────────────────────────────────────────────────"
    echo "  │ Domain  : ${DNSTT_DOMAIN}"
    echo "  │ Pubkey  : ${dnstt_pub}"
    echo -e "  │ SOCKS5  : ${C_GREEN}127.0.0.1:1080${C_RESET}  ${C_DIM}${cred_note}${C_RESET}"
    echo "  └─────────────────────────────────────────────────"
    echo "  Command:"
    echo "    ./dnstt-client -doh https://dns.google/dns-query \\"
    echo "      -pubkey-file server.pub \\"
    echo "      ${DNSTT_DOMAIN} 127.0.0.1:1080"
    hr
    echo ""
}

# ════════════════════════════════════════════════════════════
#  MIDDLE PROXY
# ════════════════════════════════════════════════════════════

setup_middle_proxy() {
    section "Middle-proxy (dnsmasq DNS multiplexer)"
    require dnsmasq
    cat > /etc/dnsmasq.d/tunnel-kit.conf << DNSCONF
server=/${MDNS_DOMAIN}/8.8.8.8
server=/${MDNS_DOMAIN}/1.1.1.1
server=/${SLIP_DOMAIN}/8.8.8.8
server=/${SLIP_DOMAIN}/1.1.1.1
server=/${DNSTT_DOMAIN}/8.8.8.8
server=/${DNSTT_DOMAIN}/1.1.1.1
DNSCONF
    systemctl restart dnsmasq
    info "dnsmasq configured. Point client DNS to this VPS IP."
}

# ════════════════════════════════════════════════════════════
#  INTERACTIVE WIZARD
# ════════════════════════════════════════════════════════════

wizard_collect_inputs() {
    draw_banner
    echo -e "  ${C_CYAN}${C_BOLD}Install Wizard${C_RESET}  — configure your tunnels\n"

    # ── Server IP ──────────────────────────────────────────
    echo -e "  ${C_BOLD}── Server ─────────────────────────────────────────${C_RESET}"
    ask SERVER_IP "Server public IP" "${SERVER_IP}"

    # ── Which tunnels ─────────────────────────────────────
    echo ""
    echo -e "  ${C_BOLD}── Tunnels to install ─────────────────────────────${C_RESET}"
    ask_yn "Install MasterDnsVPN  (a.domain)" "y" && INSTALL_MDNS=1 || INSTALL_MDNS=0
    ask_yn "Install Slipstream    (b.domain)" "y" && INSTALL_SLIP=1 || INSTALL_SLIP=0
    ask_yn "Install dnstt         (c.domain)" "y" && INSTALL_DNSTT=1 || INSTALL_DNSTT=0

    if (( INSTALL_MDNS + INSTALL_SLIP + INSTALL_DNSTT == 0 )); then
        warn "No tunnels selected. Exiting."
        exit 0
    fi

    # ── Domains ───────────────────────────────────────────
    echo ""
    echo -e "  ${C_BOLD}── Domains ────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_DIM}NS delegation must point these subdomains to ${SERVER_IP}${C_RESET}"
    echo ""
    [[ $INSTALL_MDNS  == 1 ]] && ask MDNS_DOMAIN  "MasterDnsVPN domain" "${MDNS_DOMAIN}"
    [[ $INSTALL_SLIP  == 1 ]] && ask SLIP_DOMAIN  "Slipstream domain  " "${SLIP_DOMAIN}"
    [[ $INSTALL_DNSTT == 1 ]] && ask DNSTT_DOMAIN "dnstt domain       " "${DNSTT_DOMAIN}"

    # ── Credentials ───────────────────────────────────────
    echo ""
    echo -e "  ${C_BOLD}── SOCKS5 Authentication ──────────────────────────${C_RESET}"
    echo -e "  ${C_DIM}Set credentials to require username+password on all tunnels.${C_RESET}"
    echo -e "  ${C_DIM}Leave username empty for no-auth (open proxy).${C_RESET}"
    echo ""
    ask TUNNEL_USER "Username" ""
    if [[ -n "$TUNNEL_USER" ]]; then
        ask_pass TUNNEL_PASS "Password"
        if [[ -z "$TUNNEL_PASS" ]]; then
            warn "Empty password — switching to no-auth."
            TUNNEL_USER=""
        fi
    fi

    # Update derived vars
    SOCKS_USER="${TUNNEL_USER:-barzin}"
    SOCKS_PASS="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"

    # ── Confirmation ──────────────────────────────────────
    echo ""
    hr
    echo -e "\n  ${C_BOLD}${C_WHITE}Configuration Summary${C_RESET}\n"
    printf "  %-22s  %s\n" "Server IP:"   "${SERVER_IP}"
    [[ $INSTALL_MDNS  == 1 ]] && printf "  %-22s  %s\n" "MasterDnsVPN:" "${MDNS_DOMAIN}"
    [[ $INSTALL_SLIP  == 1 ]] && printf "  %-22s  %s\n" "Slipstream:"   "${SLIP_DOMAIN}"
    [[ $INSTALL_DNSTT == 1 ]] && printf "  %-22s  %s\n" "dnstt:"        "${DNSTT_DOMAIN}"
    if [[ -n "$TUNNEL_USER" ]]; then
        printf "  %-22s  %s\n" "Auth:" "user=${TUNNEL_USER}  pass=****"
    else
        printf "  %-22s  %s\n" "Auth:" "none (open proxy)"
    fi
    echo ""
    hr
    echo ""

    if ! ask_yn "Proceed with installation?" "y"; then
        echo "  Aborted."
        exit 0
    fi
}

wizard_run_install() {
    install_deps
    install_bundled_binaries

    [[ $INSTALL_MDNS  == 1 ]] && setup_masterdnsvpn
    [[ $INSTALL_SLIP  == 1 ]] && setup_slipstream
    [[ $INSTALL_DNSTT == 1 ]] && setup_dnstt

    # Always set up dnstm router
    setup_dnstm

    echo ""
    section "Installation Complete"
    print_client_configs
}

# ════════════════════════════════════════════════════════════
#  SERVICE CONTROL MENU
# ════════════════════════════════════════════════════════════

service_control_menu() {
    local services=(
        "masterdnsvpn"
        "dnstm-slip-socks"
        "microsocks-slip"
        "dnstm-dnstt"
        "microsocks-noauth"
        "dnstm-dnsrouter"
    )

    while true; do
        draw_banner
        section "Service Control"
        echo ""
        local i=1
        for svc in "${services[@]}"; do
            local state; state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            local icon
            [[ "$state" == "active" ]] && icon="${C_GREEN}●${C_RESET}" || icon="${C_RED}○${C_RESET}"
            printf "  ${icon} %2d) %-32s ${C_DIM}%s${C_RESET}\n" "$i" "$svc" "$state"
            ((i++))
        done
        echo ""
        printf "  ${C_DIM}%3s) %s${C_RESET}\n" "b" "Back to main menu"
        echo ""
        echo -en "  ${C_WHITE}Select service [1-${#services[@]}]:${C_RESET} "
        local choice; read -r choice
        [[ "$choice" == "b" || "$choice" == "B" ]] && break
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#services[@]} )); then
            local svc="${services[$((choice-1))]}"
            echo ""
            echo -e "  ${C_BOLD}${svc}${C_RESET}"
            echo ""
            printf "  1) Start    2) Stop    3) Restart    4) Logs    5) Back\n"
            echo ""
            echo -en "  ${C_WHITE}Action:${C_RESET} "
            local action; read -r action
            case "$action" in
                1) systemctl start   "$svc" && info "Started $svc" || warn "Failed" ;;
                2) systemctl stop    "$svc" && info "Stopped $svc" || warn "Failed" ;;
                3) systemctl restart "$svc" && info "Restarted $svc" || warn "Failed" ;;
                4) echo ""; journalctl -u "$svc" -n 40 --no-pager; echo "" ;;
                *) ;;
            esac
            press_enter
        fi
    done
}

# ════════════════════════════════════════════════════════════
#  CREDENTIALS UPDATE MENU
# ════════════════════════════════════════════════════════════

update_credentials_menu() {
    draw_banner
    section "Update SOCKS5 Credentials"
    echo ""
    echo -e "  ${C_DIM}Changes will be applied to all running tunnels.${C_RESET}"
    echo ""

    ask TUNNEL_USER "New username (empty = remove auth)" ""
    if [[ -n "$TUNNEL_USER" ]]; then
        ask_pass TUNNEL_PASS "New password"
        if [[ -z "$TUNNEL_PASS" ]]; then
            warn "Empty password — no-auth will be used."
            TUNNEL_USER=""
        fi
    fi

    SOCKS_USER="${TUNNEL_USER:-barzin}"
    SOCKS_PASS="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"

    echo ""
    if ask_yn "Apply credentials and restart tunnel services?" "y"; then
        # Rewrite MasterDnsVPN config
        if [[ -f "${MDNS_INSTALL_DIR}/server_config.toml" ]]; then
            write_masterdnsvpn_config
            systemctl restart masterdnsvpn 2>/dev/null && info "masterdnsvpn restarted" || true
        fi

        # Rewrite microsocks-slip (Slipstream backend)
        local slip_user="${TUNNEL_USER:-barzin}"
        local slip_pass="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"
        if systemctl is-enabled microsocks-slip &>/dev/null; then
            sed -i "s|ExecStart=.*microsocks.*-p ${SOCKS_PORT}.*|ExecStart=/usr/local/bin/microsocks -p ${SOCKS_PORT} -u ${slip_user} -P ${slip_pass}|" \
                /etc/systemd/system/microsocks-slip.service 2>/dev/null || true
            systemctl daemon-reload
            systemctl restart microsocks-slip 2>/dev/null && info "microsocks-slip restarted" || true
        fi

        # Rewrite microsocks-noauth (dnstt backend)
        if [[ -n "$TUNNEL_USER" ]]; then
            cat > /etc/systemd/system/microsocks-noauth.service << UNIT
[Unit]
Description=microsocks SOCKS5 (auth) — dnstt backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_PORT} -u ${TUNNEL_USER} -P ${TUNNEL_PASS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
        else
            cat > /etc/systemd/system/microsocks-noauth.service << UNIT
[Unit]
Description=microsocks SOCKS5 no-auth — dnstt backend
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_NOAUTH_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
        fi
        systemctl daemon-reload
        systemctl restart microsocks-noauth 2>/dev/null && info "microsocks-noauth restarted" || true

        info "Credentials updated on all tunnels."
    fi
    press_enter
}

# ════════════════════════════════════════════════════════════
#  MAIN MENU
# ════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        draw_banner

        # Quick status bar
        local mdns_st slip_st dnstt_st router_st
        systemctl is-active --quiet masterdnsvpn    2>/dev/null && mdns_st="${C_GREEN}●${C_RESET}" || mdns_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet dnstm-slip-socks 2>/dev/null && slip_st="${C_GREEN}●${C_RESET}" || slip_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet dnstm-dnstt      2>/dev/null && dnstt_st="${C_GREEN}●${C_RESET}" || dnstt_st="${C_RED}○${C_RESET}"
        systemctl is-active --quiet dnstm-dnsrouter  2>/dev/null && router_st="${C_GREEN}●${C_RESET}" || router_st="${C_RED}○${C_RESET}"

        echo -e "  ${C_DIM}Tunnels: ${mdns_st} MasterDnsVPN  ${slip_st} Slipstream  ${dnstt_st} dnstt  ${router_st} Router${C_RESET}"
        echo ""
        hr
        echo ""
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  1  "Install / Reinstall tunnels  (wizard)"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  2  "Show service status"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  3  "Manage services  (start / stop / logs)"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  4  "Show client configs"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  5  "Update SOCKS5 credentials"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  6  "Install MasterDnsVPN only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  7  "Install Slipstream only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  8  "Install dnstt only"
        printf "  ${C_YELLOW}%2d)${C_RESET} %s\n"  9  "Set up middle-proxy  (Iranian VPS)"
        printf "  ${C_DIM}%3s) %s${C_RESET}\n"    "q" "Quit"
        echo ""
        hr
        echo ""
        echo -en "  ${C_WHITE}Choose [1-9 / q]:${C_RESET} "
        local choice; read -r choice

        case "$choice" in
            1)
                wizard_collect_inputs
                wizard_run_install
                press_enter
                ;;
            2)
                show_status
                press_enter
                ;;
            3)
                service_control_menu
                ;;
            4)
                print_client_configs
                press_enter
                ;;
            5)
                update_credentials_menu
                ;;
            6)
                draw_banner
                echo ""
                ask MDNS_DOMAIN  "MasterDnsVPN domain" "${MDNS_DOMAIN}"
                ask TUNNEL_USER  "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-barzin}"
                SOCKS_PASS="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"
                install_deps
                setup_masterdnsvpn
                print_client_configs
                press_enter
                ;;
            7)
                draw_banner
                echo ""
                ask SLIP_DOMAIN  "Slipstream domain" "${SLIP_DOMAIN}"
                ask TUNNEL_USER  "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-barzin}"
                SOCKS_PASS="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"
                install_deps
                install_bundled_binaries
                setup_slipstream
                press_enter
                ;;
            8)
                draw_banner
                echo ""
                ask DNSTT_DOMAIN "dnstt domain" "${DNSTT_DOMAIN}"
                ask TUNNEL_USER  "SOCKS5 username (empty=no-auth)" ""
                [[ -n "$TUNNEL_USER" ]] && ask_pass TUNNEL_PASS "SOCKS5 password"
                SOCKS_USER="${TUNNEL_USER:-barzin}"
                SOCKS_PASS="${TUNNEL_PASS:-FFbCXFUlIwmjOBG!I5}"
                install_deps
                install_bundled_binaries
                setup_dnstt
                print_client_configs
                press_enter
                ;;
            9)
                draw_banner
                echo ""
                ask MDNS_DOMAIN  "MasterDnsVPN domain" "${MDNS_DOMAIN}"
                ask SLIP_DOMAIN  "Slipstream domain"   "${SLIP_DOMAIN}"
                ask DNSTT_DOMAIN "dnstt domain"        "${DNSTT_DOMAIN}"
                setup_middle_proxy
                press_enter
                ;;
            q|Q)
                echo ""
                echo -e "  ${C_DIM}Bye.${C_RESET}"
                echo ""
                exit 0
                ;;
            *)
                ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════

MODE="${1:-menu}"

case "$MODE" in
    menu)                main_menu ;;
    install)             wizard_collect_inputs; wizard_run_install ;;
    masterdnsvpn)        install_deps; setup_masterdnsvpn; print_client_configs ;;
    slipstream)          install_deps; install_bundled_binaries; setup_slipstream ;;
    dnstt)               install_deps; install_bundled_binaries; setup_dnstt; print_client_configs ;;
    dnstm)               install_deps; install_bundled_binaries; setup_dnstm ;;
    status)              show_status ;;
    client-config)       print_client_configs ;;
    middle-proxy)        setup_middle_proxy ;;
    *)
        echo ""
        echo "  DNS Tunnel Kit — Credits: github.com/mrvcoder"
        echo ""
        echo "  Usage:  $0 [mode]"
        echo "  No mode → interactive menu"
        echo ""
        echo "  Modes:"
        printf "    %-18s  %s\n" "menu"          "Interactive menu (default)"
        printf "    %-18s  %s\n" "install"        "Guided install wizard"
        printf "    %-18s  %s\n" "masterdnsvpn"   "Install MasterDnsVPN only"
        printf "    %-18s  %s\n" "slipstream"     "Install Slipstream only"
        printf "    %-18s  %s\n" "dnstt"          "Install dnstt only"
        printf "    %-18s  %s\n" "status"         "Show service status"
        printf "    %-18s  %s\n" "client-config"  "Print all client configs"
        printf "    %-18s  %s\n" "middle-proxy"   "Iranian VPS DNS multiplexer"
        echo ""
        echo "  Env overrides: TUNNEL_USER, TUNNEL_PASS, MDNS_DOMAIN, SLIP_DOMAIN, DNSTT_DOMAIN"
        echo ""
        ;;
esac
