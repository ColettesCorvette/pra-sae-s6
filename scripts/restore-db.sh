#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Scénario 2 — Restauration de la base de données MariaDB
# Restaure le dump SQL depuis le dernier snapshot Restic
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE_DIR="/tmp/restic-restore"
export RESTIC_PASSWORD_FILE="${PROJECT_DIR}/secrets/restic-password"
export RESTIC_REPOSITORY="/mnt/restic-backup/repo"

DB_CONTAINER="bookstack_db"
DB_NAME="bookstack"
DB_USER="root"
DB_PASS=$(grep DB_ROOT_PASS "${PROJECT_DIR}/bookstack/.env" | cut -d= -f2)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

START_TIME=$(date +%s)

log "=== Restauration de la base de données MariaDB ==="

# --- 1. Extraire le dump SQL depuis le dernier snapshot Restic ---------------
log "Extraction du dump SQL depuis le dernier snapshot..."
rm -rf "${RESTORE_DIR}"
mkdir -p "${RESTORE_DIR}"

restic restore latest \
    --target "${RESTORE_DIR}" \
    --include "dumps/bookstack.sql"

# Trouver le fichier restauré (il est dans un sous-dossier reproduisant le chemin original)
DUMP_FILE=$(find "${RESTORE_DIR}" -name "bookstack.sql" -type f | head -1)

if [ -z "${DUMP_FILE}" ]; then
    log "ERREUR : dump SQL introuvable dans le snapshot."
    exit 1
fi

DUMP_SIZE=$(du -h "${DUMP_FILE}" | cut -f1)
log "Dump extrait : ${DUMP_FILE} (${DUMP_SIZE})"

# --- 2. Réinjecter le dump dans MariaDB -------------------------------------
log "Remise à zéro de la base de données (DROP + CREATE)..."
# Nécessaire pour garantir une ardoise propre : si la base contient déjà
# des tables (même vides ou corrompues), la réinjection du dump échouerait
# sur les CREATE TABLE. On supprime et on recrée.
docker exec "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" \
    -e "DROP DATABASE IF EXISTS ${DB_NAME}; CREATE DATABASE ${DB_NAME};"

log "Réinjection du dump dans MariaDB..."
docker exec -i "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" < "${DUMP_FILE}"

# --- 3. Vérification --------------------------------------------------------
log "Vérification : comptage des tables..."
TABLE_COUNT=$(docker exec "${DB_CONTAINER}" \
    mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" \
    -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${DB_NAME}';" 2>/dev/null)

log "Tables trouvées : ${TABLE_COUNT}"

# --- 4. Nettoyage -----------------------------------------------------------
rm -rf "${RESTORE_DIR}"

DURATION=$(( $(date +%s) - START_TIME ))
log "=== Restauration terminée en ${DURATION} secondes ==="
log "Vérifier manuellement : http://localhost:6875"
