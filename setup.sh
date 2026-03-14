#!/usr/bin/env bash
# ============================================================
#  DNS Tunnel Kit — Multi-Tunnel Setup Script
#  Supports: MasterDnsVPN + Slipstream + dnstt
#  Credits : https://github.com/mrvcoder
# ============================================================
#
#  Modes:
#    install           — Full setup (all three tunnels + dnstm)
#    masterdnsvpn      — Install / update MasterDnsVPN only
#    slipstream        — Install Slipstream only
#    dnstt             — Install dnstt only
#    status            — Show all tunnel service status
#    client-config     — Print client configs for all tunnels
#    middle-proxy      — Iranian VPS: dnsmasq DNS multiplexer
#
#  Architecture (server):
#    dnstm DNS router → UDP :53
#      ├─ a.barzin.biz  → forward  → MasterDnsVPN   :5312  (built-in SOCKS5 + ChaCha20)
#      ├─ b.barzin.biz  → slipstream → microsocks    :58077 (auth SOCKS5)
#      └─ c.barzin.biz  → dnstt    → microsocks-noauth :58078 (no-auth SOCKS5)
#
#  MasterDnsVPN:
#    Domain  : a.barzin.biz
#    Port    : UDP 5312 (internal, behind dnstm)
#    Encryption: ChaCha20 (method 2)
#    SOCKS5  : built-in — no external microsocks needed
#    Binary  : downloaded from GitHub releases on install
#
#  Slipstream:
#    Domain  : b.barzin.biz
#    Port    : 5310 (internal, behind dnstm)
#    SOCKS5  : microsocks :58077 (auth: see SOCKS_USER/SOCKS_PASS)
#
#  dnstt:
#    Domain  : c.barzin.biz
#    Port    : 5311 (internal, behind dnstm)
#    SOCKS5  : microsocks-noauth :58078 (no-auth)
#    Keys    : /opt/dnstt/server.key + server.pub
# ============================================================

set -euo pipefail

# ─── Config ─────────────────────────────────────────────────
SERVER_IP="138.124.115.113"

# MasterDnsVPN
MDNS_DOMAIN="${MDNS_DOMAIN:-a.barzin.biz}"
MDNS_INSTALL_DIR="/opt/masterdnsvpn"
MDNS_PORT="5312"
MDNS_ENCRYPTION="2"                  # 2=ChaCha20

# Slipstream
SLIP_DOMAIN="${SLIP_DOMAIN:-b.barzin.biz}"
SLIP_CERT_DIR="/etc/dnstm/tunnels/slip-socks"
SLIP_PORT="5310"

# dnstt
DNSTT_DOMAIN="${DNSTT_DOMAIN:-c.barzin.biz}"
DNSTT_PORT="5311"
DNSTT_KEY_DIR="/opt/dnstt"

# Shared SOCKS5 (Slipstream backend)
SOCKS_USER="barzin"
SOCKS_PASS='FFbCXFUlIwmjOBG!I5'
SOCKS_PORT="58077"                   # auth SOCKS5 (Slipstream)
SOCKS_NOAUTH_PORT="58078"            # no-auth SOCKS5 (dnstt)

# dnstm config location
DNSTM_CONFIG="/etc/dnstm/config.json"

# GitHub release base for MasterDnsVPN
MDNS_GH_BASE="https://github.com/masterking32/MasterDnsVPN/releases/latest/download"

# ─── Helpers ────────────────────────────────────────────────
info()    { echo -e "\e[32m[+]\e[0m $*"; }
warn()    { echo -e "\e[33m[!]\e[0m $*"; }
error()   { echo -e "\e[31m[-]\e[0m $*"; exit 1; }
section() { echo -e "\n\e[36m━━━ $* ━━━\e[0m"; }
hr()      { echo "────────────────────────────────────────────────────"; }
require() { command -v "$1" >/dev/null 2>&1 || error "Missing: $1. Install it first."; }

