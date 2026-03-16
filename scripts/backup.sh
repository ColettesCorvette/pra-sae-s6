#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script de sauvegarde — Étapes 2 & 3
# Étape 2 : Sauvegarde locale (dump MariaDB + volumes Docker → Restic local)
# Étape 3 : Réplication vers stockage objet MinIO (backend S3 de Restic)
# =============================================================================

# --- Configuration -----------------------------------------------------------
# Résout le chemin du projet à partir de l'emplacement du script
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_STAGING="/tmp/restic-staging"
RESTIC_REPO="/mnt/restic-backup/repo"

# prometheus
START_TIME=$(date +%s)
METRICS_DIR="${PROJECT_DIR}/metrics"
REPORT_DIR="${PROJECT_DIR}/reports"
mkdir -p "${METRICS_DIR}" "${REPORT_DIR}"

S3_STATUS="skipped"

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

# En cas d'erreur non gérée (set -e), écrire un rapport "failed"
# et mettre backup_integrity_status à 1 pour alerter Prometheus.
on_error() {
    local exit_code=$?
    local line_number=$1
    log "ERREUR à la ligne ${line_number} (code ${exit_code}) — rapport d'échec généré."

    local err_duration=$(( $(date +%s) - START_TIME ))

    # Rapport JSON failure
    cat > "${REPORT_DIR}/backup-$(date +%Y%m%d-%H%M%S).json" <<JSONEOF
{
  "date": "$(date -Iseconds)",
  "status": "failed",
  "duration_seconds": ${err_duration},
  "error_line": ${line_number},
  "error_code": ${exit_code}
}
JSONEOF

    # Métrique Prometheus : indique l'échec à node_exporter
    mkdir -p "${METRICS_DIR}"
    cat > "${METRICS_DIR}/backup.prom" <<PROMEOF
# HELP backup_integrity_status Statut de la vérification d'intégrité (0=OK, 1=erreur)
# TYPE backup_integrity_status gauge
backup_integrity_status 1
PROMEOF
}
trap 'on_error $LINENO' ERR

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
docker exec "${DB_CONTAINER}" mariadb-dump -u"${DB_USER}" -p"${DB_PASS}" --single-transaction --routines --triggers "${DB_NAME}" > "${BACKUP_STAGING}/dumps/${DB_NAME}.sql" 2>/dev/null
DUMP_SIZE=$(du -h "${BACKUP_STAGING}/dumps/${DB_NAME}.sql" | cut -f1)
log "Dump terminé : ${DUMP_SIZE}"

#--- Arret des conteneurs (BookStack + supervision pour cohérence des volumes)
log "Arrêt des conteneurs..."
docker stop bookstack bookstack_db 2>/dev/null || true
if docker ps --format '{{.Names}}' | grep -qE '^(grafana|prometheus|node_exporter|alertmanager)$'; then
    log "Arrêt de la stack supervision..."
    cd "${PROJECT_DIR}/supervision"
    docker compose stop 2>/dev/null || true
    cd "${PROJECT_DIR}"
fi

# --- 2. Export des volumes Docker en tar -------------------------------------
# Les fichiers dans les volumes appartiennent à root (UID 0 dans le conteneur).
# On les exporte en tar depuis un conteneur Alpine pour éviter les problèmes
# de permissions côté host. Restic sauvegardera les archives tar.
log "Export du volume BookStack (bookstack_data)..."
docker run --rm -v bookstack_bookstack_data:/source:ro -v "${BACKUP_STAGING}/volumes":/backup alpine tar czf /backup/bookstack_data.tar.gz -C /source .

log "Export du volume Grafana (grafana_data)..."

if docker volume inspect supervision_grafana-data >/dev/null 2>&1; then
    docker run --rm -v supervision_grafana-data:/source:ro -v "${BACKUP_STAGING}/volumes":/backup alpine tar czf /backup/grafana_data.tar.gz -C /source .
else
    log "WARN: Volume grafana-data introuvable, skip."
fi

# --- 3. Copie des fichiers de configuration ----------------------------------
log "Copie des fichiers de configuration..."
cp "${PROJECT_DIR}/bookstack/.env" "${BACKUP_STAGING}/config/bookstack.env"
cp "${PROJECT_DIR}/bookstack/docker-compose.yml" "${BACKUP_STAGING}/config/bookstack-compose.yml"

if [ -f "${PROJECT_DIR}/supervision/docker-compose.yml" ]; then
    cp "${PROJECT_DIR}/supervision/docker-compose.yml" "${BACKUP_STAGING}/config/supervision-compose.yml"
fi

# --- 4. Sauvegarde Restic ----------------------------------------------------
log "Lancement de restic backup..."
restic backup "${BACKUP_STAGING}" --tag bookstack --tag mariadb --tag config --verbose

#--- Redémarage des conteneurs
log "Redémarage des conteneurs..."
docker start bookstack_db bookstack
sleep 5 # attendre que MariaDB soit prête

