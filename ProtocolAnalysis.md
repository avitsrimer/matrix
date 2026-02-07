# Matrix Protocol — Traffic Analysis, Surveillance & Blocking

## How Matrix Protocol Works (Network Level)

### Overview

Matrix uses a client-server architecture over HTTPS. All communication goes through the homeserver. There is **no direct client-to-client connection** for text messages — only for voice/video media streams (WebRTC).

```
                    HTTPS (REST API)              HTTPS (Federation, optional)
  ┌────────┐      ──────────────────►  ┌──────────┐  ◄──────────────────►  ┌──────────────┐
  │ Client │                           │  Your    │                        │ Other Matrix │
  │(Element)│     ◄──────────────────  │  Server  │  ──────────────────►   │  Servers     │
  └────────┘        Sync responses     │ (Synapse)│     (only if           └──────────────┘
                                       └──────────┘      federation on)

  For voice/video:

  ┌────────┐  ── STUN/TURN ──►  ┌────────┐
  │Client A│                     │ Coturn │
  └───┬────┘                     └────────┘
      │
      │  Direct P2P (WebRTC, DTLS-SRTP)     ← if NAT traversal succeeds
      │  OR via TURN relay                  ← if P2P fails
      │
  ┌───┴────┐
  │Client B│
  └────────┘
```

---

## What Actually Goes Over The Wire

### Case 1: Client ↔ Server (Text, Files, Presence)

**Protocol**: HTTPS (TLS 1.2/1.3) over TCP port 443.

**What the regulator/ISP sees (without breaking TLS)**:

| Layer | Visible | Details |
|-------|---------|---------|
| IP | **Yes** | Source IP (client) → Destination IP (your server) |
| TCP | **Yes** | Port 443, connection timing, session duration |
| TLS handshake | **Partially** | SNI field (server hostname) in ClientHello — **visible in plaintext** in TLS 1.2. In TLS 1.3 with ECH — encrypted |
| TLS certificate | **Yes** (TLS 1.2) | Server certificate is sent in plaintext in TLS 1.2. In TLS 1.3 — encrypted after ServerHello |
| HTTP payload | **No** | All HTTP request/response bodies are encrypted |
| Message content | **No** | Additionally E2E-encrypted with Olm/Megolm — even if TLS is broken, messages are still encrypted blobs |
| Metadata inside TLS | **No** | URLs (`/_matrix/client/...`), room IDs, user IDs, message bodies — all inside TLS tunnel |

**What the regulator CAN infer without breaking TLS**:

- Your server's IP address
- That the client is connecting to this IP on port 443
- **Traffic volume** and **timing patterns** (when you send messages, roughly how much data)
- Via SNI: the domain name (if you use one)
- Via reverse DNS / IP WHOIS: which hosting provider, which country
- Via traffic fingerprinting: approximate protocol identification (see DPI section below)

**What the regulator CANNOT see**:

- Message content (double-encrypted: TLS + E2E Olm/Megolm)
- Who you're talking to (room membership is inside TLS)
- Room names, topics, file names
- Specific API endpoints being called

#### Actual HTTP traffic inside TLS (invisible to ISP):

```http
PUT /_matrix/client/v3/rooms/!abc:yourdomain/send/m.room.encrypted/txn123
Authorization: Bearer syt_xxx...
Content-Type: application/json

{
  "algorithm": "m.megolm.v1.aes-sha2",
  "ciphertext": "AwgBEoABbQ0E8...<opaque encrypted blob>...",
  "device_id": "ABCDEF",
  "sender_key": "curve25519:...",
  "session_id": "..."
}
```

Even if TLS is somehow broken (compromised CA, MITM proxy at state level), the actual message is **still encrypted** — the `ciphertext` field is an Olm/Megolm encrypted blob that only the recipient devices can decrypt with their private keys. The server itself cannot read it.

---

### Case 2: Client ↔ Client (Voice/Video Calls)

Voice and video use **WebRTC** which has its own encryption layer.

#### Scenario A: Direct P2P (STUN succeeds)