install_deps() {
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y curl wget unzip python3 openssl 2>/dev/null || true
}

# ─── Binaries from bin/ ──────────────────────────────────────
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

    # Resolve exact download URL from GitHub API (avoids redirect chains that cause hangs)
    info "Fetching latest release info from GitHub..."
    local api_url="https://api.github.com/repos/masterking32/MasterDnsVPN/releases/latest"
    local release_json
    release_json=$(curl -sf --connect-timeout 15 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        "$api_url") || { warn "GitHub API unreachable — falling back to latest/download URL"; release_json=""; }

    get_asset_url() {
        local name="$1"
        if [[ -n "$release_json" ]]; then
            echo "$release_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    if a['name'] == '${name}':
        print(a['browser_download_url'])
        break
" 2>/dev/null
        fi
    }

    local url; url=$(get_asset_url "$asset")
    [[ -z "$url" ]] && url="${MDNS_GH_BASE}/${asset}"

    mkdir -p "$MDNS_INSTALL_DIR"
    local tmp; tmp=$(mktemp -d)

    info "Downloading ${asset} (~42MB)..."
    # curl with progress bar, 10-min timeout, 3 retries, follow redirects
    if ! curl -L --retry 3 --retry-delay 3 \
              --connect-timeout 30 --max-time 600 \
              --progress-bar \
              -o "${tmp}/server.tar.gz" "$url"; then
        warn "Modern glibc build failed — trying legacy build..."
        local url_legacy; url_legacy=$(get_asset_url "$asset_legacy")
        [[ -z "$url_legacy" ]] && url_legacy="${MDNS_GH_BASE}/${asset_legacy}"
        curl -L --retry 3 --retry-delay 3 \
             --connect-timeout 30 --max-time 600 \
             --progress-bar \
             -o "${tmp}/server.tar.gz" "$url_legacy" \
             || { rm -rf "$tmp"; error "Download failed for both modern and legacy builds"; }
    fi

    info "Extracting..."
    tar xf "${tmp}/server.tar.gz" -C "${tmp}"
    # Binary has version suffix e.g. MasterDnsVPN_Server_Linux_AMD64_v2026.03.14...
    local bin; bin=$(find "${tmp}" -type f -name 'MasterDnsVPN_Server*' \
        ! -name '*.gz' ! -name '*.zip' ! -name '*.toml' ! -name '*.txt' | head -1)
    [[ -z "$bin" ]] && error "Server binary not found in archive"

    mv "$bin" "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server"
    chmod +x "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server"
    rm -rf "$tmp"

    local size; size=$(du -sh "${MDNS_INSTALL_DIR}/MasterDnsVPN_Server" | cut -f1)
    info "MasterDnsVPN installed: ${MDNS_INSTALL_DIR}/MasterDnsVPN_Server (${size})"
}

