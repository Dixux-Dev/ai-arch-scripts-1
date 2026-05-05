#!/bin/bash
# =============================================================
# FASE 2 — Bridge Chatwoot ↔ Dify (Chatdify)
#
# Uso: bash bridge.sh
#
# Prerequisitos:
#   1. Fase 1 completada (instalar.sh)
#   2. Haber creado una app en Dify y copiado su API Key
#   3. Haber creado un Agent Bot en Chatwoot y copiado su token
#
# Lo que hace este script:
#   - Solicita interactivamente los API keys necesarios
#   - Clona y despliega Chatdify como contenedor Docker
#   - Lo conecta a las redes internas del stack (app-network + chatwoot-net)
#   - Registra el webhook en Chatwoot automáticamente (vía red Docker interna)
#   - Guarda todo en ~/.stack.env
# =============================================================
set -eo pipefail
trap 'echo ""; echo "❌ Error en línea $LINENO. Revisa los logs arriba." >&2' ERR

CREDS_FILE="$HOME/.stack.env"
BRIDGE_DIR="$HOME/chatdify"
COMPOSE_DIR="$HOME/dify/docker"
OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"

# ----------------------------------------------------------
# Helper: actualiza o agrega una clave en .stack.env
# ----------------------------------------------------------
update_or_add() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$CREDS_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$CREDS_FILE"
    else
        echo "${key}=${value}" >> "$CREDS_FILE"
    fi
}

# ----------------------------------------------------------
# Helper: curl ejecutado DENTRO de la red Docker (app-network)
# Necesario porque chatwoot-rails:3000 no tiene puerto expuesto al host.
# ----------------------------------------------------------
docker_curl() {
    docker run --rm \
        --network app-network \
        curlimages/curl:latest \
        --silent --max-time 10 \
        "$@"
}

# ----------------------------------------------------------
# Verificar que la Fase 1 está completa
# ----------------------------------------------------------
if [ ! -f "$CREDS_FILE" ]; then
    echo ""
    echo "❌ No se encontró $CREDS_FILE"
    echo "   Ejecuta primero la Fase 1: bash instalar.sh"
    exit 1
fi

source "$CREDS_FILE"

if [ -z "$DIFY_URL" ] || [ -z "$CHATWOOT_URL" ]; then
    echo "❌ El archivo $CREDS_FILE está incompleto. Re-ejecuta instalar.sh"
    exit 1
fi

if [ -z "$CHATWOOT_REDIS_PASSWORD" ]; then
    echo "❌ CHATWOOT_REDIS_PASSWORD no encontrado en $CREDS_FILE."
    echo "   Verifica que instalar.sh se completó correctamente."
    exit 1
fi

if [ ! -f "$OVERRIDE_FILE" ]; then
    echo "❌ No se encontró $OVERRIDE_FILE. ¿Está la Fase 1 completa?"
    exit 1
fi

echo ""
echo "🔗 Fase 2 — Conectando Chatwoot ↔ Dify"
echo "   Dify:     $DIFY_URL"
echo "   Chatwoot: $CHATWOOT_URL"
echo "=================================================="

# ----------------------------------------------------------
# Reutilizar keys si ya existen en .stack.env
# ----------------------------------------------------------
if [ -n "$DIFY_API_KEY" ] && [ -n "$CHATWOOT_API_KEY" ] && \
   [ -n "$CHATWOOT_ADMIN_API_KEY" ] && [ -n "$CHATWOOT_ACCOUNT_ID" ]; then
    echo ""
    echo "♻️  Keys ya configuradas en $CREDS_FILE, reutilizando..."
    echo "   DIFY_API_KEY:          ${DIFY_API_KEY:0:12}..."
    echo "   CHATWOOT_API_KEY:      ${CHATWOOT_API_KEY:0:8}..."
    echo "   CHATWOOT_ADMIN_TOKEN:  ${CHATWOOT_ADMIN_API_KEY:0:8}..."
    echo "   CHATWOOT_ACCOUNT_ID:   $CHATWOOT_ACCOUNT_ID"
