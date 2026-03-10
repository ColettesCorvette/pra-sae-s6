#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script de sauvegarde locale avec Restic
# Étape 2 — Sauvegarde des volumes Docker + dump MariaDB
# =============================================================================

# --- Configuration -----------------------------------------------------------
PROJECT_DIR="/home/thomas/pra-sae"
BACKUP_STAGING="/tmp/restic-staging"
RESTIC_REPO="/mnt/restic-backup/repo"
export RESTIC_PASSWORD_FILE="${PROJECT_DIR}/secrets/restic-password"
export RESTIC_REPOSITORY="${RESTIC_REPO}"

# Conteneurs et base de données
DB_CONTAINER="bookstack_db"
DB_NAME="bookstack"
DB_USER="root"
# Le mot de passe root est lu depuis le .env de BookStack
DB_PASS=$(grep DB_ROOT_PASS "${PROJECT_DIR}/bookstack/.env" | cut -d= -f2)

# --- Fonctions ---------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

cleanup() {
    log "Nettoyage du répertoire de staging..."
    # Certains fichiers copiés depuis les volumes Docker appartiennent à root,
    # on utilise un conteneur Alpine pour nettoyer proprement
    docker run --rm -v "${BACKUP_STAGING}":/cleanup alpine sh -c "rm -rf /cleanup/*" 2>/dev/null || true
    rm -rf "${BACKUP_STAGING}"
}
trap cleanup EXIT

# --- Préparation du staging --------------------------------------------------
log "=== Début de la sauvegarde ==="
# Nettoyage préalable (même logique que cleanup)
if [ -d "${BACKUP_STAGING}" ]; then
    docker run --rm -v "${BACKUP_STAGING}":/cleanup alpine sh -c "rm -rf /cleanup/*" 2>/dev/null || true
    rm -rf "${BACKUP_STAGING}"
fi
mkdir -p "${BACKUP_STAGING}/dumps"
mkdir -p "${BACKUP_STAGING}/volumes"
mkdir -p "${BACKUP_STAGING}/config"

# --- 1. Dump de la base MariaDB ---------------------------------------------
log "Dump de la base MariaDB (${DB_NAME})..."
docker exec "${DB_CONTAINER}" \
    mariadb-dump -u"${DB_USER}" -p"${DB_PASS}" \
    --single-transaction --routines --triggers \
    "${DB_NAME}" > "${BACKUP_STAGING}/dumps/${DB_NAME}.sql" 2>/dev/null

DUMP_SIZE=$(du -h "${BACKUP_STAGING}/dumps/${DB_NAME}.sql" | cut -f1)
log "Dump terminé : ${DUMP_SIZE}"

# --- 2. Export des volumes Docker en tar -------------------------------------
# Les fichiers dans les volumes appartiennent à root (UID 0 dans le conteneur).
# On les exporte en tar depuis un conteneur Alpine pour éviter les problèmes
# de permissions côté host. Restic sauvegardera les archives tar.
log "Export du volume BookStack (bookstack_data)..."
docker run --rm \
    -v bookstack_bookstack_data:/source:ro \
    -v "${BACKUP_STAGING}/volumes":/backup \
    alpine tar czf /backup/bookstack_data.tar.gz -C /source .

log "Export du volume Grafana (grafana_data)..."
if docker volume inspect supervision_grafana-data >/dev/null 2>&1; then
    docker run --rm \
        -v supervision_grafana-data:/source:ro \
        -v "${BACKUP_STAGING}/volumes":/backup \
        alpine tar czf /backup/grafana_data.tar.gz -C /source .
else
    log "WARN: Volume grafana-data introuvable, skip."
fi

# --- 3. Copie des fichiers de configuration ----------------------------------
log "Copie des fichiers de configuration..."
cp "${PROJECT_DIR}/bookstack/.env" "${BACKUP_STAGING}/config/bookstack.env"
cp "${PROJECT_DIR}/bookstack/docker-compose.yml" "${BACKUP_STAGING}/config/bookstack-compose.yml"

if [ -f "${PROJECT_DIR}/supervision/docker-compose.yml" ]; then
    cp "${PROJECT_DIR}/supervision/docker-compose.yml" \
       "${BACKUP_STAGING}/config/supervision-compose.yml"
fi

# --- 4. Sauvegarde Restic ----------------------------------------------------
log "Lancement de restic backup..."
restic backup "${BACKUP_STAGING}" \
    --tag bookstack --tag mariadb --tag config \
    --verbose

# --- 5. Vérification ---------------------------------------------------------
log "Vérification de l'intégrité du dépôt..."
restic check

log "Snapshots disponibles :"
restic snapshots

log "=== Sauvegarde terminée avec succès ==="
