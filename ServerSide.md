# Server-Side Plan — Matrix Chat (Dockerized)

## Goal

A single `docker compose up` that spins up everything needed to run a private Matrix chat server — deployable on any Linux VPS, home server, or cloud instance. You and your friends connect using Element (or any Matrix client) and get E2E-encrypted text, voice, and video.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   Host Machine                      │
│                                                     │
│  ┌─────────────┐  ┌──────────┐  ┌───────────────┐  │
│  │   Synapse    │  │ Postgres │  │  Coturn       │  │
│  │  (homeserver)│  │  (DB)    │  │  (TURN/STUN)  │  │
│  │  :8008       │  │  :5432   │  │  :3478/:5349  │  │
│  └──────┬───────┘  └────┬─────┘  └───────────────┘  │
│         │               │                            │
│  ┌──────┴───────────────┴──────────────────────┐     │
│  │          Internal Docker Network            │     │
│  └─────────────────────┬───────────────────────┘     │
│                        │                             │
│  ┌─────────────────────┴───────────────────────┐     │
│  │         Caddy (reverse proxy + TLS)         │     │
│  │         :80 / :443                          │     │
│  └─────────────────────────────────────────────┘     │
│                                                     │
└─────────────────────────────────────────────────────┘
          ▲                           ▲
          │ HTTPS (Matrix API)        │ UDP/TCP (TURN media)
          │                           │
     Element clients              Voice/Video
     (friends' devices)           relay traffic
```

### Components

| Container | Image | Role |
|-----------|-------|------|
| **synapse** | `matrixdotorg/synapse:latest` | Matrix homeserver — handles accounts, rooms, messages, federation |
| **postgres** | `postgres:16-alpine` | Persistent database for Synapse |
| **coturn** | `coturn/coturn:latest` | TURN/STUN server — relays voice/video when P2P fails (NAT, firewalls) |
| **caddy** | `caddy:2-alpine` | Reverse proxy with automatic HTTPS via Let's Encrypt |

---

## Prerequisites (Host)

| Requirement | Details |
|-------------|---------|
| **VPS / Server** | Any Linux box with 1+ GB RAM, 1 vCPU, 10 GB disk (small group) |
| **Docker & Docker Compose** | v2+ (comes with modern Docker installs) |
| **Domain name** | e.g. `matrix.yourdomain.com` — A record pointed at server IP |
| **Open ports** | `80`, `443` (HTTP/S), `3478` (STUN), `5349` (TURN TLS), `49152-65535/udp` (TURN media relay) |

---

## File Structure

```
matrix/
├── docker-compose.yml          # Orchestrates all containers
├── caddy/
│   └── Caddyfile               # Reverse proxy config
├── synapse/
│   └── homeserver.yaml         # Synapse configuration (generated, then customized)
├── coturn/
│   └── turnserver.conf         # TURN server configuration
├── .env                        # Environment variables (secrets, domain, etc.)
├── Requirements.md             # (existing)
└── ServerSide.md               # (this document)
```

---

## Container Details

### 1. Synapse (Homeserver)

**What it does**: The core of the system. Manages user accounts, rooms, message history, E2E encryption key distribution, and federation with other Matrix servers (optional).

**Key configuration decisions**:
- **Database**: PostgreSQL (not SQLite) — required for any real usage beyond a single user
- **Registration**: Disabled by default; create accounts via CLI (`register_new_matrix_user`) or enable registration with a shared secret/token so only invited people can join
- **Federation**: Optional — enable if you want to talk to users on other Matrix servers (e.g., matrix.org); disable for a fully private island server
- **Media store**: Mounted as a Docker volume for uploaded files, avatars, etc.
- **Workers**: Not needed for a small friend group (<50 users). Single-process Synapse is sufficient
- **Rate limiting**: Can be relaxed for a private server with trusted users

**Volumes**:
- `synapse-data:/data` — media store, signing keys, config
- `postgres-data:/var/lib/postgresql/data` — database persistence

### 2. PostgreSQL (Database)

**What it does**: Stores all Synapse data — users, rooms, messages, device keys, etc.

**Key configuration decisions**:
- Use `postgres:16-alpine` for small footprint
- Dedicated database `synapse` with dedicated user
- Credentials stored in `.env`, never hardcoded
- Persistent volume so data survives container restarts

### 3. Coturn (TURN/STUN Server)

**What it does**: Enables voice/video calls to work reliably. Without it, calls fail when either party is behind a strict NAT or firewall.

- **STUN**: Helps clients discover their public IP (lightweight, almost always works)
- **TURN**: Relays media traffic through the server when direct P2P fails (heavier, but essential for reliability)

**Key configuration decisions**:
- Shared secret authentication between Synapse and Coturn (Synapse generates time-limited TURN credentials for clients)
- TLS on port `5349` using the same domain certificate
- UDP relay range `49152-65535` (standard ephemeral port range)
- `no-multicast-peers` and `no-tcp-relay` for security hardening
- Realm set to match the server domain

### 4. Caddy (Reverse Proxy + TLS)

**What it does**: Sits in front of Synapse, terminates TLS, and auto-provisions Let's Encrypt certificates.

**Why Caddy over Nginx**: Zero-config HTTPS. No manual certbot cron jobs, no renewal scripts. Caddy handles it all automatically.

**Key configuration decisions**:
- Proxy `https://matrix.yourdomain.com` → `synapse:8008`
- Serve `/.well-known/matrix/server` and `/.well-known/matrix/client` for federation discovery and client auto-config
- Headers for security (HSTS, X-Frame-Options, etc.)

---

## Configuration Plan

### `.env` File (secrets & settings)

```
DOMAIN=matrix.yourdomain.com
SYNAPSE_SERVER_NAME=yourdomain.com
POSTGRES_PASSWORD=<generated-strong-password>
POSTGRES_USER=synapse
POSTGRES_DB=synapse
TURN_SHARED_SECRET=<generated-strong-secret>
SYNAPSE_REGISTRATION_SHARED_SECRET=<generated-strong-secret>
```

### `docker-compose.yml` — Service Definitions

```yaml
# Planned structure (not final implementation)

services:
  synapse:
    image: matrixdotorg/synapse:latest
    depends_on: [postgres]
    volumes: [synapse-data:/data]
    environment: [from .env]
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    volumes: [postgres-data:/var/lib/postgresql/data]
    environment: [from .env]
    restart: unless-stopped

  coturn:
    image: coturn/coturn:latest
    network_mode: host          # needs direct access to UDP ports
    volumes: [./coturn/turnserver.conf:/etc/turnserver.conf]
    restart: unless-stopped

  caddy:
    image: caddy:2-alpine
    ports: ["80:80", "443:443"]
    volumes: [./caddy/Caddyfile:/etc/caddy/Caddyfile, caddy-data:/data]
    restart: unless-stopped

volumes:
  synapse-data:
  postgres-data:
  caddy-data:
```

### `homeserver.yaml` — Key Synapse Settings

| Setting | Value | Why |
|---------|-------|-----|
| `server_name` | `yourdomain.com` | Identity of the server in Matrix federation (`@user:yourdomain.com`) |
| `database.name` | `psycopg2` | Use Postgres, not SQLite |
| `enable_registration` | `false` | Create accounts manually for security |
| `turn_uris` | `["turn:matrix.yourdomain.com:3478?transport=udp", "turns:matrix.yourdomain.com:5349?transport=tcp"]` | Points clients to Coturn |
| `turn_shared_secret` | from `.env` | Auth between Synapse ↔ Coturn |
| `enable_media_repo` | `true` | File/image uploads |
| `max_upload_size` | `50M` | Reasonable for a small group |

### `turnserver.conf` — Key Coturn Settings

| Setting | Value | Why |
|---------|-------|-----|
| `realm` | `yourdomain.com` | Must match server domain |
| `use-auth-secret` | enabled | Shared secret auth with Synapse |
| `static-auth-secret` | from `.env` | Matching secret |
| `min-port` / `max-port` | `49152` / `65535` | UDP relay port range |
| `cert` / `pkey` | TLS cert paths | For TURNS (TLS-encrypted TURN) |
| `no-tcp-relay` | enabled | Security hardening |
| `denied-peer-ip` | private ranges | Prevent relay to internal network |

---

## Deployment Steps

### First-time Setup

1. **Clone repo** on the server
2. **Copy `.env.example` → `.env`** and fill in domain + generate secrets
3. **Generate Synapse config**:
   ```bash
   docker compose run --rm synapse generate
   ```
4. **Edit `homeserver.yaml`** with Postgres, TURN, and registration settings
5. **Open firewall ports**: 80, 443, 3478, 5349, 49152-65535/udp
6. **Start everything**:
   ```bash
   docker compose up -d
   ```
7. **Create user accounts**:
   ```bash
   docker compose exec synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
   ```
8. **Share the server address** with friends — they connect via Element using `yourdomain.com`

### Day-to-day Operations

| Task | Command |
|------|---------|
| Start | `docker compose up -d` |
| Stop | `docker compose down` |
| View logs | `docker compose logs -f synapse` |
| Update images | `docker compose pull && docker compose up -d` |
| Backup | Dump Postgres + copy `synapse-data` volume |
| Add user | `docker compose exec synapse register_new_matrix_user ...` |

---

## Security Checklist

- [ ] Registration disabled (invite-only via CLI)
- [ ] Strong passwords in `.env` (generated, not hand-typed)
- [ ] `.env` is in `.gitignore` — never committed
- [ ] TLS everywhere (Caddy auto-HTTPS + Coturn TLS)
- [ ] Firewall only opens required ports
- [ ] Coturn denies relay to private IP ranges
- [ ] E2E encryption enabled in all rooms (client-side setting)
- [ ] Device verification done between all participants
- [ ] Regular `docker compose pull` to get security patches
- [ ] Optional: disable federation if you don't need it (reduces attack surface)

---

## Resource Estimates (Small Group, <10 Users)

| Resource | Estimate |
|----------|----------|
| RAM | ~512 MB idle, ~1 GB under load |
| CPU | 1 vCPU sufficient |
| Disk | 10-20 GB (grows with media uploads) |
| Bandwidth | Minimal for text; voice/video relay depends on usage |
| Cost | $5-10/month on most VPS providers |

---

## Deployment Mode: Domain-less with Self-Signed Cert

For maximum privacy (no domain registration paper trail), the server can run on a bare IP with a self-signed CA. This does **not** break E2E encryption — Olm/Megolm is independent of TLS.

**Changes vs. domain-based setup**:

| Component | Domain Setup | IP + Self-Signed Setup |
|-----------|-------------|----------------------|
| **Caddy** | Auto Let's Encrypt | **Replaced with Nginx** (or Caddy with custom cert) — no ACME needed |
| **TLS cert** | Automatic | Generate your own CA + server cert; distribute CA to friends |
| **Synapse `server_name`** | `yourdomain.com` | Your server IP (e.g., `203.0.113.42`) |
| **TURN** | `turn:yourdomain.com` | `turn:203.0.113.42` with TURNS on port 443 |
| **Federation** | Optional | **Disabled** (no domain = no federation anyway) |
| **Client config** | Auto-discovery via `.well-known` | Manual: friends enter `https://<IP>:443` and import your CA cert |

**Self-signed CA generation (planned)**:
```bash
# Will be scripted in setup.sh
openssl genrsa -out ca.key 4096
openssl req -new -x509 -key ca.key -out ca.crt -days 3650 -subj "/CN=MatrixCA"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=<SERVER_IP>"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 3650
```

Friends receive `ca.crt` via a trusted channel and install it on their devices.

See [ProtocolAnalysis.md](ProtocolAnalysis.md) for detailed traffic analysis, DPI risks, and why self-signed certs don't affect E2E security.

---

## Optional Enhancements (Future)

- **Element Web**: Add a container serving Element Web UI so friends don't need to install anything — just visit `chat.yourdomain.com` in a browser
- **Bridges**: Connect to other platforms (Telegram, Signal, WhatsApp) via Matrix bridges
- **Monitoring**: Add Prometheus + Grafana for metrics
- **Backups**: Automated daily Postgres dump + offsite sync
- **Federation**: Enable to communicate with the wider Matrix network

---

## Implementation Order

1. **`docker-compose.yml`** + **`.env.example`** — get the skeleton running
2. **Synapse + Postgres** — homeserver boots and accepts connections
3. **Caddy** — HTTPS termination, server reachable from the internet
4. **Coturn** — voice/video calls work reliably
5. **Hardening** — security checklist, firewall rules, `.gitignore`
6. **Documentation** — README with setup instructions for friends
