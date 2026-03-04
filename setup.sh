#!/usr/bin/env bash
# ==============================================================================
#  dns-tunnel-setup.sh — dnstt + Slipstream DNS Tunnel Manager
#  Sets up the exact same stack used in production:
#    • dnstm      — DNS router / tunnel manager
#    • dnstt-server  — DNSTT tunnel backend
#    • slipstream-server — Slipstream tunnel backend
#    • microsocks    — Authenticated SOCKS5 proxy
# ==============================================================================

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  PURPLE='\033[0;35m'
BOLD='\033[1m';    DIM='\033[2m';      NC='\033[0m'

SCRIPT_VERSION="1.0.0"

# ── Paths ──────────────────────────────────────────────────────────────────────
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/dnstm"
TUNNEL_DIR="$CONF_DIR/tunnels"
STATE_FILE="$CONF_DIR/setup.env"          # persisted setup values
DNSTM_CONF="$CONF_DIR/config.json"
DNSTM_USER="dnstm"
TUNNEL_USER="tunneluser"

SVC_DNSTM="dnstm"
SVC_DNSTT="dnstm-dnstt-socks"
SVC_SLIP="dnstm-slip-socks"
SVC_SOCKS="microsocks"

# ── Helpers ────────────────────────────────────────────────────────────────────
banner() {
  clear
  echo -e "${BOLD}${CYAN}"
  echo "  ██████╗ ███╗   ██╗███████╗    ████████╗██╗   ██╗███╗   ██╗███╗   ██╗███████╗██╗     "
  echo "  ██╔══██╗████╗  ██║██╔════╝    ╚══██╔══╝██║   ██║████╗  ██║████╗  ██║██╔════╝██║     "
  echo "  ██║  ██║██╔██╗ ██║███████╗       ██║   ██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██║     "
  echo "  ██║  ██║██║╚██╗██║╚════██║       ██║   ██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██║     "
  echo "  ██████╔╝██║ ╚████║███████║       ██║   ╚██████╔╝██║ ╚████║██║ ╚████║███████╗███████╗"
  echo "  ╚═════╝ ╚═╝  ╚═══╝╚══════╝       ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚══════╝"
  echo -e "${NC}${DIM}  dnstt + Slipstream DNS Tunnel Manager — v${SCRIPT_VERSION}${NC}"
  echo ""
}

info()    { echo -e "  ${CYAN}[•]${NC} $*"; }
ok()      { echo -e "  ${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $*"; }
err()     { echo -e "  ${RED}[✗]${NC} $*"; }
section() { echo -e "\n${BOLD}${BLUE}──── $* ────${NC}"; }
ask()     { echo -e -n "  ${PURPLE}[?]${NC} $* "; }

require_root() {
  [[ $EUID -eq 0 ]] || { err "Run as root (sudo $0)"; exit 1; }
}

press_enter() {
  echo ""
  ask "Press Enter to continue..."; read -r
}

load_state() {
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
}

save_state() {
  mkdir -p "$CONF_DIR"
  cat > "$STATE_FILE" <<EOF
# DNS Tunnel Setup — saved configuration
# Generated: $(date)
SLIP_DOMAIN="${SLIP_DOMAIN:-}"
DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
SLIP_PORT="${SLIP_PORT:-5310}"
DNSTT_PORT="${DNSTT_PORT:-5311}"
SOCKS_PORT="${SOCKS_PORT:-58076}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
TUNNEL_USER_PASS="${TUNNEL_USER_PASS:-}"
SERVER_IP="${SERVER_IP:-}"
EOF
  chmod 600 "$STATE_FILE"
}

svc_status() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "${GREEN}● running${NC}"
  elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    echo -e "${YELLOW}○ stopped${NC}"
  else
    echo -e "${RED}✗ not installed${NC}"
  fi
}

