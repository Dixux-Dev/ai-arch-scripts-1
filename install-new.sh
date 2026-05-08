#!/bin/bash
# =============================================================
# INSTALACIÓN COMPLETA — Dify + Chatwoot + Bridge Chatdify
#
# Uso: bash install-new.sh "token-cloudflare" \
#        "https://dify.dominio.com" "https://chat.dominio.com" \
#        "admin@email.com" "password-admin"
#
# Paso manual después del script (por cada bot):
#   1. Chatwoot → asignar el Agent Bot al inbox correspondiente
#      Settings → Inboxes → (inbox) → Configuration → Agent Bots
#
# Bots: coloca cada bot en bots/<nombre>/workflow.yml
#       El script detecta las carpetas y te deja elegir cuáles instalar.
#
# Arquitectura de redes Docker:
#   default        → red interna de Dify
#   app-network    → red compartida Dify↔Chatwoot (webhooks internos)
#   chatwoot-net   → red interna de Chatwoot + Bridges
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
    echo "Uso: bash install-new.sh \"cf-token\" \\"
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

CREDS_FILE="$HOME/.stack.env"
COMPOSE_DIR="$HOME/dify/docker"
OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOTS_DIR="$SCRIPT_DIR/bots"

# Reutilizar secretos de Chatwoot si ya existen (evita romper volúmenes)
if [ -f "$CREDS_FILE" ] && grep -q "^CHATWOOT_DB_PASSWORD=" "$CREDS_FILE"; then
    CHATWOOT_DB_PASSWORD=$(grep "^CHATWOOT_DB_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2)
    CHATWOOT_SECRET_KEY=$(grep "^CHATWOOT_SECRET_KEY=" "$CREDS_FILE" | cut -d'=' -f2)
    CHATWOOT_REDIS_PASSWORD=$(grep "^CHATWOOT_REDIS_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2)
    NEW_INSTALL=false
    echo "   ♻️  Reutilizando secretos de Chatwoot existentes en $CREDS_FILE"
else
    CHATWOOT_DB_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/' | cut -c1-24)
    CHATWOOT_SECRET_KEY=$(openssl rand -hex 32)
    CHATWOOT_REDIS_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/' | cut -c1-24)
    NEW_INSTALL=true
fi

echo ""
echo "🚀 Instalando stack completo: Dify + Chatwoot + Bridge"
echo "   Dify URL:     $DIFY_URL"
echo "   Chatwoot URL: $CHATWOOT_URL"
echo "   Admin email:  $ADMIN_EMAIL"
echo "=================================================="

# ----------------------------------------------------------
# Helper: actualiza o agrega una clave en .stack.env
# ----------------------------------------------------------
update_or_add() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$CREDS_FILE" 2>/dev/null; then
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
# Helper: crear label en Chatwoot vía red Docker interna.
# 422 = ya existe → warning, no es error fatal (idempotente).
# Usa $CHATWOOT_ACCOUNT_ID y $CHATWOOT_ADMIN_API_KEY (definidas en B1).
# ----------------------------------------------------------
cw_create_label() {
    local title="$1" color="$2"
    local resp
    resp=$(docker_curl -X POST \
        "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/labels" \
        -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"$title\",\"color\":\"$color\",\"show_on_sidebar\":true}" \
        2>/dev/null || echo '{}')
    if echo "$resp" | python3 -c "import sys,json; exit(0 if json.load(sys.stdin).get('id') else 1)" 2>/dev/null; then
        echo "   ✅ Label '$title'"
    else
        echo "   ⚠️  Label '$title' (puede ya existir, se omite)"
    fi
}

# ----------------------------------------------------------
# Helper: crear automation rule simple (1 condición, 1 acción).
# Uso: cw_create_automation <nombre> <event> <attr> <op> <values_json> <action> <param_json>
#   values_json  → array JSON p.ej. '[]' o '["texto"]'
#   param_json   → array JSON p.ej. '["bot-pausa"]' o '[5]'
# ----------------------------------------------------------
cw_create_automation() {
    local name="$1" event="$2" attr="$3" op="$4" values_json="$5" action="$6" param_json="$7"
    local resp
    resp=$(docker_curl -X POST \
        "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/automation_rules" \
        -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$name\",
            \"event_name\": \"$event\",
            \"active\": true,
            \"conditions\": [{
                \"attribute_key\": \"$attr\",
                \"filter_operator\": \"$op\",
                \"values\": $values_json,
                \"query_operator\": null
            }],
            \"actions\": [{
                \"action_name\": \"$action\",
                \"action_params\": $param_json
            }]
        }" 2>/dev/null || echo '{}')
    if echo "$resp" | python3 -c "import sys,json; exit(0 if json.load(sys.stdin).get('id') else 1)" 2>/dev/null; then
        echo "   ✅ Automation '$name'"
    else
        echo "   ⚠️  Automation '$name': $(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(list(d.values())[0] if d else 'error desconocido')" 2>/dev/null | head -c 100)"
    fi
}

