#!/usr/bin/env bash
# ============================================================
#  dnstm-setup.sh — DNS Tunnel Manager (dnstm + slipstream + dnstt)
#  Manages: microsocks, dnstm, slipstream-server, dnstt-server
# ============================================================
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Paths ────────────────────────────────────────────────────
BIN_DIR="/usr/local/bin"
CFG_DIR="/etc/dnstm"
TUN_DIR="$CFG_DIR/tunnels"
CFG_FILE="$CFG_DIR/config.json"
SSHD_CFG="/etc/ssh/sshd_config"

SERVICES=(microsocks dnstm dnstm-slip-socks dnstm-dnstt-socks)

# ── Helpers ──────────────────────────────────────────────────
info()    { echo -e "${CYAN}[•]${RESET} $*"; }
ok()      { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
err()     { echo -e "${RED}[✗]${RESET} $*"; }
die()     { err "$*"; exit 1; }
hr()      { echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }
bold()    { echo -e "${BOLD}$*${RESET}"; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

prompt() {
    local var="$1" msg="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [${default}]"
    read -rp "$(echo -e "${YELLOW}?${RESET} ${msg}${hint}: ")" val
    [[ -z "$val" ]] && val="$default"
    printf -v "$var" '%s' "$val"
}

prompt_secret() {
    local var="$1" msg="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" [press Enter to keep]"
    read -rsp "$(echo -e "${YELLOW}?${RESET} ${msg}${hint}: ")" val
    echo
    [[ -z "$val" ]] && val="$default"
    printf -v "$var" '%s' "$val"
}

read_cfg() {
    python3 -c "import json,sys; d=json.load(open('$CFG_FILE')); print(d$1)" 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════
main_menu() {
    while true; do
        clear
        hr
        bold "       DNS Tunnel Manager — dnstm + slipstream + dnstt"
        hr
        echo -e "  ${BOLD}1)${RESET} 🛠  Setup       — Install & configure everything from scratch"
        echo -e "  ${BOLD}2)${RESET} ✏️  Edit Config  — Modify /etc/dnstm/config.json"
        echo -e "  ${BOLD}3)${RESET} 📊 Status       — View all service states"
        echo -e "  ${BOLD}4)${RESET} ⚙️  Manage       — Start / Stop / Restart + show credentials"
        echo -e "  ${BOLD}0)${RESET} 🚪 Exit"
        hr
        prompt choice "Choose" ""
        case "$choice" in
            1) menu_setup ;;
            2) menu_edit ;;
            3) menu_status ;;
            4) menu_manage ;;
            0) echo "Bye!"; exit 0 ;;
            *) warn "Invalid choice" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  1. SETUP