# ── Install binaries ───────────────────────────────────────────────────────────
install_dnstt_server() {
  section "Installing dnstt-server"
  if [[ -x "$BIN_DIR/dnstt-server" ]]; then
    ok "dnstt-server already installed: $($BIN_DIR/dnstt-server -version 2>&1 | head -1)"
    return
  fi

  info "Attempting to install dnstt-server via Go..."
  if command -v go &>/dev/null; then
    GOPATH=/tmp/go-install go install www.bamsoftware.com/git/dnstt.git/cmd/dnstt-server@latest
    cp /tmp/go-install/bin/dnstt-server "$BIN_DIR/dnstt-server"
    chmod +x "$BIN_DIR/dnstt-server"
    ok "dnstt-server installed via Go"
    return
  fi

  info "Go not found. Trying to download prebuilt binary..."
  local ARCH
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="arm"   ;;
    *)       err "Unknown arch: $ARCH"; return 1 ;;
  esac

  # Try to download from known locations
  local URLS=(
    "https://www.bamsoftware.com/software/dnstt/releases/dnstt-linux-${ARCH}"
    "https://github.com/bamsoftware/dnstt/releases/latest/download/dnstt-linux-${ARCH}"
  )
  for url in "${URLS[@]}"; do
    if curl -fsSL "$url" -o "$BIN_DIR/dnstt-server" 2>/dev/null; then
      chmod +x "$BIN_DIR/dnstt-server"
      ok "dnstt-server downloaded from $url"
      return
    fi
  done

  warn "Auto-install failed. Please install dnstt-server manually:"
  warn "  go install www.bamsoftware.com/git/dnstt.git/cmd/dnstt-server@latest"
  warn "  Then copy to $BIN_DIR/dnstt-server"
  press_enter
}

install_microsocks() {
  section "Installing microsocks"
  if [[ -x "$BIN_DIR/microsocks" ]]; then
    ok "microsocks already installed"
    return
  fi

  info "Building microsocks from source..."
  apt-get install -y -q git build-essential 2>/dev/null || true
  local TMP; TMP=$(mktemp -d)
  git clone --depth=1 https://github.com/rofl0r/microsocks "$TMP/microsocks" 2>/dev/null
  make -C "$TMP/microsocks" -j"$(nproc)" 2>/dev/null
  cp "$TMP/microsocks/microsocks" "$BIN_DIR/microsocks"
  chmod +x "$BIN_DIR/microsocks"
  rm -rf "$TMP"
  ok "microsocks built and installed"
}

install_slipstream_server() {
  section "Installing slipstream-server"
  if [[ -x "$BIN_DIR/slipstream-server" ]]; then
    ok "slipstream-server already installed"
    return
  fi

  warn "slipstream-server binary not found."
  warn "Please provide the binary path (or press Enter to skip and install manually later):"
  ask "Path to slipstream-server binary: "; read -r SRC_PATH
  if [[ -f "${SRC_PATH:-}" ]]; then
    cp "$SRC_PATH" "$BIN_DIR/slipstream-server"
    chmod +x "$BIN_DIR/slipstream-server"
    ok "slipstream-server installed from $SRC_PATH"
  else
    warn "Skipped — install $BIN_DIR/slipstream-server manually before starting"
  fi
}

install_dnstm() {
  section "Installing dnstm"
  if [[ -x "$BIN_DIR/dnstm" ]]; then
    ok "dnstm already installed: $($BIN_DIR/dnstm version 2>&1 | head -1)"
    return
  fi

  warn "dnstm binary not found."
  warn "Please provide the binary path (or press Enter to skip):"
  ask "Path to dnstm binary: "; read -r SRC_PATH
  if [[ -f "${SRC_PATH:-}" ]]; then
    cp "$SRC_PATH" "$BIN_DIR/dnstm"
    chmod +x "$BIN_DIR/dnstm"
    ok "dnstm installed from $SRC_PATH"
  else
    warn "Skipped — install $BIN_DIR/dnstm manually"
  fi
}

