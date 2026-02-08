#!/usr/bin/env bash
set -euo pipefail

# =============================================================
#  Matrix Private Server — Automated Setup
#  Generates .env (secrets + IP), certs, signing key, then
#  renders all *.template files into final configs.
#  Run once before first `docker compose up -d`.
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---- Check dependencies ----
for cmd in openssl docker; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is not installed. Please install it first."
        exit 1
    fi
done

if ! docker compose version &>/dev/null 2>&1; then
    err "docker compose (v2) is required. Please update Docker."
    exit 1
fi

# ---- Load or create .env ----
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        info "Created .env from .env.example"
    else
        err ".env.example not found"
        exit 1
    fi
fi

source .env

# ---- Auto-detect server IP if not set ----
if [ -z "${SERVER_IP:-}" ]; then
    SERVER_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
             || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
             || hostname -I 2>/dev/null | awk '{print $1}' \
             || echo "127.0.0.1")
    info "Auto-detected SERVER_IP=$SERVER_IP"
    sed -i "s|^SERVER_IP=.*|SERVER_IP=$SERVER_IP|" .env
fi

# ---- Generate secrets if not set ----
gen_secret() { openssl rand -hex 32; }

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    POSTGRES_PASSWORD=$(gen_secret)
    sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    ok "Generated POSTGRES_PASSWORD"
fi

if [ -z "${SYNAPSE_REGISTRATION_SHARED_SECRET:-}" ]; then
    SYNAPSE_REGISTRATION_SHARED_SECRET=$(gen_secret)
    sed -i "s|^SYNAPSE_REGISTRATION_SHARED_SECRET=.*|SYNAPSE_REGISTRATION_SHARED_SECRET=$SYNAPSE_REGISTRATION_SHARED_SECRET|" .env
    ok "Generated SYNAPSE_REGISTRATION_SHARED_SECRET"
fi

if [ -z "${TURN_SHARED_SECRET:-}" ]; then
    TURN_SHARED_SECRET=$(gen_secret)
    sed -i "s|^TURN_SHARED_SECRET=.*|TURN_SHARED_SECRET=$TURN_SHARED_SECRET|" .env
    ok "Generated TURN_SHARED_SECRET"
fi

# ---- Generate one-time secrets not stored in .env ----
SYNAPSE_MACAROON_SECRET="${SYNAPSE_MACAROON_SECRET:-$(gen_secret)}"
SYNAPSE_FORM_SECRET="${SYNAPSE_FORM_SECRET:-$(gen_secret)}"

# ---- Defaults ----
TURN_MIN_PORT="${TURN_MIN_PORT:-49152}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49999}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"
POSTGRES_USER="${POSTGRES_USER:-synapse}"
POSTGRES_DB="${POSTGRES_DB:-synapse}"

# =============================================================
#  Generate self-signed CA + server certificate
# =============================================================
CERT_DIR="$SCRIPT_DIR/certs"
mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    warn "Certificates already exist in $CERT_DIR — skipping generation."
    warn "Delete certs/ directory and re-run setup.sh to regenerate."
else
    info "Generating self-signed CA and server certificate..."

    # CA key + cert
    openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
    openssl req -new -x509 \
        -key "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.crt" \
        -days "$CERT_VALIDITY_DAYS" \
        -subj "/CN=MatrixPrivateCA" \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

    # Server key + cert (signed by CA)
    openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null
    openssl req -new \
        -key "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.csr" \
        -subj "/CN=$SERVER_IP" 2>/dev/null

    # SAN extension for IP-based cert
    cat > "$CERT_DIR/san.cnf" <<SANEOF
