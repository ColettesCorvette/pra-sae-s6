# Étape 3 — Externalisation vers un stockage objet (MinIO)

## Contexte

Cette étape met en œuvre la **copie 3 de la règle 3-2-1** : répliquer les sauvegardes Restic vers un stockage objet S3-compatible, hors du volume de production.

L'option retenue est **MinIO auto-hébergé** (Option A du sujet), déployé en Docker sur la même machine. En production réelle, MinIO serait déployé sur un serveur distinct ou remplacé par un cloud public pour garantir la séparation géographique.

---

## Architecture

```
Machine de production
│
├── BookStack + MariaDB (volumes Docker)
├── Grafana (volume Docker)
│
│  [1] dump SQL + export volumes (backup.sh)
│
├── Dépôt Restic LOCAL              ← Copie 2 (loop device /mnt/restic-backup)
│        │
│        │  [2] restic copy (incrémental, chiffré)
│        ▼
└── MinIO (conteneur Docker)        ← Copie 3 "hors site simulé"
     └── Bucket : restic-backup
          API S3 → http://localhost:9000
          Console → http://localhost:9001
```

---

## Fichiers ajoutés / modifiés

| Fichier | Description |
|---|---|
| `minio/docker-compose.yml` | Stack Docker pour MinIO (API S3 + console web) |
| `minio/.env.example` | Template des variables d'environnement MinIO |
| `secrets/minio-credentials.example` | Template des credentials pour Restic/scripts |
| `scripts/init-minio-repo.sh` | Script d'initialisation one-shot (bucket + repo Restic S3) |
| `scripts/backup.sh` | Modifié : ajout de `restic forget` (§2) + section réplication S3 (§3) |

---

## Procédure de déploiement

### Prérequis

- Docker installé et démarré
- Étape 2 réalisée : dépôt Restic local initialisé (`/mnt/restic-backup/repo`)
- Fichier `secrets/restic-password` présent

### 1. Configurer les credentials

```bash
# Copier les templates
cp minio/.env.example         minio/.env
cp secrets/minio-credentials.example secrets/minio-credentials

# Modifier les mots de passe dans les deux fichiers copiés
# (les valeurs par défaut peuvent être gardées pour un projet académique)
```

> **Important** : les fichiers `minio/.env` et `secrets/minio-credentials` sont dans `.gitignore` et ne seront jamais commités.

### 2. Démarrer MinIO

```bash
cd minio/
docker compose up -d
```

Vérifier que MinIO est opérationnel :

```bash
# Attendre ~10 secondes puis :
curl -s http://localhost:9000/minio/health/ready && echo "MinIO OK"

# Console web accessible sur :
# http://localhost:9001  (login : valeurs de minio/.env)
```

### 3. Initialiser le bucket et le dépôt Restic S3

```bash
bash scripts/init-minio-repo.sh
```

Sortie attendue :
```
[2026-XX-XX XX:XX:XX] Vérification de la disponibilité de MinIO...
[2026-XX-XX XX:XX:XX] MinIO est opérationnel.
[2026-XX-XX XX:XX:XX] Création du bucket 'restic-backup'...
Bucket restic-backup créé avec succès.
[2026-XX-XX XX:XX:XX] Initialisation du dépôt Restic sur MinIO...
created restic repository xxxxxxxx at s3:http://localhost:9000/restic-backup
[2026-XX-XX XX:XX:XX] === Initialisation terminée ===
```

### 4. Lancer la première sauvegarde complète

```bash
bash scripts/backup.sh
```

Le script réalise maintenant dans l'ordre :
1. Dump MariaDB
2. Export volumes Docker en tar.gz
3. Copie des fichiers de configuration
4. `restic backup` → dépôt local
5. `restic forget` → rétention sur le dépôt local
6. `restic check` → intégrité locale
7. `restic copy` → réplication vers MinIO
8. `restic forget` → rétention sur MinIO
9. `restic check` → intégrité MinIO

### 5. Vérifications

**Via Restic :**
```bash
source secrets/minio-credentials
export RESTIC_PASSWORD_FILE=secrets/restic-password
export RESTIC_REPOSITORY=s3:http://localhost:9000/restic-backup

restic snapshots    # liste les snapshots dans MinIO
restic check        # vérifie l'intégrité du dépôt distant
```

**Via la console MinIO :**
Ouvrir http://localhost:9001 → Buckets → `restic-backup` → Explorer

Les dossiers suivants doivent être présents : `data/`, `index/`, `keys/`, `snapshots/`

---

## Mesures de temps de transfert

> **À compléter lors de l'exécution sur la machine Linux du groupe.**

```bash
# Mesure de la première sauvegarde complète vers MinIO
time restic copy \
    --repo /mnt/restic-backup/repo \
    --to-repo s3:http://localhost:9000/restic-backup
```

| Métrique | Valeur mesurée |
|---|---|
| Durée du `restic copy` (première fois) | _à mesurer_ |
| Volume total stocké dans MinIO | _à mesurer_ (`mcli du local/restic-backup`) |
| Durée du `restic copy` (incrémental) | _à mesurer_ |
| Volume transféré (incrémental) | _à mesurer_ |

**Note** : MinIO tournant sur `localhost`, la latence réseau est quasi nulle. En production avec un stockage distant, les temps seraient dominés par la bande passante internet (typiquement 10–100× plus lents).

---

## Comparaison MinIO vs cloud public

| Critère | MinIO (Option A) | Cloud public — ex. Scaleway S3 (Option B) |
|---|---|---|
| **Coût** | Gratuit (open source) | Gratuit jusqu'à 75 Go chez Scaleway, puis ~0,01 €/Go/mois + frais d'egress |
| **Mise en œuvre** | `docker compose up` — aucun compte, aucune configuration réseau | Créer un compte, générer des API keys IAM, choisir une région, configurer HTTPS |
| **Souveraineté des données** | Totale — les données restent sur la machine du groupe | Données hébergées chez un tiers (Scaleway = France/Europe = RGPD-friendly) |
| **Performances** | Latence ≈ 0 ms (localhost), débit = vitesse du disque local | Latence 20–50 ms, débit limité par la connexion internet |
| **Fiabilité** | Mono-nœud, mono-disque — pas de redondance. Si la machine tombe, MinIO tombe | SLA 99.9%+, réplication multi-datacenter gérée par le fournisseur |
| **Scalabilité** | Limitée à un serveur (mode distribué nécessite plusieurs nœuds) | Illimitée — le fournisseur gère l'infrastructure |
| **Vrai hors-site** | Non (même machine) — insuffisant en cas de disaster complet | Oui — séparation géographique réelle |

**Conclusion** : MinIO est le choix adapté pour ce projet pédagogique — simplicité de déploiement, coût zéro, pas de compte à créer. En production, un cloud public (Scaleway, Backblaze B2) ou un MinIO distribué sur un serveur distant serait nécessaire pour garantir la séparation géographique de la règle 3-2-1.
