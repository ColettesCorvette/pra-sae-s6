#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Scénario ransomware — Restauration depuis le stockage distant (MinIO)
#
# Simule un ransomware : les volumes Docker ET le dépôt Restic local sont
# corrompus. Seule la copie sur MinIO (hors site) est intacte.
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE_DIR="/tmp/restic-restore"
export RESTIC_PASSWORD_FILE="${PROJECT_DIR}/secrets/restic-password"

# Credentials MinIO
MINIO_CREDS="${PROJECT_DIR}/secrets/minio-credentials"
if [ ! -f "${MINIO_CREDS}" ]; then
    echo "ERREUR : ${MINIO_CREDS} introuvable."
    exit 1
fi
source "${MINIO_CREDS}"

export RESTIC_REPOSITORY="s3:http://localhost:9000/restic-backup"

DB_CONTAINER="bookstack_db"
DB_NAME="bookstack"
DB_USER="root"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

START_TIME=$(date +%s)

log "=== SCÉNARIO RANSOMWARE ==="
log "=== Restauration depuis le dépôt distant (MinIO) ==="
log ""
log "Hypothèse : les volumes Docker et le dépôt Restic local sont compromis."
log "On restaure exclusivement depuis le stockage objet S3."
log ""

# --- 1. Vérifier que le dépôt MinIO est accessible --------------------------
log "Vérification du dépôt distant..."
restic snapshots
log ""

# --- 2. Extraire le dernier snapshot depuis MinIO ----------------------------
log "Extraction du dernier snapshot depuis MinIO..."
rm -rf "${RESTORE_DIR}"
mkdir -p "${RESTORE_DIR}"

restic restore latest \
    --target "${RESTORE_DIR}"

STAGING="${RESTORE_DIR}/tmp/restic-staging"
log "Contenu restauré depuis MinIO :"
ls -lh "${STAGING}/dumps/" "${STAGING}/volumes/" "${STAGING}/config/"

# --- 3. Restaurer les fichiers de configuration ------------------------------
log "Restauration des fichiers de configuration..."
cp "${STAGING}/config/bookstack.env" "${PROJECT_DIR}/bookstack/.env"
cp "${STAGING}/config/bookstack-compose.yml" "${PROJECT_DIR}/bookstack/docker-compose.yml"

DB_PASS=$(grep DB_ROOT_PASS "${PROJECT_DIR}/bookstack/.env" | cut -d= -f2)

# --- 4. Relancer les conteneurs ----------------------------------------------
log "Relance de la stack Docker..."
cd "${PROJECT_DIR}/bookstack"
docker compose up -d
cd "${PROJECT_DIR}"

log "Attente du démarrage de MariaDB..."
for i in $(seq 1 30); do
    if docker exec "${DB_CONTAINER}" mariadb -u"${DB_USER}" -p"${DB_PASS}" -e "SELECT 1;" >/dev/null 2>&1; then
        log "MariaDB prête après ${i} secondes."
        break
    fi
    sleep 1
done

# --- 5. Réinjecter le dump SQL -----------------------------------------------
log "Remise à zéro de la base de données (DROP + CREATE)..."
docker exec "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" \
    -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME};"

log "Réinjection du dump SQL..."
docker exec -i "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < "${STAGING}/dumps/bookstack.sql"

# --- 6. Restaurer le volume BookStack ----------------------------------------
log "Restauration du volume BookStack (bookstack_data)..."
docker run --rm \
    -v bookstack_bookstack_data:/target \
    -v "${STAGING}/volumes":/backup:ro \
    alpine sh -c "cd /target && tar xzf /backup/bookstack_data.tar.gz"

# --- 7. Redémarrer BookStack -------------------------------------------------
log "Redémarrage de BookStack..."
docker restart bookstack
sleep 5

# --- 8. Vérification ---------------------------------------------------------
log "Vérification..."
TABLE_COUNT=$(docker exec "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" \
    -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}';" 2>/dev/null)
log "Tables dans la base : ${TABLE_COUNT}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:6875 2>/dev/null || echo "000")
log "Code HTTP BookStack : ${HTTP_CODE}"

# --- 9. Nettoyage ------------------------------------------------------------
rm -rf "${RESTORE_DIR}"

DURATION=$(( $(date +%s) - START_TIME ))
log ""
log "=== Restauration depuis MinIO terminée en ${DURATION} secondes ==="
log "Le dépôt Restic local devra être réinitialisé séparément."
log "Vérifier manuellement : http://localhost:6875"