write_masterdnsvpn_config() {
    section "Writing MasterDnsVPN server_config.toml"

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

    cat > "${MDNS_INSTALL_DIR}/server_config.toml" << TOML
# ==============================================================
# MasterDnsVPN Server Config
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ==============================================================

UDP_HOST = "127.0.0.1"
UDP_PORT = ${MDNS_PORT}

DOMAIN = ["${MDNS_DOMAIN}"]

# SOCKS5 built-in (no external microsocks needed)
PROTOCOL_TYPE = "SOCKS5"
USE_EXTERNAL_SOCKS5 = false
FORWARD_IP = "127.0.0.1"
FORWARD_PORT = 1080
SOCKS5_AUTH = false
SOCKS5_USER = "admin"
SOCKS5_PASS = "unused"
SOCKS_HANDSHAKE_TIMEOUT = 120.0

# 0=None 1=XOR 2=ChaCha20 3=AES-128-GCM 4=AES-192-GCM 5=AES-256-GCM
DATA_ENCRYPTION_METHOD = ${MDNS_ENCRYPTION}

# Compression: 0=OFF 1=ZSTD 2=LZ4 3=ZLIB
SUPPORTED_UPLOAD_COMPRESSION_TYPES   = [0, 1, 2, 3]
SUPPORTED_DOWNLOAD_COMPRESSION_TYPES = [0, 1, 2, 3]

# ARQ — tuned for high packet-loss (Iran ISP)
ARQ_WINDOW_SIZE         = 256
ARQ_INITIAL_RTO         = 0.4
ARQ_MAX_RTO             = 1.2
ARQ_CONTROL_INITIAL_RTO = 0.4
ARQ_CONTROL_MAX_RTO     = 1.2
ARQ_CONTROL_MAX_RETRIES = 200

SESSION_TIMEOUT          = 300
SESSION_CLEANUP_INTERVAL = 30
MAX_SESSIONS             = 255

MAX_CONCURRENT_REQUESTS = 500
CPU_WORKER_THREADS      = 0
MAX_PACKETS_PER_BATCH   = 1000
SOCKET_BUFFER_SIZE      = 8388608

LOG_LEVEL      = "INFO"
CONFIG_VERSION = 3.0
TOML

    info "Config written → ${MDNS_INSTALL_DIR}/server_config.toml"
}

install_masterdnsvpn_service() {
    section "Installing masterdnsvpn.service"
    cat > /etc/systemd/system/masterdnsvpn.service << UNIT
[Unit]
Description=MasterDnsVPN Server (${MDNS_DOMAIN})
Documentation=https://github.com/masterking32/MasterDnsVPN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${MDNS_INSTALL_DIR}
ExecStart=${MDNS_INSTALL_DIR}/MasterDnsVPN_Server
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
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
    info "masterdnsvpn.service installed"
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
        || warn "masterdnsvpn not running — check: journalctl -u masterdnsvpn -n 30"
}

# ════════════════════════════════════════════════════════════
#  SLIPSTREAM
# ════════════════════════════════════════════════════════════

setup_slipstream() {
    section "Setting up Slipstream (${SLIP_DOMAIN})"

    require slipstream-server
    require microsocks

    mkdir -p "$SLIP_CERT_DIR"

    # Generate TLS cert for slipstream if not present
    if [[ ! -f "${SLIP_CERT_DIR}/cert.pem" ]]; then
        info "Generating self-signed cert for Slipstream..."
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
            -keyout "${SLIP_CERT_DIR}/key.pem" \
            -out "${SLIP_CERT_DIR}/cert.pem" \
            -days 3650 -nodes -subj "/CN=${SLIP_DOMAIN}" 2>/dev/null
        chmod 600 "${SLIP_CERT_DIR}/key.pem"
        info "Cert generated → ${SLIP_CERT_DIR}/cert.pem"
    else
        info "Reusing existing cert → ${SLIP_CERT_DIR}/cert.pem"
    fi

    # microsocks service (auth SOCKS5 — Slipstream backend)
    cat > /etc/systemd/system/microsocks-slip.service << UNIT
[Unit]
Description=microsocks SOCKS5 — Slipstream backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_PORT} -u ${SOCKS_USER} -P ${SOCKS_PASS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    # Slipstream server service
    cat > /etc/systemd/system/dnstm-slip-socks.service << UNIT
[Unit]
Description=Slipstream DNS Tunnel (${SLIP_DOMAIN})
After=network-online.target microsocks-slip.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/slipstream-server \\
    --domain ${SLIP_DOMAIN} \\
    --udp 127.0.0.1:${SLIP_PORT} \\
    --cert ${SLIP_CERT_DIR}/cert.pem \\
    --key  ${SLIP_CERT_DIR}/key.pem \\
    --socks5 127.0.0.1:${SOCKS_PORT}
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
        || warn "Slipstream not running — check: journalctl -u dnstm-slip-socks -n 30"
}

# ════════════════════════════════════════════════════════════
#  DNSTT
# ════════════════════════════════════════════════════════════