# ── Setup steps ────────────────────────────────────────────────────────────────
collect_inputs() {
  section "Configuration"
  echo ""

  load_state

  ask "Server public IP [${SERVER_IP:-}]: "; read -r inp
  SERVER_IP="${inp:-${SERVER_IP:-}}"

  echo ""
  echo -e "  ${DIM}Slipstream uses fake-TLS over DNS (domain for Slipstream subdomain, e.g. b.yourdomain.com)${NC}"
  ask "Slipstream domain [${SLIP_DOMAIN:-}]: "; read -r inp
  SLIP_DOMAIN="${inp:-${SLIP_DOMAIN:-}}"

  ask "Slipstream port (UDP, default 5310) [${SLIP_PORT:-5310}]: "; read -r inp
  SLIP_PORT="${inp:-${SLIP_PORT:-5310}}"

  echo ""
  echo -e "  ${DIM}DNSTT tunnels traffic over DNS TXT records (separate subdomain, e.g. a.yourdomain.com)${NC}"
  ask "DNSTT domain [${DNSTT_DOMAIN:-}]: "; read -r inp
  DNSTT_DOMAIN="${inp:-${DNSTT_DOMAIN:-}}"

  ask "DNSTT port (UDP, default 5311) [${DNSTT_PORT:-5311}]: "; read -r inp
  DNSTT_PORT="${inp:-${DNSTT_PORT:-5311}}"

  echo ""
  section "SOCKS5 Proxy Authentication"
  ask "SOCKS5 port (localhost only, default 58076) [${SOCKS_PORT:-58076}]: "; read -r inp
  SOCKS_PORT="${inp:-${SOCKS_PORT:-58076}}"

  ask "SOCKS5 username [${SOCKS_USER:-}]: "; read -r inp
  SOCKS_USER="${inp:-${SOCKS_USER:-}}"

  ask "SOCKS5 password [${SOCKS_PASS:-}]: "; read -r -s inp; echo ""
  SOCKS_PASS="${inp:-${SOCKS_PASS:-}}"

  echo ""
  section "SSH Tunnel User"
  echo -e "  ${DIM}A restricted user account used for SSH-based SOCKS5 forwarding${NC}"
  ask "Tunnel SSH username [${TUNNEL_USER}]: "; read -r inp
  TUNNEL_USER="${inp:-$TUNNEL_USER}"

  ask "Tunnel user password [${TUNNEL_USER_PASS:-}]: "; read -r -s inp; echo ""
  TUNNEL_USER_PASS="${inp:-${TUNNEL_USER_PASS:-}}"

  echo ""
  echo -e "${BOLD}  Summary:${NC}"
  echo -e "  ${DIM}Slipstream  → ${SLIP_DOMAIN}:${SLIP_PORT}${NC}"
  echo -e "  ${DIM}DNSTT       → ${DNSTT_DOMAIN}:${DNSTT_PORT}${NC}"
  echo -e "  ${DIM}SOCKS5      → 127.0.0.1:${SOCKS_PORT} (user: ${SOCKS_USER})${NC}"
  echo -e "  ${DIM}Tunnel user → ${TUNNEL_USER}${NC}"
  echo ""
  ask "Continue with setup? [Y/n]: "; read -r CONFIRM
  [[ "${CONFIRM:-y}" =~ ^[Nn] ]] && { info "Aborted."; return 1; }
}

create_users() {
  section "Creating System Users"

  # dnstm service user
  if ! id "$DNSTM_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /sbin/nologin "$DNSTM_USER"
    ok "Created system user: $DNSTM_USER"
  else
    ok "User $DNSTM_USER already exists"
  fi

  # SSH tunnel user
  if ! id "$TUNNEL_USER" &>/dev/null; then
    useradd --home "/home/$TUNNEL_USER" --create-home --shell /bin/false "$TUNNEL_USER"
    ok "Created tunnel user: $TUNNEL_USER"
  else
    ok "User $TUNNEL_USER already exists"
  fi

  if [[ -n "${TUNNEL_USER_PASS:-}" ]]; then
    echo "${TUNNEL_USER}:${TUNNEL_USER_PASS}" | /usr/sbin/chpasswd
    ok "Set password for $TUNNEL_USER"
  fi
}

configure_ssh() {
  section "Configuring SSH for Tunnel User"

  # Enable PasswordAuthentication if not already
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

  # Remove old block if it exists
  sed -i "/^Match User ${TUNNEL_USER}/,/^$/d" /etc/ssh/sshd_config

  # Append the match block
  cat >> /etc/ssh/sshd_config <<EOF

Match User ${TUNNEL_USER}
    AllowTcpForwarding yes
    AllowStreamLocalForwarding yes
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication yes
    PubkeyAuthentication yes
EOF

  systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
  ok "SSH configured for $TUNNEL_USER"
}

