# Étape 1 — Analyse de l'existant et stratégie

## 1. Inventaire des données critiques

### Service : BookStack (application web)

| Donnée | Emplacement | Type | Criticité |
|---|---|---|---|
| Base de données MariaDB (contenu wiki, utilisateurs, permissions) | Volume `bookstack_mariadb_data` → `/var/lib/mysql` | Base de données | **Critique** — toutes les pages, livres et comptes utilisateurs |
| Configuration BookStack (fichiers Laravel, thèmes, uploads) | Volume `bookstack_bookstack_data` → `/config` | Fichiers applicatifs | **Critique** — inclut les uploads d'images/fichiers joints aux pages |
| `docker-compose.yml` | `bookstack/docker-compose.yml` | Fichier de configuration | **Important** — définition de l'infrastructure, versionné dans Git |
| `.env` (APP_KEY, mots de passe BDD, credentials LDAP) | `bookstack/.env` | Secrets | **Critique** — sans APP_KEY, BookStack ne peut pas déchiffrer les données en base. Non versionné |

### Détail de la base MariaDB

| Base | Contenu |
|---|---|
| `bookstack` | Base applicative : pages, livres, étagères, utilisateurs, permissions, tags, pièces jointes |
| `mysql`, `information_schema`, `performance_schema`, `sys` | Bases système — pas besoin de les sauvegarder, elles sont recréées automatiquement |

### Service : Stack de supervision (Prometheus/Grafana)

Déployée dans `autres-services/Audit-machine/supervision/`, cette stack conteneurisée assure le monitoring système.

| Donnée | Emplacement | Type | Criticité |
|---|---|---|---|
| Données Grafana (dashboards, préférences, alertes) | Volume `grafana-data` → `/var/lib/grafana` | Fichiers applicatifs | **Important** — dashboards personnalisés et configuration des datasources |
| Données Prometheus (séries temporelles) | Stockage interne conteneur (non persisté dans un volume nommé) | Base TSDB | **Faible** — données recollectées automatiquement après redémarrage, perte acceptable |
| Configuration Prometheus | `supervision/prometheus/prometheus.yml` | Fichier de configuration | **Important** — versionné dans Git |
| Configuration json_exporter | `supervision/json_exporter/config.yml` | Fichier de configuration | **Important** — versionné dans Git |
| Provisioning Grafana (datasources) | `supervision/grafana/provisioning/` | Fichier de configuration | **Important** — versionné dans Git |
| Dashboard Grafana exporté (JSON) | `supervision/grafana/dashboards/` | Fichier de configuration | **Important** — versionné dans Git |
| `docker-compose.yml` | `supervision/docker-compose.yml` | Fichier de configuration | **Important** — versionné dans Git |

**Note** : les conteneurs `agent_a` et `agent_b` sont stateless (ils lisent `/proc` du host et génèrent un JSON à la volée). Ils n'ont aucune donnée persistante à sauvegarder.

### Service : SAE Forensique

Le projet `autres-services/SAE-forensique/` contient uniquement des scripts d'analyse (C, Ruby, Bash) et un Makefile. **Aucun service Docker ni donnée persistante** — tout est versionné dans Git. Pas de sauvegarde nécessaire au-delà du dépôt Git lui-même.

### Résumé : ce qu'il faut sauvegarder

| # | Donnée | Source | Méthode |
|---|---|---|---|
| 1 | Dump SQL de la base `bookstack` | MariaDB | `mysqldump` avant sauvegarde |
| 2 | Volume `bookstack_bookstack_data` | BookStack | `restic backup` du volume |
| 3 | Volume `grafana-data` | Grafana | `restic backup` du volume |
| 4 | Fichier `.env` (secrets BookStack) | `bookstack/.env` | `restic backup` |
| 5 | Fichiers `docker-compose.yml` des deux stacks | Git + backup | `restic backup` (redondance avec Git) |

---

## 2. Objectifs de reprise : RPO et RTO

| Service | RPO (perte max acceptable) | RTO (durée max de coupure) | Justification |
|---|---|---|---|
| BookStack (application) | **24h** | **1h** | Wiki interne — les modifications sont peu fréquentes (quelques pages/jour). Une perte de 24h est acceptable. La remise en service doit être rapide car c'est le service principal. |
| MariaDB (base de données) | **24h** | **30 min** | La base est le coeur des données. Le RTO est plus court car la restauration d'un dump SQL est rapide (~minutes). |
| Grafana (dashboards) | **24h** | **30 min** | Les dashboards changent rarement. Les datasources et dashboards provisionnés sont dans Git, seules les modifications manuelles seraient perdues. |
| Prometheus (métriques) | **N/A** | **15 min** | Les séries temporelles se recollectent automatiquement. Pas de sauvegarde nécessaire — un simple redémarrage du conteneur suffit. |
| Fichier `.env` (secrets) | **N/A** (rarement modifié) | **5 min** | Fichier statique, changé uniquement lors d'un redéploiement. Copie à jour dans la sauvegarde. |

**Fréquence de sauvegarde retenue : 1 fois par jour (nuit, 02h00)**, cohérente avec un RPO de 24h.

---