setup_dnstt() {
    section "Setting up dnstt (${DNSTT_DOMAIN})"

    require dnstt-server
    require microsocks

    mkdir -p "$DNSTT_KEY_DIR"

    # Generate keypair if not present
    if [[ ! -f "${DNSTT_KEY_DIR}/server.key" ]]; then
        info "Generating dnstt keypair..."
        dnstt-server -gen-key \
            -privkey-file "${DNSTT_KEY_DIR}/server.key" \
            -pubkey-file  "${DNSTT_KEY_DIR}/server.pub"
        chmod 600 "${DNSTT_KEY_DIR}/server.key"
        info "Keypair → ${DNSTT_KEY_DIR}/server.{key,pub}"
    else
        info "Reusing existing dnstt keypair."
    fi

    local pubkey; pubkey=$(cat "${DNSTT_KEY_DIR}/server.pub")

    # microsocks no-auth (dnstt backend)
    cat > /etc/systemd/system/microsocks-noauth.service << UNIT
[Unit]
Description=microsocks SOCKS5 no-auth — dnstt backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/microsocks -p ${SOCKS_NOAUTH_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

    # dnstt server service
    # Note: dnstt-server uses positional args: DOMAIN UPSTREAMADDR (no -tcp flag)
    cat > /etc/systemd/system/dnstm-dnstt.service << UNIT
[Unit]
Description=dnstt DNS Tunnel (${DNSTT_DOMAIN})
After=network-online.target microsocks-noauth.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstt-server \\
    -udp 127.0.0.1:${DNSTT_PORT} \\
    -privkey-file ${DNSTT_KEY_DIR}/server.key \\
    ${DNSTT_DOMAIN} 127.0.0.1:${SOCKS_NOAUTH_PORT}
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
        && info "dnstt ✓ running  (pubkey: ${pubkey})" \
        || warn "dnstt not running — check: journalctl -u dnstm-dnstt -n 30"
}

# ════════════════════════════════════════════════════════════
#  DNSTM — DNS ROUTER
# ════════════════════════════════════════════════════════════

setup_dnstm() {
    section "Configuring dnstm DNS router"

    require dnstm

    mkdir -p /etc/dnstm

    # Write full three-tunnel config
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
  "route": {
    "mode": "multi"
  }
}
JSON

    # dnstm systemd service
    cat > /etc/systemd/system/dnstm-dnsrouter.service << UNIT
[Unit]
Description=dnstm DNS Traffic Router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dnstm -config ${DNSTM_CONFIG}
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT

    # Disable systemd-resolved on :53 if present
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        warn "Disabling systemd-resolved stub listener (conflicts with port 53)..."
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/no-stub.conf << CONF
[Resolve]
DNSStubListener=no
CONF
        systemctl restart systemd-resolved
    fi

    systemctl daemon-reload
    systemctl enable --now dnstm-dnsrouter
    sleep 2
    systemctl is-active --quiet dnstm-dnsrouter \
        && info "dnstm-dnsrouter ✓ running on :53" \
        || warn "dnstm-dnsrouter not running — check: journalctl -u dnstm-dnsrouter -n 30"
}

# ════════════════════════════════════════════════════════════
#  FULL INSTALL
# ════════════════════════════════════════════════════════════

install_full() {
    section "Full install: MasterDnsVPN + Slipstream + dnstt"
    install_deps
    install_bundled_binaries
    setup_masterdnsvpn
    setup_slipstream
    setup_dnstt
    setup_dnstm
    print_client_configs
}

# ════════════════════════════════════════════════════════════
#  STATUS
# ════════════════════════════════════════════════════════════