else
    echo ""
    echo "📋 Necesito 4 datos para conectar el bridge."
    echo "   Sigue las instrucciones para obtener cada uno."
    echo ""

    # ── Dify API Key ──────────────────────────────────────────
    echo "─────────────────────────────────────────────────"
    echo "1️⃣  DIFY API KEY"
    echo ""
    echo "   → Entra a $DIFY_URL"
    echo "   → Abre tu aplicación (Chatflow o Agent)"
    echo "   → Menú lateral: 'API Access'"
    echo "   → Copia la API Key (empieza con app-...)"
    echo ""
    while true; do
        read -r -p "   Pega aquí el Dify API Key: " DIFY_API_KEY
        if [[ "$DIFY_API_KEY" =~ ^app- ]]; then
            echo "   ✅ Dify API Key recibido"
            break
        else
            echo "   ⚠️  Debe empezar con 'app-', intenta de nuevo"
        fi
    done
    echo ""

    # ── Chatwoot Account ID ───────────────────────────────────
    echo "─────────────────────────────────────────────────"
    echo "2️⃣  CHATWOOT ACCOUNT ID"
    echo ""
    echo "   → Entra a $CHATWOOT_URL"
    echo "   → Mira la URL: /app/accounts/NÚMERO/..."
    echo "   → El número es tu Account ID"
    echo ""
    while true; do
        read -r -p "   Escribe el Account ID (solo el número): " CHATWOOT_ACCOUNT_ID
        if [[ "$CHATWOOT_ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
            echo "   ✅ Account ID: $CHATWOOT_ACCOUNT_ID"
            break
        else
            echo "   ⚠️  Solo números, intenta de nuevo"
        fi
    done
    echo ""

    # ── Chatwoot Agent Bot Token ──────────────────────────────
    echo "─────────────────────────────────────────────────"
    echo "3️⃣  CHATWOOT AGENT BOT ACCESS TOKEN"
    echo ""
    echo "   → En Chatwoot: Settings → Integrations → Agent Bots"
    echo "   → Crea un nuevo Agent Bot (nombre sugerido: 'Dify')"
    echo "   → En Webhook URL pon cualquier cosa por ahora"
    echo "     (lo actualizaremos automáticamente)"
    echo "   → Copia el Access Token que aparece al crearlo"
    echo ""
    while true; do
        read -r -p "   Pega aquí el Agent Bot Access Token: " CHATWOOT_API_KEY
        if [ ${#CHATWOOT_API_KEY} -gt 10 ]; then
            echo "   ✅ Agent Bot Token recibido"
            break
        else
            echo "   ⚠️  Token muy corto, intenta de nuevo"
        fi
    done
    echo ""

    # ── Chatwoot Admin API Key ────────────────────────────────
    echo "─────────────────────────────────────────────────"
    echo "4️⃣  CHATWOOT ADMIN (SUPER ADMIN) API KEY"
    echo ""
    echo "   → En Chatwoot: haz clic en tu avatar (arriba izquierda)"
    echo "   → Profile Settings → scroll hasta abajo"
    echo "   → Sección 'Access Token'"
    echo "   → Copia el token (es tu token personal de admin)"
    echo ""
    while true; do
        read -r -p "   Pega aquí el Admin Access Token: " CHATWOOT_ADMIN_API_KEY
        if [ ${#CHATWOOT_ADMIN_API_KEY} -gt 10 ]; then
            echo "   ✅ Admin Token recibido"
            break
        else
            echo "   ⚠️  Token muy corto, intenta de nuevo"
        fi
    done
fi

# ----------------------------------------------------------
# Generar secretos internos del bridge
# ----------------------------------------------------------
if [ -z "$BRIDGE_DB_PASSWORD" ]; then
    BRIDGE_DB_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/' | cut -c1-24)
fi
if [ -z "$BRIDGE_SECRET_KEY" ]; then
    BRIDGE_SECRET_KEY=$(openssl rand -hex 32)
fi

BRIDGE_INTERNAL_URL="http://chatdify:8000"
BRIDGE_WEBHOOK_PATH="/api/v1/chatwoot-webhook"
WEBHOOK_URL="${BRIDGE_INTERNAL_URL}${BRIDGE_WEBHOOK_PATH}"

# Detectar prefijo del proyecto Compose para nombres de volúmenes
COMPOSE_PROJECT=$(cd "$COMPOSE_DIR" && docker compose config --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','docker'))" \
    2>/dev/null || echo "docker")
echo ""
echo "ℹ️  Proyecto Docker Compose detectado: $COMPOSE_PROJECT"

# ----------------------------------------------------------
# Clonar Chatdify (siempre desde cero para evitar .env viejo)
# ----------------------------------------------------------
echo ""
echo "📥 Preparando repositorio de Chatdify..."
if [ -d "$BRIDGE_DIR" ]; then
    echo "   🗑️  Limpiando instalación anterior..."
    rm -rf "$BRIDGE_DIR"
fi
git clone https://github.com/alexbalandi/chatwoot-dify.git "$BRIDGE_DIR"
echo "   ✅ Repositorio clonado en $BRIDGE_DIR"

# ----------------------------------------------------------
# Crear .env del bridge
# ----------------------------------------------------------
echo ""
echo "⚙️  Configurando variables de entorno del bridge..."

cat > "$BRIDGE_DIR/.env" << EOF
# Chatdify — Bridge Chatwoot ↔ Dify
# Generado por bridge.sh — $(date)

# ── Chatwoot ─────────────────────────────────────────────
# chatwoot-rails:3000 accesible desde chatdify vía chatwoot-net
CHATWOOT_API_URL=http://chatwoot-rails:3000
CHATWOOT_API_KEY=${CHATWOOT_API_KEY}
CHATWOOT_ADMIN_API_KEY=${CHATWOOT_ADMIN_API_KEY}
CHATWOOT_ACCOUNT_ID=${CHATWOOT_ACCOUNT_ID}

# ── Dify ─────────────────────────────────────────────────
# nginx:80 accesible desde chatdify vía app-network
DIFY_API_URL=http://nginx:80/v1
DIFY_API_KEY=${DIFY_API_KEY}

# ── Bridge interno ────────────────────────────────────────
SECRET_KEY=${BRIDGE_SECRET_KEY}

# ── Base de datos propia del bridge ──────────────────────
DB_HOST=chatdify-postgres
DB_PORT=5432
POSTGRES_DB=chatdify
POSTGRES_USER=chatdify
POSTGRES_PASSWORD=${BRIDGE_DB_PASSWORD}
DATABASE_URL=postgresql://chatdify:${BRIDGE_DB_PASSWORD}@chatdify-postgres:5432/chatdify

# ── Redis (comparte el Redis de Chatwoot, DB index 1) ────
REDIS_HOST=chatwoot-redis
REDIS_PORT=6379
CELERY_BROKER_URL=redis://:${CHATWOOT_REDIS_PASSWORD}@chatwoot-redis:6379/1
CELERY_RESULT_BACKEND=redis://:${CHATWOOT_REDIS_PASSWORD}@chatwoot-redis:6379/1
EOF

chmod 600 "$BRIDGE_DIR/.env"
echo "   ✅ .env del bridge creado"

# ----------------------------------------------------------
# Modificar docker-compose.override.yml con python3
#
# Problema raíz de versiones anteriores:
#   El bloque chatdify se insertaba FUERA de services: porque
#   los marcadores quedaban al nivel raíz del YAML.
#
# Solución: NO usar marcadores. Simplemente:
#   1. Eliminar servicios chatdify-* previos por nombre
#   2. Eliminar volumen chatdify_postgres_data previo de volumes:
#   3. Insertar el bloque nuevo DENTRO de services: (antes de volumes:)
#   4. Declarar el volumen en volumes:
#
# Todo con python3, sin sed/awk, usando export para pasar variables.
# ----------------------------------------------------------
echo ""
echo "🔧 Actualizando docker-compose.override.yml..."

export _PY_OVERRIDE="$OVERRIDE_FILE"
export _PY_DB_PASS="$BRIDGE_DB_PASSWORD"
export _PY_BRIDGE="$BRIDGE_DIR"

python3 << 'PYEOF'
import os, re, sys

OVERRIDE_FILE = os.environ["_PY_OVERRIDE"]
DB_PASSWORD   = os.environ["_PY_DB_PASS"]
BRIDGE_DIR    = os.environ["_PY_BRIDGE"]

with open(OVERRIDE_FILE, "r") as f:
    original = f.read()

content = original

# ── Paso 1: eliminar cualquier rastro de runs anteriores ─────────────────────

# 1a. Eliminar bloque entre marcadores si existe (legacy de versión anterior)
MARKER_BEGIN = "# <<< CHATDIFY-BEGIN >>>"
MARKER_END   = "# <<< CHATDIFY-END >>>"
if MARKER_BEGIN in content:
    pattern = re.compile(
        re.escape(MARKER_BEGIN) + r".*?" + re.escape(MARKER_END) + r"\n?",
        re.DOTALL
    )
    content = pattern.sub("", content)
    print("   ⚠️  Marcadores legacy de chatdify eliminados")

# 1b. Eliminar servicios chatdify-* por nombre de servicio
# Cada servicio en el override empieza con "  nombre-servicio:\n" (2 espacios)
# y termina justo antes del siguiente servicio de nivel raíz o sección raíz.
# Usamos regex para eliminar cada bloque chatdify-*
service_names = ["chatdify-postgres", "chatdify", "chatdify-worker"]
for svc in service_names:
    # Eliminar desde "  chatdify-X:\n" hasta (sin incluir) la siguiente
    # línea que empiece con exactamente 2 espacios + letra (otro servicio)
    # o con 0 espacios + letra (sección raíz como volumes:, networks:)
    pattern = re.compile(
        r"^  " + re.escape(svc) + r":.*?(?=\n  [a-zA-Z]|\n[a-zA-Z])",
        re.MULTILINE | re.DOTALL
    )
    if pattern.search(content):
        content = pattern.sub("", content)
        print(f"   ⚠️  Servicio {svc} previo eliminado")

# 1c. Eliminar volumen chatdify_postgres_data de la sección volumes:
# Solo líneas con exactamente 2 espacios de indentación
content = re.sub(r'^  chatdify_postgres_data:\s*\n', '', content, flags=re.MULTILINE)

# ── Paso 2: construir el bloque de servicios chatdify ─────────────────────────
# Sin marcadores — el bloque va limpiamente dentro de services:
services_block = (
    "\n"
    "  # --- Chatdify: Bridge Chatwoot <-> Dify -----------------------------------\n"
    "  chatdify-postgres:\n"
    "    image: postgres:16-alpine\n"
    "    restart: always\n"
    "    environment:\n"
    "      POSTGRES_DB: chatdify\n"
    "      POSTGRES_USER: chatdify\n"
    f"      POSTGRES_PASSWORD: {DB_PASSWORD}\n"
    "    volumes:\n"
    "      - chatdify_postgres_data:/var/lib/postgresql/data\n"
    "    healthcheck:\n"
    '      test: ["CMD-SHELL", "pg_isready -U chatdify -d chatdify"]\n'
    "      interval: 10s\n"
    "      timeout: 5s\n"
    "      retries: 5\n"
    "    networks:\n"
    "      - chatwoot-net\n"
    "\n"
    "  chatdify:\n"
    "    image: eremeye/chatdify:latest\n"
    "    restart: always\n"
    "    depends_on:\n"
    "      chatdify-postgres:\n"
    "        condition: service_healthy\n"
    "    env_file:\n"
    f"      - {BRIDGE_DIR}/.env\n"
    "    ports:\n"
    '      - "127.0.0.1:8001:8000"\n'
    "    networks:\n"
    "      - default       # accede a nginx:80 (Dify)\n"
    "      - chatwoot-net  # recibe webhook de chatwoot-rails\n"
    "\n"
    "  chatdify-worker:\n"
    "    image: eremeye/chatdify:latest\n"
    "    restart: always\n"
    "    command: celery -A app.tasks worker --loglevel=info --concurrency=4 --pool=prefork\n"
    "    depends_on:\n"
    "      chatdify-postgres:\n"
    "        condition: service_healthy\n"
    "    env_file:\n"
    f"      - {BRIDGE_DIR}/.env\n"
    "    networks:\n"
    "      - default       # accede a nginx:80 (Dify API)\n"
    "      - chatwoot-net  # accede a chatwoot-rails:3000 y chatwoot-redis\n"
)

# ── Paso 3: insertar servicios justo antes de "^volumes:" ────────────────────
if not re.search(r'^volumes:', content, re.MULTILINE):
    print("ERROR: No se encontró la sección 'volumes:' en el override.")
    print("       El archivo puede estar corrupto. Re-ejecuta instalar.sh")
    sys.exit(1)

content = re.sub(
    r'^(volumes:)',
    services_block + r'\1',
    content,
    count=1,
    flags=re.MULTILINE
)

# ── Paso 4: declarar chatdify_postgres_data en la sección volumes: ────────────
# Verificar si ya está declarado en la sección volumes: (después de insertar)
volumes_match = re.search(r'^volumes:(.*?)(?=\nnetworks:|\Z)', content, re.MULTILINE | re.DOTALL)
vol_already_declared = volumes_match and "chatdify_postgres_data:" in volumes_match.group(1)

if not vol_already_declared:
    content = re.sub(
        r'^(volumes:\s*\n)',
        r'\1  chatdify_postgres_data:\n',
        content,
        count=1,
        flags=re.MULTILINE
    )
    print("   ✅ Volumen chatdify_postgres_data declarado en volumes:")
else:
    print("   ℹ️  Volumen chatdify_postgres_data ya declarado en volumes:")

# ── Paso 5: escribir resultado ────────────────────────────────────────────────
with open(OVERRIDE_FILE, "w") as f:
    f.write(content)

print("   ✅ docker-compose.override.yml actualizado correctamente")
PYEOF

unset _PY_OVERRIDE _PY_DB_PASS _PY_BRIDGE

# ----------------------------------------------------------
# Verificar que las redes externas existen en Docker
# ----------------------------------------------------------
for NET in app-network chatwoot-net; do
    if ! docker network inspect "$NET" &>/dev/null; then
        echo "   🔧 Creando red Docker faltante: $NET"
        docker network create "$NET"
    fi
done

# ----------------------------------------------------------
# Validar el override con docker compose config ANTES de
# intentar levantar nada
# ----------------------------------------------------------
echo ""
echo "🔍 Validando docker-compose.override.yml..."
cd "$COMPOSE_DIR"
if docker compose config --quiet 2>/dev/null; then
    echo "   ✅ Configuración válida"
else
    echo ""
    echo "   ❌ El override tiene errores. Output de docker compose config:"
    docker compose config 2>&1 | head -40
    echo ""
    echo "   Puedes inspeccionar el archivo con:"
    echo "   cat $OVERRIDE_FILE"
    exit 1
fi

# ----------------------------------------------------------
# Limpiar volúmenes previos del bridge para evitar
# "password authentication failed" al recrear Postgres
# ----------------------------------------------------------
echo ""
echo "🗑️  Limpiando volúmenes anteriores del bridge..."
for VOL_NAME in \
    "${COMPOSE_PROJECT}_chatdify_postgres_data" \
    "docker_chatdify_postgres_data" \
    "dify_chatdify_postgres_data"; do
    if docker volume inspect "$VOL_NAME" &>/dev/null 2>&1; then
        echo "   Eliminando: $VOL_NAME"
        docker volume rm "$VOL_NAME" 2>/dev/null || true
    fi
done
echo "   ✅ Limpieza completada"

# ----------------------------------------------------------
# Levantar el bridge
# ----------------------------------------------------------
echo ""
echo "🐳 Levantando Chatdify..."
docker compose up -d --force-recreate chatdify-postgres chatdify chatdify-worker
echo "   ✅ Contenedores iniciados"

# ----------------------------------------------------------
# Esperar que el bridge esté listo
# Chatdify expone /health (no /api/v1/health)
# ----------------------------------------------------------
echo ""
echo "⏳ Esperando que Chatdify esté listo (hasta 90s)..."
BRIDGE_READY=false
for i in $(seq 1 18); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 http://localhost:8001/health 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ]; then
        echo ""
        echo "   ✅ Chatdify respondiendo en :8001/health"
        BRIDGE_READY=true
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

if [ "$BRIDGE_READY" = false ]; then
    echo "   ⚠️  Chatdify no respondió en 90s. Revisa los logs:"
    echo "      cd $COMPOSE_DIR && docker compose logs chatdify"
    echo ""
    echo "   Continuando (el webhook se puede configurar manualmente)..."
fi

# ----------------------------------------------------------
# Registrar webhook en Chatwoot automáticamente
#
# Las llamadas a chatwoot-rails:3000 se hacen DENTRO de la red
# Docker vía docker_curl(), ya que ese servicio no expone
# ningún puerto al host.
#
# Los Agent Bots son recursos GLOBALES de superadmin.
# Endpoint: /api/v1/agent_bots  (sin account_id)
# ----------------------------------------------------------
echo ""
echo "🔗 Configurando webhook en Chatwoot..."
echo "   Listando Agent Bots globales..."

CW_BOTS_RESP=$(docker_curl \
    "http://chatwoot-rails:3000/api/v1/agent_bots" \
    -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
    -H "Content-Type: application/json" \
    2>/dev/null || echo "connection_error")

if echo "$CW_BOTS_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    echo "   ✅ Conexión con Chatwoot exitosa"

    BOT_ID=$(echo "$CW_BOTS_RESP" | python3 -c "
import sys, json
try:
    bots = json.load(sys.stdin)
    if not isinstance(bots, list) or len(bots) == 0:
        print('')
        sys.exit(0)
    for b in bots:
        if b.get('name','').lower() == 'dify':
            print(b['id'])
            sys.exit(0)
    print(bots[0]['id'])
except Exception:
    print('')
" 2>/dev/null || echo "")

    if [ -n "$BOT_ID" ]; then
        echo "   📎 Bot ID encontrado: $BOT_ID"
        echo "   🔗 Webhook URL: $WEBHOOK_URL"

        UPDATE_RESP=$(docker_curl \
            -X PATCH "http://chatwoot-rails:3000/api/v1/agent_bots/${BOT_ID}" \
            -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"outgoing_url\": \"$WEBHOOK_URL\"}" \
            2>/dev/null || echo '{"error":"update failed"}')

        if echo "$UPDATE_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sys.exit(0 if 'id' in d else 1)
" 2>/dev/null; then
            echo "   ✅ Agent Bot actualizado correctamente"
            echo "      outgoing_url → $WEBHOOK_URL"
        else
            echo "   ⚠️  No se pudo actualizar el Agent Bot via API"
            echo "      Respuesta: $UPDATE_RESP"
            echo ""
            echo "   📌 Configúralo manualmente en Chatwoot:"
            echo "      Settings → Integrations → Agent Bots → Edit"
            echo "      Outgoing URL: $WEBHOOK_URL"
        fi
    else
        echo "   ⚠️  No se encontró ningún Agent Bot"
        echo ""
        echo "   📌 Crea uno en Chatwoot y configura el webhook:"
        echo "      Settings → Integrations → Agent Bots → New Bot"
        echo "      Outgoing URL: $WEBHOOK_URL"
    fi
else
    echo "   ⚠️  No se pudo conectar con Chatwoot o el Admin Token es incorrecto"
    echo "      Respuesta raw: ${CW_BOTS_RESP:0:300}"
    echo ""
    echo "   📌 Configura el webhook manualmente en Chatwoot:"
    echo "      Settings → Integrations → Agent Bots → Edit"
    echo "      Outgoing URL: $WEBHOOK_URL"
fi

# ----------------------------------------------------------
# Guardar credenciales en .stack.env
# ----------------------------------------------------------
echo ""
echo "💾 Actualizando credenciales en $CREDS_FILE..."
update_or_add "DIFY_API_KEY"            "$DIFY_API_KEY"
update_or_add "CHATWOOT_API_KEY"        "$CHATWOOT_API_KEY"
update_or_add "CHATWOOT_ADMIN_API_KEY"  "$CHATWOOT_ADMIN_API_KEY"
update_or_add "CHATWOOT_ACCOUNT_ID"     "$CHATWOOT_ACCOUNT_ID"
update_or_add "BRIDGE_DB_PASSWORD"      "$BRIDGE_DB_PASSWORD"
update_or_add "BRIDGE_SECRET_KEY"       "$BRIDGE_SECRET_KEY"
update_or_add "BRIDGE_WEBHOOK_URL"      "$WEBHOOK_URL"
echo "   ✅ Credenciales actualizadas"

# ----------------------------------------------------------
# Resumen final
# ----------------------------------------------------------
echo ""
echo "=================================================="
echo "✅ FASE 2 COMPLETA — Bridge activo"
echo "=================================================="
echo ""
echo "🔗 Flujo de mensajes:"
echo ""
echo "   Usuario → Chatwoot → chatdify:8000 → Dify API → chatdify → Chatwoot → Usuario"
echo ""
echo "─────────────────────────────────────────────────"
echo "⚠️  ÚLTIMO PASO MANUAL (1 clic en Chatwoot):"
echo ""
echo "   → $CHATWOOT_URL"
echo "   → Settings → Inboxes → (tu inbox) → Settings → Configuration"
echo "   → Pestaña 'Agent Bots'"
echo "   → Selecciona el Agent Bot 'Dify' → Guardar"
echo ""
echo "─────────────────────────────────────────────────"
echo "🔍 Diagnóstico rápido:"
echo ""
echo "   # Estado de los contenedores del bridge"
echo "   cd $COMPOSE_DIR && docker compose ps chatdify chatdify-worker chatdify-postgres"
echo ""
echo "   # Health check (debe responder 200)"
echo "   curl -sv http://localhost:8001/health"
echo ""
echo "   # Logs en tiempo real"
echo "   cd $COMPOSE_DIR && docker compose logs -f chatdify"
echo "   cd $COMPOSE_DIR && docker compose logs -f chatdify-worker"
echo ""
echo "   # Verificar Agent Bots desde red interna"
echo "   docker run --rm --network app-network curlimages/curl \\"
echo "     http://chatwoot-rails:3000/api/v1/agent_bots \\"
echo "     -H 'api_access_token: \$CHATWOOT_ADMIN_API_KEY'"
echo ""
echo "─────────────────────────────────────────────────"
echo "🔄 Cambiar el API Key de Dify en el futuro:"
echo "   nano $BRIDGE_DIR/.env"
echo "   cd $COMPOSE_DIR && docker compose restart chatdify chatdify-worker"
echo ""