create_dirs() {
  section "Creating Directory Structure"

  mkdir -p "$TUNNEL_DIR/slip-socks"
  mkdir -p "$TUNNEL_DIR/dnstt-socks"
  chown -R "$DNSTM_USER:$DNSTM_USER" "$CONF_DIR"
  chmod 750 "$CONF_DIR" "$TUNNEL_DIR" "$TUNNEL_DIR/slip-socks" "$TUNNEL_DIR/dnstt-socks"
  ok "Directories created at $CONF_DIR"
}

generate_slipstream_cert() {
  section "Generating Slipstream TLS Certificate"

  local CERT="$TUNNEL_DIR/slip-socks/cert.pem"
  local KEY="$TUNNEL_DIR/slip-socks/key.pem"

  if [[ -f "$CERT" && -f "$KEY" ]]; then
    ok "Slipstream cert already exists — skipping generation"
    return
  fi

  openssl req -x509 -newkey ec \
    -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$KEY" \
    -out "$CERT" \
    -days 3650 \
    -nodes \
    -subj "/CN=${SLIP_DOMAIN}" \
    2>/dev/null

  chown "$DNSTM_USER:$DNSTM_USER" "$CERT" "$KEY"
  chmod 640 "$KEY"
  chmod 644 "$CERT"
  ok "Slipstream cert generated (10 years): $CERT"
}

generate_dnstt_keys() {
  section "Generating DNSTT Keypair"

  local PRIV="$TUNNEL_DIR/dnstt-socks/server.key"
  local PUB="$TUNNEL_DIR/dnstt-socks/server.pub"

  if [[ -f "$PRIV" && -f "$PUB" ]]; then
    ok "DNSTT keys already exist — skipping generation"
    DNSTT_PUBKEY=$(cat "$PUB")
    return
  fi

  if [[ ! -x "$BIN_DIR/dnstt-server" ]]; then
    warn "dnstt-server not installed — cannot generate keys yet"
    return
  fi

  "$BIN_DIR/dnstt-server" -gen-key -privkey-file "$PRIV" -pubkey-file "$PUB"
  DNSTT_PUBKEY=$(cat "$PUB")
  chown "$DNSTM_USER:$DNSTM_USER" "$PRIV" "$PUB"
  chmod 600 "$PRIV"
  chmod 644 "$PUB"
  ok "DNSTT keypair generated"
  echo -e "\n  ${YELLOW}⚠ Public key (share this with clients):${NC}"
  echo -e "  ${BOLD}$DNSTT_PUBKEY${NC}\n"
}

write_dnstm_config() {
  section "Writing dnstm config"

  cat > "$DNSTM_CONF" <<EOF
{
  "log": {
    "level": "info"
  },
  "listen": {
    "address": "0.0.0.0:53"
  },
  "proxy": {
    "port": ${SOCKS_PORT}
  },
  "backends": [
    {
      "tag": "socks",
      "type": "socks",
      "address": "127.0.0.1:${SOCKS_PORT}"
    }
  ],
  "tunnels": [
    {
      "tag": "slip-socks",
      "enabled": true,
      "transport": "slipstream",
      "backend": "socks",
      "domain": "${SLIP_DOMAIN}",
      "port": ${SLIP_PORT},
      "slipstream": {
        "cert": "${TUNNEL_DIR}/slip-socks/cert.pem",
        "key": "${TUNNEL_DIR}/slip-socks/key.pem"
      }
    },
    {
      "tag": "dnstt-socks",
      "enabled": true,
      "transport": "dnstt",
      "backend": "socks",
      "domain": "${DNSTT_DOMAIN}",
      "port": ${DNSTT_PORT},
      "dnstt": {
        "mtu": 1232,
        "private_key": "${TUNNEL_DIR}/dnstt-socks/server.key"
      }
    }
  ],
  "route": {
    "mode": "multi",
    "active": "slip-socks",
    "default": "slip-socks"
  }
}
EOF
  chown "$DNSTM_USER:$DNSTM_USER" "$DNSTM_CONF"
  chmod 640 "$DNSTM_CONF"
  ok "Config written to $DNSTM_CONF"
}

