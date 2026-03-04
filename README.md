# 🌐 DNS Tunnel Kit

Bypass DNS-based internet censorship using **DNSTT** and **Slipstream** tunnels — routes all traffic through an authenticated SOCKS5 proxy hidden inside DNS traffic.

> **Credits:** [github.com/mrvcoder](https://github.com/mrvcoder)

---

## 📸 Terminal Preview

```
────────────────────────────────────────────────────────────
       DNS Tunnel Manager — dnstm + slipstream + dnstt
       Credits: https://github.com/mrvcoder
────────────────────────────────────────────────────────────
  1) 🛠  Setup       — Install & configure everything from scratch
  2) ✏️  Edit Config  — Modify /etc/dnstm/config.json
  3) 📊 Status       — View all service states
  4) ⚙️  Manage       — Start / Stop / Restart + show credentials
  0) 🚪 Exit
────────────────────────────────────────────────────────────
? Choose:
```

**Status view:**
```
────────────────────────────────────────────────────────────
  📊 Service Status
────────────────────────────────────────────────────────────
  ● RUNNING   microsocks
           Active: active (running) since ...
           Main PID: 1234

  ● RUNNING   dnstm
           Active: active (running) since ...
           Main PID: 1235

  ● RUNNING   dnstm-slip-socks
           Active: active (running) since ...

  ● RUNNING   dnstm-dnstt-socks
           Active: active (running) since ...

────────────────────────────────────────────────────────────
  Listening ports:
  udp   0.0.0.0:53       dnstm
  tcp   127.0.0.1:58076  microsocks
  udp   127.0.0.1:5310   slipstream-server
  udp   127.0.0.1:5311   dnstt-server
────────────────────────────────────────────────────────────
  Config: /etc/dnstm/config.json
  Listen : 0.0.0.0:53
  Tunnel : [✓] slip-socks  b.yourdomain.com:5310
  Tunnel : [✓] dnstt-socks  a.yourdomain.com:5311
  Route  : slip-socks
```

---

## 📦 What's Included

| File | Description |
|------|-------------|
| `setup.sh` | Interactive setup & management script |
| `bin/dnstm` | DNS tunnel router — listens on UDP :53 |
| `bin/dnstt-server` | DNSTT tunnel backend (DNS TXT record encoding) |
| `bin/slipstream-server` | Slipstream tunnel backend (fake-TLS over DNS) |
| `bin/microsocks` | Lightweight authenticated SOCKS5 proxy |

> All binaries are prebuilt for **Linux x86_64**. The script auto-builds `microsocks` from source if your system is incompatible.

---

## 🔧 How It Works

```
Client (censored network — Iran, etc.)
    │
    │  DNS queries → port 53
    ▼
[dnstm — DNS Router  :53]
    ├── Slipstream queries → slipstream-server :5310 → microsocks :58076
    └── DNSTT queries     → dnstt-server :5311      → microsocks :58076
                                                              │
                                                    SOCKS5 proxy
                                               (your apps connect here)
```

- **Slipstream** wraps traffic in fake-TLS handshakes inside DNS — hard to fingerprint
- **DNSTT** encodes traffic as DNS TXT record responses — works through recursive resolvers
- **microsocks** is the authenticated SOCKS5 endpoint that clients ultimately connect to
- **dnstm** is the DNS router that dispatches incoming DNS queries to the right tunnel backend

---

## 🚀 Quick Start

### 1. One-line install

```bash
wget -O setup.sh https://github.com/BarzinJarvis/dns-tunnel-kit/releases/latest/download/setup.sh
chmod +x setup.sh
sudo ./setup.sh
```

Or clone the full repo (includes prebuilt binaries):

```bash
git clone https://github.com/BarzinJarvis/dns-tunnel-kit
cd dns-tunnel-kit
sudo ./setup.sh
```

### 2. DNS delegation (required)

Add **NS records** in your DNS provider pointing two subdomains at your server IP:

| Type | Name | Value |
|------|------|-------|
| `NS` | `a` | `your.server.ip` |
| `NS` | `b` | `your.server.ip` |

So queries for `a.yourdomain.com` and `b.yourdomain.com` reach your server directly.

### 3. Run setup

The script asks for:
- Slipstream domain + port (e.g. `b.yourdomain.com`, port `5310`)
- DNSTT domain + port (e.g. `a.yourdomain.com`, port `5311`)
- SOCKS5 username + password
- SSH tunnel username + password

Then it **automatically**:
- Creates `dnstm` system user + SSH tunnel user
- Downloads & installs all 4 binaries (builds `microsocks` from source if needed)
- Generates a self-signed TLS cert for Slipstream
- Generates a DNSTT keypair (shows public key for your DNS TXT record)
- Writes `/etc/dnstm/config.json`
- Creates + enables + starts all 4 systemd services
- Configures `sshd` with a restricted `Match User` block for the tunnel user
- Saves all credentials to `/etc/dnstm/credentials.txt`

---

## ⚙️ Script Menu

```
1) 🛠  Setup       — full installation & interactive configuration
2) ✏️  Edit Config  — open config.json in $EDITOR, validate JSON, reload services
3) 📊 Status       — service states, listening ports, config summary
4) ⚙️  Manage       — start / stop / restart + show credentials + change passwords
```

---

## 📱 Client Setup (connecting from censored network)

### Slipstream (recommended — harder to detect)

Use **SlipNet** Android app:
- Domain: `b.yourdomain.com`
- Mode: `SLIPSTREAM_SSH`
- SSH host: `127.0.0.1:22`
- SSH user/pass: the tunnel user credentials from setup
- SOCKS5 output on: `0.0.0.0:1080`

### DNSTT

Use the [dnstt client](https://www.bamsoftware.com/software/dnstt/):

```bash
dnstt-client -udp your.dns.resolver:53 \
  -pubkey <PUBLIC_KEY_FROM_SETUP> \
  a.yourdomain.com \
  127.0.0.1:1080
```

The public key is shown during setup and in **Manage → Show credentials**.

---

## 🔒 Security

- **microsocks** requires username + password — unauthenticated connections are rejected
- **SSH tunnel user** has no shell, no TTY — only TCP forwarding is allowed
- **All services** run as unprivileged `dnstm` system user
- **Slipstream** uses a self-signed TLS cert generated during setup
- **Credentials** stored in `/etc/dnstm/credentials.txt` (chmod 600)

---

## 🗂 Service Architecture

```
systemd services
  microsocks.service        — SOCKS5 proxy (127.0.0.1:58076, auth required)
  dnstm.service             — DNS router (0.0.0.0:53 → tunnel backends)
  dnstm-slip-socks.service  — Slipstream server (127.0.0.1:5310 → microsocks)
  dnstm-dnstt-socks.service — DNSTT server (127.0.0.1:5311 → microsocks)
```

---

## 📋 Binary Versions

| Binary | Version | Source |
|--------|---------|--------|
| `dnstt-server` | latest | [bamsoftware.com/software/dnstt](https://www.bamsoftware.com/software/dnstt/) |
| `microsocks` | latest | [github.com/rofl0r/microsocks](https://github.com/rofl0r/microsocks) |
| `slipstream-server` | — | bundled |
| `dnstm` | v0.6.7 | bundled |

---

## 📜 License

Scripts: MIT — free to use, modify, and distribute.  
Bundled binaries retain their original licenses.

---

> **Credits:** [github.com/mrvcoder](https://github.com/mrvcoder)
