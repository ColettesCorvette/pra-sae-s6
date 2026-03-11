#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Scénario 1 — Restauration partielle
# Restaure un fichier ou dossier spécifique depuis un snapshot Restic
# Usage : ./restore-file.sh <chemin-dans-le-snapshot>
# Exemple : ./restore-file.sh config/bookstack.env
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESTORE_DIR="/tmp/restic-restore"
export RESTIC_PASSWORD_FILE="${PROJECT_DIR}/secrets/restic-password"
export RESTIC_REPOSITORY="/mnt/restic-backup/repo"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

TARGET="${1:-}"
if [ -z "${TARGET}" ]; then
    log "Usage : $0 <chemin-dans-le-snapshot>"
    log "Fichiers disponibles dans le dernier snapshot :"
    restic ls latest | head -30
    exit 1
fi

START_TIME=$(date +%s)

log "=== Restauration partielle : ${TARGET} ==="

# --- 1. Extraire le fichier depuis le snapshot -------------------------------
rm -rf "${RESTORE_DIR}"
mkdir -p "${RESTORE_DIR}"

log "Extraction depuis le dernier snapshot..."
restic restore latest \
    --target "${RESTORE_DIR}" \
    --include "${TARGET}"

# --- 2. Afficher ce qui a été restauré --------------------------------------
log "Fichiers restaurés :"
find "${RESTORE_DIR}" -type f -exec ls -lh {} \;

DURATION=$(( $(date +%s) - START_TIME ))
log "=== Restauration partielle terminée en ${DURATION} secondes ==="
log "Fichiers disponibles dans : ${RESTORE_DIR}"
log "Il reste à copier manuellement le fichier vers sa destination."
