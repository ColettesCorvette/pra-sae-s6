# PRA — Plan de reprise d'activité et sauvegarde externalisée

> SAÉ S6.B.01 — BUT Informatique 3A, parcours DACS — Mars 2026

Solution de sauvegarde et de reprise d'activité pour une infrastructure de services Linux conteneurisés (BookStack + MariaDB, stack de supervision Prometheus/Grafana).

## Structure

```
pra-sae/
├── bookstack/              # Docker Compose + config de BookStack (service à protéger)
├── supervision/            # Stack Prometheus/Grafana (service à protéger)
├── scripts/
│   └── backup.sh           # Script de sauvegarde locale Restic
├── secrets/                # Mots de passe Restic, credentials MinIO (gitignored)
└── docs/
    ├── 01-analyse-strategie.md    # Étape 1 — Inventaire, RPO/RTO, règle 3-2-1
    ├── 01-analyse-strategie.txt   # Idem en texte brut
    └── 03-externalisation-guide.txt  # Guide pour l'étape 3 (MinIO)
```

## Démarrage rapide

```bash
# 1. Lancer BookStack
cd bookstack/
cp .env.example .env
# Renseigner APP_KEY, DB_PASS, DB_ROOT_PASS
docker compose up -d

# 2. Monter le loop device (simulé disque de sauvegarde)
sudo dd if=/dev/zero of=/opt/restic-disk.img bs=1M count=2048
sudo mkfs.ext4 /opt/restic-disk.img
sudo mkdir -p /mnt/restic-backup
sudo mount -o loop /opt/restic-disk.img /mnt/restic-backup
sudo chown $USER:$USER /mnt/restic-backup

# 3. Initialiser le dépôt Restic
export RESTIC_PASSWORD_FILE=secrets/restic-password
restic init --repo /mnt/restic-backup/repo

# 4. Lancer une sauvegarde
bash scripts/backup.sh
```
