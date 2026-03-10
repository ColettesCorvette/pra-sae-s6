#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script d'initialisation du stockage objet MinIO pour Restic
# Étape 3 — À exécuter UNE SEULE FOIS avant la première sauvegarde S3
# =============================================================================
# Prérequis :
#   - MinIO doit être démarré (cd minio/ && docker compose up -d)
#   - Le fichier secrets/minio-credentials doit exister
#   - Le fichier secrets/restic-password doit exister (dépôt local déjà init)
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINIO_CREDS="${PROJECT_DIR}/secrets/minio-credentials"
MINIO_URL="http://localhost:9000"
BUCKET_NAME="restic-backup"
RESTIC_REPO_S3="s3:${MINIO_URL}/${BUCKET_NAME}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Vérifications préalables ------------------------------------------------
if [ ! -f "${MINIO_CREDS}" ]; then
    echo "ERREUR : ${MINIO_CREDS} introuvable."
    echo "  → Copier secrets/minio-credentials.example → secrets/minio-credentials"
    echo "    et renseigner les valeurs (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)."
    exit 1
fi

if [ ! -f "${PROJECT_DIR}/secrets/restic-password" ]; then
    echo "ERREUR : secrets/restic-password introuvable."
    echo "  → Ce fichier doit contenir le mot de passe du dépôt Restic local."
    exit 1
fi

# Chargement des credentials MinIO
# shellcheck source=/dev/null
source "${MINIO_CREDS}"

export RESTIC_PASSWORD_FILE="${PROJECT_DIR}/secrets/restic-password"

# --- Vérification que MinIO est accessible -----------------------------------
log "Vérification de la disponibilité de MinIO (${MINIO_URL})..."
if ! curl -sf "${MINIO_URL}/minio/health/ready" > /dev/null 2>&1; then
    echo "ERREUR : MinIO ne répond pas sur ${MINIO_URL}."
    echo "  → Lancer MinIO avec : cd minio/ && docker compose up -d"
    echo "  → Puis attendre quelques secondes et relancer ce script."
    exit 1
fi
log "MinIO est opérationnel."

# --- Création du bucket via le client mc (Docker) ----------------------------
log "Création du bucket '${BUCKET_NAME}'..."

# mc tourne dans un conteneur éphémère rattaché au même réseau que MinIO.
# L'URL interne utilise le nom du conteneur ("minio") comme hostname,
# ce qui évite les problèmes de resolv host depuis l'intérieur d'un conteneur.
MINIO_INTERNAL_URL="http://minio:9000"

docker run --rm \
    --network minio_default \
    --entrypoint sh \
    minio/mc -c "
        mc alias set local ${MINIO_INTERNAL_URL} ${AWS_ACCESS_KEY_ID} ${AWS_SECRET_ACCESS_KEY} --api s3v4 2>&1 &&
        if mc ls local/${BUCKET_NAME} > /dev/null 2>&1; then
            echo 'Le bucket ${BUCKET_NAME} existe déjà.'
        else
            mc mb local/${BUCKET_NAME} &&
            echo 'Bucket ${BUCKET_NAME} créé avec succès.'
        fi
    "

# --- Initialisation du dépôt Restic sur MinIO --------------------------------
log "Initialisation du dépôt Restic sur MinIO (${RESTIC_REPO_S3})..."
if restic -r "${RESTIC_REPO_S3}" snapshots > /dev/null 2>&1; then
    log "Le dépôt Restic existe déjà sur MinIO — rien à faire."
else
    restic init --repo "${RESTIC_REPO_S3}"
    log "Dépôt Restic initialisé avec succès sur MinIO."
fi

log ""
log "=== Initialisation terminée ==="
log "Prochaines étapes :"
log "  1. Lancer une sauvegarde complète : bash scripts/backup.sh"
log "  2. Vérifier depuis la console MinIO : http://localhost:9001"
log "     (login : valeurs de secrets/minio-credentials)"
log "  3. Ou vérifier via Restic :"
log "     source secrets/minio-credentials"
log "     restic -r ${RESTIC_REPO_S3} snapshots"
