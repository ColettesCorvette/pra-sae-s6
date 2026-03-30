# PRA — Plan de reprise d'activité et sauvegarde externalisée

> SAÉ S6.B.01 — BUT Informatique 3A, parcours DACS — Mars 2026

Solution de sauvegarde et de reprise d'activité pour une infrastructure de services Linux conteneurisés (BookStack + MariaDB, stack de supervision Prometheus/Grafana).

## Structure

```
pra-sae/
├── bookstack/                  # Service à protéger (BookStack + MariaDB)
├── minio/                      # Stockage objet S3 auto-hébergé
├── supervision/                # Prometheus, Grafana, Alertmanager, node_exporter
├── systemd/                    # Timer + service pour planification automatique
├── scripts/
│   ├── setup.sh                # Initialisation complète de l'environnement
│   ├── backup/
│   │   └── backup.sh           # Sauvegarde locale + réplication MinIO
│   ├── minio/
│   │   └── init-minio-repo.sh  # Initialisation du bucket et dépôt Restic S3
│   └── restore/
│       ├── restore-file.sh     # Scénario 1 — restauration partielle
│       ├── restore-db.sh       # Scénario 2 — restauration BDD
│       ├── restore-full.sh     # Scénario 3 — restauration complète
│       └── restore-ransomware.sh # Scénario 4 — restauration depuis MinIO
├── secrets/                    # Gitignored (mots de passe, credentials)
├── metrics/                    # Gitignored (métriques Prometheus générées)
├── reports/                    # Gitignored (rapports JSON générés)
└── docs/                       # Analyse, stratégie, documentation
```

## Démarrage rapide

```bash
# 1. Setup complet (installe les dépendances, crée le loop device, lance BookStack + MinIO)
sudo ./scripts/setup.sh

# 2. Lancer une sauvegarde (locale + réplication MinIO)
./scripts/backup/backup.sh
```

## Restauration

```bash
./scripts/restore/restore-file.sh config/bookstack.env  # fichier spécifique
./scripts/restore/restore-db.sh                          # base de données
./scripts/restore/restore-full.sh                        # service complet
./scripts/restore/restore-ransomware.sh                  # depuis MinIO (repo local corrompu)
```
