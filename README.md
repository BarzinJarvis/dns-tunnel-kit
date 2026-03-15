# 🌐 DNS Tunnel Kit

Bypass DNS-based internet censorship using **three independent DNS tunnel methods** — MasterDnsVPN, Slipstream, and dnstt — all managed by a single setup script.

> **Credits:** [github.com/mrvcoder](https://github.com/mrvcoder)

---

## 🏗 Architecture

```
                            ┌─────────────────────────────────────┐
  Client (Iran)             │  Frankfurt Server :53               │
  ─────────────             │                                     │
  MasterDnsVPN client  ───▶ │  dnstm DNS Router                   │
  SlipNet (Slipstream) ───▶ │    ├─ a.yourdomain.com → MasterDnsVPN :5312  (ChaCha20 + SOCKS5)
  dnstt-client         ───▶ │    ├─ b.yourdomain.com → Slipstream   :5310  → microsocks :58077
                            │    └─ c.yourdomain.com → dnstt        :5311  → microsocks :58078
                            └─────────────────────────────────────┘
```

| Tunnel | Domain | Protocol | Encryption | SOCKS5 |
|---|---|---|---|---|
| **MasterDnsVPN** | `a.yourdomain.com` | Custom DNS + ARQ | ChaCha20 | built-in |
| **Slipstream** | `b.yourdomain.com` | DNS → SSH | via SSH | microsocks (auth) |
| **dnstt** | `c.yourdomain.com` | DNS TXT encoding | none | microsocks (no-auth) |

All three run simultaneously on the same server, each on a different subdomain.

---

## 📦 Included Binaries (`bin/`)

| Binary | Purpose |
|---|---|
| `dnstm` | DNS traffic multiplexer — routes per-domain to the right tunnel |
| `slipstream-server` | Slipstream DNS tunnel server |
| `dnstt-server` | dnstt DNS tunnel server |
| `microsocks` | Lightweight SOCKS5 server (Slipstream + dnstt backends) |

> **MasterDnsVPN** is not bundled — `setup.sh` downloads the latest release automatically from  
> [github.com/masterking32/MasterDnsVPN/releases](https://github.com/masterking32/MasterDnsVPN/releases/latest)

---

## 🚀 Quick Start

### Full Server Setup

```bash
git clone https://github.com/BarzinJarvis/dns-tunnel-kit
cd dns-tunnel-kit

# Install everything: MasterDnsVPN + Slipstream + dnstt + dnstm router
sudo bash setup.sh install
```

### Individual Tunnels

```bash
sudo bash setup.sh masterdnsvpn   # MasterDnsVPN only
sudo bash setup.sh slipstream     # Slipstream only
sudo bash setup.sh dnstt          # dnstt only
sudo bash setup.sh dnstm          # dnstm DNS router only
```

### Custom Domains

Override domains via environment variables:

```bash
sudo MDNS_DOMAIN=tunnel1.example.com \
     SLIP_DOMAIN=tunnel2.example.com \
     DNSTT_DOMAIN=tunnel3.example.com \
     bash setup.sh install
```

---

## 🛠 All Modes

```
setup.sh install         Full setup (all three tunnels + dnstm router)
setup.sh masterdnsvpn    Install / update MasterDnsVPN only
setup.sh slipstream      Install Slipstream only
setup.sh dnstt           Install dnstt only
setup.sh dnstm           Install dnstm DNS router only
setup.sh client-config   Print client configs for all three tunnels
setup.sh status          Show all service status
setup.sh middle-proxy    Set up Iranian VPS DNS multiplexer (dnsmasq)
```

---

## 📱 Client Setup

### 🔵 MasterDnsVPN (`a.yourdomain.com`)

1. Download client: [MasterDnsVPN Releases](https://github.com/masterking32/MasterDnsVPN/releases/latest)
2. Get your encryption key from the server: `cat /opt/masterdnsvpn/encrypt_key.txt`
3. Create `client_config.toml`:

```toml
SOCKS5_HOST = "127.0.0.1"
SOCKS5_PORT = 1080

DOMAINS = ["a.yourdomain.com"]
DATA_ENCRYPTION_METHOD = 2   # 2 = ChaCha20
ENCRYPT_KEY = "<your-key>"

ARQ_WINDOW_SIZE = 256
ARQ_INITIAL_RTO = 0.4
ARQ_MAX_RTO     = 1.2

PROTOCOL_TYPE = "SOCKS5"
LOG_LEVEL     = "INFO"
```

4. Scan for best DNS resolvers, then start:
```bash
./MasterDnsVPN_Client --scan
./MasterDnsVPN_Client
```

5. SOCKS5 proxy at `127.0.0.1:1080`

---

### 🟢 Slipstream (`b.yourdomain.com`)

Use [SlipNet Android app](https://github.com/BarzinJarvis/SlipNet) with profile:

| Setting | Value |
|---|---|
| Type | `SLIPSTREAM_SSH` |
| Domain | `b.yourdomain.com` |
| Cert | copy `/etc/dnstm/tunnels/slip-socks/cert.pem` from server |

---

### 🟡 dnstt (`c.yourdomain.com`)

Compatible clients: `dnstt-client`, NoizDNS client, SlipNet (NoizDNS profile type).

1. Get pubkey from server: `cat /opt/dnstt/server.pub`
2. Run dnstt-client:

```bash
./dnstt-client \
  -doh https://dns.google/dns-query \
  -pubkey-file server.pub \
  c.yourdomain.com 127.0.0.1:1080
```

3. SOCKS5 proxy at `127.0.0.1:1080` (no auth required)

---

## 🔧 Services

| Service | Tunnel | Port |
|---|---|---|
| `masterdnsvpn.service` | MasterDnsVPN | UDP 5312 (internal) |
| `dnstm-slip-socks.service` | Slipstream | UDP 5310 (internal) |
| `microsocks-slip.service` | Slipstream SOCKS5 backend | TCP 58077 |
| `dnstm-dnstt.service` | dnstt | UDP 5311 (internal) |
| `microsocks-noauth.service` | dnstt SOCKS5 backend | TCP 58078 |
| `dnstm-dnsrouter.service` | DNS Router (all tunnels) | UDP 53 |

---

## ✅ Check Status

```bash
sudo bash setup.sh status
```

---

## 🌍 Middle Proxy (Iranian VPS)

For users inside Iran who need a local DNS relay:

```bash
sudo bash setup.sh middle-proxy
```

Installs `dnsmasq` rules forwarding all three tunnel domains to public DNS resolvers. Point clients' DNS to this VPS IP.

---

## 📋 DNS Delegation

Each tunnel domain needs NS records pointing to the Frankfurt server.  
Add these DNS records at your registrar / Cloudflare:

```
a.yourdomain.com  NS  ns1.a.yourdomain.com
ns1.a.yourdomain.com  A  YOUR_SERVER_IP

b.yourdomain.com  NS  ns1.b.yourdomain.com
ns1.b.yourdomain.com  A  YOUR_SERVER_IP

c.yourdomain.com  NS  ns1.c.yourdomain.com
ns1.c.yourdomain.com  A  YOUR_SERVER_IP
```

---

## 📄 License

MIT