```
Client A  ◄──── DTLS-SRTP over UDP ────►  Client B
          (direct, no server in the middle)
```

**What the regulator sees**:

| Layer | Visible | Details |
|-------|---------|---------|
| IP | **Yes** | Client A's IP ↔ Client B's IP — **both endpoints are visible** |
| UDP | **Yes** | Ephemeral ports, packet sizes, timing |
| DTLS handshake | **Partially** | Fingerprints of DTLS certificates (but these are ephemeral, self-signed) |
| SRTP payload | **No** | Audio/video encrypted with SRTP keys negotiated via DTLS |
| Codec info | **Potentially** | Packet size patterns can hint at codec (Opus audio, VP8/VP9 video) |

**Key risk**: In P2P mode, **both clients' real IPs are exposed to each other AND to any network observer**. The regulator can see that Client A at IP `1.2.3.4` is having a direct media session with Client B at IP `5.6.7.8`.

#### Scenario B: Via TURN Relay (P2P fails)

```
Client A  ──► TURN server (your Coturn) ◄──  Client B
```

**What the regulator sees**:

| Layer | Visible | Details |
|-------|---------|---------|
| IP | **Partially** | Client A → TURN server IP, Client B → TURN server IP. Clients don't see each other's IPs |
| UDP | **Yes** | Ports, packet sizes, bidirectional media flow timing |
| Content | **No** | SRTP-encrypted media, TURN server is just a dumb relay |

**Advantage of TURN**: The regulator sees both clients talking to your server, but cannot trivially prove they are talking **to each other** without traffic correlation analysis (matching packet timing/sizes between the two streams).

#### Signaling for Calls

Call setup (offer/answer SDP, ICE candidates) goes through the Matrix homeserver via the normal HTTPS channel — so it's covered by Case 1. The regulator doesn't see the call signaling.

---

### Case 3: Federation (Server ↔ Server) — If Enabled

```
Your Server  ◄──── HTTPS (port 8448) ────►  matrix.org / other servers
```

**What the regulator sees**: HTTPS connection from your server to known Matrix federation servers. This **confirms** your server is a Matrix homeserver.

**Recommendation**: **Disable federation** for a private friend group. It eliminates this attack surface entirely and prevents the regulator from identifying your server by its federation traffic.

---

## DPI (Deep Packet Inspection) Analysis

### Can DPI Identify Matrix Traffic?

**Short answer**: With moderate effort, yes. Here's how:

#### 1. SNI-Based Detection (Trivial)

If you use a domain name, the TLS ClientHello contains the SNI field in plaintext:

```
ClientHello:
  Server Name: matrix.yourdomain.com    ← visible to DPI
```

The regulator can:
- Block all connections with SNI matching `*matrix*` (crude but effective for default setups)
- Build a list of known Matrix homeserver domains and block them

**Mitigation**: Use ECH (Encrypted Client Hello) — supported in TLS 1.3 with compatible clients and CDN. Or use an IP address directly (no SNI sent).

#### 2. Traffic Pattern Fingerprinting (Moderate Difficulty)

Matrix client-server API has distinctive patterns:

| Pattern | What DPI Sees |
|---------|--------------|
| Long-lived connection | `/sync` endpoint uses long-polling (30s+ timeout), creating persistent HTTPS connections with periodic bursts |
| Consistent packet sizes | Sync responses have characteristic size distributions |
| Bidirectional asymmetry | Small requests (sending message) → large responses (sync with history) |
| Periodic keep-alives | Regular interval requests even when idle |

**Compared to normal HTTPS browsing**: Web browsing has bursty, asymmetric (large download) patterns with many different destination IPs. Matrix traffic goes to **one IP** persistently, with a distinctive long-polling pattern.

#### 3. TURN/STUN Detection (Easy)

STUN/TURN have well-known byte patterns in their first packets:

```
STUN Binding Request:
  Byte 0-1: 0x0001 (Binding Request)
  Byte 4-7: 0x2112A442 (Magic Cookie)    ← STUN signature, trivially detectable
```