write_services() {
  section "Writing systemd services"

  # microsocks
  cat > /etc/systemd/system/${SVC_SOCKS}.service <<EOF
[Unit]
Description=Microsocks SOCKS5 Proxy (authenticated)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${BIN_DIR}/microsocks -i 127.0.0.1 -p ${SOCKS_PORT} -u ${SOCKS_USER} -P ${SOCKS_PASS}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  # dnstt-server
  cat > /etc/systemd/system/${SVC_DNSTT}.service <<EOF
[Unit]
Description=DNSTT DNS Tunnel (${DNSTT_DOMAIN})
After=network-online.target ${SVC_SOCKS}.service
Wants=network-online.target
Requires=${SVC_SOCKS}.service

[Service]
Type=simple
User=${DNSTM_USER}
Group=${DNSTM_USER}
ExecStart=${BIN_DIR}/dnstt-server \\
  -udp 127.0.0.1:${DNSTT_PORT} \\
  -privkey-file ${TUNNEL_DIR}/dnstt-socks/server.key \\
  -mtu 1232 \\
  ${DNSTT_DOMAIN} \\
  127.0.0.1:${SOCKS_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  # slipstream-server
  cat > /etc/systemd/system/${SVC_SLIP}.service <<EOF
[Unit]
Description=Slipstream DNS Tunnel (${SLIP_DOMAIN})
After=network-online.target ${SVC_SOCKS}.service
Wants=network-online.target
Requires=${SVC_SOCKS}.service

[Service]
Type=simple
User=${DNSTM_USER}
Group=${DNSTM_USER}
ExecStart=${BIN_DIR}/slipstream-server \\
  --dns-listen-host 127.0.0.1 \\
  --domain ${SLIP_DOMAIN} \\
  --dns-listen-port ${SLIP_PORT} \\
  --target-address 127.0.0.1:${SOCKS_PORT} \\
  --cert ${TUNNEL_DIR}/slip-socks/cert.pem \\
  --key  ${TUNNEL_DIR}/slip-socks/key.pem
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  # dnstm router (DNS :53 → tunnels)
  cat > /etc/systemd/system/${SVC_DNSTM}.service <<EOF
[Unit]
Description=DNSTM DNS Router (port 53 → tunnels)
After=network-online.target ${SVC_DNSTT}.service ${SVC_SLIP}.service
Wants=network-online.target

[Service]
Type=simple
User=${DNSTM_USER}
Group=${DNSTM_USER}
ExecStart=${BIN_DIR}/dnstm dnsrouter serve
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadOnlyPaths=${CONF_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  ok "Services written and daemon reloaded"
}

enable_and_start() {
  section "Enabling & Starting Services"

  local SVCS=("$SVC_SOCKS" "$SVC_DNSTT" "$SVC_SLIP" "$SVC_DNSTM")
  for svc in "${SVCS[@]}"; do
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
      systemctl enable --now "$svc" 2>/dev/null && ok "Started: $svc" || warn "Failed to start: $svc"
    fi
  done
}

check_dns_delegation() {
  section "DNS Delegation Check"
  echo ""
  echo -e "  ${BOLD}Add these NS records in your DNS provider:${NC}"
  echo ""
  echo -e "  ${YELLOW}For Slipstream (${SLIP_DOMAIN}):${NC}"
  echo -e "  Type: NS   Name: ${SLIP_DOMAIN%.${SLIP_DOMAIN#*.}}   Value: ${SERVER_IP:-your.server.ip}"
  echo ""
  echo -e "  ${YELLOW}For DNSTT (${DNSTT_DOMAIN}):${NC}"
  echo -e "  Type: NS   Name: ${DNSTT_DOMAIN%.${DNSTT_DOMAIN#*.}}   Value: ${SERVER_IP:-your.server.ip}"
  echo ""
  echo -e "  ${DIM}Both subdomains must have their NS record pointing to this server's IP.${NC}"
  echo -e "  ${DIM}This is what makes DNS queries for those subdomains reach this machine.${NC}"

  if [[ -f "$TUNNEL_DIR/dnstt-socks/server.pub" ]]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}DNSTT Client Public Key:${NC}"
    echo -e "  ${BOLD}$(cat "$TUNNEL_DIR/dnstt-socks/server.pub")${NC}"
    echo -e "  ${DIM}(Give this to clients using the DNSTT tunnel)${NC}"
  fi
}

# ── Main setup flow ────────────────────────────────────────────────────────────
do_setup() {
  banner
  echo -e "  ${BOLD}Full Setup — dnstt + Slipstream + SOCKS5${NC}"
  echo ""
  require_root

  collect_inputs || return 0
  save_state

  install_microsocks
  install_dnstt_server
  install_slipstream_server
  install_dnstm
  create_users
  configure_ssh
  create_dirs
  generate_slipstream_cert
  generate_dnstt_keys
  write_dnstm_config
  write_services
  enable_and_start

  echo ""
  ok "${BOLD}Setup complete!${NC}"
  echo ""
  check_dns_delegation
  press_enter
}

# ── Status ─────────────────────────────────────────────────────────────────────
do_status() {
  banner
  echo -e "  ${BOLD}Service Status${NC}\n"
  require_root
  load_state

  printf "  %-26s %s\n" "Service" "Status"
  printf "  %-26s %s\n" "───────────────────────" "───────────"
  printf "  %-26s %b\n" "microsocks (SOCKS5)"     "$(svc_status $SVC_SOCKS)"
  printf "  %-26s %b\n" "dnstt-server"            "$(svc_status $SVC_DNSTT)"
  printf "  %-26s %b\n" "slipstream-server"       "$(svc_status $SVC_SLIP)"
  printf "  %-26s %b\n" "dnstm (DNS router :53)"  "$(svc_status $SVC_DNSTM)"

  echo ""
  section "Port Listeners"
  ss -ulnp 2>/dev/null | grep -E ":53|:${SOCKS_PORT:-58076}|:${SLIP_PORT:-5310}|:${DNSTT_PORT:-5311}" \
    | awk '{printf "  %-40s %s\n", $5, $6}' || true

  echo ""
  section "Configuration"
  if [[ -f "$STATE_FILE" ]]; then
    echo -e "  Slipstream  : ${SLIP_DOMAIN:-?}:${SLIP_PORT:-5310}"
    echo -e "  DNSTT       : ${DNSTT_DOMAIN:-?}:${DNSTT_PORT:-5311}"
    echo -e "  SOCKS5 port : 127.0.0.1:${SOCKS_PORT:-58076}"
    echo -e "  SOCKS5 user : ${SOCKS_USER:-?}"
    echo -e "  Tunnel user : ${TUNNEL_USER}"
  else
    warn "No saved state — run Setup first"
  fi

  echo ""
  section "DNSTT Public Key"
  local PUB="$TUNNEL_DIR/dnstt-socks/server.pub"
  [[ -f "$PUB" ]] && echo -e "  ${BOLD}$(cat "$PUB")${NC}" || warn "Key not generated yet"

  echo ""
  section "Recent Logs (last 10 lines each)"
  for svc in $SVC_SOCKS $SVC_DNSTT $SVC_SLIP $SVC_DNSTM; do
    echo -e "\n  ${CYAN}$svc:${NC}"
    journalctl -u "$svc" -n 10 --no-pager 2>/dev/null \
      | tail -10 | sed 's/^/    /' || true
  done

  press_enter
}

# ── Edit ───────────────────────────────────────────────────────────────────────
edit_menu() {
  while true; do
    banner
    echo -e "  ${BOLD}Edit Configuration${NC}\n"
    require_root
    load_state

    echo -e "  ${BOLD}1.${NC} SOCKS5 credentials (user/pass)"
    echo -e "  ${BOLD}2.${NC} Slipstream domain / port"
    echo -e "  ${BOLD}3.${NC} DNSTT domain / port"
    echo -e "  ${BOLD}4.${NC} Tunnel SSH user password"
    echo -e "  ${BOLD}5.${NC} Regenerate Slipstream TLS cert"
    echo -e "  ${BOLD}6.${NC} Regenerate DNSTT keypair"
    echo -e "  ${BOLD}7.${NC} Edit dnstm config.json directly"
    echo -e "  ${BOLD}0.${NC} Back"
    echo ""
    ask "Choice: "; read -r CHOICE

    case "$CHOICE" in
      1)
        ask "New SOCKS5 username [${SOCKS_USER:-}]: "; read -r inp
        SOCKS_USER="${inp:-$SOCKS_USER}"
        ask "New SOCKS5 password: "; read -r -s inp; echo ""
        SOCKS_PASS="${inp:-$SOCKS_PASS}"
        save_state
        write_dnstm_config
        write_services
        systemctl restart "$SVC_SOCKS" 2>/dev/null && ok "microsocks restarted with new credentials"
        press_enter ;;
      2)
        ask "New Slipstream domain [${SLIP_DOMAIN:-}]: "; read -r inp
        SLIP_DOMAIN="${inp:-$SLIP_DOMAIN}"
        ask "New Slipstream port [${SLIP_PORT:-5310}]: "; read -r inp
        SLIP_PORT="${inp:-$SLIP_PORT}"
        save_state
        write_dnstm_config
        write_services
        systemctl restart "$SVC_SLIP" "$SVC_DNSTM" 2>/dev/null && ok "Slipstream restarted"
        press_enter ;;
      3)
        ask "New DNSTT domain [${DNSTT_DOMAIN:-}]: "; read -r inp
        DNSTT_DOMAIN="${inp:-$DNSTT_DOMAIN}"
        ask "New DNSTT port [${DNSTT_PORT:-5311}]: "; read -r inp
        DNSTT_PORT="${inp:-$DNSTT_PORT}"
        save_state
        write_dnstm_config
        write_services
        systemctl restart "$SVC_DNSTT" "$SVC_DNSTM" 2>/dev/null && ok "DNSTT restarted"
        press_enter ;;
      4)
        ask "New password for $TUNNEL_USER: "; read -r -s inp; echo ""
        TUNNEL_USER_PASS="${inp:-$TUNNEL_USER_PASS}"
        echo "${TUNNEL_USER}:${TUNNEL_USER_PASS}" | /usr/sbin/chpasswd
        save_state
        ok "Password updated for $TUNNEL_USER"
        press_enter ;;
      5)
        rm -f "$TUNNEL_DIR/slip-socks/cert.pem" "$TUNNEL_DIR/slip-socks/key.pem"
        generate_slipstream_cert
        systemctl restart "$SVC_SLIP" 2>/dev/null && ok "Slipstream restarted with new cert"
        press_enter ;;
      6)
        rm -f "$TUNNEL_DIR/dnstt-socks/server.key" "$TUNNEL_DIR/dnstt-socks/server.pub"
        generate_dnstt_keys
        systemctl restart "$SVC_DNSTT" 2>/dev/null && ok "DNSTT restarted with new keys"
        press_enter ;;
      7)
        "${EDITOR:-nano}" "$DNSTM_CONF"
        systemctl restart "$SVC_DNSTT" "$SVC_SLIP" "$SVC_DNSTM" 2>/dev/null
        ok "Config saved and services restarted"
        press_enter ;;
      0) return ;;
    esac
  done
}

