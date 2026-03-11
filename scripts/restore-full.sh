#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Scénario 3 — Restauration complète d'un service conteneurisé
# Détruit tout (conteneurs + volumes) puis restaure depuis Restic
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE_DIR="/tmp/restic-restore"
export RESTIC_PASSWORD_FILE="${PROJECT_DIR}/secrets/restic-password"
export RESTIC_REPOSITORY="/mnt/restic-backup/repo"

DB_CONTAINER="bookstack_db"
DB_NAME="bookstack"
DB_USER="root"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

START_TIME=$(date +%s)

log "=== Restauration complète du service BookStack ==="

# --- 1. Extraire tout le snapshot Restic -------------------------------------
log "Extraction du dernier snapshot complet..."
rm -rf "${RESTORE_DIR}"
mkdir -p "${RESTORE_DIR}"

restic restore latest \
    --target "${RESTORE_DIR}"

STAGING="${RESTORE_DIR}/tmp/restic-staging"
log "Contenu restauré :"
ls -lh "${STAGING}/dumps/" "${STAGING}/volumes/" "${STAGING}/config/"

# --- 2. Restaurer les fichiers de configuration ------------------------------
log "Restauration des fichiers de configuration..."
cp "${STAGING}/config/bookstack.env" "${PROJECT_DIR}/bookstack/.env"
cp "${STAGING}/config/bookstack-compose.yml" "${PROJECT_DIR}/bookstack/docker-compose.yml"

# Relire le mot de passe DB depuis le .env restauré
DB_PASS=$(grep DB_ROOT_PASS "${PROJECT_DIR}/bookstack/.env" | cut -d= -f2)

# --- 3. Relancer les conteneurs (les volumes seront recréés vides) -----------
log "Relance de la stack Docker..."
cd "${PROJECT_DIR}/bookstack"
docker compose up -d
cd "${PROJECT_DIR}"

# Attendre que MariaDB soit prête
log "Attente du démarrage de MariaDB..."
for i in $(seq 1 30); do
    if docker exec "${DB_CONTAINER}" mariadb -u"${DB_USER}" -p"${DB_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
        log "MariaDB prête après ${i} secondes."
        break
    fi
    sleep 1
done

# --- 4. Réinjecter le dump SQL -----------------------------------------------
log "Réinjection du dump SQL..."
docker exec -i "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < "${STAGING}/dumps/bookstack.sql"

# --- 5. Restaurer le volume BookStack (uploads, config interne) --------------
log "Restauration du volume BookStack (bookstack_data)..."
docker run --rm \
    -v bookstack_bookstack_data:/target \
    -v "${STAGING}/volumes":/backup:ro \
    alpine sh -c "cd /target && tar xzf /backup/bookstack_data.tar.gz"

# --- 6. Redémarrer BookStack pour prendre en compte les fichiers restaurés ---
log "Redémarrage de BookStack..."
docker restart bookstack
sleep 5

# --- 7. Vérification ---------------------------------------------------------
log "Vérification..."
TABLE_COUNT=$(docker exec "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" \
    -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}';" 2>/dev/null)
log "Tables dans la base : ${TABLE_COUNT}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:6875 2>/dev/null || echo "000")
log "Code HTTP BookStack : ${HTTP_CODE}"

# --- 8. Nettoyage ------------------------------------------------------------
rm -rf "${RESTORE_DIR}"

DURATION=$(( $(date +%s) - START_TIME ))
log "=== Restauration complète terminée en ${DURATION} secondes ==="
log "Vérifier manuellement : http://localhost:6875"
