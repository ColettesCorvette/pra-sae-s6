#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script de setup initial — PRA SAÉ S6
#
# Prépare l'environnement complet en une seule commande :
#   1. Loop device (disque de sauvegarde simulé)
#   2. Dépôt Restic local
#   3. BookStack (génération APP_KEY, .env, lancement)
#   4. MinIO (si credentials présents)
#
# Usage : sudo bash scripts/setup.sh
# =============================================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

LOOP_IMG="/opt/restic-disk.img"
LOOP_SIZE_MB=2048
MOUNT_POINT="/mnt/restic-backup"
RESTIC_REPO="${MOUNT_POINT}/repo"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Vérification des prérequis ----------------------------------------------
check_prereqs() {
    log "Vérification des prérequis..."
    local missing=()

    command -v docker  >/dev/null 2>&1 || missing+=("docker")
    command -v restic  >/dev/null 2>&1 || missing+=("restic")

    if [ ${#missing[@]} -gt 0 ]; then
        err "Paquets manquants : ${missing[*]}"
        err "Installer avec : sudo pacman -S ${missing[*]}"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        err "Docker n'est pas démarré. Lancer : sudo systemctl start docker"
        exit 1
    fi

    log "Prérequis OK (docker, restic)"
}

# --- Loop device -------------------------------------------------------------
setup_loop_device() {
    log "=== Configuration du loop device ==="

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        if [ -f "${RESTIC_REPO}/config" ]; then
            log "Loop device déjà monté et dépôt Restic présent. Skip."
            return
        fi
        log "Loop device monté mais pas de dépôt Restic. On continue."
        return
    fi

    # Créer l'image si elle n'existe pas
    if [ ! -f "${LOOP_IMG}" ]; then
        log "Création de l'image disque (${LOOP_SIZE_MB} Mo)..."
        dd if=/dev/zero of="${LOOP_IMG}" bs=1M count=${LOOP_SIZE_MB} status=progress
        log "Formatage en ext4..."
        mkfs.ext4 -F "${LOOP_IMG}"
    fi

    # Monter
    mkdir -p "${MOUNT_POINT}"
    mount -o loop "${LOOP_IMG}" "${MOUNT_POINT}"

    # Donner les droits à l'utilisateur qui a lancé sudo
    REAL_USER="${SUDO_USER:-$(whoami)}"
    chown "${REAL_USER}:${REAL_USER}" "${MOUNT_POINT}"

    log "Loop device monté sur ${MOUNT_POINT}"

    # Ajouter au fstab pour persistence après reboot
    if ! grep -q "${LOOP_IMG}" /etc/fstab 2>/dev/null; then
        echo "${LOOP_IMG}  ${MOUNT_POINT}  ext4  loop,nofail  0  0" >> /etc/fstab
        log "Entrée ajoutée dans /etc/fstab (montage automatique au boot)"
    fi
}

# --- Mot de passe Restic -----------------------------------------------------
setup_restic_password() {
    local pw_file="${PROJECT_DIR}/secrets/restic-password"
    mkdir -p "${PROJECT_DIR}/secrets"

    if [ -f "${pw_file}" ]; then
        log "Mot de passe Restic déjà présent. Skip."
        return
    fi

    log "Génération du mot de passe Restic..."
    openssl rand -base64 32 > "${pw_file}"
    chmod 600 "${pw_file}"

    # Donner la propriété au vrai utilisateur
    REAL_USER="${SUDO_USER:-$(whoami)}"
    chown "${REAL_USER}:${REAL_USER}" "${pw_file}"

    log "Mot de passe sauvegardé dans ${pw_file}"
}

# --- Dépôt Restic local ------------------------------------------------------
setup_restic_repo() {
    local pw_file="${PROJECT_DIR}/secrets/restic-password"

    if [ -f "${RESTIC_REPO}/config" ]; then
        log "Dépôt Restic local déjà initialisé. Skip."
        return
    fi

    log "Initialisation du dépôt Restic sur ${RESTIC_REPO}..."

    # Exécuter en tant que l'utilisateur réel (pas root)
    REAL_USER="${SUDO_USER:-$(whoami)}"
    su - "${REAL_USER}" -c "RESTIC_PASSWORD_FILE='${pw_file}' restic init --repo '${RESTIC_REPO}'"

    log "Dépôt Restic initialisé."
}

# --- BookStack ---------------------------------------------------------------
setup_bookstack() {
    log "=== Configuration de BookStack ==="

    local bs_dir="${PROJECT_DIR}/bookstack"
    local env_file="${bs_dir}/.env"

    if [ -f "${env_file}" ]; then
        # Vérifier que APP_KEY est renseigné
        local app_key=$(grep "^APP_KEY=" "${env_file}" | cut -d= -f2-)
        if [ -n "${app_key}" ] && [ "${app_key}" != "" ]; then
            log "BookStack .env existe avec APP_KEY. Skip."
            return
        fi
    fi

    # Copier le template si pas de .env
    if [ ! -f "${env_file}" ]; then
        cp "${bs_dir}/.env.example" "${env_file}"
        log "Fichier .env créé depuis .env.example"
    fi

    # Générer APP_KEY
    log "Génération de APP_KEY..."
    local app_key
    app_key=$(docker run --rm --entrypoint /bin/bash lscr.io/linuxserver/bookstack:latest appkey 2>/dev/null)
    if [ -z "${app_key}" ]; then
        warn "Impossible de générer APP_KEY. Renseigner manuellement dans ${env_file}"
        return
    fi

    # Injecter APP_KEY dans le .env
    sed -i "s|^APP_KEY=.*|APP_KEY=${app_key}|" "${env_file}"

    REAL_USER="${SUDO_USER:-$(whoami)}"
    chown "${REAL_USER}:${REAL_USER}" "${env_file}"

    log "APP_KEY générée et injectée dans ${env_file}"
}

# --- Lancement BookStack -----------------------------------------------------
start_bookstack() {
    if docker ps --format '{{.Names}}' | grep -q '^bookstack$'; then
        log "BookStack déjà en cours d'exécution. Skip."
        return
    fi

    log "Lancement de BookStack..."
    REAL_USER="${SUDO_USER:-$(whoami)}"
    cd "${PROJECT_DIR}/bookstack"
    su - "${REAL_USER}" -c "cd '${PROJECT_DIR}/bookstack' && docker compose up -d"
    cd "${PROJECT_DIR}"
    log "BookStack lancé sur http://localhost:6875"
    log "Identifiants par défaut : admin@admin.com / password"
}

# --- MinIO (optionnel) -------------------------------------------------------
setup_minio() {
    local minio_dir="${PROJECT_DIR}/minio"

    if [ ! -f "${minio_dir}/docker-compose.yml" ]; then
        warn "Pas de docker-compose MinIO trouvé. Skip."
        return
    fi

    log "=== Configuration de MinIO ==="

    # Créer .env si absent
    if [ ! -f "${minio_dir}/.env" ]; then
        if [ -f "${minio_dir}/.env.example" ]; then
            cp "${minio_dir}/.env.example" "${minio_dir}/.env"
            log "MinIO .env créé depuis .env.example"
        fi
    fi

    # Lancer MinIO si pas déjà en cours
    if ! docker ps --format '{{.Names}}' | grep -q '^minio$'; then
        REAL_USER="${SUDO_USER:-$(whoami)}"
        su - "${REAL_USER}" -c "cd '${minio_dir}' && docker compose up -d"
        log "MinIO lancé (API: http://localhost:9000, Console: http://localhost:9001)"
    else
        log "MinIO déjà en cours d'exécution. Skip."
    fi
}

# --- Résumé ------------------------------------------------------------------
print_summary() {
    echo ""
    log "========================================="
    log "  Setup terminé avec succès"
    log "========================================="
    echo ""
    echo "  Loop device    : ${MOUNT_POINT} (${LOOP_SIZE_MB} Mo)"
    echo "  Dépôt Restic   : ${RESTIC_REPO}"
    echo "  Mot de passe   : ${PROJECT_DIR}/secrets/restic-password"
    echo "  BookStack      : http://localhost:6875"
    echo "  MinIO console  : http://localhost:9001"
    echo ""
    echo "  Prochaine étape : bash scripts/backup/backup.sh"
    echo ""
}

# --- Main --------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    err "Ce script doit être lancé avec sudo."
    err "Usage : sudo bash scripts/setup.sh"
    exit 1
fi

check_prereqs
setup_loop_device
setup_restic_password
setup_restic_repo
setup_bookstack
start_bookstack
setup_minio
print_summary
