#!/bin/bash
# =============================================================
# bot-control.sh — Gestión de bridges y estado de bot
#
# Uso:
#   bash bot-control.sh health            — estado de todos los bridges
#   bash bot-control.sh status            — conversaciones abiertas con labels
#   bash bot-control.sh pause  <conv_id>  — aplicar label bot-pausa
#   bash bot-control.sh resume <conv_id>  — restaurar label bot-activo
# =============================================================

set -eo pipefail
trap 'echo "" && echo "❌ Error en línea $LINENO." >&2' ERR

CREDS_FILE="$HOME/.stack.env"

if [ ! -f "$CREDS_FILE" ]; then
    echo "❌ No se encontró $CREDS_FILE. Ejecuta install-new.sh primero."
    exit 1
fi

# Lectura robusta de credenciales (sin 'source', tolera comentarios y espacios)
_cred() { grep "^${1}=" "$CREDS_FILE" 2>/dev/null | cut -d'=' -f2- | head -1; }
CHATWOOT_URL=$(          _cred CHATWOOT_URL)
CHATWOOT_ADMIN_API_KEY=$(_cred CHATWOOT_ADMIN_API_KEY)
CHATWOOT_ACCOUNT_ID=$(   _cred CHATWOOT_ACCOUNT_ID)

for VAR in CHATWOOT_URL CHATWOOT_ADMIN_API_KEY CHATWOOT_ACCOUNT_ID; do
    if [ -z "${!VAR}" ]; then
        echo "❌ Variable $VAR no encontrada en $CREDS_FILE"
        exit 1
    fi
done

# ----------------------------------------------------------
# Helper: llamada a la API pública de Chatwoot (desde el host)
# ----------------------------------------------------------
cw_api() {
    local method="$1" path="$2"; shift 2
    curl -s --max-time 15 \
        -X "$method" "$CHATWOOT_URL/api/v1/accounts/$CHATWOOT_ACCOUNT_ID${path}" \
        -H "api_access_token: $CHATWOOT_ADMIN_API_KEY" \
        -H "Content-Type: application/json" \
        "$@"
}

# ----------------------------------------------------------
# Helpers de labels: GET actual → modificar → POST (reemplaza todo)
# ----------------------------------------------------------
_get_labels() {
    local conv_id="$1"
    cw_api GET "/conversations/$conv_id/labels" \
        | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('payload',[])))" \
        2>/dev/null || echo '[]'
}

_set_labels() {
    local conv_id="$1" labels_json="$2"
    cw_api POST "/conversations/$conv_id/labels" \
        -d "{\"labels\": $labels_json}" >/dev/null
}

_modify_labels() {
    # Uso: _modify_labels <conv_id> <add> <remove>
    local conv_id="$1" add_label="$2" remove_label="$3"
    local current new_labels
    current=$(_get_labels "$conv_id")
    new_labels=$(python3 -c "
import json
labels = json.loads('$current')
labels = [l for l in labels if l != '$remove_label']
if '$add_label' and '$add_label' not in labels:
    labels.append('$add_label')
print(json.dumps(labels))
" 2>/dev/null || echo "$current")
    _set_labels "$conv_id" "$new_labels"
}

# ----------------------------------------------------------
# Comando: health
# ----------------------------------------------------------
cmd_health() {
    echo ""
    echo "🏥 Estado de bridges"
    echo "──────────────────────────────────────────"

    local found=0
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^BOT_(.+)_PORT$ ]] || continue
        local slug="${BASH_REMATCH[1],,}"
        slug="${slug//_/-}"
        local port="${val// /}"
        local http
        http=$(curl -s -o /dev/null -w "%{http_code}" \
            --max-time 5 "http://localhost:${port}/api/v1/health" 2>/dev/null || echo "000")
        if [ "$http" = "200" ]; then
            echo "   ✅ $slug  (puerto $port)"
        else
            echo "   ❌ $slug  (puerto $port) — HTTP $http"
        fi
        found=$((found + 1))
    done < "$CREDS_FILE"

    if [ "$found" -eq 0 ]; then
        echo "   ⚠️  No se encontraron bots en $CREDS_FILE"
    fi
    echo ""
}