[v3_ext]
subjectAltName = IP:$SERVER_IP
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
SANEOF

    openssl x509 -req \
        -in "$CERT_DIR/server.csr" \
        -CA "$CERT_DIR/ca.crt" \
        -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERT_DIR/server.crt" \
        -days "$CERT_VALIDITY_DAYS" \
        -extfile "$CERT_DIR/san.cnf" \
        -extensions v3_ext 2>/dev/null

    rm -f "$CERT_DIR/server.csr" "$CERT_DIR/san.cnf" "$CERT_DIR/ca.srl"

    chmod 600 "$CERT_DIR/ca.key" "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt"

    ok "CA certificate:     $CERT_DIR/ca.crt"
    ok "Server certificate: $CERT_DIR/server.crt"
    ok "Server key:         $CERT_DIR/server.key"

    echo ""
    warn "БЕЗОПАСНОСТЬ: ca.key — приватный ключ вашего CA."
    warn "Рекомендуется скопировать его на флешку и удалить с сервера."
    warn "Он понадобится только для перегенерации серверного сертификата."
    warn "  cp $CERT_DIR/ca.key /путь/к/флешке/ && rm $CERT_DIR/ca.key"
    echo ""
fi

# =============================================================
#  Generate Synapse signing key (one-time)
# =============================================================
SIGNING_KEY_PATH="$SCRIPT_DIR/synapse/signing.key"
if [ ! -f "$SIGNING_KEY_PATH" ]; then
    SIGNING_KEY_ID="a_$(openssl rand -hex 4)"
    SIGNING_KEY_MATERIAL=$(openssl rand -base64 32)
    echo "ed25519 $SIGNING_KEY_ID $SIGNING_KEY_MATERIAL" > "$SIGNING_KEY_PATH"
    chmod 600 "$SIGNING_KEY_PATH"
    ok "Generated Synapse signing key"
fi

# =============================================================
#  Render templates — replace %%VAR%% placeholders with values
# =============================================================
render_template() {
    local src="$1"
    local dst="$2"

    cp "$src" "$dst"

    # Replace all %%VAR%% placeholders with actual values
    sed -i "s|%%SERVER_IP%%|$SERVER_IP|g"                                             "$dst"
    sed -i "s|%%POSTGRES_USER%%|$POSTGRES_USER|g"                                     "$dst"
    sed -i "s|%%POSTGRES_PASSWORD%%|$POSTGRES_PASSWORD|g"                             "$dst"
    sed -i "s|%%POSTGRES_DB%%|$POSTGRES_DB|g"                                         "$dst"
    sed -i "s|%%SYNAPSE_REGISTRATION_SHARED_SECRET%%|$SYNAPSE_REGISTRATION_SHARED_SECRET|g" "$dst"
    sed -i "s|%%SYNAPSE_MACAROON_SECRET%%|$SYNAPSE_MACAROON_SECRET|g"                 "$dst"
    sed -i "s|%%SYNAPSE_FORM_SECRET%%|$SYNAPSE_FORM_SECRET|g"                         "$dst"
    sed -i "s|%%TURN_SHARED_SECRET%%|$TURN_SHARED_SECRET|g"                           "$dst"
    sed -i "s|%%TURN_MIN_PORT%%|$TURN_MIN_PORT|g"                                     "$dst"
    sed -i "s|%%TURN_MAX_PORT%%|$TURN_MAX_PORT|g"                                     "$dst"

    ok "Rendered $(basename "$dst")"
}

info "Rendering config templates..."

render_template synapse/homeserver.yaml.template  synapse/homeserver.yaml
render_template coturn/turnserver.conf.template    coturn/turnserver.conf
render_template nginx/nginx.conf.template          nginx/nginx.conf
render_template element/config.json.template       element/config.json
render_template docker-compose.yml.template        docker-compose.yml

# =============================================================
#  Summary
# =============================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
info "Next steps:"
echo "  1. Review .env and adjust if needed"
echo "  2. Start the server:"
echo "       docker compose up -d"
echo "  3. Create your admin user:"
echo "       ./scripts/create-user.sh yourusername --admin"
echo "  4. Create accounts for friends:"
echo "       ./scripts/create-user.sh friendname"
echo "  5. Element Web (browser) is at:"
echo "       https://$SERVER_IP:8443"
echo "  6. Show connection instructions:"
echo "       ./scripts/show-connection-info.sh"
echo "  7. Send friends the file:  certs/ca.crt"
echo ""

# ---- Auto-show connection info ----
echo -e "${CYAN}--- Connection info preview ---${NC}"
bash "$SCRIPT_DIR/scripts/show-connection-info.sh"