DPI can easily detect STUN/TURN traffic regardless of the port.

**Mitigation**: TURNS (TURN over TLS on port 443) — wraps everything in TLS, making it look like normal HTTPS traffic.

#### 4. TLS Certificate Fingerprinting (If Self-Signed)

Self-signed certificates have distinctive properties:
- Issuer = Subject (self-referential)
- No OCSP/CRL information
- Often unusual validity periods

In TLS 1.2, the certificate is sent in plaintext — DPI can see it's self-signed and flag it.

In TLS 1.3, the certificate is encrypted, so this attack doesn't work.

### DPI Blocking Difficulty Rating

| Method | Difficulty to Detect | Difficulty to Block | Collateral Damage |
|--------|---------------------|--------------------|--------------------|
| SNI blocking | Trivial | Trivial | Low (targeted) |
| IP blacklisting | Trivial (if IP known) | Trivial | Low |
| STUN/TURN magic cookie | Easy | Easy | Medium (breaks all WebRTC) |
| Traffic pattern analysis | Moderate | Moderate | High (false positives) |
| Block self-signed certs | Easy (TLS 1.2) | Easy | Very High (breaks many services) |
| Deep traffic fingerprinting | Hard | Hard | Very High |

---

## What the Regulator Can Prove

### With Passive Observation Only (Just Watching Traffic)

| Fact | Can They Prove It? | How |
|------|-------------------|-----|
| Client connects to your server | **Yes** | IP logs |
| Your server is a Matrix homeserver | **Likely** | Traffic patterns, federation probes, port scanning (Matrix has `/.well-known` endpoint on port 443) |
| Specific messages sent | **No** | E2E encrypted (Olm/Megolm) |
| Who talks to whom in which rooms | **No** | Inside TLS |
| Voice/video call happening | **Yes** | WebRTC traffic patterns are distinctive |
| Who is calling whom (P2P) | **Yes** | Both IPs visible in P2P mode |
| Who is calling whom (TURN) | **Probably** | Traffic correlation between two clients connecting to TURN server simultaneously |
| Call content | **No** | SRTP encrypted |

### With Server Seizure (Physical Access to Server)

| Fact | Can They Get It? | How |
|------|-----------------|-----|
| User accounts, display names | **Yes** | In Postgres database |
| Room membership (who is in which room) | **Yes** | In Postgres database |
| Message content | **No** | Messages stored as E2E-encrypted blobs; server never has the keys |
| File uploads (unencrypted rooms) | **Yes** | In media store |
| File uploads (E2E rooms) | **No** | Stored encrypted |
| Call history (metadata) | **Partially** | Call events stored, but content was never on server |
| IP logs | **Yes** (if logging enabled) | Synapse logs by default; **disable access logs** and set IP to `0.0.0.0` in config |

### Hardening Recommendations Against Surveillance

1. **Disable federation** — your server doesn't announce itself to the Matrix network
2. **Disable Synapse access logging** or set `request_log` to minimal
3. **Force all calls through TURN** (disable P2P ICE candidates in clients to hide client IPs from each other and observers)
4. **Use TURNS (TURN over TLS)** on port 443 — STUN/TURN becomes indistinguishable from HTTPS
5. **TLS 1.3 only** — certificates and more of the handshake are encrypted
6. **Don't use an obvious domain** like `matrix.mydomain.com` — use something generic
7. **Consider Cloudflare/CDN fronting** — your server IP is hidden behind CDN; traffic looks like CDN traffic
8. **Deploy on a VPS in a friendly jurisdiction** — makes seizure harder
9. **Full disk encryption** on the server — protects data at rest if hardware is seized

---

## Domain, Self-Signed Certs & E2E — Practical Answers

### Do I Need a Domain?

**No, not strictly.** You can run Matrix on a bare IP address. Here's the comparison:

| Approach | Pros | Cons |
|----------|------|------|
| **Domain + Let's Encrypt** | Auto TLS, easy for clients, looks like normal HTTPS traffic | Domain registration = identity paper trail; SNI reveals domain name |
| **Domain + Cloudflare proxy** | Hides server IP, CDN absorbs DPI, looks like Cloudflare traffic | Cloudflare can see TLS-layer traffic (but NOT E2E content); domain registration paper trail |
| **IP only + self-signed cert** | No domain registration, no SNI leak, no paper trail | Clients must manually trust cert; TLS 1.2 DPI can spot self-signed; no auto-renewal |
| **IP + self-signed + Tor** | Maximum anonymity | Slow, complex setup, Tor exit nodes may be blocked |

### Can I Use a Self-Signed Certificate?

**Yes, with caveats.**

**What works**:
- Synapse runs fine with self-signed certs
- You generate a cert, configure it in your reverse proxy (or Synapse directly)
- You send the cert fingerprint (or the CA cert file) to your friends
- They configure Element to trust it

**How to configure Element with self-signed cert**:
- **Element Desktop (recommended)**: Can be configured to accept self-signed certs via custom `config.json` or by importing your CA into the system trust store
- **Element Android**: Accepts custom CAs added to the Android trust store (Settings → Security → Install certificate)
- **Element iOS**: Install CA profile via Safari, then trust it in Settings → General → About → Certificate Trust Settings
- **Element Web (browser)**: The user navigates to `https://<your-ip>:8448`, accepts the browser warning, then connects normally

**The important point**: Self-signed certs affect only the **transport layer (TLS)**. E2E encryption is a completely separate layer.

### Does Self-Signed Cert Break E2E Encryption?

**Absolutely not.** E2E encryption in Matrix is **independent of TLS**.

```
┌─────────────────────────────────────────────────┐
│                   Message                        │
│                                                  │
│   ┌──────────────────────────────────────┐       │
│   │  Layer 2: Olm/Megolm E2E Encryption │       │  ← Keys are on devices only.
│   │  (device-to-device, server can't     │       │     Server NEVER has these keys.
│   │   read this even with full access)   │       │     Self-signed cert changes NOTHING here.
│   └──────────────────────────────────────┘       │
│                                                  │
│   ┌──────────────────────────────────────┐       │
│   │  Layer 1: TLS Transport Encryption   │       │  ← Self-signed cert works here.
│   │  (protects data in transit between   │       │     As long as your friends verify the
│   │   client and server)                 │       │     cert fingerprint, MITM is prevented.
│   └──────────────────────────────────────┘       │
│                                                  │
└─────────────────────────────────────────────────┘
```

**How E2E works regardless of TLS**:
1. Each device generates a Curve25519 key pair locally
2. Public keys are uploaded to the server (but private keys never leave the device)
3. When sending a message, the client encrypts with Megolm session keys shared via Olm (double ratchet)
4. The server stores only ciphertext — even with a compromised server, messages are unreadable
5. **Device verification** (cross-signing, QR codes, emoji comparison) ensures you're talking to the right person, not a MITM — this is independent of TLS entirely

**Conclusion**: Self-signed cert + E2E = **fully secure**. Your friends verify your TLS cert fingerprint once (transport security), and verify each other's devices via Element's built-in verification (E2E security). Two independent layers, both intact.

### Recommended Setup for Maximum Privacy

```
Server: VPS with bare IP, no domain registration
TLS: Self-signed CA → server cert (you are your own CA)
Distribution: Send friends the CA cert file + server IP over a trusted channel (in person, Signal, etc.)
Federation: Disabled
TURN: TURNS on port 443 (looks like HTTPS)
Logging: Minimal (disable IP logging in Synapse)
Clients: Element Desktop or Mobile (import your CA)
Verification: E2E device verification between all participants in person
```

This setup leaves the regulator with:
- An IP address of a VPS running something on port 443
- TLS traffic that looks like generic HTTPS
- No domain name to trace
- No federation traffic to identify Matrix
- No message content (E2E)
- No call content (SRTP)
- Only traffic volume and timing patterns as potential fingerprinting vectors