# ═══════════════════════════════════════════════════════════
menu_setup() {
    need_root
    clear; hr; bold "  🛠  Setup — Collect Configuration"; hr; echo

    # ── Collect inputs ──────────────────────────────────────
    bold "── Slipstream tunnel ──"
    prompt SLIP_DOMAIN  "Slipstream DNS domain (e.g. b.example.com)" "b.barzin.biz"
    prompt SLIP_PORT    "Slipstream listen port (on 127.0.0.1)"      "5310"

    echo
    bold "── dnstt tunnel ──"
    prompt DNSTT_DOMAIN "dnstt DNS domain (e.g. a.example.com)"       "a.barzin.biz"
    prompt DNSTT_PORT   "dnstt listen port (on 127.0.0.1)"            "5311"

    echo
    bold "── SOCKS5 backend (microsocks) ──"
    prompt SOCKS_PORT   "SOCKS5 listen port"                           "58076"
    prompt SOCKS_USER   "SOCKS5 username"                              "barzin"
    prompt_secret SOCKS_PASS "SOCKS5 password"

    echo
    bold "── SSH tunnel user ──"
    prompt SSH_USER     "SSH restricted username"                      "tunneluser"
    prompt_secret SSH_PASS "SSH password for $SSH_USER"

    echo
    bold "── dnstm listen ──"
    prompt DNSTM_LISTEN "dnstm DNS listen address"                    "0.0.0.0:53"

    echo; hr
    bold "  Summary"
    hr
    echo "  Slipstream : $SLIP_DOMAIN  port=$SLIP_PORT"
    echo "  dnstt      : $DNSTT_DOMAIN  port=$DNSTT_PORT"
    echo "  SOCKS5     : 127.0.0.1:$SOCKS_PORT  user=$SOCKS_USER"
    echo "  SSH user   : $SSH_USER"
    echo "  dnstm      : $DNSTM_LISTEN"
    hr
    prompt confirm "Proceed with installation? (yes/no)" "yes"
    [[ "$confirm" != "yes" ]] && { warn "Aborted."; return; }

    # ── Install dependencies ────────────────────────────────
    info "Installing dependencies..."
    apt-get install -y -q openssh-server openssl curl wget python3 2>/dev/null || true
    ok "Dependencies ready"

    # ── Create system users ─────────────────────────────────
    info "Creating system users..."
    if ! id dnstm &>/dev/null; then
        /usr/sbin/useradd --system --no-create-home --shell /bin/false dnstm
        ok "Created system user: dnstm"
    else
        ok "User dnstm already exists"
    fi

    if ! id "$SSH_USER" &>/dev/null; then
        /usr/sbin/adduser --disabled-password --gecos "" "$SSH_USER"
        echo "$SSH_USER:$SSH_PASS" | /usr/sbin/chpasswd
        ok "Created user: $SSH_USER"
    else
        warn "User $SSH_USER already exists — updating password"
        echo "$SSH_USER:$SSH_PASS" | /usr/sbin/chpasswd
    fi

    # ── Check / install binaries ────────────────────────────
    install_binaries

    # ── Create directories ──────────────────────────────────
    info "Creating config directories..."
    mkdir -p "$TUN_DIR/slip-socks" "$TUN_DIR/dnstt-ssh"
    chown -R dnstm:dnstm "$CFG_DIR"
    ok "Directories: $CFG_DIR"

    # ── Generate slipstream TLS cert ────────────────────────
    SLIP_CERT="$TUN_DIR/slip-socks/cert.pem"
    SLIP_KEY="$TUN_DIR/slip-socks/key.pem"
    if [[ ! -f "$SLIP_CERT" ]]; then
        info "Generating slipstream TLS certificate..."
        openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
            -keyout "$SLIP_KEY" -out "$SLIP_CERT" \
            -subj "/CN=$SLIP_DOMAIN" \
            -addext "subjectAltName=DNS:$SLIP_DOMAIN" 2>/dev/null
        chown dnstm:dnstm "$SLIP_CERT" "$SLIP_KEY"
        chmod 600 "$SLIP_KEY"
        ok "TLS cert: $SLIP_CERT"
    else
        ok "TLS cert already exists: $SLIP_CERT"
    fi

    # ── Generate dnstt keypair ───────────────────────────────
    DNSTT_KEY="$TUN_DIR/dnstt-ssh/server.key"
    DNSTT_PUB="$TUN_DIR/dnstt-ssh/server.pub"
    if [[ ! -f "$DNSTT_KEY" ]]; then
        info "Generating dnstt keypair..."
        if [[ -x "$BIN_DIR/dnstt-server" ]]; then
            cd "$TUN_DIR/dnstt-ssh"
            "$BIN_DIR/dnstt-server" -gen-key -privkey-file server.key -pubkey-file server.pub 2>/dev/null || \
                openssl genpkey -algorithm X25519 -out server.key 2>/dev/null && \
                openssl pkey -in server.key -pubout -out server.pub 2>/dev/null
        else
            warn "dnstt-server not found — generating placeholder key with openssl"
            openssl genpkey -algorithm X25519 -out "$DNSTT_KEY" 2>/dev/null || \
                dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p > "$DNSTT_KEY"
        fi
        chown -R dnstm:dnstm "$TUN_DIR/dnstt-ssh/"
        chmod 600 "$DNSTT_KEY"
        ok "dnstt keypair: $DNSTT_KEY"
    else
        ok "dnstt key already exists: $DNSTT_KEY"
    fi

    # Print pubkey for DNS TXT record
    if [[ -f "$DNSTT_PUB" ]]; then
        PUBKEY=$(cat "$DNSTT_PUB" 2>/dev/null | grep -v '^-' | tr -d '\n' || echo "(read key manually)")
        echo
        warn "⚠  Add this TXT record to DNS for $DNSTT_DOMAIN:"
        echo -e "   ${BOLD}$PUBKEY${RESET}"
        echo
    fi

    # ── Write config.json ───────────────────────────────────
    info "Writing $CFG_FILE..."
    cat > "$CFG_FILE" <<EOF
{
  "log": { "level": "info" },
  "listen": { "address": "$DNSTM_LISTEN" },
  "proxy": { "port": $SOCKS_PORT },
  "backends": [
    { "tag": "socks", "type": "socks", "address": "127.0.0.1:$SOCKS_PORT" }
  ],
  "tunnels": [
    {
      "tag": "slip-socks",
      "enabled": true,
      "transport": "slipstream",
      "backend": "socks",
      "domain": "$SLIP_DOMAIN",
      "port": $SLIP_PORT,
      "slipstream": {
        "cert": "$SLIP_CERT",
        "key": "$SLIP_KEY"
      }
    },
    {
      "tag": "dnstt-socks",
      "enabled": true,
      "transport": "dnstt",
      "backend": "socks",
      "domain": "$DNSTT_DOMAIN",
      "port": $DNSTT_PORT,
      "dnstt": {
        "mtu": 1232,
        "private_key": "$DNSTT_KEY"
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
    chown dnstm:dnstm "$CFG_FILE"
    ok "Config written: $CFG_FILE"

    # ── Write systemd units ─────────────────────────────────
    info "Writing systemd units..."

    cat > /etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=microsocks SOCKS5 proxy
After=network.target

[Service]
ExecStart=$BIN_DIR/microsocks -i 127.0.0.1 -p $SOCKS_PORT -u $SOCKS_USER -P $SOCKS_PASS
Restart=always
RestartSec=5
User=dnstm
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/dnstm.service <<EOF
[Unit]
Description=dnstm DNS router
After=network.target microsocks.service
Requires=microsocks.service

[Service]
ExecStart=$BIN_DIR/dnstm dnsrouter serve
WorkingDirectory=$CFG_DIR
Restart=always
RestartSec=5
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/dnstm-slip-socks.service <<EOF
[Unit]
Description=Slipstream DNS tunnel (slip-socks)
After=network.target microsocks.service
Requires=microsocks.service

[Service]
ExecStart=$BIN_DIR/slipstream-server \\
  --dns-listen-host 127.0.0.1 \\
  --domain $SLIP_DOMAIN \\
  --dns-listen-port $SLIP_PORT \\
  --target-address 127.0.0.1:$SOCKS_PORT \\
  --cert $SLIP_CERT \\
  --key $SLIP_KEY
Restart=always
RestartSec=5
User=dnstm

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/dnstm-dnstt-socks.service <<EOF
[Unit]
Description=dnstt DNS tunnel (dnstt-socks)
After=network.target microsocks.service
Requires=microsocks.service

[Service]
ExecStart=$BIN_DIR/dnstt-server \\
  -udp 127.0.0.1:$DNSTT_PORT \\
  -privkey-file $DNSTT_KEY \\
  -mtu 1232 \\
  $DNSTT_DOMAIN 127.0.0.1:$SOCKS_PORT
Restart=always
RestartSec=5
User=dnstm

[Install]
WantedBy=multi-user.target
EOF

    ok "Systemd units written"

    # ── Configure SSH for tunnel user ───────────────────────
    configure_sshd "$SSH_USER"

    # ── Enable & start services ─────────────────────────────
    info "Enabling and starting services..."
    systemctl daemon-reload
    for svc in "${SERVICES[@]}"; do
        systemctl enable "$svc" 2>/dev/null && ok "Enabled: $svc"
        systemctl restart "$svc" && ok "Started: $svc" || warn "Failed to start: $svc"
    done

    # ── Save credentials to file ─────────────────────────────
    CREDS_FILE="$CFG_DIR/credentials.txt"
    cat > "$CREDS_FILE" <<EOF
# DNS Tunnel Credentials — generated $(date)
SOCKS5_HOST=127.0.0.1
SOCKS5_PORT=$SOCKS_PORT
SOCKS5_USER=$SOCKS_USER
SOCKS5_PASS=$SOCKS_PASS

SSH_USER=$SSH_USER
SSH_PASS=$SSH_PASS

SLIP_DOMAIN=$SLIP_DOMAIN
SLIP_PORT=$SLIP_PORT
SLIP_CERT=$SLIP_CERT

DNSTT_DOMAIN=$DNSTT_DOMAIN
DNSTT_PORT=$DNSTT_PORT
DNSTT_PUBKEY_FILE=$DNSTT_PUB
EOF
    chmod 600 "$CREDS_FILE"
    ok "Credentials saved: $CREDS_FILE"

    echo; hr; ok "Setup complete!"; hr
    read -rp "Press Enter to return to menu..."
}

# ── Install binaries helper ──────────────────────────────────
RELEASE_ZIP="https://github.com/BarzinJarvis/dns-tunnel-kit/releases/latest/download/dns-tunnel-kit-linux-x86_64.zip"
REQUIRED_BINS=(dnstm dnstt-server slipstream-server microsocks)

install_binaries() {
    local missing=()
    for bin in "${REQUIRED_BINS[@]}"; do
        [[ -x "$BIN_DIR/$bin" ]] || missing+=("$bin")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "All binaries present in $BIN_DIR"; return
    fi

    warn "Missing binaries: ${missing[*]}"
    info "Auto-downloading from GitHub release..."

    # Check for required tools
    local dl_tool=""
    if command -v wget &>/dev/null; then dl_tool="wget"
    elif command -v curl &>/dev/null; then dl_tool="curl"
    else die "Neither wget nor curl found. Install one and retry."; fi

    local tmp_zip="/tmp/dns-tunnel-kit.zip"
    local tmp_dir="/tmp/dns-tunnel-kit-extract"

    # Download zip
    info "Downloading $RELEASE_ZIP ..."
    if [[ "$dl_tool" == "wget" ]]; then
        wget -q --show-progress -O "$tmp_zip" "$RELEASE_ZIP" || die "Download failed"
    else
        curl -L --progress-bar -o "$tmp_zip" "$RELEASE_ZIP" || die "Download failed"
    fi

    # Extract
    rm -rf "$tmp_dir"; mkdir -p "$tmp_dir"
    if command -v unzip &>/dev/null; then
        unzip -q "$tmp_zip" -d "$tmp_dir"
    else
        info "unzip not found — installing..."
        apt-get install -y -q unzip 2>/dev/null || die "Cannot install unzip"
        unzip -q "$tmp_zip" -d "$tmp_dir"
    fi

    # Find and install each binary (may be in a subdirectory)
    for bin in "${missing[@]}"; do
        local found
        found=$(find "$tmp_dir" -type f -name "$bin" | head -1)
        if [[ -n "$found" ]]; then
            cp "$found" "$BIN_DIR/$bin"
            chmod +x "$BIN_DIR/$bin"
            ok "Installed: $bin → $BIN_DIR/$bin"
        else
            warn "Not found in zip: $bin — you may need to install it manually"
        fi
    done

    rm -f "$tmp_zip"
    rm -rf "$tmp_dir"

    # Final check
    local still_missing=()
    for bin in "${REQUIRED_BINS[@]}"; do
        [[ -x "$BIN_DIR/$bin" ]] || still_missing+=("$bin")
    done
    if [[ ${#still_missing[@]} -gt 0 ]]; then
        warn "Still missing after download: ${still_missing[*]}"
        echo
        echo "  Manual options:"
        echo "  1) Provide a custom download URL base"
        echo "  2) Provide path to a local directory containing the binaries"
        echo "  3) Continue anyway (services will fail to start)"
        prompt bin_choice "Choice" "3"
        case "$bin_choice" in
            1)
                prompt BASE_URL "Base URL" ""
                for bin in "${still_missing[@]}"; do
                    info "Downloading $bin..."
                    wget -q -O "$BIN_DIR/$bin" "${BASE_URL%/}/$bin" && \
                        chmod +x "$BIN_DIR/$bin" && ok "Installed: $bin" || warn "Failed: $bin"
                done
                ;;
            2)
                prompt BIN_SRC "Directory path" "/tmp"
                for bin in "${still_missing[@]}"; do
                    if [[ -f "$BIN_SRC/$bin" ]]; then
                        cp "$BIN_SRC/$bin" "$BIN_DIR/$bin"
                        chmod +x "$BIN_DIR/$bin" && ok "Copied: $bin"
                    else
                        warn "Not found: $BIN_SRC/$bin"
                    fi
                done
                ;;
            3) warn "Continuing — some services may fail" ;;
        esac
    else
        ok "All binaries installed successfully"
    fi
}

# ── Configure sshd for tunnel user ──────────────────────────
configure_sshd() {
    local user="$1"
    info "Configuring sshd for $user..."

    # Remove existing Match block for this user if present
    if grep -q "Match User $user" "$SSHD_CFG" 2>/dev/null; then
        warn "Match User $user already in sshd_config — skipping (edit manually if needed)"
        return
    fi

    cat >> "$SSHD_CFG" <<EOF

# DNS tunnel restricted user — added by dnstm-setup.sh
Match User $user
    AllowTcpForwarding yes
    AllowStreamLocalForwarding yes
    PermitTTY no
    X11Forwarding no
    PasswordAuthentication yes
    PubkeyAuthentication yes
EOF

    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    ok "sshd configured for $user"
}

# ═══════════════════════════════════════════════════════════
#  2. EDIT CONFIG
# ═══════════════════════════════════════════════════════════
menu_edit() {
    need_root
    [[ -f "$CFG_FILE" ]] || { err "Config not found: $CFG_FILE  (run Setup first)"; sleep 2; return; }

    EDITOR="${EDITOR:-nano}"
    info "Opening $CFG_FILE with $EDITOR..."
    "$EDITOR" "$CFG_FILE"

    echo
    info "Validating JSON..."
    if python3 -c "import json; json.load(open('$CFG_FILE'))" 2>/dev/null; then
        ok "JSON valid"
    else
        err "Invalid JSON! Fix before reloading."
        read -rp "Press Enter to re-open editor or Ctrl+C to abort..."
        "$EDITOR" "$CFG_FILE"
    fi

    prompt reload_now "Reload services now? (yes/no)" "yes"
    if [[ "$reload_now" == "yes" ]]; then
        for svc in "${SERVICES[@]}"; do
            systemctl is-active "$svc" &>/dev/null && \
                systemctl restart "$svc" && ok "Restarted: $svc" || true
        done
    fi

    read -rp "Press Enter to return to menu..."
}

# ═══════════════════════════════════════════════════════════
#  3. STATUS
# ═══════════════════════════════════════════════════════════
menu_status() {
    clear; hr; bold "  📊 Service Status"; hr; echo

    for svc in "${SERVICES[@]}"; do
        local state color
        if systemctl is-active "$svc" &>/dev/null; then
            state="● RUNNING"; color="$GREEN"
        elif systemctl is-enabled "$svc" &>/dev/null; then
            state="○ STOPPED"; color="$YELLOW"
        else
            state="✗ MISSING"; color="$RED"
        fi
        printf "  ${color}%-8s${RESET}  %s\n" "$state" "$svc"

        # Show brief status line
        systemctl status "$svc" --no-pager -l 2>/dev/null \
            | grep -E "Active:|Main PID:" | head -2 | sed 's/^/           /'
        echo
    done

    hr
    # Show listening ports
    bold "  Listening ports:"
    ss -tlunp 2>/dev/null | grep -E "microsocks|dnstm|slipstream|dnstt|:53 |:5310|:5311|:58076" \
        | sed 's/^/  /' || netstat -tlunp 2>/dev/null | grep -E "53|5310|5311|58076" | sed 's/^/  /' || true

    hr
    # Show config summary if exists
    if [[ -f "$CFG_FILE" ]]; then
        bold "  Config: $CFG_FILE"
        python3 -c "
import json, sys
d = json.load(open('$CFG_FILE'))
print(f\"  Listen : {d.get('listen',{}).get('address','?')}\")
for t in d.get('tunnels', []):
    tag = t.get('tag','?')
    dom = t.get('domain','?')
    port = t.get('port','?')
    enabled = '✓' if t.get('enabled') else '✗'
    print(f\"  Tunnel : [{enabled}] {tag}  {dom}:{port}\")
print(f\"  Route  : {d.get('route',{}).get('default','?')}\")
" 2>/dev/null || warn "(could not parse config)"
    fi

    echo; read -rp "Press Enter to return to menu..."
}

# ═══════════════════════════════════════════════════════════
#  4. MANAGE
# ═══════════════════════════════════════════════════════════
menu_manage() {
    while true; do
        clear; hr; bold "  ⚙️  Manage Services"; hr
        echo -e "  ${BOLD}1)${RESET} ▶  Start all services"
        echo -e "  ${BOLD}2)${RESET} ■  Stop all services"
        echo -e "  ${BOLD}3)${RESET} ↺  Restart all services"
        echo -e "  ${BOLD}4)${RESET} 🔑 Show credentials"
        echo -e "  ${BOLD}5)${RESET} 🔑 Change SOCKS5 password"
        echo -e "  ${BOLD}6)${RESET} 🔑 Change SSH tunnel user password"
        echo -e "  ${BOLD}0)${RESET} ← Back"
        hr
        prompt choice "Choose" ""
        case "$choice" in
            1) svc_action start   ;;
            2) svc_action stop    ;;
            3) svc_action restart ;;
            4) show_credentials   ;;
            5) change_socks_pass  ;;
            6) change_ssh_pass    ;;
            0) return ;;
            *) warn "Invalid" ;;
        esac
    done
}

