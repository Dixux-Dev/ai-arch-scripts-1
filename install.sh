#!/bin/bash

# =============================================================
# FASE 1 — Infraestructura + Setup inicial
#
# Uso: bash instalar.sh "token-cloudflare" \
#        "https://dify.dominio.com" "https://chat.dominio.com" \
#        "admin@email.com" "password-admin"
#
# Instala: Dify + Chatwoot + Cloudflare Tunnel
# Configura: Admin de Dify y Chatwoot automáticamente
#
# Arquitectura de redes Docker:
#   default        → red interna de Dify (nginx, api, worker, web, db, redis...)
#   app-network    → red compartida: Dify api/worker + Chatwoot rails/sidekiq
#                    (permite webhooks HTTP entre ambos sistemas)
#   chatwoot-net   → red interna de Chatwoot (rails, sidekiq, postgres, redis)
# =============================================================

set -eo pipefail

trap 'echo ""; echo "❌ Error en línea $LINENO. Revisa los logs arriba." >&2' ERR

# ----------------------------------------------------------
# Argumentos y validación
# ----------------------------------------------------------
CLOUDFLARE_TOKEN="${1:-}"
DIFY_URL="${2:-}"
CHATWOOT_URL="${3:-}"
ADMIN_EMAIL="${4:-}"
ADMIN_PASSWORD="${5:-}"

if [ -z "$CLOUDFLARE_TOKEN" ] || [ -z "$DIFY_URL" ] || [ -z "$CHATWOOT_URL" ] || \
   [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ]; then
    echo ""
    echo "❌ Faltan argumentos."
    echo ""
    echo "Uso: bash instalar.sh \"cf-token\" \\"
    echo "       \"https://dify.dominio.com\" \"https://chat.dominio.com\" \\"
    echo "       \"admin@email.com\" \"password-admin\""
    echo ""
    exit 1
fi

