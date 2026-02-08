#!/usr/bin/env bash
set -euo pipefail

# =============================================================
#  Matrix Private Server — Automated Setup
#  Generates certs, secrets, configs. Run once before first start.
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
    # Try to get public IP, fall back to local IP
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

TURN_MIN_PORT="${TURN_MIN_PORT:-49152}"
TURN_MAX_PORT="${TURN_MAX_PORT:-49999}"
CERT_VALIDITY_DAYS="${CERT_VALIDITY_DAYS:-3650}"
POSTGRES_USER="${POSTGRES_USER:-synapse}"
POSTGRES_DB="${POSTGRES_DB:-synapse}"

# ---- Generate self-signed CA + server certificate ----
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

    # Cleanup temp files
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

# ---- Generate Synapse homeserver.yaml ----
SYNAPSE_DIR="$SCRIPT_DIR/synapse"
mkdir -p "$SYNAPSE_DIR"

SYNAPSE_SIGNING_KEY_PATH="$SYNAPSE_DIR/signing.key"
if [ ! -f "$SYNAPSE_SIGNING_KEY_PATH" ]; then
    # Generate a signing key (ed25519)
    # Synapse expects format: ed25519 a_xxxx <base64key>
    SIGNING_KEY_ID="a_$(openssl rand -hex 4)"
    SIGNING_KEY_MATERIAL=$(openssl rand -base64 32)
    echo "ed25519 $SIGNING_KEY_ID $SIGNING_KEY_MATERIAL" > "$SYNAPSE_SIGNING_KEY_PATH"
    chmod 600 "$SYNAPSE_SIGNING_KEY_PATH"
    ok "Generated Synapse signing key"
fi

SYNAPSE_MACAROON_SECRET=$(openssl rand -hex 32)

cat > "$SYNAPSE_DIR/homeserver.yaml" <<HSEOF
# =============================================================
#  Synapse homeserver — private, no federation, maximum security
#  Auto-generated by setup.sh — $(date -Iseconds)
# =============================================================

server_name: "$SERVER_IP"
pid_file: /data/homeserver.pid
public_baseurl: "https://$SERVER_IP/"

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['0.0.0.0']
    resources:
      - names: [client, keys]
        compress: false

# --- Database (PostgreSQL) ---
database:
  name: psycopg2
  args:
    user: "$POSTGRES_USER"
    password: "$POSTGRES_PASSWORD"
    database: "$POSTGRES_DB"
    host: postgres
    port: 5432
    cp_min: 2
    cp_max: 5

# --- Logging (minimal — no IPs) ---
log_config: "/data/log.config"

# --- Security ---
registration_shared_secret: "$SYNAPSE_REGISTRATION_SHARED_SECRET"
enable_registration: false
enable_registration_without_verification: false
macaroon_secret_key: "$SYNAPSE_MACAROON_SECRET"
form_secret: "$(openssl rand -hex 32)"
signing_key_path: "/data/signing.key"
suppress_key_server_warning: true

# --- Federation OFF ---
federation_domain_whitelist: []
allow_public_rooms_over_federation: false
allow_public_rooms_without_auth: false
limit_remote_rooms:
  enabled: true
  complexity: 0

# --- TURN (voice/video) ---
turn_uris:
  - "turns:$SERVER_IP:5349?transport=tcp"
  - "turn:$SERVER_IP:3478?transport=udp"
turn_shared_secret: "$TURN_SHARED_SECRET"
turn_user_lifetime: 1h
turn_allow_guests: false

# --- Media ---
enable_media_repo: true
max_upload_size: "50M"
media_store_path: "/data/media_store"
url_preview_enabled: false

# --- Rate limiting (relaxed for private server) ---
rc_message:
  per_second: 10
  burst_count: 50
rc_login:
  address:
    per_second: 1
    burst_count: 5
  account:
    per_second: 1
    burst_count: 5

# --- Misc ---
report_stats: false
enable_metrics: false
trusted_key_servers: []
serve_server_wellknown: true
HSEOF