svc_action() {
    need_root
    local action="$1"
    echo
    for svc in "${SERVICES[@]}"; do
        systemctl "$action" "$svc" 2>/dev/null && ok "${action^}: $svc" || warn "Failed ${action}: $svc"
    done
    read -rp "Press Enter to continue..."
}

show_credentials() {
    clear; hr; bold "  🔑 Credentials"; hr; echo

    CREDS_FILE="$CFG_DIR/credentials.txt"
    if [[ -f "$CREDS_FILE" ]]; then
        cat "$CREDS_FILE" | grep -v '^#'
    else
        warn "No credentials file found at $CREDS_FILE"
        warn "Run Setup first, or check $CFG_FILE manually."
    fi

    # Also show dnstt pubkey
    PUB_FILE="$TUN_DIR/dnstt-ssh/server.pub"
    if [[ -f "$PUB_FILE" ]]; then
        echo
        bold "── dnstt public key (add as DNS TXT record) ──"
        cat "$PUB_FILE"
    fi

    # Show slipstream cert fingerprint
    CERT_FILE="$TUN_DIR/slip-socks/cert.pem"
    if [[ -f "$CERT_FILE" ]]; then
        echo
        bold "── Slipstream TLS cert fingerprint ──"
        openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null || true
        openssl x509 -in "$CERT_FILE" -noout -dates 2>/dev/null || true
    fi

    echo; read -rp "Press Enter to return..."
}