if [[ ! "$DIFY_URL" =~ ^https:// ]]; then
    echo "❌ DIFY_URL debe comenzar con https://"
    exit 1
fi

if [[ ! "$CHATWOOT_URL" =~ ^https:// ]]; then
    echo "❌ CHATWOOT_URL debe comenzar con https://"
    exit 1
fi

if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
    echo "❌ El password del admin debe tener al menos 8 caracteres."
    exit 1
fi

# Archivo de credenciales único por VPS
CREDS_FILE="$HOME/.stack.env"

# Secretos de Chatwoot — reutilizar si ya existen para no romper volúmenes
if [ -f "$CREDS_FILE" ] && grep -q "^CHATWOOT_DB_PASSWORD=" "$CREDS_FILE"; then
    CHATWOOT_DB_PASSWORD=$(grep "^CHATWOOT_DB_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2)
    CHATWOOT_SECRET_KEY=$(grep "^CHATWOOT_SECRET_KEY=" "$CREDS_FILE" | cut -d'=' -f2)
    CHATWOOT_REDIS_PASSWORD=$(grep "^CHATWOOT_REDIS_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2)
    echo "   ♻️  Reutilizando secretos existentes en $CREDS_FILE"
else
    CHATWOOT_DB_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/' | cut -c1-24)
    CHATWOOT_SECRET_KEY=$(openssl rand -hex 32)
    CHATWOOT_REDIS_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/' | cut -c1-24)
fi

echo ""
echo "🚀 Instalando stack Dify + Chatwoot"
echo "   Dify URL:     $DIFY_URL"
echo "   Chatwoot URL: $CHATWOOT_URL"
echo "   Admin email:  $ADMIN_EMAIL"
echo "=================================================="

# ----------------------------------------------------------
# 1. Dependencias del sistema
# ----------------------------------------------------------
echo ""
echo "📦 Verificando dependencias del sistema..."

NEED_UPDATE=0
for pkg in curl git openssl jq; do
    if ! command -v "$pkg" &>/dev/null; then
        NEED_UPDATE=1
    fi
done

if [ "$NEED_UPDATE" -eq 1 ]; then
    apt-get update -qq
    for pkg in curl git openssl jq; do
        if ! command -v "$pkg" &>/dev/null; then
            echo "   Instalando $pkg..."
            apt-get install -y -qq "$pkg"
        fi
    done
fi

for pkg in curl git openssl jq; do
    echo "   ✅ $pkg $(command -v "$pkg")"
done

# ----------------------------------------------------------
# 2. Docker
# ----------------------------------------------------------
echo ""
echo "📦 Verificando Docker..."

if ! command -v docker &>/dev/null; then
    echo "   Docker no encontrado, instalando..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo "   ✅ Docker instalado"
else
    echo "   ✅ Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

if ! docker compose version &>/dev/null; then
    echo "❌ Docker Compose plugin no disponible. Instala docker-compose-plugin."
    exit 1
fi

echo "   ✅ Docker Compose $(docker compose version --short)"

# ----------------------------------------------------------
# 3. Redes compartidas
# ----------------------------------------------------------
echo ""
echo "🌐 Verificando redes Docker..."

for NET in app-network chatwoot-net; do
    if docker network inspect "$NET" &>/dev/null; then
        echo "   ⚠️  $NET ya existe, omitiendo"
    else
        docker network create "$NET"
        echo "   ✅ Red $NET creada"
    fi
done

# ----------------------------------------------------------
# 4. Clonar Dify
# ----------------------------------------------------------
echo ""
echo "📥 Preparando repositorio de Dify..."

cd "$HOME"

DIFY_DOCKER_DIR="$HOME/dify/docker"
DIFY_COMPOSE="$DIFY_DOCKER_DIR/docker-compose.yaml"

if [ -f "$DIFY_COMPOSE" ] && git -C "$HOME/dify" status &>/dev/null; then
    echo "   ⚠️  Repositorio dify ya existe y está completo, omitiendo clonado"
else
    if [ -d "$HOME/dify" ]; then
        echo "   ⚠️  Carpeta dify existe pero está incompleta, eliminando..."
        rm -rf "$HOME/dify"
    fi
    echo "   Clonando repositorio de Dify..."
    git clone https://github.com/langgenius/dify.git
    echo "   ✅ Repositorio clonado"
fi

cd "$HOME/dify/docker"

# ----------------------------------------------------------
# 5. Configurar .env de Dify
# ----------------------------------------------------------
echo ""
echo "⚙️  Configurando variables de entorno de Dify..."

if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "   ✅ Archivo .env creado desde .env.example"
else
    echo "   ⚠️  Archivo .env ya existe, actualizando valores"
fi

sed -i "s|APP_WEB_URL=.*|APP_WEB_URL=$DIFY_URL|" .env
sed -i "s|CONSOLE_WEB_URL=.*|CONSOLE_WEB_URL=$DIFY_URL|" .env
sed -i "s|CONSOLE_API_URL=.*|CONSOLE_API_URL=$DIFY_URL|" .env
sed -i "s|SERVICE_API_URL=.*|SERVICE_API_URL=$DIFY_URL|" .env
echo "   ✅ URLs configuradas: $DIFY_URL"

if grep -q "^NGINX_HTTPS_ENABLED=" .env; then
    sed -i "s|^NGINX_HTTPS_ENABLED=.*|NGINX_HTTPS_ENABLED=false|" .env
else
    echo "NGINX_HTTPS_ENABLED=false" >> .env
fi
echo "   ✅ NGINX_HTTPS_ENABLED=false"

if grep -q "^EXPOSE_NGINX_SSL_PORT=" .env; then
    sed -i "s|^EXPOSE_NGINX_SSL_PORT=.*|EXPOSE_NGINX_SSL_PORT=8443|" .env
else
    echo "EXPOSE_NGINX_SSL_PORT=8443" >> .env
fi
echo "   ✅ EXPOSE_NGINX_SSL_PORT=8443"

if grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" .env; then
    sed -i "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TOKEN|" .env
else
    echo "" >> .env
    echo "CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TOKEN" >> .env
fi
echo "   ✅ CLOUDFLARE_TUNNEL_TOKEN configurado"

if grep -q "^CHATWOOT_URL=" .env; then
    sed -i "s|^CHATWOOT_URL=.*|CHATWOOT_URL=$CHATWOOT_URL|" .env
else
    echo "" >> .env
    echo "CHATWOOT_URL=$CHATWOOT_URL" >> .env
fi
echo "   ✅ CHATWOOT_URL=$CHATWOOT_URL"

# ----------------------------------------------------------
# 6. docker-compose.override.yml
#
# DISEÑO DE REDES:
#   default      → red interna de Dify (nginx, api, worker, web, db, redis)
#   app-network  → red compartida Dify↔Chatwoot para webhooks internos
#   chatwoot-net → red interna de Chatwoot (rails, sidekiq, postgres, redis)
#
# TUNNEL:
#   Un solo cloudflared, un token, múltiples hostnames en Zero Trust:
#     dify.dominio.com  → http://nginx:80
#     chat.dominio.com  → http://chatwoot-rails:3000
#
# WEBHOOKS internos:
#   Dify → Chatwoot: http://chatwoot-rails:3000  (vía app-network)
#   Chatwoot → Dify: http://nginx:80             (vía app-network)
# ----------------------------------------------------------
echo ""
echo "🔧 Creando docker-compose.override.yml..."

cat > docker-compose.override.yml << EOF
services:

  # ─── Cloudflare Tunnel (único para todo el stack) ──────────────────────────
  # Un token = un túnel. Hostnames configurados en Cloudflare Zero Trust:
  #   $(echo "$DIFY_URL" | sed 's|https://||')  → http://nginx:80
  #   $(echo "$CHATWOOT_URL" | sed 's|https://||')  → http://chatwoot-rails:3000
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: always
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TOKEN}
    dns:
      - 1.1.1.1
      - 8.8.8.8
    networks:
      - default       # accede a nginx:80 (Dify)
      - chatwoot-net  # accede a chatwoot-rails:3000

  # ─── Postgres de Chatwoot ──────────────────────────────────────────────────
  # pgvector/pgvector:pg16 incluye la extensión vector que requiere Chatwoot
  chatwoot-postgres:
    image: pgvector/pgvector:pg16
    restart: always
    environment:
      POSTGRES_DB: chatwoot
      POSTGRES_USER: chatwoot
      POSTGRES_PASSWORD: ${CHATWOOT_DB_PASSWORD}
    volumes:
      - chatwoot_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chatwoot -d chatwoot"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - chatwoot-net

  # ─── Redis de Chatwoot (independiente del Redis de Dify) ───────────────────
  chatwoot-redis:
    image: redis:7-alpine
    restart: always
    command: redis-server --requirepass ${CHATWOOT_REDIS_PASSWORD}
    volumes:
      - chatwoot_redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${CHATWOOT_REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - chatwoot-net

  # ─── Chatwoot Rails (app server) ───────────────────────────────────────────
  chatwoot-rails:
    image: chatwoot/chatwoot:latest
    restart: always
    depends_on:
      chatwoot-postgres:
        condition: service_healthy
      chatwoot-redis:
        condition: service_healthy
    entrypoint: docker/entrypoints/rails.sh
    command: bundle exec rails s -b 0.0.0.0 -p 3000
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: ${CHATWOOT_SECRET_KEY}
      DATABASE_URL: postgresql://chatwoot:${CHATWOOT_DB_PASSWORD}@chatwoot-postgres:5432/chatwoot
      REDIS_URL: redis://:${CHATWOOT_REDIS_PASSWORD}@chatwoot-redis:6379
      FRONTEND_URL: ${CHATWOOT_URL}
      FORCE_SSL: "false"
      ENABLE_ACCOUNT_SIGNUP: "false"
    volumes:
      - chatwoot_storage:/app/storage
    networks:
      - chatwoot-net
      - app-network

  # ─── Chatwoot Sidekiq (background jobs) ────────────────────────────────────
  chatwoot-sidekiq:
    image: chatwoot/chatwoot:latest
    restart: always
    depends_on:
      chatwoot-postgres:
        condition: service_healthy
      chatwoot-redis:
        condition: service_healthy
    entrypoint: docker/entrypoints/rails.sh
    command: bundle exec sidekiq -C config/sidekiq.yml
    environment:
      RAILS_ENV: production
      SECRET_KEY_BASE: ${CHATWOOT_SECRET_KEY}
      DATABASE_URL: postgresql://chatwoot:${CHATWOOT_DB_PASSWORD}@chatwoot-postgres:5432/chatwoot
      REDIS_URL: redis://:${CHATWOOT_REDIS_PASSWORD}@chatwoot-redis:6379
      FRONTEND_URL: ${CHATWOOT_URL}
      FORCE_SSL: "false"
    volumes:
      - chatwoot_storage:/app/storage
    networks:
      - chatwoot-net
      - app-network

  # ─── Dify: api, worker y plugin_daemon se unen a app-network ───────────────
  api:
    networks:
      - app-network

  worker:
    networks:
      - app-network

  plugin_daemon:
    networks:
      - default
      - app-network

volumes:
  chatwoot_postgres_data:
  chatwoot_redis_data:
  chatwoot_storage:

networks:
  app-network:
    external: true
  chatwoot-net:
    external: true
  default:
    driver: bridge
EOF

echo "   ✅ docker-compose.override.yml creado"

# ----------------------------------------------------------
# 7. Limpiar estado inconsistente y levantar servicios
# ----------------------------------------------------------
echo ""
echo "🧹 Limpiando contenedores y redes huérfanas..."
docker compose down --remove-orphans 2>/dev/null || true
docker network rm docker_default 2>/dev/null || true

echo "🐳 Levantando servicios..."
docker compose up -d --remove-orphans

# ----------------------------------------------------------
# 8. Función de espera genérica
# ----------------------------------------------------------
wait_healthy() {
    local service="$1"
    local max="${2:-18}"  # default 90s (18 × 5s)
    local i=0
    while [ $i -lt $max ]; do
        STATUS=$(docker compose ps "$service" --format json 2>/dev/null \
            | grep -o '"Health":"[^"]*"\|"State":"[^"]*"' | head -2 || true)
        if echo "$STATUS" | grep -q '"Health":"healthy"'; then
            echo "   ✅ $service healthy"
            return 0
        elif echo "$STATUS" | grep -q '"State":"running"'; then
            if ! echo "$STATUS" | grep -q '"State":"restarting"'; then
                echo "   ✅ $service running"
                return 0
            fi
        fi
        sleep 5
        i=$((i + 1))
        echo -n "."
    done
    echo ""
    echo "   ⚠️  $service tardó más de $((max * 5))s — revisa: docker compose logs $service"
    return 1
}

# ----------------------------------------------------------
# 9. Preparar DB de Chatwoot
# ----------------------------------------------------------
echo ""
echo "⏳ Esperando Postgres y Redis de Chatwoot..."

wait_healthy chatwoot-postgres
wait_healthy chatwoot-redis

echo ""
echo "🗄️  Inicializando base de datos de Chatwoot..."
docker compose run --rm chatwoot-rails bundle exec rails db:chatwoot_prepare
echo "   ✅ DB de Chatwoot preparada"

# ----------------------------------------------------------
# 10. Esperar servicios críticos de Dify
#     Dify necesita ~2 min para migrar su DB interna
# ----------------------------------------------------------
echo ""
echo "⏳ Esperando que Dify inicialice (hasta 3 min)..."

wait_healthy nginx 36  # 36 × 5s = 3 min

# ----------------------------------------------------------
# 11. Setup automático del admin de Dify
# ----------------------------------------------------------
echo ""
echo "👤 Configurando admin de Dify..."

DIFY_INTERNAL="http://localhost/console/api"
DIFY_SETUP_DONE=false

for attempt in $(seq 1 12); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "$DIFY_INTERNAL/setup" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        SETUP_RESP=$(curl -s -X POST "$DIFY_INTERNAL/setup" \
            -H "Content-Type: application/json" \
            -d "{
                \"email\": \"$ADMIN_EMAIL\",
                \"name\": \"Admin\",
                \"password\": \"$ADMIN_PASSWORD\"
            }" 2>/dev/null || echo '{"result":"error"}')

        if echo "$SETUP_RESP" | grep -q '"result":"success"'; then
            echo "   ✅ Admin de Dify creado: $ADMIN_EMAIL"
            DIFY_SETUP_DONE=true
            break
        elif echo "$SETUP_RESP" | grep -q '"already_setup"'; then
            echo "   ⚠️  Dify ya tiene admin configurado, omitiendo"
            DIFY_SETUP_DONE=true
            break
        else
            echo "   ⚠️  Setup respondió inesperadamente: $SETUP_RESP"
            break
        fi
    elif [ "$HTTP_CODE" = "403" ]; then
        echo "   ⚠️  Dify ya tiene admin configurado, omitiendo"
        DIFY_SETUP_DONE=true
        break
    else
        echo -n "   Esperando que Dify esté listo (intento $attempt/12)..."
        sleep 5
        echo ""
    fi
done

if [ "$DIFY_SETUP_DONE" = false ]; then
    echo "   ⚠️  No se pudo configurar el admin de Dify automáticamente."
    echo "   Hazlo manualmente en: $DIFY_URL"
fi

# ----------------------------------------------------------
# 12. Setup automático del admin de Chatwoot
# ----------------------------------------------------------
echo ""
echo "👤 Configurando admin de Chatwoot..."

CHATWOOT_SETUP_DONE=false

# Esperar que chatwoot-rails esté aceptando conexiones
for attempt in $(seq 1 12); do
    CW_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        "http://chatwoot-rails:3000/auth/sign_in" 2>/dev/null || echo "000")
    if [ "$CW_CODE" != "000" ]; then
        break
    fi
    echo -n "   Esperando que Chatwoot esté listo (intento $attempt/12)..."
    sleep 5
    echo ""
done

# Crear superadmin via rails runner dentro del contenedor
CW_ADMIN_RESULT=$(docker compose exec -T chatwoot-rails \
    bundle exec rails runner \
    "
    begin
      user = User.find_by(email: '$ADMIN_EMAIL')
      if user
        puts 'already_exists'
      else
        user = User.new(
          name: 'Admin',
          email: '$ADMIN_EMAIL',
          password: '$ADMIN_PASSWORD',
          password_confirmation: '$ADMIN_PASSWORD',
          type: 'SuperAdmin'
        )
        if user.save
          puts 'created'
        else
          puts 'error: ' + user.errors.full_messages.join(', ')
        end
      end
    rescue => e
      puts 'exception: ' + e.message
    end
    " 2>/dev/null | tail -1 || echo "error")

if echo "$CW_ADMIN_RESULT" | grep -q "created"; then
    echo "   ✅ Admin de Chatwoot creado: $ADMIN_EMAIL"
    CHATWOOT_SETUP_DONE=true
elif echo "$CW_ADMIN_RESULT" | grep -q "already_exists"; then
    echo "   ⚠️  Chatwoot ya tiene ese usuario, omitiendo"
    CHATWOOT_SETUP_DONE=true
else
    echo "   ⚠️  No se pudo crear admin de Chatwoot: $CW_ADMIN_RESULT"
    echo "   Hazlo manualmente en: $CHATWOOT_URL"
fi

# ----------------------------------------------------------
# 13. Guardar credenciales
# ----------------------------------------------------------
echo ""
echo "💾 Guardando credenciales..."

cat > "$CREDS_FILE" << EOF
# Stack Dify + Chatwoot — $(date)
# ¡PROTEGE ESTE ARCHIVO! Contiene secretos de producción.

ADMIN_EMAIL=$ADMIN_EMAIL

# ── Dify ────────────────────────────────────────────────────
DIFY_URL=$DIFY_URL

# ── Chatwoot ─────────────────────────────────────────────────
CHATWOOT_URL=$CHATWOOT_URL
CHATWOOT_DB_PASSWORD=$CHATWOOT_DB_PASSWORD
CHATWOOT_SECRET_KEY=$CHATWOOT_SECRET_KEY
CHATWOOT_REDIS_PASSWORD=$CHATWOOT_REDIS_PASSWORD

# ── Bridge (se completa en Fase 2 con conectar.sh) ───────────
DIFY_API_KEY=
CHATWOOT_API_KEY=
CHATWOOT_ACCOUNT_ID=

# ── Conectividad interna (desde dentro de app-network) ────────
# Dify  → Chatwoot: http://chatwoot-rails:3000
# Chatwoot → Dify:  http://nginx:80
EOF
chmod 600 "$CREDS_FILE"
echo "   ✅ Credenciales guardadas en: $CREDS_FILE"

# ----------------------------------------------------------
# Resumen final
# ----------------------------------------------------------
echo ""
echo "=================================================="
echo "✅ FASE 1 COMPLETA"
echo "=================================================="
echo ""
echo "🌐 Cloudflare Zero Trust — configurar 2 hostnames en el mismo túnel:"
echo ""
echo "   $(echo "$DIFY_URL" | sed 's|https://||')   →   http://nginx:80"
echo "   $(echo "$CHATWOOT_URL" | sed 's|https://||')   →   http://chatwoot-rails:3000"
echo ""
echo "─────────────────────────────────────────────────"
echo "🔑 Credenciales de acceso:"
echo "   Email:    $ADMIN_EMAIL"
echo "   Password: $ADMIN_PASSWORD"
echo ""
echo "   Dify:     $DIFY_URL"
echo "   Chatwoot: $CHATWOOT_URL"
echo "─────────────────────────────────────────────────"
echo ""
echo "⏭️  PRÓXIMOS PASOS para activar el bridge Chatwoot↔Dify:"
echo ""
echo "   1. Entra a Dify ($DIFY_URL)"
echo "      → Crea tu aplicación (Chatflow o Agent)"
echo "      → Ve a 'API Access' en el menú lateral"
echo "      → Copia el API Key (app-xxxxx...)"
echo ""
echo "   2. Entra a Chatwoot ($CHATWOOT_URL)"
echo "      → Settings → Integrations → Agent Bots → New Agent Bot"
echo "      → Copia el Access Token"
echo "      → Anota el Account ID (está en la URL: /app/accounts/ID/...)"
echo ""
echo "   3. Ejecuta la Fase 2:"
echo "      bash conectar.sh"
echo ""
echo "─────────────────────────────────────────────────"
echo "🔍 Comandos útiles (desde $HOME/dify/docker):"
echo "   docker compose ps                        # estado de todos los servicios"
echo "   docker compose logs -f cloudflared       # tunnel"
echo "   docker compose logs -f chatwoot-rails    # Chatwoot app"
echo "   docker compose logs -f nginx             # Dify proxy"
echo ""
echo "🔄 Actualizar Chatwoot:"
echo "   cd $HOME/dify/docker"
echo "   docker compose pull chatwoot-rails chatwoot-sidekiq"
echo "   docker compose up -d chatwoot-rails chatwoot-sidekiq"
echo "   docker compose run --rm chatwoot-rails bundle exec rails db:chatwoot_prepare"
echo ""
echo "🗄️  Acceso directo a la DB de Chatwoot:"
echo "   docker compose exec chatwoot-postgres psql -U chatwoot -d chatwoot"
echo ""
