#!/bin/bash

# =============================================================
# Uso: bash desinstalar.sh
#
# Elimina COMPLETAMENTE el stack del VPS:
#   - Contenedores (Dify + Chatwoot + Cloudflare + Bridge)
#   - Volúmenes de datos (Postgres, Redis, storage)
#   - Redes Docker del stack
#   - Repositorio de Dify
#   - Archivos de configuración y credenciales
#
# ⚠️  IRREVERSIBLE — hace backup de credenciales antes de borrar
# =============================================================

set -e

trap 'echo ""; echo "⚠️  Advertencia: Error en línea $LINENO. Continuando..." >&2' ERR

CREDS_FILE="$HOME/.stack.env"
BACKUP_FILE="$HOME/.stack.env.bak"
DIFY_DIR="$HOME/dify"
COMPOSE_DIR="$DIFY_DIR/docker"

echo ""
echo "🗑️  Desinstalando stack Dify + Chatwoot"
echo "=================================================="
echo ""
echo "⚠️  ADVERTENCIA: Esta operación es IRREVERSIBLE."
echo "   Se eliminarán todos los datos, volúmenes y configuraciones."
echo ""

# ----------------------------------------------------------
# Confirmación interactiva
# ----------------------------------------------------------
read -r -p "   ¿Confirmas que quieres eliminar todo el stack? [escribir 'si' para confirmar]: " CONFIRM

if [ "$CONFIRM" != "si" ]; then
    echo ""
    echo "   Operación cancelada."
    exit 0
fi

echo ""

# ----------------------------------------------------------
# Backup de credenciales antes de borrar
# ----------------------------------------------------------
if [ -f "$CREDS_FILE" ]; then
    cp "$CREDS_FILE" "$BACKUP_FILE"
    echo "💾 Backup de credenciales guardado en: $BACKUP_FILE"
fi

# ----------------------------------------------------------
# 1. Bajar el stack con Docker Compose
# ----------------------------------------------------------
echo ""
echo "🐳 Bajando contenedores del stack..."

if [ -f "$COMPOSE_DIR/docker-compose.yaml" ] || [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    cd "$COMPOSE_DIR"
    docker compose down --remove-orphans --volumes 2>/dev/null || true
    echo "   ✅ Stack bajado via docker compose"
else
    echo "   ⚠️  No se encontró docker-compose en $COMPOSE_DIR — eliminando contenedores manualmente..."
fi

# ----------------------------------------------------------
# 2. Eliminar contenedores huérfanos
# ----------------------------------------------------------
echo ""
echo "🧹 Eliminando contenedores relacionados..."

for CONTAINER in $(docker ps -a --format "{{.Names}}" 2>/dev/null \
    | grep -E "chatwoot|cloudflared|dify|^docker-" || true); do
    docker stop "$CONTAINER" 2>/dev/null || true
    docker rm   "$CONTAINER" 2>/dev/null || true
    echo "   🗑️  Eliminado: $CONTAINER"
done

echo "   ✅ Contenedores eliminados"

# ----------------------------------------------------------
# 3. Eliminar volúmenes
# ----------------------------------------------------------
echo ""
echo "💽 Eliminando volúmenes de datos..."

# Volúmenes de Chatwoot
for VOL in chatwoot_postgres_data chatwoot_redis_data chatwoot_storage; do
    if docker volume inspect "$VOL" &>/dev/null; then
        docker volume rm "$VOL" 2>/dev/null || true
        echo "   🗑️  Volumen eliminado: $VOL"
    fi
done

# Volúmenes de bridges (uno por bot: chatdify_<slug>_postgres_data)
for VOL in $(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "chatdify_" || true); do
    docker volume rm "$VOL" 2>/dev/null || true
    echo "   🗑️  Volumen eliminado: $VOL"
done

# Volúmenes del proyecto Dify (prefijo docker_)
for VOL in $(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "^docker_" || true); do
    docker volume rm "$VOL" 2>/dev/null || true
    echo "   🗑️  Volumen eliminado: $VOL"
done

echo "   ✅ Volúmenes eliminados"

# ----------------------------------------------------------
# 4. Eliminar redes del stack
# ----------------------------------------------------------
echo ""
echo "🌐 Eliminando redes Docker..."

for NET in app-network chatwoot-net docker_default; do
    if docker network inspect "$NET" &>/dev/null; then
        docker network rm "$NET" 2>/dev/null || true
        echo "   🗑️  Red eliminada: $NET"
    fi
done

echo "   ✅ Redes eliminadas"

# ----------------------------------------------------------
# 5. Eliminar imágenes del stack
# ----------------------------------------------------------
echo ""
echo "🖼️  Eliminando imágenes del stack..."

IMAGES=(
    "langgenius/dify-api"
    "langgenius/dify-web"
    "langgenius/dify-plugin-daemon"
    "langgenius/dify-sandbox"
    "chatwoot/chatwoot"
    "eremeye/chatdify"
    "cloudflare/cloudflared"
    "pgvector/pgvector"
    "redis:7-alpine"
    "redis:6-alpine"
    "semitechnologies/weaviate"
    "ubuntu/squid"
    "nginx"
    "busybox"
)

for IMAGE in "${IMAGES[@]}"; do
    if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE}"; then
        docker rmi "$IMAGE" 2>/dev/null || true
        echo "   🗑️  Imagen eliminada: $IMAGE"
    fi
