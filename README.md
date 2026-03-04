# DNS Tunnel Kit

> Bypass DNS-based internet censorship using **DNSTT** and **Slipstream** tunnels — routes all traffic through a SOCKS5 proxy hidden inside DNS traffic.

---

## What's included

| File | Description |
|------|-------------|
| `setup.sh` | Interactive setup & management script |
| `bin/dnstm` | DNS tunnel router — listens on UDP :53, routes to tunnel backends |
| `bin/dnstt-server` | DNSTT tunnel backend (encodes traffic in DNS TXT records) |
| `bin/slipstream-server` | Slipstream tunnel backend (fake-TLS over DNS) |
| `bin/microsocks` | Lightweight authenticated SOCKS5 proxy |

All binaries are prebuilt for **Linux x86_64**.

---

## How it works

```
Client (Iran / censored network)
    │
    │  DNS queries → port 53
    ▼
[dnstm — DNS Router :53]
    ├── Slipstream queries → slipstream-server :5310 → microsocks :58076
    └── DNSTT queries     → dnstt-server :5311      → microsocks :58076
                                                              │
                                                     SOCKS5 proxy
                                                     (your apps connect here)
```

- **Slipstream** wraps traffic in fake-TLS handshakes inside DNS — hard to fingerprint
- **DNSTT** encodes traffic in DNS TXT record responses — works through recursive resolvers
- **microsocks** is the authenticated SOCKS5 endpoint that clients ultimately connect to

---

## Quick start

### Prerequisites
- Linux server with a public IP
- A domain you control (to add NS records)
- Port 53 (UDP) open on your server

### 1. DNS delegation

Add **NS records** in your DNS provider pointing two subdomains at your server IP:

| Type | Name | Value |
|------|------|-------|
| `NS` | `a` (for DNSTT) | `your.server.ip` |
| `NS` | `b` (for Slipstream) | `your.server.ip` |

So queries for `a.yourdomain.com` and `b.yourdomain.com` reach your server directly.

### 2. Run the setup script

```bash
git clone https://github.com/BarzinJarvis/dns-tunnel-kit
cd dns-tunnel-kit
chmod +x setup.sh
sudo ./setup.sh
```

The script will ask for:
- Your server IP
- Slipstream domain (e.g. `b.yourdomain.com`)
- DNSTT domain (e.g. `a.yourdomain.com`)
- SOCKS5 username & password
- SSH tunnel user & password

It then installs everything and starts all services as systemd units.

---

## Script menu

```
1. 🔧 Setup   — full installation & configuration
2. ✏️  Edit    — update domains, ports, credentials, regenerate certs/keys
3. 📊 Status  — service status, open ports, logs, keys
4. ⚙️  Manage  → start / stop / restart (all or individual) + show credentials
```

---

## Client setup (connecting from censored network)

### Slipstream (recommended — harder to detect)

Use **SlipNet** Android app or any Slipstream-compatible client:
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

The public key is shown during setup and in `Manage → Show credentials`.

---

## Security

- microsocks requires **username + password** — unauthenticated connections are rejected
- SSH tunnel user has **no shell, no TTY** — only TCP forwarding allowed
- All services run as unprivileged users with systemd sandboxing
- Slipstream uses a self-signed TLS certificate (generated during setup)

---

## Architecture

```
systemd services:
  microsocks.service        — SOCKS5 proxy (127.0.0.1:58076, auth required)
  dnstm-slip-socks.service  — Slipstream server (127.0.0.1:5310 → microsocks)
  dnstm-dnstt-ssh.service   — DNSTT server (127.0.0.1:5311 → microsocks)
  dnstm-dnsrouter.service   — DNS router (0.0.0.0:53 → slip/dnstt backends)
```

---

## Binary versions

| Binary | Version | Source |
|--------|---------|--------|
| `dnstt-server` | latest | [bamsoftware.com/software/dnstt](https://www.bamsoftware.com/software/dnstt/) |
| `microsocks` | latest | [github.com/rofl0r/microsocks](https://github.com/rofl0r/microsocks) |
| `slipstream-server` | — | bundled |
| `dnstm` | v0.6.7 | bundled |

---

## License

Scripts: MIT  
Bundled binaries retain their original licenses.