# ----------------------------------------------------------
# Comando: status
# ----------------------------------------------------------
cmd_status() {
    echo ""
    echo "📋 Conversaciones abiertas"
    echo "──────────────────────────────────────────"

    local resp
    resp=$(cw_api GET "/conversations?status=open&page=1")

    if ! echo "$resp" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "❌ Error conectando a Chatwoot: $(echo "$resp" | head -c 200)"
        exit 1
    fi

    python3 << PYEOF
import json, sys

data = json.loads('''$(echo "$resp" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || echo '{}')''')
convs = data.get("data", {}).get("payload", [])

if not convs:
    print("   (sin conversaciones abiertas)")
else:
    for c in convs:
        cid      = c.get("id", "?")
        labels   = c.get("labels", []) or []
        assignee = (c.get("meta", {}).get("assignee") or {}).get("name", "sin asignar")
        contact  = (c.get("meta", {}).get("sender")   or {}).get("name", "Desconocido")
        label_str = ", ".join(labels) if labels else "sin labels"

        # Indicador visual de estado del bot
        if "bot-pausa" in labels or "escalado" in labels:
            indicator = "🟠"
        elif "bot-activo" in labels:
            indicator = "🟢"
        else:
            indicator = "⚪"

        print(f"   {indicator} #{cid}  {contact}  [{label_str}]  agente: {assignee}")
PYEOF
    echo ""
}

# ----------------------------------------------------------
# Comando: pause <conv_id>
# ----------------------------------------------------------
cmd_pause() {
    local conv_id="${1:-}"
    if [ -z "$conv_id" ]; then
        echo "❌ Uso: bash bot-control.sh pause <conv_id>"
        exit 1
    fi

    echo ""
    echo "⏸️  Aplicando bot-pausa en conversación #$conv_id..."
    _modify_labels "$conv_id" "bot-pausa" "bot-activo"
    echo "   ✅ Labels actualizadas (bot-pausa activo)"
    echo ""
    echo "   ─── ACCIÓN MANUAL REQUERIDA ───────────────────────"
    echo "   Para que el bot deje de responder mensajes:"
    echo ""
    echo "   Chatwoot → conversación #$conv_id → panel lateral derecho"
    echo "   → sección 'Conversation Actions' → 'Agent Bot'"
    echo "   → clic 'Remove Agent Bot'"
    echo "   ────────────────────────────────────────────────────"
    echo ""
}

# ----------------------------------------------------------
# Comando: resume <conv_id>
# ----------------------------------------------------------
cmd_resume() {
    local conv_id="${1:-}"
    if [ -z "$conv_id" ]; then
        echo "❌ Uso: bash bot-control.sh resume <conv_id>"
        exit 1
    fi

    echo ""
    echo "▶️  Restaurando bot-activo en conversación #$conv_id..."
    _modify_labels "$conv_id" "bot-activo" "bot-pausa"
    _modify_labels "$conv_id" "" "escalado"
    echo "   ✅ Labels actualizadas (bot-activo)"
    echo ""
    echo "   ─── ACCIÓN MANUAL REQUERIDA (si removiste el bot) ─"
    echo "   Si removiste el Agent Bot de esta conversación:"
    echo ""
    echo "   Chatwoot → Settings → Inboxes → (tu inbox)"
    echo "   → Pestaña 'Agent Bots' → selecciona el bot → Guardar"
    echo "   ────────────────────────────────────────────────────"
    echo ""
}

# ----------------------------------------------------------
# Dispatcher
# ----------------------------------------------------------
CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
    health)  cmd_health ;;
    status)  cmd_status ;;
    pause)   cmd_pause  "$@" ;;
    resume)  cmd_resume "$@" ;;
    help|--help|-h)
        echo ""
        echo "Uso: bash bot-control.sh <comando> [args]"
        echo ""
        echo "Comandos:"
        echo "  health              Estado de todos los bridges"
        echo "  status              Conversaciones abiertas con labels de bot"
        echo "  pause  <conv_id>    Aplica label 'bot-pausa' a la conversación"
        echo "  resume <conv_id>    Restaura label 'bot-activo' en la conversación"
        echo ""
        echo "Credenciales leídas de: $CREDS_FILE"
        echo ""
        ;;
    *)
        echo "❌ Comando desconocido: $CMD"
        echo "   Usa: bash bot-control.sh help"
        exit 1
        ;;
esac