# Relancer la supervision si elle était active
if [ -f "${PROJECT_DIR}/supervision/docker-compose.yml" ]; then
    log "Relance de la stack supervision..."
    cd "${PROJECT_DIR}/supervision"
    docker compose start 2>/dev/null || true
    cd "${PROJECT_DIR}"
fi

# --- 5. Politique de rétention -----------------------------------------------
# Étape 2 — exigée par le sujet (§2.3)
log "Application de la politique de rétention (local)..."
restic forget --keep-daily   7 --keep-weekly  4 --keep-monthly 12 --prune

# --- 6. Vérification de l'intégrité (local) ----------------------------------
log "Vérification de l'intégrité du dépôt local..."
restic check

log "Snapshots disponibles (dépôt local) :"
restic snapshots

# =============================================================================
# ÉTAPE 3 — Réplication vers MinIO (stockage objet S3)
# =============================================================================

# Chargement des credentials MinIO (gitignored)
MINIO_CREDS="${PROJECT_DIR}/secrets/minio-credentials"
if [ ! -f "${MINIO_CREDS}" ]; then
    log "WARN: ${MINIO_CREDS} introuvable — réplication S3 ignorée."
    log "      Copier secrets/minio-credentials.example → secrets/minio-credentials et remplir les valeurs."
else
    # shellcheck source=/dev/null
    source "${MINIO_CREDS}"

    RESTIC_REPO_S3="s3:http://localhost:9000/restic-backup"
    log "=== Début de la réplication vers MinIO (${RESTIC_REPO_S3}) ==="

    # --- 7. Copie des snapshots du dépôt local vers MinIO --------------------
    # 'restic copy' transfère uniquement les données manquantes (incrémental).
    # Depuis restic 0.17, la syntaxe est --from-repo (source) et --repo (destination).
    log "Copie des snapshots vers MinIO..."
    restic copy --from-repo "${RESTIC_REPOSITORY}" --from-password-file "${RESTIC_PASSWORD_FILE}" --repo "${RESTIC_REPO_S3}" --password-file "${RESTIC_PASSWORD_FILE}"

    # --- 8. Politique de rétention sur le dépôt distant ---------------------
    log "Application de la politique de rétention (MinIO)..."
    RESTIC_REPOSITORY="${RESTIC_REPO_S3}" restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune

    # --- 9. Vérification de l'intégrité du dépôt distant --------------------
    log "Vérification de l'intégrité du dépôt MinIO..."
    RESTIC_REPOSITORY="${RESTIC_REPO_S3}" restic check

    log "Snapshots disponibles (dépôt MinIO) :"
    RESTIC_REPOSITORY="${RESTIC_REPO_S3}" restic snapshots

    S3_STATUS="success"
    log "=== Réplication vers MinIO terminée avec succès ==="
fi

# --- . Génération du rapport JSON et des métriques (Étape 4) ---------------
log "Génération des rapports et métriques..."

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# On récupère les infos du dernier snapshot (nécessite l'outil 'jq')
if ! command -v jq &>/dev/null; then
    log "WARN: jq non installé — métriques et rapport JSON ignorés."
    log "      Installer avec : sudo pacman -S jq  (ou apt install jq)"
    log "=== Sauvegarde complète terminée avec succès ==="
    exit 0
fi

SNAPSHOT_ID=$(restic snapshots --json latest | jq -r '.[-1].short_id')
SNAPSHOT_SIZE=$(restic stats --json latest | jq -r '.total_size')

# Création du rapport JSON (Étape 1.g du guide)
cat > "${REPORT_DIR}/backup-$(date +%Y%m%d-%H%M%S).json" <<JSONEOF
{
  "date": "$(date -Iseconds)",
  "status": "success",
  "duration_seconds": ${DURATION},
  "snapshot_id": "${SNAPSHOT_ID}",
  "snapshot_size_bytes": ${SNAPSHOT_SIZE},
  "integrity_check": "passed",
  "s3_replication": "${S3_STATUS}"
}
JSONEOF

# --- . Écriture des métriques pour Prometheus (Etape 3.b du guide) ---
log "Écriture des métriques pour node_exporter..."
cat > "${METRICS_DIR}/backup.prom" <<PROMEOF
# HELP backup_last_success_timestamp Horodatage de la dernière sauvegarde réussie
# TYPE backup_last_success_timestamp gauge
backup_last_success_timestamp $(date +%s)

# HELP backup_duration_seconds Durée de la dernière sauvegarde en secondes
# TYPE backup_duration_seconds gauge
backup_duration_seconds ${DURATION}

# HELP backup_snapshot_size_bytes Taille du dernier snapshot en octets
# TYPE backup_snapshot_size_bytes gauge
backup_snapshot_size_bytes ${SNAPSHOT_SIZE}

# HELP backup_integrity_status Statut de la vérification d'intégrité (0=OK, 1=erreur)
# TYPE backup_integrity_status gauge
backup_integrity_status 0
PROMEOF

log "=== Sauvegarde complète terminée avec succès ==="
