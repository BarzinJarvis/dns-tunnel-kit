# 🌐 DNS Tunnel Kit

Bypass DNS-based internet censorship using **MasterDnsVPN** and **Slipstream** tunnels — routes all traffic through a SOCKS5 proxy hidden inside DNS queries.

> **Credits:** [github.com/mrvcoder](https://github.com/mrvcoder)

---

## 🔄 What Changed (March 2026)

| Component | Before | After |
|---|---|---|
| DNS Tunnel (`a.barzin.biz`) | dnstt / NoizDNS | **MasterDnsVPN** |
| SOCKS5 on that tunnel | separate microsocks | **built-in** (no extra process) |
| Encryption | none | **ChaCha20** |
| Slipstream (`b.barzin.biz`) | unchanged ✅ | unchanged ✅ |

---

## 🏗 Architecture

```
                            ┌─────────────────────────────────┐
                            │     Frankfurt Server            │
                            │     138.124.115.113             │
  Client (Iran)             │                                 │
  ────────────              │  dnstm (DNS Router) :53         │
  SlipNet / MasterDnsVPN    │     ├─ a.barzin.biz ──▶ MasterDnsVPN :5312  (ChaCha20 + SOCKS5)
      │                     │     └─ b.barzin.biz ──▶ Slipstream   :5310  ──▶ microsocks :58077
      │ DNS queries          │                                 │
      └────────────────────▶│ UDP :53                         │
                            └─────────────────────────────────┘
```

Two tunnels, one domain per tunnel:

| Tunnel | Domain | Protocol | SOCKS5 |
|---|---|---|---|
| **MasterDnsVPN** | `a.barzin.biz` | DNS + ChaCha20 ARQ | built-in |
| **Slipstream** | `b.barzin.biz` | DNS → SSH → SOCKS5 | microsocks `:58077` |

---

## 📦 Included Binaries (`bin/`)

| Binary | Purpose |
|---|---|
| `dnstm` | DNS traffic multiplexer — routes per-domain to each tunnel |
| `microsocks` | Lightweight SOCKS5 server — used by Slipstream backend |
| `slipstream-server` | Slipstream DNS tunnel server |

> **MasterDnsVPN** is **not** bundled — `setup.sh` downloads the latest release automatically from  
> https://github.com/masterking32/MasterDnsVPN/releases/latest

---

## 🚀 Quick Start

### Server Setup (Frankfurt VPS)

```bash
# Clone
git clone https://github.com/BarzinJarvis/dns-tunnel-kit
cd dns-tunnel-kit

# Copy binaries
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/{dnstm,microsocks,slipstream-server}

# Full install (downloads MasterDnsVPN, configures dnstm, creates systemd services)
sudo bash setup.sh install
```

### Migrate Existing Server (from NoizDNS/dnstt)

```bash
sudo bash setup.sh masterdnsvpn-migrate
```

This will:
1. Download & install MasterDnsVPN
2. Stop and disable `dnstm-dnstt-ssh` + `microsocks-noauth`
3. Update dnstm config to forward `a.barzin.biz` → MasterDnsVPN
4. Print client config (including the encryption key)

---

## 🛠 Modes

```
setup.sh install               Full install (MasterDnsVPN + Slipstream + dnstm)
setup.sh masterdnsvpn          Install/reinstall MasterDnsVPN only
setup.sh masterdnsvpn-migrate  Migrate from NoizDNS/dnstt → MasterDnsVPN
setup.sh masterdnsvpn-update   Update MasterDnsVPN binary to latest release
setup.sh status                Show all tunnel service status
setup.sh middle-proxy          Set up Iranian middle-proxy VPS (dnsmasq)
setup.sh client-config         Print MasterDnsVPN client config
```

---

## 📱 Client Setup

### MasterDnsVPN (`a.barzin.biz`)

1. Download the client from [MasterDnsVPN Releases](https://github.com/masterking32/MasterDnsVPN/releases/latest)
2. Get your `ENCRYPT_KEY` from the server:
   ```bash
   cat /opt/masterdnsvpn/encrypt_key.txt
   ```
3. Create `client_config.toml`:
   ```toml
   SOCKS5_HOST = "127.0.0.1"
   SOCKS5_PORT = 1080

   DOMAINS = ["a.barzin.biz"]
   DATA_ENCRYPTION_METHOD = 2   # ChaCha20
   ENCRYPT_KEY = "<your-key-here>"

   ARQ_WINDOW_SIZE = 256
   ARQ_INITIAL_RTO = 0.4
   ARQ_MAX_RTO     = 1.2

   PROTOCOL_TYPE = "SOCKS5"
   LOG_LEVEL     = "INFO"
   ```
4. Run: `./MasterDnsVPN_Client --scan` (find best resolvers), then `./MasterDnsVPN_Client`
5. SOCKS5 proxy at `127.0.0.1:1080`

### Slipstream (`b.barzin.biz`)

Use [SlipNet Android app](https://github.com/BarzinJarvis/SlipNet) with profile type `SLIPSTREAM_SSH`.

---

## 🔧 Services

| Service | Purpose | Status |
|---|---|---|
| `masterdnsvpn.service` | MasterDnsVPN DNS tunnel | ✅ Active |
| `dnstm-dnsrouter.service` | DNS traffic router on :53 | ✅ Active |
| `dnstm-slip-socks.service` | Slipstream tunnel | ✅ Active |
| `microsocks.service` | SOCKS5 for Slipstream | ✅ Active |
| `microsocks-slip-public.service` | Public SOCKS5 for Slipstream | ✅ Active |
| `dnstm-dnstt-ssh.service` | NoizDNS/dnstt (legacy) | ❌ Retired |
| `microsocks-noauth.service` | No-auth microsocks (legacy) | ❌ Retired |

---

## ✅ Check Status

```bash
sudo bash setup.sh status
```

---

## 🌍 Middle Proxy (Iranian VPS)

If your users need a local DNS relay inside Iran:

```bash
sudo bash setup.sh middle-proxy
```

Installs `dnsmasq` forwarding rules for `a.barzin.biz` and `b.barzin.biz` to public resolvers.

---

## 📄 License

MIT