## 3. Stratégie de sauvegarde : règle 3-2-1

La **règle 3-2-1** est le principe directeur de notre stratégie :

- **3 copies** des données : la donnée en production + la sauvegarde locale Restic + la sauvegarde externalisée (stockage objet)
- **2 supports différents** : le disque de production (volume Docker) + le dépôt Restic sur loop device (simule un disque séparé)
- **1 copie hors site** : répliquée vers un stockage objet distant (MinIO ou cloud)

### Pourquoi cette règle ?

| Scénario d'incident | Sans 3-2-1 | Avec 3-2-1 |
|---|---|---|
| Panne disque local | Données perdues | Restauration depuis la copie locale ou distante |
| Suppression accidentelle d'un volume | Données perdues | Restauration depuis Restic (snapshot antérieur) |
| Ransomware / chiffrement malveillant | Toutes les copies locales compromises | La copie hors site est intacte (stockage objet isolé) |
| Corruption silencieuse | Non détectée | Restic vérifie l'intégrité (`restic check`) |

### Architecture retenue

```
┌─────────────────────────────────────────────────────────────────┐
│                      Machine de production                      │
│                                                                 │
│   ┌──────────────┐  ┌──────────┐  ┌─────────┐  ┌──────────────┐  │
│   │  BookStack    │  │ MariaDB  │  │ Grafana │  │ .env+compose │  │
│   │  (volume)     │  │ (volume) │  │ (volume)│  │  (fichiers)  │  │
│   └──────┬───────┘  └────┬─────┘  └────┬────┘  └──────┬───────┘  │
│          │                   │                     │            │
│          │     Script orchestrateur (nuit, 02h00)  │            │
│          │         dump SQL + restic backup         │            │
│          ▼                   ▼                     ▼            │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │           Dépôt Restic local (loop device)              │   │
│   │     Copie 2 — chiffré, dédupliqué, versionné           │   │
│   └─────────────────────────┬───────────────────────────────┘   │
│                             │                                   │
│                      restic backup (S3)                         │
│                             │                                   │
└─────────────────────────────┼───────────────────────────────────┘
                              ▼
                 ┌────────────────────────┐
                 │   Stockage objet S3    │
                 │   (MinIO ou cloud)     │
                 │   Copie 3 — hors site  │
                 └────────────────────────┘
```

### Politique de rétention

```
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
```

| Granularité | Conservation | Justification |
|---|---|---|
| Quotidienne | 7 jours | Permet de restaurer n'importe quel jour de la dernière semaine |
| Hebdomadaire | 4 semaines | Couverture d'un mois complet |
| Mensuelle | 12 mois | Historique sur un an pour les besoins d'audit ou de rollback long |

---

## 4. Scénarios d'incident pour les tests de restauration

### Scénario 1 — Panne disque (données locales inaccessibles)

- **Description** : le disque contenant les volumes Docker tombe en panne. Les conteneurs ne démarrent plus.
- **Simulation** : arrêter les conteneurs, supprimer les deux volumes Docker (`docker volume rm`), puis restaurer depuis le dépôt Restic.
- **Données impactées** : volume BookStack + volume MariaDB
- **Procédure de reprise** : restauration complète depuis Restic → recréation des volumes → réinjection des données + dump SQL → relance de la stack.
- **RTO cible** : < 1h

### Scénario 2 — Suppression accidentelle d'un volume Docker

- **Description** : un opérateur exécute par erreur `docker volume rm bookstack_mariadb_data`, supprimant la base de données.
- **Simulation** : `docker compose down` puis `docker volume rm bookstack_mariadb_data`
- **Données impactées** : base MariaDB uniquement
- **Procédure de reprise** : restauration du dump SQL depuis un snapshot Restic (`restic restore --include`), recréation du volume, réinjection avec `mariadb < dump.sql`.
- **RTO cible** : < 30 min

### Scénario 3 — Ransomware simulé (chiffrement des données)

- **Description** : un ransomware chiffre tous les fichiers accessibles sur la machine, y compris les volumes Docker et les sauvegardes locales.
- **Simulation** : on remplace le contenu des volumes par des données aléatoires (sans utiliser de logiciel malveillant réel). On suppose que le dépôt Restic local est compromis.
- **Données impactées** : tous les volumes + dépôt Restic local
- **Procédure de reprise** : restauration depuis la copie externalisée (stockage objet S3, hors site) qui n'est pas touchée par le ransomware.
- **RTO cible** : < 1h (dépend du débit réseau pour le téléchargement)

---

## Récapitulatif

| Élément | Valeur |
|---|---|
| Services protégés | BookStack + MariaDB + Grafana (stack supervision) |
| RPO | 24h |
| RTO application | 1h |
| RTO base de données | 30 min |
| Fréquence de sauvegarde | Quotidienne (02h00) |
| Outil de sauvegarde | Restic (chiffré, dédupliqué, incrémental) |
| Stockage local | Dépôt Restic sur loop device |
| Stockage distant | Stockage objet S3 (MinIO ou cloud) |
| Rétention | 7 daily + 4 weekly + 12 monthly |
| Scénarios de test | Panne disque, suppression volume, ransomware simulé |