# ── Manage ─────────────────────────────────────────────────────────────────────
manage_menu() {
  while true; do
    banner
    echo -e "  ${BOLD}Manage Tunnels${NC}\n"
    require_root
    load_state

    echo -e "  ${CYAN}All services:${NC}"
    echo -e "  ${BOLD}1.${NC}  Start all"
    echo -e "  ${BOLD}2.${NC}  Stop all"
    echo -e "  ${BOLD}3.${NC}  Restart all"
    echo ""
    echo -e "  ${CYAN}Individual:${NC}"
    echo -e "  ${BOLD}4.${NC}  microsocks (SOCKS5 proxy)   — $(svc_status $SVC_SOCKS)"
    echo -e "  ${BOLD}5.${NC}  dnstt-server               — $(svc_status $SVC_DNSTT)"
    echo -e "  ${BOLD}6.${NC}  slipstream-server          — $(svc_status $SVC_SLIP)"
    echo -e "  ${BOLD}7.${NC}  dnstm (DNS router :53)     — $(svc_status $SVC_DNSTM)"
    echo ""
    echo -e "  ${CYAN}Auth / Keys:${NC}"
    echo -e "  ${BOLD}8.${NC}  Show credentials & public keys"
    echo ""
    echo -e "  ${BOLD}0.${NC}  Back"
    echo ""
    ask "Choice: "; read -r CHOICE

    _restart_svc() {
      local action="$1"; shift
      for svc in "$@"; do
        systemctl "$action" "$svc" 2>/dev/null \
          && ok "${action^}: $svc" \
          || warn "Failed to $action: $svc"
      done
      press_enter
    }

    case "$CHOICE" in
      1) _restart_svc start  "$SVC_SOCKS" "$SVC_DNSTT" "$SVC_SLIP" "$SVC_DNSTM" ;;
      2) _restart_svc stop   "$SVC_DNSTM" "$SVC_SLIP"  "$SVC_DNSTT" "$SVC_SOCKS" ;;
      3) _restart_svc restart "$SVC_SOCKS" "$SVC_DNSTT" "$SVC_SLIP" "$SVC_DNSTM" ;;
      4)
        echo -e "\n  microsocks: $(svc_status $SVC_SOCKS)"
        ask "Action [start/stop/restart]: "; read -r A
        _restart_svc "$A" "$SVC_SOCKS" ;;
      5)
        echo -e "\n  dnstt-server: $(svc_status $SVC_DNSTT)"
        ask "Action [start/stop/restart]: "; read -r A
        _restart_svc "$A" "$SVC_DNSTT" ;;
      6)
        echo -e "\n  slipstream-server: $(svc_status $SVC_SLIP)"
        ask "Action [start/stop/restart]: "; read -r A
        _restart_svc "$A" "$SVC_SLIP" ;;
      7)
        echo -e "\n  dnstm: $(svc_status $SVC_DNSTM)"
        ask "Action [start/stop/restart]: "; read -r A
        _restart_svc "$A" "$SVC_DNSTM" ;;
      8)
        banner
        echo -e "  ${BOLD}Credentials & Keys${NC}\n"
        echo -e "  ${CYAN}SOCKS5 Proxy${NC}"
        echo -e "  Host     : 127.0.0.1:${SOCKS_PORT:-58076}"
        echo -e "  Username : ${SOCKS_USER:-?}"
        echo -e "  Password : ${SOCKS_PASS:-?}"
        echo ""
        echo -e "  ${CYAN}SSH Tunnel User${NC}"
        echo -e "  User     : ${TUNNEL_USER}"
        echo -e "  Password : ${TUNNEL_USER_PASS:-?}"
        echo -e "  Port     : 22 (or your SSH port)"
        echo ""
        echo -e "  ${CYAN}Slipstream${NC}"
        echo -e "  Domain   : ${SLIP_DOMAIN:-?}"
        echo -e "  Port     : ${SLIP_PORT:-5310}"
        if [[ -f "$TUNNEL_DIR/slip-socks/cert.pem" ]]; then
          echo -e "  Cert FP  : $(openssl x509 -fingerprint -noout -sha256 \
            -in "$TUNNEL_DIR/slip-socks/cert.pem" 2>/dev/null | cut -d= -f2)"
        fi
        echo ""
        echo -e "  ${CYAN}DNSTT${NC}"
        echo -e "  Domain   : ${DNSTT_DOMAIN:-?}"
        echo -e "  Port     : ${DNSTT_PORT:-5311}"
        if [[ -f "$TUNNEL_DIR/dnstt-socks/server.pub" ]]; then
          echo -e "  ${BOLD}${YELLOW}Public Key: $(cat "$TUNNEL_DIR/dnstt-socks/server.pub")${NC}"
        fi
        press_enter ;;
      0) return ;;
    esac
  done
}

# ── Main Menu ──────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    banner
    echo -e "  ${BOLD}Main Menu${NC}\n"

    load_state 2>/dev/null || true

    # Quick status line
    echo -e "  Services: microsocks $(svc_status $SVC_SOCKS)  dnstt $(svc_status $SVC_DNSTT)  slipstream $(svc_status $SVC_SLIP)  router $(svc_status $SVC_DNSTM)"
    echo ""
    echo -e "  ${BOLD}1.${NC}  🔧  Setup         — full initial installation & configuration"
    echo -e "  ${BOLD}2.${NC}  ✏️   Edit          — update domains, ports, credentials"
    echo -e "  ${BOLD}3.${NC}  📊  Status        — service status, ports, logs"
    echo -e "  ${BOLD}4.${NC}  ⚙️   Manage        — start / stop / restart / show auth"
    echo -e "  ${BOLD}0.${NC}  ❌  Exit"
    echo ""
    ask "Choice: "; read -r CHOICE

    case "$CHOICE" in
      1) do_setup  ;;
      2) edit_menu ;;
      3) do_status ;;
      4) manage_menu ;;
      0) echo ""; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

# ── Entry point ────────────────────────────────────────────────────────────────
main_menu