show_status() {
    section "DNS Tunnel Kit — Service Status"

    # Format: "svc1|svc2_alias:Label"  (aliases separated by |, checked in order)
    local services=(
        "masterdnsvpn:MasterDnsVPN   (${MDNS_DOMAIN})"
        "dnstm-slip-socks:Slipstream       (${SLIP_DOMAIN})"
        "microsocks-slip|microsocks-slip-public|microsocks:microsocks auth  (:${SOCKS_PORT})"
        "dnstm-dnstt:dnstt            (${DNSTT_DOMAIN})"
        "microsocks-noauth:microsocks noauth (:${SOCKS_NOAUTH_PORT})"
        "dnstm-dnsrouter:dnstm DNS router  (:53)"
    )

    echo ""
    for entry in "${services[@]}"; do
        local svcs="${entry%%:*}"
        local label="${entry#*:}"
        local running=false
        local active_svc="$svcs"
        # Try each alias (pipe-separated) until one is found active
        IFS='|' read -ra svc_list <<< "$svcs"
        for s in "${svc_list[@]}"; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                running=true
                active_svc="$s"
                break
            fi
        done
        if $running; then
            printf "  \e[32m●\e[0m %-32s  %s\n" "$active_svc" "$label"
        else
            printf "  \e[31m○\e[0m %-32s  %s\n" "${svc_list[0]}" "$label"
        fi
    done

    echo ""
    info "Port :53 listener:"
    ss -lnup sport = :53 2>/dev/null | grep -v Netid | head -3 || true
    info "Port :${MDNS_PORT} listener (MasterDnsVPN):"
    ss -lnup sport = :"${MDNS_PORT}" 2>/dev/null | grep -v Netid | head -3 || true
    echo ""
}

# ════════════════════════════════════════════════════════════
#  CLIENT CONFIGS
# ════════════════════════════════════════════════════════════

print_client_configs() {
    section "Client Configurations"

    # ── MasterDnsVPN ──
    local mdns_key
    mdns_key=$(cat "${MDNS_INSTALL_DIR}/encrypt_key.txt" 2>/dev/null || echo "RUN: cat ${MDNS_INSTALL_DIR}/encrypt_key.txt")

    hr
    echo ""
    echo "  🔵 MasterDnsVPN (${MDNS_DOMAIN})"
    echo "  Download client: https://github.com/masterking32/MasterDnsVPN/releases/latest"
    echo ""
    cat << CLIENTCFG
  client_config.toml:
  ───────────────────
  SOCKS5_HOST = "127.0.0.1"
  SOCKS5_PORT = 1080
  DOMAINS = ["${MDNS_DOMAIN}"]
  DATA_ENCRYPTION_METHOD = ${MDNS_ENCRYPTION}
  ENCRYPT_KEY = "${mdns_key}"
  ARQ_WINDOW_SIZE = 256
  ARQ_INITIAL_RTO = 0.4
  ARQ_MAX_RTO     = 1.2
  PROTOCOL_TYPE = "SOCKS5"
  LOG_LEVEL     = "INFO"
CLIENTCFG

    echo ""
    echo "  Run: ./MasterDnsVPN_Client --scan   (find best resolvers)"
    echo "       ./MasterDnsVPN_Client           (start tunnel)"
    echo "  SOCKS5: 127.0.0.1:1080"

    # ── Slipstream ──
    echo ""
    hr
    echo ""
    echo "  🟢 Slipstream (${SLIP_DOMAIN})"
    echo "  Use SlipNet Android app with profile type: SLIPSTREAM_SSH"
    echo ""
    echo "  Profile settings:"
    echo "    Domain    : ${SLIP_DOMAIN}"
    echo "    Cert      : ${SLIP_CERT_DIR}/cert.pem  (copy to client)"
    echo "    SOCKS5    : auth — user=${SOCKS_USER}  pass=<configured>"
    echo ""

    # ── dnstt ──
    local dnstt_pub
    dnstt_pub=$(cat "${DNSTT_KEY_DIR}/server.pub" 2>/dev/null || echo "RUN: cat ${DNSTT_KEY_DIR}/server.pub")

    echo ""
    hr
    echo ""
    echo "  🟡 dnstt (${DNSTT_DOMAIN})"
    echo "  Compatible clients: dnstt-client, NoizDNS client, SlipNet (NoizDNS profile)"
    echo ""
    echo "  Client settings:"
    echo "    DNS domain : ${DNSTT_DOMAIN}"
    echo "    Public key : ${dnstt_pub}"
    echo "    SOCKS5     : 127.0.0.1:1080  (no-auth)"
    echo ""
    echo "  dnstt-client command:"
    echo "    ./dnstt-client -doh https://dns.google/dns-query \\"
    echo "      -pubkey-file server.pub \\"
    echo "      ${DNSTT_DOMAIN} 127.0.0.1:1080"
    echo ""
    hr
    echo ""
}