done

docker image prune -f 2>/dev/null || true
echo "   ✅ Imágenes eliminadas"

# ----------------------------------------------------------
# 6. Eliminar repositorio de Dify y chatdify
# ----------------------------------------------------------
echo ""
echo "📁 Eliminando repositorio de Dify..."

if [ -d "$DIFY_DIR" ]; then
    # Intentar con permisos de usuario primero
    sudo chown -R $(whoami):$(whoami) "$DIFY_DIR" 2>/dev/null || true
    rm -rf "$DIFY_DIR" 2>/dev/null || true
    
    # Si aún existe, usar sudo
    if [ -d "$DIFY_DIR" ]; then
        sudo rm -rf "$DIFY_DIR"
    fi
    
    if [ ! -d "$DIFY_DIR" ]; then
        echo "   ✅ Eliminado: $DIFY_DIR"
    else
        echo "   ⚠️  No se pudo eliminar: $DIFY_DIR"
    fi
else
    echo "   ⚠️  No se encontró: $DIFY_DIR"
fi

# Eliminar directorio de env files de los bridges (~/.chatdify/*.bot.env)
BRIDGE_ENVS_DIR="$HOME/chatdify"
if [ -d "$BRIDGE_ENVS_DIR" ]; then
    rm -rf "$BRIDGE_ENVS_DIR" 2>/dev/null || true
    if [ ! -d "$BRIDGE_ENVS_DIR" ]; then
        echo "   ✅ Eliminado: $BRIDGE_ENVS_DIR"
    else
        sudo rm -rf "$BRIDGE_ENVS_DIR" 2>/dev/null || true
    fi
fi

# ----------------------------------------------------------
# 7. Eliminar credenciales
# ----------------------------------------------------------
echo ""
echo "📄 Eliminando archivos de configuración..."

if [ -f "$CREDS_FILE" ]; then
    rm -f "$CREDS_FILE"
    echo "   🗑️  Eliminado: $CREDS_FILE"
fi

echo "   ✅ Archivos de configuración eliminados"

# ----------------------------------------------------------
# 8. Limpiar sistema Docker
# ----------------------------------------------------------
echo ""
echo "🧽 Limpiando sistema Docker..."
docker system prune -f 2>/dev/null || true
echo "   ✅ Sistema Docker limpiado"

# ----------------------------------------------------------
# Verificación final
# ----------------------------------------------------------
echo ""
echo "🔍 Verificación final..."

REMAINING=$(docker ps -a --format "{{.Names}}" 2>/dev/null \
    | grep -E "chatwoot|dify|cloudflared" || true)
REMAINING_VOLS=$(docker volume ls --format "{{.Name}}" 2>/dev/null \
    | grep -E "chatwoot|docker_|chatdify_" || true)
REMAINING_NETS=$(docker network ls --format "{{.Name}}" 2>/dev/null \
    | grep -E "app-network|chatwoot-net" || true)

if [ -z "$REMAINING" ] && [ -z "$REMAINING_VOLS" ] && [ -z "$REMAINING_NETS" ]; then
    echo "   ✅ Sin rastros del stack — VPS limpio"
else
    [ -n "$REMAINING" ]      && echo "   ⚠️  Contenedores restantes: $REMAINING"
    [ -n "$REMAINING_VOLS" ] && echo "   ⚠️  Volúmenes restantes: $REMAINING_VOLS"
    [ -n "$REMAINING_NETS" ] && echo "   ⚠️  Redes restantes: $REMAINING_NETS"
    echo "   Elimínalos manualmente con:"
    echo "   docker rm / docker volume rm / docker network rm"
fi

# ----------------------------------------------------------
# Resumen final
# ----------------------------------------------------------
echo ""
echo "=================================================="
echo "✅ Desinstalación completa"
echo "=================================================="
echo ""
if [ -f "$BACKUP_FILE" ]; then
    echo "💾 Backup de credenciales conservado en: $BACKUP_FILE"
    echo "   Elimínalo cuando ya no lo necesites:"
    echo "   rm $BACKUP_FILE"
    echo ""
fi
echo "📁 Archivos del proyecto preservados intencionalmente:"
echo "   knowledge/   — documentos del cliente (elimina manualmente si no los necesitas)"
echo "   plugins.list — catálogo de plugins (reutilizable en futuras instalaciones)"
echo ""
echo "🖥️  Espacio disponible en disco:"
df -h / | tail -1 | awk '{print "   " $4 " libres de " $2}'
echo ""