ok "Generated synapse/homeserver.yaml"

# ---- Generate Synapse log config (minimal) ----
cat > "$SYNAPSE_DIR/log.config" <<LOGEOF
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'
handlers:
  console:
    class: logging.StreamHandler
    formatter: precise
    stream: ext://sys.stdout
root:
  level: WARN
  handlers: [console]
loggers:
  synapse.storage.SQL:
    level: WARN
LOGEOF

ok "Generated synapse/log.config"

# ---- Generate Coturn config ----
COTURN_DIR="$SCRIPT_DIR/coturn"
mkdir -p "$COTURN_DIR"

cat > "$COTURN_DIR/turnserver.conf" <<TURNEOF
# =============================================================
#  Coturn — TURN/STUN server for Matrix voice/video
#  Auto-generated by setup.sh — $(date -Iseconds)
# =============================================================

# --- Network ---
listening-port=3478
tls-listening-port=5349
min-port=$TURN_MIN_PORT
max-port=$TURN_MAX_PORT
realm=$SERVER_IP
external-ip=$SERVER_IP

# --- TLS ---
cert=/certs/server.crt
pkey=/certs/server.key

# --- Authentication (shared secret with Synapse) ---
use-auth-secret
static-auth-secret=$TURN_SHARED_SECRET

# --- Security hardening ---
no-multicast-peers
no-tcp-relay
no-tlsv1
no-tlsv1_1
no-cli

# Deny relay to private networks
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=127.0.0.0-127.255.255.255

# --- Logging ---
no-stdout-log
syslog
TURNEOF

ok "Generated coturn/turnserver.conf"

# ---- Generate Nginx config ----
NGINX_DIR="$SCRIPT_DIR/nginx"
mkdir -p "$NGINX_DIR"

cat > "$NGINX_DIR/nginx.conf" <<NGXEOF
# =============================================================
#  Nginx — TLS reverse proxy for Synapse
#  Auto-generated by setup.sh — $(date -Iseconds)
# =============================================================

worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    # --- Basic settings ---
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    client_max_body_size 50m;
    server_tokens off;

    # --- Logging (no client IPs) ---
    log_format  noip  '[\$time_local] "\$request" \$status \$body_bytes_sent';
    access_log  /var/log/nginx/access.log  noip;

    # --- TLS proxy for Synapse ---
    server {
        listen 443 ssl http2;

        ssl_certificate     /certs/server.crt;
        ssl_certificate_key /certs/server.key;

        ssl_protocols TLSv1.3;
        ssl_prefer_server_ciphers off;

        # --- Security headers ---
        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options DENY always;

        # --- .well-known for Matrix client auto-discovery ---
        location /.well-known/matrix/client {
            default_type application/json;
            add_header Access-Control-Allow-Origin *;
            return 200 '{"m.homeserver":{"base_url":"https://$SERVER_IP"}}';
        }

        location /.well-known/matrix/server {
            default_type application/json;
            return 200 '{"m.server":"$SERVER_IP:443"}';
        }

        # --- Proxy to Synapse ---
        location ~ ^(/_matrix|/_synapse/client) {
            proxy_pass http://synapse:8008;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Host \$host;

            # For long-polling /sync
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
        }

        # Default: deny (on Matrix API port)
        location / {
            return 404;
        }
    }

    # --- Element Web (browser client) on port 8443 ---
    server {
        listen 8443 ssl http2;

        ssl_certificate     /certs/server.crt;
        ssl_certificate_key /certs/server.key;

        ssl_protocols TLSv1.3;
        ssl_prefer_server_ciphers off;

        add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Content-Security-Policy "frame-ancestors 'self'" always;

        location / {
            proxy_pass http://element:80;
            proxy_set_header Host \$host;
        }
    }

    # --- Redirect HTTP to HTTPS ---
    server {
        listen 80;
        return 301 https://\$host\$request_uri;
    }
}
NGXEOF