# ----------------------------------------------------------
# Helper: crear Knowledge Base en Dify y subir archivos
# Uso: setup_knowledge_base <nombre_kb>
# ----------------------------------------------------------
setup_knowledge_base() {
    local KB_NAME="${1:-Base de Conocimiento}"
    local KB_DIR="$SCRIPT_DIR/knowledge"

    mapfile -t KB_FILES < <(find "$KB_DIR" -maxdepth 1 -type f \
        \( -iname "*.pdf" -o -iname "*.txt" -o -iname "*.md" \
           -o -iname "*.docx" -o -iname "*.csv" \) 2>/dev/null | sort)

    if [ ${#KB_FILES[@]} -eq 0 ]; then
        echo "   ⚠️  knowledge/ sin archivos compatibles — se omite KB."
        return 0
    fi

    # Login a Dify console (mismo patrón que setup_bot)
    local COOKIE_JAR CSRF_TOKEN LOGIN_RESP ENCODED_PASS
    COOKIE_JAR=$(mktemp /tmp/dify-kb-XXXXXX.txt)
    ENCODED_PASS=$(echo -n "$ADMIN_PASSWORD" | base64)
    LOGIN_RESP=$(curl -s -c "$COOKIE_JAR" -X POST "http://localhost/console/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENCODED_PASS\"}" \
        2>/dev/null || echo '{"result":"error"}')
    CSRF_TOKEN=$(grep "csrf_token" "$COOKIE_JAR" | awk '{print $NF}' | tail -1 || echo "")

    if [ -z "$CSRF_TOKEN" ] || ! echo "$LOGIN_RESP" | grep -q '"result":"success"'; then
        echo "   ⚠️  No se pudo autenticar en Dify — KB no creada."
        rm -f "$COOKIE_JAR"; return 0
    fi

    # Reutilizar KB existente si ya fue creada en una instalación previa
    local DATASET_ID
    DATASET_ID=$(grep "^DIFY_KB_ID=" "$CREDS_FILE" 2>/dev/null | cut -d'=' -f2- | head -1 || echo "")

    if [ -z "$DATASET_ID" ]; then
        local DS_RESP
        DS_RESP=$(curl -s -X POST "http://localhost/console/api/datasets" \
            -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            -d "{\"name\":\"$KB_NAME\",\"permission\":\"all_team_members\",
                 \"indexing_technique\":\"high_quality\"}" \
            2>/dev/null || echo '{}')
        DATASET_ID=$(echo "$DS_RESP" | python3 -c \
            "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        if [ -z "$DATASET_ID" ]; then
            echo "   ⚠️  No se pudo crear el dataset: $(echo "$DS_RESP" | head -c 100)"
            rm -f "$COOKIE_JAR"; return 0
        fi
        update_or_add "DIFY_KB_ID" "$DATASET_ID"
        echo "   ✅ Dataset creado (id: $DATASET_ID)"
    else
        echo "   ℹ️  Reutilizando KB existente (id: $DATASET_ID)"
    fi

    # Subir cada archivo
    local ok=0 fail=0
    for fpath in "${KB_FILES[@]}"; do
        local fname; fname=$(basename "$fpath")
        local UPLOAD_RESP
        UPLOAD_RESP=$(curl -s -X POST \
            "http://localhost/console/api/datasets/$DATASET_ID/document/create_by_file" \
            -b "$COOKIE_JAR" -H "X-CSRF-Token: $CSRF_TOKEN" \
            -F "file=@$fpath" \
            -F 'data={"indexing_technique":"high_quality","process_rule":{"mode":"automatic"}}' \
            2>/dev/null || echo '{}')
        if echo "$UPLOAD_RESP" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('document',{}).get('id') else 1)" \
            2>/dev/null; then
            echo "   ✅ $fname"
            ok=$((ok + 1))
        else
            echo "   ⚠️  $fname: $(echo "$UPLOAD_RESP" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(list(d.values())[0] if d else '')" \
                2>/dev/null | head -c 80)"
            fail=$((fail + 1))
        fi
    done

    rm -f "$COOKIE_JAR"
    echo "   📚 KB: $ok archivo(s) subido(s), $fail con error."
}

# ----------------------------------------------------------
# Helper: instalar plugins del marketplace de Dify
# Uso: install_plugins "org/name" ...   (el script obtiene la versión más reciente)
# Flujo: marketplace batch API → latest_package_identifier → Dify Console API install
# ----------------------------------------------------------
install_plugins() {
    local plugins=("$@")
    [ ${#plugins[@]} -eq 0 ] && return 0

    echo ""
    echo "🧩 Instalando plugins en Dify..."

    # Normalizar identificadores a "org/name" (quitar versión si viene como "org/name/version")
    local plugin_ids=()
    local p
    for p in "${plugins[@]}"; do
        # Extraer solo las 2 primeras partes: org/name
        local norm
        norm=$(echo "$p" | awk -F'/' '{print $1"/"$2}')
        plugin_ids+=("$norm")
    done

    # Consultar marketplace batch API para obtener latest_package_identifier (con hash)
    local BATCH_JSON
    BATCH_JSON=$(python3 -c "import json,sys; print(json.dumps({'plugin_ids': sys.argv[1:]}))" "${plugin_ids[@]}")
    local DIFY_VER
    DIFY_VER=$(docker exec docker-api-1 python3 -c \
        "from configs import dify_config; print(dify_config.project.version)" 2>/dev/null || echo "0.15.0")

    local BATCH_RESP
    BATCH_RESP=$(curl -s --max-time 20 \
        "https://marketplace.dify.ai/api/v1/plugins/batch" \
        -H "Content-Type: application/json" \
        -H "X-Dify-Version: $DIFY_VER" \
        -d "$BATCH_JSON" 2>/dev/null || echo '{}')

    local PKG_IDS_JSON
    PKG_IDS_JSON=$(echo "$BATCH_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    plugins = d.get('data', {}).get('plugins', [])
    ids = [p['latest_package_identifier'] for p in plugins if p.get('latest_package_identifier')]
    print(json.dumps(ids))
except:
    print('[]')
" 2>/dev/null || echo "[]")

    if [ "$PKG_IDS_JSON" = "[]" ]; then
        echo "   ⚠️  No se obtuvieron identificadores del marketplace — plugins no instalados."
        echo "      Verifica que los nombres en plugins.list sean correctos (formato: org/name)."
        echo "      Instálalos manualmente: Dify → Plugins → Marketplace."
        return 0
    fi

    local RESOLVED_COUNT
    RESOLVED_COUNT=$(echo "$PKG_IDS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    echo "   📦 Identificadores resueltos: $RESOLVED_COUNT de ${#plugin_ids[@]}"

    # Login a la Dify Console API — tokens en Set-Cookie (Secure → no en curl jar)
    local ENCODED_PASS
    ENCODED_PASS=$(echo -n "$ADMIN_PASSWORD" | base64)
    local HEADERS_FILE
    HEADERS_FILE=$(mktemp /tmp/dify-plugins-hdr-XXXXXX.txt)

    curl -s -D "$HEADERS_FILE" -X POST "http://localhost/console/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENCODED_PASS\"}" \
        > /dev/null 2>/dev/null || true

    local ACCESS_TOKEN CSRF_TOKEN
    ACCESS_TOKEN=$(grep -i "set-cookie.*__Host-access_token=" "$HEADERS_FILE" \
        | sed 's/.*__Host-access_token=\([^;]*\).*/\1/' | head -1 || echo "")
    CSRF_TOKEN=$(grep -i "set-cookie.*__Host-csrf_token=" "$HEADERS_FILE" \
        | sed 's/.*__Host-csrf_token=\([^;]*\).*/\1/' | head -1 || echo "")
    rm -f "$HEADERS_FILE"

    if [ -z "$ACCESS_TOKEN" ]; then
        echo "   ⚠️  Login en Dify falló — plugins no instalados."
        echo "      Instálalos manualmente: Dify → Plugins → Marketplace."
        return 0
    fi

    # Llamar al endpoint de instalación — inyectar cookies Secure manualmente
    local INSTALL_RESP
    INSTALL_RESP=$(curl -s --max-time 90 \
        -X POST "http://localhost/console/api/workspaces/current/plugin/install/marketplace" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "X-CSRF-Token: $CSRF_TOKEN" \
        -H "Cookie: __Host-access_token=$ACCESS_TOKEN; __Host-csrf_token=$CSRF_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"plugin_unique_identifiers\":$PKG_IDS_JSON}" \
        2>/dev/null || echo '{}')

    # Respuesta exitosa: {"all_installed": bool, "task_id": "uuid"}
    local TASK_ID
    TASK_ID=$(echo "$INSTALL_RESP" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('task_id') or '')
except: pass
" 2>/dev/null || echo "")

    if [ -n "$TASK_ID" ]; then
        PLUGIN_INSTALL_TASK_ID="$TASK_ID"
        echo "   ✅ Instalación iniciada (task: ${TASK_ID:0:8}...)"
        echo "   ℹ️  Los plugins aparecerán en Dify → Plugins en ~30 segundos."
    else
        echo "   ⚠️  Respuesta inesperada al instalar plugins:"
        echo "      $(echo "$INSTALL_RESP" | head -c 200)"
        echo "      Instálalos manualmente: Dify → Plugins → Marketplace."
    fi
}

# ----------------------------------------------------------
# Helper: guardar credenciales de plugins via Dify Console API
# Uso: configure_plugins "org/name|tipo:campo:provider_id|valor" ...
# tipo = model | tool
# ----------------------------------------------------------
configure_plugins() {
    local entries=("$@")
    [ ${#entries[@]} -eq 0 ] && return 0

    echo ""
    echo "🔑 Configurando credenciales de plugins..."

    local ENCODED_PASS HEADERS_FILE ACCESS_TOKEN CSRF_TOKEN
    ENCODED_PASS=$(echo -n "$ADMIN_PASSWORD" | base64)
    HEADERS_FILE=$(mktemp /tmp/dify-cfg-hdr-XXXXXX.txt)
    curl -s -D "$HEADERS_FILE" -X POST "http://localhost/console/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENCODED_PASS\"}" > /dev/null 2>/dev/null || true
    ACCESS_TOKEN=$(grep -i "set-cookie.*__Host-access_token=" "$HEADERS_FILE" \
        | sed 's/.*__Host-access_token=\([^;]*\).*/\1/' | head -1 || echo "")
    CSRF_TOKEN=$(grep -i "set-cookie.*__Host-csrf_token=" "$HEADERS_FILE" \
        | sed 's/.*__Host-csrf_token=\([^;]*\).*/\1/' | head -1 || echo "")
    rm -f "$HEADERS_FILE"

    if [ -z "$ACCESS_TOKEN" ]; then
        echo "   ⚠️  Login en Dify falló — credenciales no configuradas."
        return 0
    fi

    local entry
    for entry in "${entries[@]}"; do
        local plugin_id cfg value type field provider_id endpoint CRED_JSON RESP
        plugin_id=$(echo "$entry" | cut -d'|' -f1)
        cfg=$(echo "$entry"       | cut -d'|' -f2)
        value=$(echo "$entry"     | cut -d'|' -f3)
        type=$(echo "$cfg"        | cut -d':' -f1)
        field=$(echo "$cfg"       | cut -d':' -f2)
        provider_id=$(echo "$cfg" | cut -d':' -f3)

        if [ "$type" = "model" ]; then
            # Model providers: POST .../model-providers/<path>/credentials
            endpoint="http://localhost/console/api/workspaces/current/model-providers/$provider_id/credentials"
            CRED_JSON=$(python3 -c "
import json, sys
print(json.dumps({'credentials': {sys.argv[1]: sys.argv[2]}}))" \
                "$field" "$value" 2>/dev/null || echo "{}")
        else
            # Tool providers (marketplace plugins): POST .../tool-provider/builtin/<path>/add
            # Requiere campo 'type' y 'name' adicionales
            endpoint="http://localhost/console/api/workspaces/current/tool-provider/builtin/$provider_id/add"
            CRED_JSON=$(python3 -c "
import json, sys
print(json.dumps({'credentials': {sys.argv[1]: sys.argv[2]}, 'type': 'api-key', 'name': 'API KEY 1'}))" \
                "$field" "$value" 2>/dev/null || echo "{}")
        fi

        RESP=$(curl -s --max-time 20 -X POST "$endpoint" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            -H "Cookie: __Host-access_token=$ACCESS_TOKEN; __Host-csrf_token=$CSRF_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$CRED_JSON" 2>/dev/null || echo '{}')

        if echo "$RESP" | grep -q '"result":"success"'; then
            echo "   ✅ $(echo "$plugin_id" | cut -d'/' -f2) — credencial guardada"
        else
            echo "   ⚠️  $(echo "$plugin_id" | cut -d'/' -f2): $(echo "$RESP" | head -c 150)"
            echo "      Configúralo manualmente en Dify → Settings → Plugins / Model Providers."
        fi
    done
}

# ----------------------------------------------------------
# Helper: espera a que los plugins instalados estén listos
# Sondea el task_id del daemon vía Console API hasta que todos
# los plugins aparezcan instalados, o hasta timeout.
# ----------------------------------------------------------
PLUGIN_INSTALL_TASK_ID=""

wait_plugins_installed() {
    local task_id="$1"
    [ -z "$task_id" ] && return 0

    echo ""
    echo "⏳ Esperando instalación de plugins (hasta 2 min)..."

    local ENCODED_PASS HEADERS_FILE ACCESS_TOKEN CSRF_TOKEN
    ENCODED_PASS=$(echo -n "$ADMIN_PASSWORD" | base64)
    HEADERS_FILE=$(mktemp /tmp/dify-wait-hdr-XXXXXX.txt)
    curl -s -D "$HEADERS_FILE" -X POST "http://localhost/console/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ENCODED_PASS\"}" > /dev/null 2>/dev/null || true
    ACCESS_TOKEN=$(grep -i "set-cookie.*__Host-access_token=" "$HEADERS_FILE" \
        | sed 's/.*__Host-access_token=\([^;]*\).*/\1/' | head -1 || echo "")
    CSRF_TOKEN=$(grep -i "set-cookie.*__Host-csrf_token=" "$HEADERS_FILE" \
        | sed 's/.*__Host-csrf_token=\([^;]*\).*/\1/' | head -1 || echo "")
    rm -f "$HEADERS_FILE"

    if [ -z "$ACCESS_TOKEN" ]; then
        echo "   ⚠️  No se pudo autenticar para verificar estado — esperando 60s..."
        sleep 60
        return 0
    fi

    local i
    for i in $(seq 1 24); do  # 24 × 5s = 2 min máximo
        local STATUS_RESP
        STATUS_RESP=$(curl -s --max-time 10 \
            "http://localhost/console/api/workspaces/current/plugin/tasks/$task_id" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "X-CSRF-Token: $CSRF_TOKEN" \
            -H "Cookie: __Host-access_token=$ACCESS_TOKEN; __Host-csrf_token=$CSRF_TOKEN" \
            2>/dev/null || echo '{}')

        local DONE
        DONE=$(echo "$STATUS_RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    data = d.get('data', d)
    # all_installed flag (install endpoint response reutilizado)
    if data.get('all_installed'):
        print('done'); sys.exit(0)
    # status string
    status = (data.get('status') or '').lower()
    if status in ('completed', 'success', 'done', 'finished', 'installed'):
        print('done'); sys.exit(0)
    # progreso numérico
    total = data.get('total_plugins') or data.get('total', 0)
    done  = data.get('completed_plugins') or data.get('completed') or data.get('installed', 0)
    if total and total == done:
        print('done'); sys.exit(0)
    print('pending')
except:
    print('unknown')
" 2>/dev/null || echo "unknown")

        if [ "$DONE" = "done" ]; then
            echo "   ✅ Plugins listos"
            return 0
        fi
        echo -n "."
        sleep 5
    done

    echo ""
    echo "   ⚠️  Timeout — continuando con la configuración de todas formas"
    return 0
}

# ----------------------------------------------------------
# Helper: selector interactivo con flechas en consola
#
# Uso: multiselect <result_var> <título> "valor1|Etiqueta 1" "valor2|Etiqueta 2" ...
#   ↑↓  navegar   ESPACIO  marcar/desmarcar   ENTER  confirmar
# Almacena los valores seleccionados en el array <result_var>.
# ----------------------------------------------------------
multiselect() {
    local result_var="$1"
    local title="$2"
    shift 2

    local values=() labels=()
    local item
    for item in "$@"; do
        values+=("${item%%|*}")
        labels+=("${item#*|}")
    done

    local count=${#values[@]}
    local cursor=0
    local selected=()
    local i
    for ((i=0; i<count; i++)); do selected[$i]=0; done

    trap 'tput cnorm 2>/dev/null; echo ""; exit 0' INT
    tput civis 2>/dev/null || true

    _ms_draw() {
        local j
        for ((j=0; j<count; j++)); do
            if [ "$j" -eq "$cursor" ]; then
                printf " \e[36m▶\e[0m "
            else
                printf "   "
            fi
            if [ "${selected[$j]}" -eq 1 ]; then
                printf "\e[32m●\e[0m \e[1m%s\e[0m\n" "${labels[$j]}"
            else
                printf "\e[90m○\e[0m %s\n" "${labels[$j]}"
            fi
        done
    }

    echo ""
    printf "  \e[1m%s\e[0m\n" "$title"
    printf "  \e[2m↑↓ navegar   ESPACIO seleccionar   ENTER confirmar\e[0m\n"
    echo ""
    _ms_draw   # dibujo inicial — cursor queda al final de la lista

    local key esc_seq
    while true; do
        IFS= read -r -s -n1 key || true

        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n2 esc_seq 2>/dev/null || true
            case "$esc_seq" in
                '[A') if [ "$cursor" -gt 0 ]; then cursor=$((cursor - 1)); fi ;;
                '[B') if [ "$cursor" -lt $((count - 1)) ]; then cursor=$((cursor + 1)); fi ;;
            esac
        elif [[ "$key" == ' ' ]]; then
            if [ "${selected[$cursor]}" -eq 1 ]; then
                selected[$cursor]=0
            else
                selected[$cursor]=1
            fi
        elif [[ "$key" == '' ]]; then
            break
        fi

        # Redibujar: subir N líneas y sobreescribir
        tput cuu "$count" 2>/dev/null || true
        _ms_draw
    done

    echo ""
    tput cnorm 2>/dev/null || true
    trap - INT

    local result_items=()
    for ((i=0; i<count; i++)); do
        if [ "${selected[$i]}" -eq 1 ]; then
            result_items+=("${values[$i]}")
        fi
    done

    eval "${result_var}=(\"\${result_items[@]}\")"
}

# Helper: confirmación si/no en consola (sin popup)
confirm_yesno() {
    local prompt="$1"
    local answer
    printf "\n  \e[1m%s\e[0m [s/N]: " "$prompt"
    read -r answer
    [[ "$answer" =~ ^[sS]$ ]]
}

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

DIFY_COMPOSE="$COMPOSE_DIR/docker-compose.yaml"

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

cd "$COMPOSE_DIR"

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
# 6. docker-compose.override.yml (base — bridges se agregan después)
#
# DISEÑO DE REDES:
#   default      → red interna de Dify (nginx, api, worker, web, db, redis)
#   app-network  → red compartida Dify↔Chatwoot para webhooks internos
#   chatwoot-net → red interna de Chatwoot + Bridges
#
# TUNNEL:
#   Un solo cloudflared, un token, múltiples hostnames en Zero Trust:
#     dify.dominio.com  → http://nginx:80
#     chat.dominio.com  → http://chatwoot-rails:3000
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
# 7. Limpiar estado inconsistente y levantar servicios base
# ----------------------------------------------------------
echo ""
echo "🧹 Limpiando contenedores y redes huérfanas..."
docker compose down --remove-orphans 2>/dev/null || true

if [ "$NEW_INSTALL" = "true" ]; then
    echo "🗑️  Limpiando volúmenes de Chatwoot de instalaciones anteriores..."
    COMPOSE_PROJECT=$(docker compose config --format json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','docker'))" \
        2>/dev/null || echo "docker")
    for VOL in chatwoot_postgres_data chatwoot_redis_data chatwoot_storage; do
        FULL_VOL="${COMPOSE_PROJECT}_${VOL}"
        if docker volume inspect "$FULL_VOL" &>/dev/null 2>&1; then
            docker volume rm "$FULL_VOL" 2>/dev/null || true
            echo "   Eliminado: $FULL_VOL"
        fi
    done
fi

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
# 10+11. Esperar Dify y configurar admin
# ----------------------------------------------------------
echo ""
echo "⏳ Esperando que Dify esté listo y configurando admin (hasta 5 min)..."

DIFY_INTERNAL="http://localhost/console/api"
DIFY_SETUP_DONE=false

for attempt in $(seq 1 60); do
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
            echo ""
            echo "   ✅ Admin de Dify creado: $ADMIN_EMAIL"
            DIFY_SETUP_DONE=true
            break
        elif echo "$SETUP_RESP" | grep -q '"already_setup"'; then
            echo ""
            echo "   ⚠️  Dify ya tiene admin configurado, omitiendo"
            DIFY_SETUP_DONE=true
            break
        else
            echo ""
            echo "   ⚠️  Setup respondió inesperadamente (intento $attempt): $SETUP_RESP"
            sleep 5
            continue
        fi
    elif [ "$HTTP_CODE" = "403" ]; then
        echo ""
        echo "   ⚠️  Dify ya tiene admin configurado, omitiendo"
        DIFY_SETUP_DONE=true
        break
    else
        echo -n "."
        sleep 5
    fi
done

# Garantizar que dify_setups tiene la fila que Dify consulta para determinar setup state.
# Si el admin ya existía de una instalación anterior, el POST /setup puede fallar con un error
# inesperado sin que se inserte esa fila, dejando Dify en estado "not_started" indefinidamente.
DB_ROWS=$(docker exec docker-db_postgres-1 \
    psql -U postgres -d dify -tAc \
    "SELECT COUNT(*) FROM dify_setups;" 2>/dev/null || echo "0")
DB_ROWS="${DB_ROWS//[[:space:]]/}"
if [ "${DB_ROWS:-0}" = "0" ]; then
    echo "   🔧 Tabla dify_setups vacía — insertando fila..."
    DIFY_VERSION_VAL=$(docker exec docker-api-1 printenv DIFY_VERSION 2>/dev/null || echo "1.14.0")
    docker exec docker-db_postgres-1 \
        psql -U postgres -d dify -c \
        "INSERT INTO dify_setups (version, setup_at) VALUES ('${DIFY_VERSION_VAL}', NOW()) ON CONFLICT DO NOTHING;" \
        2>/dev/null && echo "   ✅ dify_setups corregida" || true
    DIFY_SETUP_DONE=true
fi

if [ "$DIFY_SETUP_DONE" = false ]; then
    echo ""
    echo "   ⚠️  No se pudo configurar el admin de Dify automáticamente."
    echo "   Hazlo manualmente en: $DIFY_URL"
fi

# ----------------------------------------------------------
# 12. Setup admin de Chatwoot
# ----------------------------------------------------------
echo ""
echo "👤 Configurando admin de Chatwoot..."

CW_ADMIN_RESULT=$(docker compose exec -T chatwoot-rails \
    bundle exec rails runner \
    "
    begin
      user = User.find_by(email: '$ADMIN_EMAIL')
      if user.nil?
        user = User.new(
          name: 'Admin',
          email: '$ADMIN_EMAIL',
          password: '$ADMIN_PASSWORD',
          password_confirmation: '$ADMIN_PASSWORD',
          confirmed_at: Time.now
        )
        unless user.save
          puts 'error: ' + user.errors.full_messages.join(', ')
          exit
        end
      end

      account = Account.first || Account.create!(name: 'Default')

      unless AccountUser.exists?(account_id: account.id, user_id: user.id)
        AccountUser.create!(account: account, user: user, role: :administrator)
      end
      ::Redis::Alfred.delete(::Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)
      if AccountUser.exists?(account_id: account.id, user_id: user.id)
        puts 'created'
      else
        puts 'already_exists'
      end
    rescue => e
      puts 'exception: ' + e.message
    end
    " 2>/dev/null | tail -1 || echo "error")

if echo "$CW_ADMIN_RESULT" | grep -q "created"; then
    echo "   ✅ Admin de Chatwoot creado: $ADMIN_EMAIL"
elif echo "$CW_ADMIN_RESULT" | grep -q "already_exists"; then
    echo "   ⚠️  Chatwoot ya tiene ese usuario configurado, omitiendo"
else
    echo "   ⚠️  No se pudo crear admin de Chatwoot: $CW_ADMIN_RESULT"
    echo "   Hazlo manualmente en: $CHATWOOT_URL"
fi

# ══════════════════════════════════════════════════════════════
# FASE 2 — Bridges Chatwoot ↔ Dify
# ══════════════════════════════════════════════════════════════
echo ""
echo "🔗 Configurando Bridges Chatwoot ↔ Dify..."
echo "=================================================="

COMPOSE_PROJECT=$(docker compose config --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','docker'))" \
    2>/dev/null || echo "docker")
echo "ℹ️  Proyecto Docker Compose detectado: $COMPOSE_PROJECT"

# ----------------------------------------------------------
# B1. Auto-derivar credenciales de Chatwoot desde el contenedor
# ----------------------------------------------------------
echo ""
echo "🔑 Obteniendo credenciales de Chatwoot automáticamente..."

CW_CREDS=$((cd "$COMPOSE_DIR" && docker compose exec -T chatwoot-rails \
    bundle exec rails runner \
    "begin
       user = User.find_by(email: '$ADMIN_EMAIL')
       account = Account.first
       raise 'usuario no encontrado' unless user
       raise 'cuenta no encontrada' unless account
       puts user.access_token.token + '|' + account.id.to_s
     rescue => e
       puts 'error: ' + e.message
     end") 2>/dev/null | tail -1 || echo "error: exec failed")

if echo "$CW_CREDS" | grep -q "^error:"; then
    echo "❌ No se pudieron obtener credenciales de Chatwoot: $CW_CREDS"
    exit 1
fi

CHATWOOT_ADMIN_API_KEY=$(echo "$CW_CREDS" | cut -d'|' -f1)
CHATWOOT_ACCOUNT_ID=$(echo "$CW_CREDS" | cut -d'|' -f2)

if [ -z "$CHATWOOT_ADMIN_API_KEY" ] || [ -z "$CHATWOOT_ACCOUNT_ID" ]; then
    echo "❌ Respuesta inesperada del rails runner: '$CW_CREDS'"
    exit 1
fi

echo "   ✅ Account ID: $CHATWOOT_ACCOUNT_ID"
echo "   ✅ Admin token obtenido"

# Obtener ID numérico del admin (necesario para automation de escalación)
CHATWOOT_ADMIN_USER_ID=$(docker_curl \
    "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/agents" \
    -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
    2>/dev/null | python3 -c "
import sys, json
try:
    agents = json.load(sys.stdin)
    email = '$ADMIN_EMAIL'.lower()
    for a in (agents if isinstance(agents, list) else []):
        if a.get('email','').lower() == email:
            print(a['id']); break
except: pass
" 2>/dev/null || echo "")

if [ -n "$CHATWOOT_ADMIN_USER_ID" ]; then
    echo "   ✅ Admin user ID: $CHATWOOT_ADMIN_USER_ID"
else
    echo "   ⚠️  No se pudo obtener admin user ID — escalación sin asignación automática"
fi

# ----------------------------------------------------------
# Guardar credenciales compartidas antes del loop de bots
# ----------------------------------------------------------
echo ""
echo "💾 Guardando credenciales compartidas en $CREDS_FILE..."

cat > "$CREDS_FILE" << EOF
# Stack Dify + Chatwoot + Bridge — $(date)
# ¡PROTEGE ESTE ARCHIVO! Contiene secretos de producción.

ADMIN_EMAIL=$ADMIN_EMAIL

# ── Dify ─────────────────────────────────────────────────────
DIFY_URL=$DIFY_URL

# ── Chatwoot ──────────────────────────────────────────────────
CHATWOOT_URL=$CHATWOOT_URL
CHATWOOT_DB_PASSWORD=$CHATWOOT_DB_PASSWORD
CHATWOOT_SECRET_KEY=$CHATWOOT_SECRET_KEY
CHATWOOT_REDIS_PASSWORD=$CHATWOOT_REDIS_PASSWORD
CHATWOOT_ADMIN_API_KEY=$CHATWOOT_ADMIN_API_KEY
CHATWOOT_ACCOUNT_ID=$CHATWOOT_ACCOUNT_ID

# ── Bots (generado por setup_bot) ─────────────────────────────
EOF
chmod 600 "$CREDS_FILE"
echo "   ✅ Credenciales compartidas guardadas"

# ----------------------------------------------------------
# 13. Labels y automatizaciones de control de bot en Chatwoot
# ----------------------------------------------------------
echo ""
echo "🏷️  Creando labels de control de bot en Chatwoot..."

cw_create_label "bot-activo" "#28a745"   # verde  — bot respondiendo
cw_create_label "bot-pausa"  "#fd7e14"   # naranja — agente humano al mando
cw_create_label "escalado"   "#dc3545"   # rojo    — escalado a humano

echo ""
echo "⚙️  Creando automatizaciones de Chatwoot..."

# A: Agente asignado → agregar label bot-pausa (tracking visual automático)
cw_create_automation \
    "[BOT] Agente asignado — pausa bot" \
    "conversation_updated" "assignee_id" "is_present" \
    '[]' "add_label" '["bot-pausa"]'

# B: Sin agente asignado → agregar label bot-activo
cw_create_automation \
    "[BOT] Sin agente — bot activo" \
    "conversation_updated" "assignee_id" "not_present" \
    '[]' "add_label" '["bot-activo"]'

# C: Escalación desde Dify — frase específica → label escalado + asignar admin
echo -n "   "
ESCALAR_PHRASE="Voy a transferirte con un agente"
AUTO_C_ACTIONS="[{\"action_name\":\"add_label\",\"action_params\":[\"escalado\"]}"
if [ -n "$CHATWOOT_ADMIN_USER_ID" ]; then
    AUTO_C_ACTIONS="${AUTO_C_ACTIONS},{\"action_name\":\"assign_an_agent\",\"action_params\":[$CHATWOOT_ADMIN_USER_ID]}"
fi
AUTO_C_ACTIONS="${AUTO_C_ACTIONS}]"

AUTO_C=$(docker_curl -X POST \
    "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/automation_rules" \
    -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"[BOT] Escalacion Dify — asignar agente\",
        \"event_name\": \"message_created\",
        \"active\": true,
        \"conditions\": [{
            \"attribute_key\": \"content\",
            \"filter_operator\": \"contains\",
            \"values\": [\"$ESCALAR_PHRASE\"],
            \"query_operator\": null
        }],
        \"actions\": $AUTO_C_ACTIONS
    }" 2>/dev/null || echo '{}')

if echo "$AUTO_C" | python3 -c "import sys,json; exit(0 if json.load(sys.stdin).get('id') else 1)" 2>/dev/null; then
    echo "✅ Automation '[BOT] Escalacion Dify — asignar agente'"
else
    echo "⚠️  Automation escalación: $(echo "$AUTO_C" | head -c 150)"
fi

# ----------------------------------------------------------
# 14. Knowledge Base (opcional)
# ----------------------------------------------------------
echo ""
KB_DIR="$SCRIPT_DIR/knowledge"
if find "$KB_DIR" -maxdepth 1 -type f \
    \( -iname "*.pdf" -o -iname "*.txt" -o -iname "*.md" \
       -o -iname "*.docx" -o -iname "*.csv" \) 2>/dev/null | grep -q .; then
    if confirm_yesno "Se encontraron documentos en knowledge/ — ¿crear Knowledge Base en Dify y cargarlos?"; then
        echo "📚 Configurando Knowledge Base..."
        setup_knowledge_base "Base de Conocimiento"
    else
        echo "ℹ️  Knowledge Base omitida."
    fi
else
    echo "ℹ️  knowledge/ vacía — Knowledge Base omitida."
    echo "   Agrega archivos PDF/TXT/MD/DOCX/CSV y re-ejecuta para crearla."
fi

# ----------------------------------------------------------
# 15. Selección de plugins del marketplace
# ----------------------------------------------------------
echo ""
echo "🧩 Selección de plugins"
echo "=================================================="

PLUGINS_FILE="$SCRIPT_DIR/plugins.list"
SELECTED_PLUGINS=()

declare -A PLUGIN_CONFIG_MAP

if [ -f "$PLUGINS_FILE" ] && grep -q "^[^#]" "$PLUGINS_FILE" 2>/dev/null; then
    PLUGIN_MENU_ITEMS=()
    while IFS='|' read -r pid desc cfg; do
        [[ "$pid" =~ ^[[:space:]]*# ]] && continue
        [ -z "${pid// /}" ] && continue
        pid="${pid// /}"
        cfg="${cfg// /}"
        PLUGIN_MENU_ITEMS+=("$pid|${desc:-$pid}")
        [ -n "$cfg" ] && PLUGIN_CONFIG_MAP["$pid"]="$cfg"
    done < "$PLUGINS_FILE"

    if [ ${#PLUGIN_MENU_ITEMS[@]} -gt 0 ]; then
        multiselect SELECTED_PLUGINS "Plugins del Marketplace" "${PLUGIN_MENU_ITEMS[@]}"
        if [ ${#SELECTED_PLUGINS[@]} -gt 0 ]; then
            echo "   🧩 Plugins seleccionados: ${SELECTED_PLUGINS[*]}"

            # Pedir API keys para los plugins que las requieren
            PLUGIN_API_KEYS=()
            for _plugin in "${SELECTED_PLUGINS[@]}"; do
                _cfg="${PLUGIN_CONFIG_MAP[$_plugin]:-}"
                [ -z "$_cfg" ] && continue
                _pname=$(echo "$_plugin" | cut -d'/' -f2)
                _field=$(echo "$_cfg" | cut -d':' -f2)
                printf "\n  🔑 \e[1m%s\e[0m — %s (vacío para omitir): " "$_pname" "$_field"
                read -r _key_val
                [ -n "$_key_val" ] && PLUGIN_API_KEYS+=("$_plugin|$_cfg|$_key_val")
            done
        else
            echo "   ℹ️  Ningún plugin seleccionado."
        fi
    fi
else
    echo "   ℹ️  plugins.list no encontrado o vacío — se omite selección de plugins."
fi

# ----------------------------------------------------------
# Selección de bots
# ----------------------------------------------------------
echo ""
echo "📦 Selección de bots"
echo "=================================================="

BOT_LIST=()
while IFS= read -r dir; do
    if [ -f "$dir/workflow.yml" ]; then
        BOT_LIST+=("$(basename "$dir")")
    fi
done < <(find "$BOTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

if [ ${#BOT_LIST[@]} -eq 0 ]; then
    echo "❌ No se encontraron bots en $BOTS_DIR"
    echo "   Crea una carpeta con un archivo workflow.yml dentro."
    exit 1
fi

BOT_MENU_ITEMS=()
for bot in "${BOT_LIST[@]}"; do
    BOT_MENU_ITEMS+=("$bot|$bot")
done

multiselect SELECTED_BOTS "Selecciona los bots a instalar" "${BOT_MENU_ITEMS[@]}"

if [ ${#SELECTED_BOTS[@]} -eq 0 ]; then
    echo "❌ No se seleccionó ningún bot."
    exit 1
fi

echo ""
echo "🤖 Bots seleccionados: ${SELECTED_BOTS[*]}"

# ----------------------------------------------------------
# Función: setup_bot <slug> <port>
#
# Instala un bot completo:
#   - Importa workflow.yml en Dify → obtiene DIFY_API_KEY
#   - Crea/actualiza Agent Bot en Chatwoot → obtiene bot token
#   - Escribe .env del bridge
#   - Agrega servicios al docker-compose.override.yml
#   - Levanta los contenedores
#   - Espera health check
#   - Guarda credenciales en ~/.stack.env
# ----------------------------------------------------------
setup_bot() {
    local BOT_SLUG="$1"
    local PORT="$2"
    local BOT_SLUG_UPPER="${BOT_SLUG^^}"
    BOT_SLUG_UPPER="${BOT_SLUG_UPPER//-/_}"
    local BOT_DIR_SRC="$BOTS_DIR/$BOT_SLUG"
    local BOT_ENV_DIR="$HOME/chatdify/$BOT_SLUG.bot.env"
    local WEBHOOK_URL="http://chatdify-${BOT_SLUG}:8000/api/v1/chatwoot-webhook"
    local VOL_SLUG="${BOT_SLUG//-/_}"
    local REDIS_DB="$((PORT - 8000))"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🤖 Bot: $BOT_SLUG  (puerto $PORT)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # -- Reutilizar o generar secretos por bot --
    local BOT_DB_PASSWORD BOT_NEW_INSTALL
    if grep -q "^BOT_${BOT_SLUG_UPPER}_DB_PASSWORD=" "$CREDS_FILE" 2>/dev/null; then
        BOT_DB_PASSWORD=$(grep "^BOT_${BOT_SLUG_UPPER}_DB_PASSWORD=" "$CREDS_FILE" | cut -d'=' -f2)
        BOT_NEW_INSTALL=false
        echo "   ♻️  Reutilizando secretos de $BOT_SLUG"
    else
        BOT_DB_PASSWORD=$(openssl rand -base64 20 | tr -d '=+/' | cut -c1-24)
        BOT_NEW_INSTALL=true
    fi

    # ── B1. Importar workflow en Dify ──────────────────────────────────────────
    echo ""
    echo "📦 Importando workflow '$BOT_SLUG' en Dify..."

    local DIFY_API_KEY=""
    local DIFY_DSL
    DIFY_DSL=$(cat "$BOT_DIR_SRC/workflow.yml")

    local DIFY_COOKIE_JAR
    DIFY_COOKIE_JAR=$(mktemp /tmp/dify-cookies-XXXXXX.txt)

    local ENCODED_PASSWORD LOGIN_RESP DIFY_CSRF_TOKEN
    ENCODED_PASSWORD=$(echo -n "$ADMIN_PASSWORD" | base64)
    LOGIN_RESP=$(curl -s -c "$DIFY_COOKIE_JAR" \
        -X POST "http://localhost/console/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$ADMIN_EMAIL\", \"password\": \"$ENCODED_PASSWORD\"}" \
        2>/dev/null || echo '{"result":"error"}')
    DIFY_CSRF_TOKEN=$(grep "csrf_token" "$DIFY_COOKIE_JAR" | awk '{print $NF}' | tail -1 || echo "")

    if [ -z "$DIFY_CSRF_TOKEN" ] || ! echo "$LOGIN_RESP" | grep -q '"result":"success"'; then
        echo "   ⚠️  No se pudo autenticar en Dify console — workflow no importado"
        echo "      Respuesta: $(echo "$LOGIN_RESP" | head -c 200)"
    else
        local IMPORT_PAYLOAD IMPORT_RESP DIFY_APP_ID
        IMPORT_PAYLOAD=$(jq -n --arg yaml "$DIFY_DSL" '{"mode":"yaml-content","yaml_content":$yaml}')
        IMPORT_RESP=$(curl -s -X POST "http://localhost/console/api/apps/imports" \
            -b "$DIFY_COOKIE_JAR" -c "$DIFY_COOKIE_JAR" \
            -H "Content-Type: application/json" \
            -H "X-CSRF-Token: $DIFY_CSRF_TOKEN" \
            -d "$IMPORT_PAYLOAD" \
            2>/dev/null || echo '{}')
        DIFY_CSRF_TOKEN=$(grep "csrf_token" "$DIFY_COOKIE_JAR" | awk '{print $NF}' | tail -1 || echo "$DIFY_CSRF_TOKEN")

        DIFY_APP_ID=$(echo "$IMPORT_RESP" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('app_id',''))" \
            2>/dev/null || echo "")

        if [ -z "$DIFY_APP_ID" ]; then
            echo "   ⚠️  No se pudo importar el workflow: $(echo "$IMPORT_RESP" | head -c 300)"
        else
            echo "   ✅ Workflow importado (app_id: $DIFY_APP_ID)"

            local APIKEY_RESP
            APIKEY_RESP=$(curl -s -X POST "http://localhost/console/api/apps/$DIFY_APP_ID/api-keys" \
                -b "$DIFY_COOKIE_JAR" -c "$DIFY_COOKIE_JAR" \
                -H "Content-Type: application/json" \
                -H "X-CSRF-Token: $DIFY_CSRF_TOKEN" \
                2>/dev/null || echo '{}')

            DIFY_API_KEY=$(echo "$APIKEY_RESP" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" \
                2>/dev/null || echo "")

            if [ -n "$DIFY_API_KEY" ]; then
                echo "   ✅ API key generado: ${DIFY_API_KEY:0:16}..."
            else
                echo "   ⚠️  No se pudo generar API key: $(echo "$APIKEY_RESP" | head -c 200)"
            fi

            # ── Publicar workflow ──────────────────────────────────────────────
            local PUBLISH_RESP
            PUBLISH_RESP=$(curl -s -X POST \
                "http://localhost/console/api/apps/$DIFY_APP_ID/workflows/publish" \
                -b "$DIFY_COOKIE_JAR" -c "$DIFY_COOKIE_JAR" \
                -H "Content-Type: application/json" \
                -H "X-CSRF-Token: $DIFY_CSRF_TOKEN" \
                -d '{}' \
                2>/dev/null || echo '{}')

            if echo "$PUBLISH_RESP" | grep -q '"result":"success"'; then
                echo "   ✅ Workflow publicado"
            else
                echo "   ⚠️  No se pudo publicar automáticamente: $(echo "$PUBLISH_RESP" | head -c 150)"
                echo "      Publícalo manualmente: $DIFY_URL → app → botón Publicar"
            fi
        fi
    fi

    rm -f "$DIFY_COOKIE_JAR"

    # ── B2. Crear o actualizar Agent Bot en Chatwoot ───────────────────────────
    echo ""
    echo "🤖 Configurando Agent Bot '$BOT_SLUG' en Chatwoot..."

    local BOTS_RESP
    BOTS_RESP=$(docker_curl \
        "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/agent_bots" \
        -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
        2>/dev/null || echo "connection_error")

    if ! echo "$BOTS_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "❌ No se pudo conectar con Chatwoot"
        echo "   Respuesta raw: ${BOTS_RESP:0:300}"
        return 1
    fi
    echo "   ✅ Conexión con Chatwoot exitosa"

    local BOT_ID
    BOT_ID=$(echo "$BOTS_RESP" | python3 -c "
import sys, json
bots = json.load(sys.stdin)
slug = '${BOT_SLUG}'.lower()
for b in bots:
    if b.get('name','').lower() == slug:
        print(b['id']); sys.exit(0)
print('')
" 2>/dev/null || echo "")

    local BOT_RESP
    if [ -n "$BOT_ID" ]; then
        BOT_RESP=$(docker_curl \
            -X PATCH "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/agent_bots/$BOT_ID" \
            -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"outgoing_url\": \"$WEBHOOK_URL\"}" \
            2>/dev/null || echo '{}')
        echo "   ✅ Agent Bot '$BOT_SLUG' existente actualizado (ID: $BOT_ID)"
    else
        BOT_RESP=$(docker_curl \
            -X POST "http://chatwoot-rails:3000/api/v1/accounts/$CHATWOOT_ACCOUNT_ID/agent_bots" \
            -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${BOT_SLUG}\", \"outgoing_url\": \"$WEBHOOK_URL\"}" \
            2>/dev/null || echo '{}')
        BOT_ID=$(echo "$BOT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        echo "   ✅ Agent Bot '$BOT_SLUG' creado (ID: $BOT_ID)"
    fi

    local CHATWOOT_API_KEY
    CHATWOOT_API_KEY=$(echo "$BOT_RESP" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('access_token',''))
" 2>/dev/null || echo "")

    if [ -z "$CHATWOOT_API_KEY" ]; then
        echo "❌ No se pudo obtener el access_token del Agent Bot"
        echo "   Respuesta: $BOT_RESP"
        return 1
    fi
    echo "   ✅ Agent Bot token obtenido"

    # ── B3. Crear .env del bridge ──────────────────────────────────────────────
    echo ""
    echo "⚙️  Configurando variables de entorno del bridge '$BOT_SLUG'..."
    mkdir -p "$HOME/chatdify"
    chmod 700 "$HOME/chatdify"

    cat > "$BOT_ENV_DIR" << ENVEOF
# Chatdify — Bridge Chatwoot <-> Dify — Bot: $BOT_SLUG
# Generado por install-new.sh — $(date)

# ── Chatwoot ─────────────────────────────────────────────
# chatwoot-rails:3000 accesible desde el bridge vía chatwoot-net
CHATWOOT_API_URL=http://chatwoot-rails:3000/api/v1
CHATWOOT_API_KEY=${CHATWOOT_API_KEY}
CHATWOOT_ACCOUNT_ID=${CHATWOOT_ACCOUNT_ID}
ALLOWED_CONVERSATION_STATUSES=open,pending

# ── Dify ─────────────────────────────────────────────────
# nginx:80 accesible desde el bridge vía default network
DIFY_API_URL=http://nginx:80/v1
DIFY_API_KEY=${DIFY_API_KEY}

# ── Base de datos propia del bridge ──────────────────────
DB_HOST=chatdify-${BOT_SLUG}-postgres
DB_PORT=5432
POSTGRES_DB=chatdify
POSTGRES_USER=chatdify
POSTGRES_PASSWORD=${BOT_DB_PASSWORD}
DATABASE_URL=postgresql://chatdify:${BOT_DB_PASSWORD}@chatdify-${BOT_SLUG}-postgres:5432/chatdify

# ── Redis (comparte Redis de Chatwoot, DB index $REDIS_DB) ──
CELERY_BROKER_URL=redis://:${CHATWOOT_REDIS_PASSWORD}@chatwoot-redis:6379/${REDIS_DB}
CELERY_RESULT_BACKEND=redis://:${CHATWOOT_REDIS_PASSWORD}@chatwoot-redis:6379/${REDIS_DB}

# ── Control de bot (human takeover) ──────────────────
# Si el bridge soporta estas vars, ignorará conversaciones con bot-pausa
HUMAN_AGENT_LABEL=bot-pausa
BOT_ACTIVE_LABEL=bot-activo
ENVEOF

    chmod 600 "$BOT_ENV_DIR"
    echo "   ✅ .env del bridge creado en $BOT_ENV_DIR"

    # ── B4. Agregar servicios chatdify al docker-compose.override.yml ──────────
    echo ""
    echo "🔧 Actualizando docker-compose.override.yml con servicios chatdify-$BOT_SLUG..."

    export _PY_OVERRIDE="$OVERRIDE_FILE"
    export _PY_DB_PASS="$BOT_DB_PASSWORD"
    export _PY_BRIDGE="$BOT_ENV_DIR"
    export _PY_SLUG="$BOT_SLUG"
    export _PY_PORT="$PORT"

    python3 << 'PYEOF'
import os, re, sys

OVERRIDE_FILE = os.environ["_PY_OVERRIDE"]
DB_PASSWORD   = os.environ["_PY_DB_PASS"]
BRIDGE_DIR    = os.environ["_PY_BRIDGE"]
BOT_SLUG      = os.environ["_PY_SLUG"]
PORT          = int(os.environ["_PY_PORT"])
VOL_SLUG      = BOT_SLUG.replace("-", "_")

with open(OVERRIDE_FILE, "r") as f:
    content = f.read()

# Eliminar marcadores legacy si existen
MARKER_BEGIN = "# <<< CHATDIFY-BEGIN >>>"
MARKER_END   = "# <<< CHATDIFY-END >>>"
if MARKER_BEGIN in content:
    content = re.compile(
        re.escape(MARKER_BEGIN) + r".*?" + re.escape(MARKER_END) + r"\n?",
        re.DOTALL
    ).sub("", content)

# Eliminar servicios previos para este slug (idempotente)
for svc in [f"chatdify-{BOT_SLUG}-postgres", f"chatdify-{BOT_SLUG}", f"chatdify-{BOT_SLUG}-worker"]:
    pattern = re.compile(
        r"^  " + re.escape(svc) + r":.*?(?=\n  [a-zA-Z]|\n[a-zA-Z])",
        re.MULTILINE | re.DOTALL
    )
    if pattern.search(content):
        content = pattern.sub("", content)
        print(f"   ⚠️  Servicio {svc} previo reemplazado")

# Eliminar declaración de volumen previa para este slug
content = re.sub(
    rf'^  chatdify_{re.escape(VOL_SLUG)}_postgres_data:\s*\n',
    '', content, flags=re.MULTILINE
)

services_block = (
    "\n"
    f"  # --- chatdify-{BOT_SLUG}: Bridge Chatwoot <-> Dify ---\n"
    f"  chatdify-{BOT_SLUG}-postgres:\n"
    "    image: postgres:16-alpine\n"
    "    restart: always\n"
    "    environment:\n"
    "      POSTGRES_DB: chatdify\n"
    "      POSTGRES_USER: chatdify\n"
    f"      POSTGRES_PASSWORD: {DB_PASSWORD}\n"
    "    volumes:\n"
    f"      - chatdify_{VOL_SLUG}_postgres_data:/var/lib/postgresql/data\n"
    "    healthcheck:\n"
    '      test: ["CMD-SHELL", "pg_isready -U chatdify -d chatdify"]\n'
    "      interval: 10s\n"
    "      timeout: 5s\n"
    "      retries: 5\n"
    "    networks:\n"
    "      - chatwoot-net\n"
    "\n"
    f"  chatdify-{BOT_SLUG}:\n"
    "    image: eremeye/chatdify:latest\n"
    "    restart: always\n"
    "    depends_on:\n"
    f"      chatdify-{BOT_SLUG}-postgres:\n"
    "        condition: service_healthy\n"
    "    env_file:\n"
    f"      - {BRIDGE_DIR}\n"
    "    ports:\n"
    f'      - "127.0.0.1:{PORT}:8000"\n'
    "    networks:\n"
    "      - default       # accede a nginx:80 (Dify)\n"
    "      - chatwoot-net  # recibe webhook de chatwoot-rails\n"
    "\n"
    f"  chatdify-{BOT_SLUG}-worker:\n"
    "    image: eremeye/chatdify:latest\n"
    "    restart: always\n"
    "    command: celery -A app.tasks worker --loglevel=info --concurrency=4 --pool=prefork\n"
    "    depends_on:\n"
    f"      chatdify-{BOT_SLUG}-postgres:\n"
    "        condition: service_healthy\n"
    "    env_file:\n"
    f"      - {BRIDGE_DIR}\n"
    "    networks:\n"
    "      - default       # accede a nginx:80 (Dify API)\n"
    "      - chatwoot-net  # accede a chatwoot-rails:3000 y chatwoot-redis\n"
)

if not re.search(r'^volumes:', content, re.MULTILINE):
    print("ERROR: No se encontró la sección 'volumes:' en el override.")
    sys.exit(1)

content = re.sub(
    r'^(volumes:)',
    services_block + r'\1',
    content, count=1, flags=re.MULTILINE
)

vol_key = f"chatdify_{VOL_SLUG}_postgres_data"
volumes_match = re.search(r'^volumes:(.*?)(?=\nnetworks:|\Z)', content, re.MULTILINE | re.DOTALL)
if not (volumes_match and f"{vol_key}:" in volumes_match.group(1)):
    content = re.sub(
        r'^(volumes:\s*\n)',
        rf'\1  {vol_key}:\n',
        content, count=1, flags=re.MULTILINE
    )
    print(f"   ✅ Volumen chatdify_{VOL_SLUG}_postgres_data declarado")

with open(OVERRIDE_FILE, "w") as f:
    f.write(content)

print(f"   ✅ docker-compose.override.yml actualizado para chatdify-{BOT_SLUG}")
PYEOF

    unset _PY_OVERRIDE _PY_DB_PASS _PY_BRIDGE _PY_SLUG _PY_PORT

    # ── B5. Validar el override ────────────────────────────────────────────────
    echo ""
    echo "🔍 Validando docker-compose.override.yml..."
    if (cd "$COMPOSE_DIR" && docker compose config --quiet 2>/dev/null); then
        echo "   ✅ Configuración válida"
    else
        echo ""
        echo "   ❌ El override tiene errores. Output de docker compose config:"
        (cd "$COMPOSE_DIR" && docker compose config 2>&1 | head -40)
        return 1
    fi

    # ── B6. Limpiar volúmenes previos si es instalación nueva ─────────────────
    if [ "$BOT_NEW_INSTALL" = "true" ]; then
        local VOL_NAME="${COMPOSE_PROJECT}_chatdify_${VOL_SLUG}_postgres_data"
        if docker volume inspect "$VOL_NAME" &>/dev/null 2>&1; then
            echo ""
            echo "🗑️  Limpiando volumen anterior: $VOL_NAME"
            docker volume rm "$VOL_NAME" 2>/dev/null || true
        fi
    fi

    # ── B7. Levantar Chatdify ──────────────────────────────────────────────────
    echo ""
    echo "🐳 Levantando chatdify-$BOT_SLUG..."
    (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate \
        "chatdify-${BOT_SLUG}-postgres" \
        "chatdify-${BOT_SLUG}" \
        "chatdify-${BOT_SLUG}-worker")
    echo "   ✅ Contenedores iniciados"

    # ── B8. Esperar que el bridge esté listo ───────────────────────────────────
    echo ""
    echo "⏳ Esperando que chatdify-$BOT_SLUG esté listo (hasta 90s)..."
    local BRIDGE_READY=false
    for i in $(seq 1 18); do
        local HTTP
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 5 "http://localhost:${PORT}/api/v1/health" 2>/dev/null || echo "000")
        if [ "$HTTP" = "200" ]; then
            echo ""
            echo "   ✅ chatdify-$BOT_SLUG respondiendo en :${PORT}/api/v1/health"
            BRIDGE_READY=true
            break
        fi
        echo -n "."
        sleep 5
    done
    echo ""

    if [ "$BRIDGE_READY" = false ]; then
        echo "   ⚠️  chatdify-$BOT_SLUG no respondió en 90s. Revisa los logs:"
        echo "      cd $COMPOSE_DIR && docker compose logs chatdify-$BOT_SLUG"
    fi

    # ── Guardar credenciales del bot ───────────────────────────────────────────
    update_or_add "BOT_${BOT_SLUG_UPPER}_DB_PASSWORD"      "$BOT_DB_PASSWORD"
    update_or_add "BOT_${BOT_SLUG_UPPER}_DIFY_API_KEY"     "$DIFY_API_KEY"
    update_or_add "BOT_${BOT_SLUG_UPPER}_CHATWOOT_API_KEY" "$CHATWOOT_API_KEY"
    update_or_add "BOT_${BOT_SLUG_UPPER}_PORT"             "$PORT"
    update_or_add "BOT_${BOT_SLUG_UPPER}_WEBHOOK_URL"      "$WEBHOOK_URL"
    echo "   ✅ Credenciales de $BOT_SLUG guardadas en $CREDS_FILE"
}

# ----------------------------------------------------------
# Instalar plugins seleccionados (antes de importar workflows)
# ----------------------------------------------------------
if [ ${#SELECTED_PLUGINS[@]} -gt 0 ]; then
    echo ""
    echo "🧩 Instalando plugins en Dify..."
    install_plugins "${SELECTED_PLUGINS[@]}" || true

    # Si hay API keys que configurar, esperar a que los plugins estén instalados
    if [ ${#PLUGIN_API_KEYS[@]} -gt 0 ]; then
        wait_plugins_installed "$PLUGIN_INSTALL_TASK_ID"
    fi
fi

if [ ${#PLUGIN_API_KEYS[@]} -gt 0 ]; then
    configure_plugins "${PLUGIN_API_KEYS[@]}" || true
fi

# ----------------------------------------------------------
# Loop principal: instalar cada bot seleccionado
# ----------------------------------------------------------
BASE_PORT=8001
for i in "${!SELECTED_BOTS[@]}"; do
    setup_bot "${SELECTED_BOTS[$i]}" "$((BASE_PORT + i))"
done

# ----------------------------------------------------------
# Resumen final
# ----------------------------------------------------------
echo ""
echo "=================================================="
echo "✅ INSTALACIÓN COMPLETA"
echo "=================================================="
echo ""
echo "🌐 Cloudflare Zero Trust — configurar 2 hostnames en el mismo túnel:"
echo ""
echo "   $(echo "$DIFY_URL" | sed 's|https://||')   →   http://nginx:80"
echo "   $(echo "$CHATWOOT_URL" | sed 's|https://||')   →   http://chatwoot-rails:3000"
echo ""
echo "─────────────────────────────────────────────────"
echo "🔑 Credenciales:"
echo "   Email:    $ADMIN_EMAIL"
echo "   Dify:     $DIFY_URL"
echo "   Chatwoot: $CHATWOOT_URL"
echo ""
echo "🤖 Bots instalados:"
BASE_PORT=8001
for i in "${!SELECTED_BOTS[@]}"; do
    echo "   - ${SELECTED_BOTS[$i]}  (bridge en :$((BASE_PORT + i)))"
done
echo ""
echo "════════════════════════════════════════════════"
echo "⚠️  PASO MANUAL REQUERIDO"
echo "════════════════════════════════════════════════"
echo ""
echo "   ✅ Workflow publicado automáticamente por el script."
echo "      Si el bot no responde, verifica en $DIFY_URL → abre la app"
echo "      → si aparece 'Borrador', haz clic en 'Publicar'"
echo ""
echo "   1️⃣  ASIGNAR AGENT BOT EN CHATWOOT (sin esto el bot no recibe mensajes)"
echo ""
echo "      → Entra a $CHATWOOT_URL"
echo "      → Settings → Inboxes → (tu inbox) → Settings → Configuration"
echo "      → Pestaña 'Agent Bots' → Selecciona el bot → Guardar"
echo ""
echo "─────────────────────────────────────────────────"
echo "🔍 Diagnóstico rápido:"
echo ""
echo "   # Estado de todos los contenedores"
echo "   cd $COMPOSE_DIR && docker compose ps"
echo ""
BASE_PORT=8001
for i in "${!SELECTED_BOTS[@]}"; do
    BOT="${SELECTED_BOTS[$i]}"
    PORT="$((BASE_PORT + i))"
    echo "   # Health check: $BOT"
    echo "   curl -sv http://localhost:${PORT}/api/v1/health"
    echo ""
    echo "   # Logs en tiempo real: $BOT"
    echo "   cd $COMPOSE_DIR && docker compose logs -f chatdify-$BOT"
    echo "   cd $COMPOSE_DIR && docker compose logs -f chatdify-$BOT-worker"
    echo ""
done
echo "─────────────────────────────────────────────────"
echo "🔗 Flujo de mensajes:"
echo ""
echo "   Usuario → Chatwoot → chatdify:8000 → Dify API → chatdify → Chatwoot → Usuario"
echo ""
echo "════════════════════════════════════════════════"
echo "🤝 TOMAR CONTROL COMO AGENTE HUMANO"
echo "════════════════════════════════════════════════"
echo ""
echo "   PASO 1 — Asígnate la conversación en Chatwoot:"
echo "      Abre la conversación → campo 'Assignee' → tu nombre"
echo "      → Label 'bot-pausa' (naranja) se aplica automáticamente"
echo ""
echo "   PASO 2 — Silencia el bot (1 clic):"
echo "      Panel lateral derecho → 'Conversation Actions'"
echo "      → 'Agent Bot' → clic 'Remove Agent Bot'"
echo "      → El bot deja de responder en esa conversación"
echo ""
echo "   REACTIVAR EL BOT:"
echo "      Desasígnate la conversación (Assignee → vacío)"
echo "      → Settings → Inboxes → (inbox) → Agent Bots → reasignar"
echo ""
echo "════════════════════════════════════════════════"
echo "🔁 ESCALACIÓN AUTOMÁTICA DESDE DIFY"
echo "════════════════════════════════════════════════"
echo ""
echo "   En el workflow de Dify agrega un nodo IF/ELSE:"
echo ""
echo "   CONDICIÓN (en el nodo IF):"
echo "      sys.query contiene: 'agente' | 'humano' | 'persona' | 'hablar con'"
echo ""
echo "   RAMA VERDADERA — nodo Answer con este texto EXACTO:"
echo "      'Voy a transferirte con un agente, un momento...'"
echo "      → Chatwoot detecta la frase y asigna automáticamente"
echo ""
echo "   RAMA FALSA — continúa con el LLM normalmente"
echo ""
echo "════════════════════════════════════════════════"
echo "🟢 ESTADO DEL BOT (visible en lista de conversaciones)"
echo "════════════════════════════════════════════════"
echo ""
echo "   🟢 bot-activo  =  bot respondiendo al cliente"
echo "   🟠 bot-pausa   =  agente humano al mando"
echo "   🔴 escalado    =  cliente pidió un humano, pendiente de atención"
echo ""
echo "   Comandos de administración:"
echo "   bash $SCRIPT_DIR/bot-control.sh health            # estado de bridges"
echo "   bash $SCRIPT_DIR/bot-control.sh status            # conversaciones abiertas"
echo "   bash $SCRIPT_DIR/bot-control.sh pause  <conv_id>  # aplicar bot-pausa"
echo "   bash $SCRIPT_DIR/bot-control.sh resume <conv_id>  # restaurar bot-activo"
echo ""