# ════════════════════════════════════════════════════════════
#  MIDDLE PROXY (Iranian VPS)
# ════════════════════════════════════════════════════════════

setup_middle_proxy() {
    section "Middle-proxy (dnsmasq DNS multiplexer)"
    require dnsmasq

    cat > /etc/dnsmasq.d/barzin-tunnel.conf << DNSCONF
server=/${MDNS_DOMAIN}/8.8.8.8
server=/${MDNS_DOMAIN}/1.1.1.1
server=/${MDNS_DOMAIN}/9.9.9.9
server=/${SLIP_DOMAIN}/8.8.8.8
server=/${SLIP_DOMAIN}/1.1.1.1
server=/${SLIP_DOMAIN}/9.9.9.9
server=/${DNSTT_DOMAIN}/8.8.8.8
server=/${DNSTT_DOMAIN}/1.1.1.1
server=/${DNSTT_DOMAIN}/9.9.9.9
DNSCONF

    systemctl restart dnsmasq
    info "dnsmasq configured for all three tunnel domains."
    info "Point clients' DNS to this VPS IP."
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════

MODE="${1:-help}"

case "$MODE" in
    install)        install_full ;;
    masterdnsvpn)   install_deps; setup_masterdnsvpn; print_client_configs ;;
    slipstream)     install_deps; install_bundled_binaries; setup_slipstream ;;
    dnstt)          install_deps; install_bundled_binaries; setup_dnstt; print_client_configs ;;
    dnstm)          install_deps; install_bundled_binaries; setup_dnstm ;;
    client-config)  print_client_configs ;;
    status)         show_status ;;
    middle-proxy)   setup_middle_proxy ;;
    *)
        echo ""
        echo "  DNS Tunnel Kit"
        echo "  Credits: https://github.com/mrvcoder"
        echo ""
        echo "  Usage:  $0 <mode>"
        echo ""
        echo "  Modes:"
        printf "    %-22s  %s\n" "install"       "Full setup (MasterDnsVPN + Slipstream + dnstt + dnstm)"
        printf "    %-22s  %s\n" "masterdnsvpn"  "Install / update MasterDnsVPN only"
        printf "    %-22s  %s\n" "slipstream"    "Install Slipstream only"
        printf "    %-22s  %s\n" "dnstt"         "Install dnstt only"
        printf "    %-22s  %s\n" "dnstm"         "Install dnstm DNS router only"
        printf "    %-22s  %s\n" "client-config" "Print client configs for all tunnels"
        printf "    %-22s  %s\n" "status"        "Show all service status"
        printf "    %-22s  %s\n" "middle-proxy"  "Set up Iranian VPS DNS multiplexer (dnsmasq)"
        echo ""
        echo "  Tunnel domains (override with env vars):"
        printf "    %-20s  %s\n" "MDNS_DOMAIN"  "${MDNS_DOMAIN}  (MasterDnsVPN)"
        printf "    %-20s  %s\n" "SLIP_DOMAIN"  "${SLIP_DOMAIN}  (Slipstream)"
        printf "    %-20s  %s\n" "DNSTT_DOMAIN" "${DNSTT_DOMAIN}  (dnstt)"
        echo ""
        ;;
esac