ok "Generated nginx/nginx.conf"

# ---- Generate Element Web config ----
ELEMENT_DIR="$SCRIPT_DIR/element"
mkdir -p "$ELEMENT_DIR"

cat > "$ELEMENT_DIR/config.json" <<ELEMEOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$SERVER_IP",
            "server_name": "$SERVER_IP"
        }
    },
    "disable_custom_urls": true,
    "disable_guests": true,
    "disable_3pid_login": true,
    "brand": "Element",
    "default_country_code": "RU",
    "show_labs_settings": false,
    "default_theme": "dark",
    "room_directory": {
        "servers": []
    },
    "setting_defaults": {
        "breadcrumbs": true,
        "UIFeature.feedback": false,
        "UIFeature.registration": false,
        "UIFeature.communities": false
    }
}
ELEMEOF

ok "Generated element/config.json"

# ---- Generate docker-compose.yml ----
cat > "$SCRIPT_DIR/docker-compose.yml" <<DCEOF
# =============================================================
#  Matrix Private Server — Docker Compose
#  Auto-generated by setup.sh — $(date -Iseconds)
# =============================================================

services:
  # --- PostgreSQL ---
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    volumes:
      - postgres-data:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: $POSTGRES_USER
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DB: $POSTGRES_DB
      POSTGRES_INITDB_ARGS: "--auth-host=md5"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $POSTGRES_USER -d $POSTGRES_DB"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - matrix-internal

  # --- Synapse (Matrix homeserver) ---
  synapse:
    image: matrixdotorg/synapse:latest
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./synapse/homeserver.yaml:/data/homeserver.yaml:ro
      - ./synapse/log.config:/data/log.config:ro
      - ./synapse/signing.key:/data/signing.key:ro
      - synapse-media:/data/media_store
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks:
      - matrix-internal

  # --- Nginx (TLS reverse proxy) ---
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on:
      synapse:
        condition: service_healthy
    ports:
      - "443:443"
      - "8443:8443"
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs/server.crt:/certs/server.crt:ro
      - ./certs/server.key:/certs/server.key:ro
    networks:
      - matrix-internal

  # --- Element Web (browser client) ---
  element:
    image: vectorim/element-web:latest
    restart: unless-stopped
    volumes:
      - ./element/config.json:/app/config.json:ro
    networks:
      - matrix-internal

  # --- Coturn (TURN/STUN for voice/video) ---
  coturn:
    image: coturn/coturn:latest
    restart: unless-stopped
    ports:
      - "3478:3478"
      - "3478:3478/udp"
      - "5349:5349"
      - "5349:5349/udp"
      - "$TURN_MIN_PORT-$TURN_MAX_PORT:$TURN_MIN_PORT-$TURN_MAX_PORT/udp"
    volumes:
      - ./coturn/turnserver.conf:/etc/turnserver.conf:ro
      - ./certs/server.crt:/certs/server.crt:ro
      - ./certs/server.key:/certs/server.key:ro
    command: ["-c", "/etc/turnserver.conf"]
    networks:
      - matrix-internal

volumes:
  postgres-data:
  synapse-media:

networks:
  matrix-internal:
    driver: bridge
DCEOF

ok "Generated docker-compose.yml"

# ---- Generate connection instructions script ----
cat > "$SCRIPT_DIR/scripts/show-connection-info.sh" <<'INFOEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/.env"

CERT_DIR="$SCRIPT_DIR/certs"
CA_FINGERPRINT=""
if [ -f "$CERT_DIR/ca.crt" ]; then
    CA_FINGERPRINT=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
fi

cat <<MSGEOF

╔══════════════════════════════════════════════════════════════╗
║           ПОДКЛЮЧЕНИЕ К СЕРВЕРУ MATRIX                      ║
╚══════════════════════════════════════════════════════════════╝

