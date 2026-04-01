# Étape 6 — Disaster Recovery Plan (DRP)

> SAÉ S6.B.01 — BUT Informatique 3A, parcours DACS — Mars 2026

---

## Table des matières

1. [Objectif et périmètre](#1-objectif-et-périmètre)
2. [Architecture globale et dépendances](#2-architecture-globale-et-dépendances)
3. [Tableau RPO / RTO — Théorique vs Mesuré](#3-tableau-rpo--rto--théorique-vs-mesuré)
4. [Procédures de reprise d'activité](#4-procédures-de-reprise-dactivité)
   - [Scénario 1 — Panne disque](#41-scénario-1--panne-disque)
   - [Scénario 2 — Suppression accidentelle](#42-scénario-2--suppression-accidentelle-dun-volume-docker)
   - [Scénario 3 — Ransomware](#43-scénario-3--ransomware)
5. [Checklist de validation post-reprise](#5-checklist-de-validation-post-reprise)
6. [Contacts et responsabilités](#6-contacts-et-responsabilités)

---

## 1. Objectif et périmètre

Ce document est le **Plan de Reprise d'Activité (PRA)** de l'infrastructure conteneurisée déployée dans le cadre de la SAÉ S6. Il décrit les procédures, les outils, les délais et les validations nécessaires pour restaurer les services en cas d'incident majeur.

### Services couverts par ce PRA

| Service | Rôle | Criticité |
|---|---|---|
| **BookStack** | Wiki interne (application web) | ⚠️ Élevée |
| **MariaDB** | Base de données de BookStack | 🚨 Critique |
| **Grafana** | Dashboards de supervision | ⚠️ Élevée |
| **Prometheus** | Collecte de métriques | 🟡 Modérée |
| **MinIO** | Stockage objet S3 (sauvegardes externalisées) | 🚨 Critique |

### Services exclus

- **Prometheus** : ses données (séries temporelles) ne sont pas persistées dans un volume nommé. Elles se recollectent automatiquement après redémarrage.
- **Agents d'audit** (`agent_a`, `agent_b`) : entièrement stateless, aucune donnée à restaurer.

---

## 2. Architecture globale et dépendances

```
┌───────────────────────────────────────────────────────────────────────┐
│                         MACHINE DE PRODUCTION                         │
│                                                                       │
│   ┌─────────────┐   ┌──────────────┐   ┌────────────────────────┐   │
│   │  BookStack   │   │   MariaDB    │   │  Stack Supervision     │   │
│   │  (web app)   │◄──►  (bookstack  │   │  Prometheus / Grafana  │   │
│   │  :8080       │   │   database)  │   │  :9090 / :3000         │   │
│   └──────┬───── ┘   └──────┬───────┘   └──────────┬─────────────┘   │
│          │                 │                        │                  │
│     Volume bookstack_       │                  Volume grafana-data     │
│     bookstack_data          │                  (dashboards)            │
│          │                 │ (dump SQL)                │               │
│          └──────────────────┼───────────────────────────────────────  │
│                             ▼                                          │
│                 ┌──────────────────────────────┐                      │
│                 │  SCRIPT backup.sh (02h00)    │                      │
│                 │  ─────────────────────────── │                      │
│                 │  1. mariadb-dump             │                      │
│                 │  2. tar volumes Docker       │                      │
│                 │  3. restic backup (local)    │                      │
│                 │  4. restic copy  (MinIO)     │                      │
│                 │  5. restic forget (rétention)│                      │
│                 │  6. restic check (intégrité) │                      │
│                 │  7. rapport JSON + .prom     │                      │
│                 └──────────┬───────────────────┘                      │
│                            │                                           │
│            ┌───────────────┴───────────────┐                          │
│            ▼                               ▼                           │
│   ┌────────────────────┐       ┌──────────────────────┐              │
│   │  Dépôt Restic LOCAL│       │  MinIO (S3)          │              │
│   │  /mnt/restic-backup│       │  :9000 (API)         │              │
│   │  (loop device 2 GB)│       │  :9001 (console web) │              │
│   │  Copie 2 — chiffré │       │  Copie 3 — hors site │              │
│   └────────────────────┘       └──────────────────────┘              │
│                                                                       │
│   ┌────────────────────────────────────────────────────────────────┐ │
│   │  SUPERVISION (node_exporter + Prometheus + Grafana)            │ │
│   │  Lit metrics/backup.prom → alerte si backup > 25h ou erreur   │ │
│   └────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│   ┌────────────────────────────────────────────────────────────────┐ │
│   │  PLANIFICATION : systemd timer (pra-backup.timer)             │ │
│   │  OnCalendar=*-*-* 02:00:00  — Tous les jours à 2h du matin   │ │
│   └────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### Dépendances techniques

| Composant | Dépend de | Impact si absent |
|---|---|---|
| BookStack | MariaDB | Démarre mais affiche une erreur de BDD |
| MariaDB | Volume `bookstack_mariadb_data` | Démarre avec une base vide |
| `backup.sh` | Docker, Restic, `jq`, BookStack en cours | Peut échouer partiellement |
| Métriques Prometheus | `backup.sh` exécuté au moins une fois | Graphiques vides dans Grafana |
| Alertes Alertmanager | Prometheus + `alerts.yml` | Aucune alerte envoyée |
| Réplication MinIO | `secrets/minio-credentials` et MinIO actif | Réplication silencieusement ignorée |

---

## 3. Tableau RPO / RTO — Théorique vs Mesuré

### Définitions

- **RPO** (Recovery Point Objective) : perte de données maximale acceptable — "jusqu'où en arrière peut-on remonter ?"
- **RTO** (Recovery Time Objective) : durée maximale de coupure de service acceptable — "combien de temps pour remettre en ligne ?"

### Tableau de synthèse

| Service | RPO Théorique | RTO Théorique | RTO Mesuré (test) | Scénario testé |
|---|---|---|---|---|
| BookStack (application) | **24h** | **< 1h** | _À mesurer lors de la démo_ | Scénario 1 & 3 |
| MariaDB (base de données) | **24h** | **< 30 min** | _À mesurer lors de la démo_ | Scénario 1 & 2 |
| Grafana (dashboards) | **24h** | **< 30 min** | _À mesurer lors de la démo_ | Scénario 1 |
| Prometheus (métriques) | **N/A** | **< 15 min** | Quasi-immédiat (`docker compose up`) | Pas de données à restaurer |

> **Note** : Les mesures "RTO Mesuré" doivent être renseignées lors des tests réels en salle (voir Étape 5). Le temps inclut la détection, la restauration et la vérification.

### Politique de rétention des sauvegardes

```
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
```

| Granularité | Conservation | Couverture |
|---|---|---|
| Quotidienne | 7 snapshots | Dernière semaine complète |
| Hebdomadaire | 4 snapshots | Dernier mois |
| Mensuelle | 12 snapshots | Dernière année |

---

## 4. Procédures de reprise d'activité

> **Prérequis pour toutes les procédures** :
> - Avoir accès à la machine Linux de déploiement (root ou sudo)
> - Le dépôt Git est cloné dans `/opt/pra-sae-s6` (ou adapter `PROJECT_DIR`)
> - `secrets/restic-password` est présent (fichier gitignored — à récupérer auprès du responsable)

---

### 4.1. Scénario 1 — Panne disque

**Situation** : le disque contenant les volumes Docker tombe en panne.  
Les conteneurs ne démarrent plus, les données sont inaccessibles.  
**Simulation** : `docker volume rm bookstack_bookstack_data bookstack_mariadb_data`

**Prérequis spécifiques** : Le dépôt Restic local (`/mnt/restic-backup`) est intact.

**Procédure** :

```bash
# 1. Arrêter la stack si encore partiellement active
docker compose -f /opt/pra-sae-s6/bookstack/docker-compose.yml down

# 2. Lancer la restauration complète
sudo bash /opt/pra-sae-s6/scripts/restore/restore-full.sh
```

**Ce que fait le script `restore-full.sh`** :
1. Monte le loop device si nécessaire (`/mnt/restic-backup`)
2. Restaure le dernier snapshot Restic vers `/tmp/restic-restore/`
3. Démarre uniquement MariaDB
4. Exécute `DROP DATABASE bookstack; CREATE DATABASE bookstack;` pour partir d'une ardoise propre
5. Réinjecte le dump SQL dans MariaDB
6. Restaure le volume BookStack depuis l'archive tar
7. Démarre BookStack
8. Affiche le temps de reprise

**Vérification post-reprise** : voir section [Checklist](#5-checklist-de-validation-post-reprise).

---

### 4.2. Scénario 2 — Suppression accidentelle d'un volume Docker

**Situation** : un opérateur exécute par erreur `docker volume rm bookstack_mariadb_data`.  
Seule la base de données est perdue, les uploads BookStack sont intacts.

**Procédure** :

```bash
# Restauration ciblée de la base de données uniquement
sudo bash /opt/pra-sae-s6/scripts/restore/restore-db.sh
```

**Ce que fait le script `restore-db.sh`** :
1. Monte le loop device si nécessaire
2. Restaure uniquement le dump SQL depuis le dernier snapshot Restic
3. S'assure que le conteneur MariaDB tourne (le relance si besoin)
4. Exécute `DROP DATABASE bookstack; CREATE DATABASE bookstack;`
5. Réinjecte le dump SQL
6. Redémarre BookStack

**Note** : les uploads et fichiers de configuration BookStack sont **intacts** — pas besoin de restaurer le volume `bookstack_bookstack_data`.

---

### 4.3. Scénario 3 — Ransomware

**Situation** : un ransomware a chiffré tous les fichiers accessibles sur la machine, y compris les volumes Docker **et le dépôt Restic local**. C'est le scénario de pire cas.  
La seule copie utilisable est la sauvegarde externalisée dans **MinIO**.

**Prérequis spécifiques** :
- MinIO est accessible (sur la même machine ou sur un hôte séparé)
- `secrets/minio-credentials` est récupérable (copie sécurisée hors machine)
- Le dépôt Restic distant est intact

**Procédure** :

```bash
# S'assurer que les credentials MinIO sont présents
# (les récupérer depuis une sauvegarde sécurisée ou le gestionnaire de secrets)
cp /chemin/securise/minio-credentials /opt/pra-sae-s6/secrets/minio-credentials

# Lancer la restauration depuis MinIO uniquement
sudo bash /opt/pra-sae-s6/scripts/restore/restore-ransomware.sh
```

**Ce que fait le script `restore-ransomware.sh`** :
1. Charge les credentials MinIO depuis `secrets/minio-credentials`
2. Vérifie la connectivité vers MinIO
3. Lance `restic restore` **directement depuis le dépôt S3 distant** (bypass du dépôt local compromis)
4. Restaure les volumes et le dump SQL depuis le snapshot distant
5. Effectue un `DROP DATABASE` + réinjection SQL
6. Restaure le volume BookStack
7. Relance la stack complète

> ⚠️ **Important** : après une restauration depuis le dépôt distant, réinitialiser le dépôt Restic local :
> ```bash
> # Supprimer l'image du loop device corrompue
> sudo rm /opt/restic-disk.img
> # Relancer le setup pour recréer le loop device et le dépôt local vierge
> sudo bash /opt/pra-sae-s6/scripts/setup.sh
> ```

---

## 5. Checklist de validation post-reprise

À exécuter **après chaque restauration**, quel que soit le scénario.

### ✅ Services Docker

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Attendu :

| Conteneur | Statut | Port |
|---|---|---|
| `bookstack` | `Up` | `0.0.0.0:8080->80/tcp` |
| `bookstack_db` | `Up` | (interne) |

### ✅ Accès à BookStack

- Ouvrir `http://<IP_MACHINE>:8080` dans un navigateur
- Vérifier que la page de connexion s'affiche
- Se connecter avec les credentials habituels
- Vérifier que les pages du wiki sont présentes et lisibles

### ✅ Intégrité des données

```bash
# Vérifier que la base de données répond
docker exec bookstack_db mariadb -uroot -p"$(grep DB_ROOT_PASS /opt/pra-sae-s6/bookstack/.env | cut -d= -f2)" \
  -e "SELECT COUNT(*) AS nb_pages FROM bookstack.pages;"
```

> Résultat attendu : un nombre > 0 si des pages avaient été créées avant l'incident.

### ✅ Dépôt Restic local

```bash
export RESTIC_REPOSITORY=/mnt/restic-backup/repo
export RESTIC_PASSWORD_FILE=/opt/pra-sae-s6/secrets/restic-password
restic snapshots    # lister les snapshots disponibles
restic check        # vérifier l'intégrité du dépôt
```

### ✅ Dépôt Restic distant (MinIO)

```bash
source /opt/pra-sae-s6/secrets/minio-credentials
export RESTIC_REPOSITORY=s3:http://localhost:9000/restic-backup
export RESTIC_PASSWORD_FILE=/opt/pra-sae-s6/secrets/restic-password
restic snapshots
restic check
```

### ✅ Métriques et supervision

```bash
# Vérifier que node_exporter scrape bien le fichier .prom
curl -s http://localhost:9100/metrics | grep backup_
```

Attendu : les métriques `backup_last_success_timestamp`, `backup_duration_seconds`, `backup_snapshot_size_bytes`, `backup_integrity_status` sont présentes.

- Ouvrir Grafana (`http://<IP>:3000`) → Dashboard "Sauvegardes Backup"
- Vérifier que `backup_integrity_status` est à **0 (OK)**

### ✅ Prochain backup automatique

```bash
systemctl status pra-backup.timer
systemctl list-timers pra-backup.timer
```

> Vérifier que le prochain déclenchement est bien planifié à 02h00.

---

## 6. Contacts et responsabilités

| Rôle | Responsabilité |
|---|---|
| **Responsable backup (Étape 3)** | Configuration MinIO, `backup.sh`, scripts de restauration |
| **Responsable supervision (Étape 4)** | `systemd`, Prometheus, Grafana, Alertmanager |
| **Responsable tests (Étape 5)** | Exécution des scénarios, mesure des RTO réels |
| **Responsable DRP (Étape 6)** | Ce document, mise à jour post-test |

---

*Document rédigé dans le cadre de la SAÉ S6.B.01 — BUT Informatique 3A, parcours DACS — Avril 2026*