change_socks_pass() {
    need_root
    CREDS_FILE="$CFG_DIR/credentials.txt"

    local cur_user cur_port cur_pass
    cur_user=$(grep "^SOCKS5_USER=" "$CREDS_FILE" 2>/dev/null | cut -d= -f2 || echo "barzin")
    cur_port=$(grep "^SOCKS5_PORT=" "$CREDS_FILE" 2>/dev/null | cut -d= -f2 || echo "58076")

    echo
    prompt_secret new_pass "New SOCKS5 password for $cur_user"
    [[ -z "$new_pass" ]] && { warn "No password entered."; return; }

    # Update unit file
    local unit="/etc/systemd/system/microsocks.service"
    if [[ -f "$unit" ]]; then
        sed -i "s/-P [^ ]*/-P $new_pass/" "$unit"
        # Update credentials file
        [[ -f "$CREDS_FILE" ]] && sed -i "s/^SOCKS5_PASS=.*/SOCKS5_PASS=$new_pass/" "$CREDS_FILE"
        systemctl daemon-reload
        systemctl restart microsocks && ok "microsocks restarted with new password"
    else
        warn "microsocks.service not found — run Setup first"
    fi

    read -rp "Press Enter to continue..."
}

change_ssh_pass() {
    need_root
    CREDS_FILE="$CFG_DIR/credentials.txt"
    local ssh_user
    ssh_user=$(grep "^SSH_USER=" "$CREDS_FILE" 2>/dev/null | cut -d= -f2 || echo "tunneluser")

    echo
    prompt_secret new_pass "New SSH password for $ssh_user"
    [[ -z "$new_pass" ]] && { warn "No password entered."; return; }

    echo "$ssh_user:$new_pass" | /usr/sbin/chpasswd && ok "Password updated for $ssh_user"
    [[ -f "$CREDS_FILE" ]] && sed -i "s/^SSH_PASS=.*/SSH_PASS=$new_pass/" "$CREDS_FILE"

    read -rp "Press Enter to continue..."
}

# ── Entry point ──────────────────────────────────────────────
main_menu