Привет! Вот инструкции для подключения к нашему приватному
серверу для защищённого общения (чат, звонки, видео).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ШАГ 1: Установи клиент Element
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Android: Google Play → "Element Messenger"
  • iPhone:  App Store  → "Element Messenger"
  • Windows/Mac/Linux: https://element.io/download
  • Браузер (ничего ставить не нужно!):
    Открой https://$SERVER_IP:8443

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ШАГ 2: Установи сертификат (ВАЖНО — без этого не подключишься)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Я пришлю тебе файл ca.crt — это корневой сертификат
  нашего сервера. Его нужно установить на устройство:

  📱 Android:
     Настройки → Безопасность → Шифрование и учётные данные
     → Установить сертификат → Сертификат ЦС
     → Выбери файл ca.crt

  📱 iPhone/iPad:
     1. Открой ca.crt через Safari или Файлы
     2. Перейди Настройки → Основные → VPN и управление устройством
        → Установи профиль «MatrixPrivateCA»
     3. Перейди Настройки → Основные → Об этом устройстве
        → Доверие сертификатам → Включи доверие для «MatrixPrivateCA»

  💻 Windows:
     Двойной клик по ca.crt → «Установить сертификат»
     → «Локальный компьютер» → «Поместить в хранилище»
     → «Доверенные корневые центры сертификации»

  💻 macOS:
     Двойной клик по ca.crt → откроется Keychain Access
     → Перетащи в «System» → Двойной клик на сертификат
     → «Trust» → «Always Trust»

  💻 Linux:
     sudo cp ca.crt /usr/local/share/ca-certificates/matrix-ca.crt
     sudo update-ca-certificates

  Отпечаток сертификата (для проверки):
  $CA_FINGERPRINT

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ШАГ 3: Подключись к серверу в Element
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Открой Element
  2. Нажми «Войти» (Sign In)
  3. Нажми «Изменить» рядом с «matrix.org»
     (или «Edit Homeserver»)
  4. Введи адрес сервера:

     https://$SERVER_IP

  5. Введи логин и пароль, которые тебе дадут

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ШАГ 4: Верификация устройств (для E2E шифрования)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  После входа нужно верифицировать устройства друг друга,
  чтобы шифрование работало:

  1. Открой чат с человеком
  2. Нажми на имя вверху → «Безопасность»
  3. Нажми «Верифицировать» → Сравните эмодзи или QR-код

  Это как в Signal — подтверждаете что видите одинаковые
  значки, и после этого даже сервер не может прочитать
  ваши сообщения.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ВАЖНО
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Все сообщения зашифрованы end-to-end (сервер не читает)
  • Звонки и видео тоже зашифрованы
  • Не пересылай файл ca.crt по открытым каналам —
    лучше передай лично или через проверенный мессенджер
  • Если потеряешь доступ — напиши мне, создам новый аккаунт
  • Для браузера: при первом входе на https://$SERVER_IP:8443
    браузер покажет предупреждение — нажми «Дополнительно»
    → «Перейти на сайт». Или установи сертификат (шаг 2)
    и предупреждения не будет

MSGEOF
INFOEOF

chmod +x "$SCRIPT_DIR/scripts/show-connection-info.sh"
ok "Generated scripts/show-connection-info.sh"

# ---- Create user helper script ----
cat > "$SCRIPT_DIR/scripts/create-user.sh" <<'USEREOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <username> [--admin]"
    echo "Example: $0 ivan"
    echo "Example: $0 ivan --admin"
    exit 1
fi

USERNAME="$1"
ADMIN_FLAG=""
if [ "${2:-}" = "--admin" ]; then
    ADMIN_FLAG="--admin"
fi

echo "Creating user: $USERNAME"
echo "Enter password when prompted."
echo ""

docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec synapse \
    register_new_matrix_user \
    -c /data/homeserver.yaml \
    -u "$USERNAME" \
    $ADMIN_FLAG \
    http://localhost:8008
USEREOF

chmod +x "$SCRIPT_DIR/scripts/create-user.sh"
ok "Generated scripts/create-user.sh"

# ---- Summary ----
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
