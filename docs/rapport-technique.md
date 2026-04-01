# Rapport technique — PRA SAE S6.B.01

> BUT Informatique 3A, parcours DACS — Avril 2026

---

## 1. Commandes Restic utilisées

### 1.1 Initialisation du depot

```bash
restic init --repo /mnt/restic-backup/repo
```

Cree un nouveau depot Restic chiffre (AES-256) sur le disque local (loop device de 2 Go). Le mot de passe est lu depuis `RESTIC_PASSWORD_FILE` (fichier chmod 600, jamais en clair dans les scripts).

### 1.2 Sauvegarde

```bash
restic backup /tmp/restic-staging --tag bookstack --tag mariadb --tag config --verbose
```

Sauvegarde incrementale : Restic decoupe les fichiers en blobs, les deduplique et ne stocke que les nouveaux blocs. Les tags permettent de filtrer les snapshots par la suite. Le dossier staging contient :
- `dumps/bookstack.sql` — dump MariaDB (`mariadb-dump --single-transaction`)
- `volumes/bookstack_data.tar.gz` — volume Docker exporte via conteneur Alpine
- `config/` — fichiers .env et docker-compose.yml

### 1.3 Politique de retention

```bash
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
```

Conserve les 7 derniers snapshots quotidiens, 4 hebdomadaires et 12 mensuels. `--prune` libere l'espace disque des blobs devenus orphelins apres suppression des anciens snapshots.

### 1.4 Verification d'integrite

```bash
restic check
```

Verifie que tous les packs de donnees sont lisibles, que les index sont coherents et qu'aucun blob n'est corrompu. Execute apres chaque sauvegarde sur le depot local et le depot distant.

### 1.5 Replication vers MinIO

```bash
restic copy \
    --from-repo /mnt/restic-backup/repo \
    --from-password-file secrets/restic-password \
    --repo s3:http://localhost:9000/restic-backup \
    --password-file secrets/restic-password
```

Copie incrementale des snapshots du depot local vers le depot S3 (MinIO). Seuls les blobs absents du depot distant sont transferes. La syntaxe `--from-repo` (source) / `--repo` (destination) est celle de Restic 0.17+.

### 1.6 Restauration

```bash
# Restauration complete
restic restore latest --target /tmp/restic-restore

# Restauration partielle (un seul fichier)
restic restore latest --target /tmp/restic-restore --include "dumps/bookstack.sql"

# Restauration depuis MinIO (si depot local corrompu)
RESTIC_REPOSITORY="s3:http://localhost:9000/restic-backup" restic restore latest --target /tmp/restic-restore
```

`latest` selectionne automatiquement le snapshot le plus recent. `--include` filtre par chemin pour ne restaurer qu'un fichier specifique.

### 1.7 Listing des snapshots

```bash
restic snapshots
```

Affiche tous les snapshots disponibles avec leur ID, date, host, tags et taille.

---

## 2. Resultats des tests de restauration

### 2.1 Protocole de test

Chaque scenario a ete teste sur une machine Arch Linux avec BookStack rempli de contenu (pages, images, utilisateurs). Le RTO est mesure automatiquement par les scripts (chronometre integre).

### 2.2 Resultats

| Scenario | Description | RTO cible | RTO mesure | Ecart |
|---|---|---|---|---|
| 1 — Fichier | Restauration partielle d'un fichier de config | < 1h | **1 seconde** | 3599x sous la cible |
| 2 — BDD | DROP + reimport du dump SQL dans MariaDB | < 30 min | **1 seconde** | 1799x sous la cible |
| 3 — Panne disque | Destruction totale (conteneurs + volumes) puis restauration locale | < 1h | **21 secondes** | 171x sous la cible |
| 4 — Ransomware | Repo local corrompu, restauration depuis MinIO | < 1h | **21 secondes** | 171x sous la cible |

### 2.3 Observations

- Le RPO effectif est de **24 heures** (frequence du timer systemd). En cas d'incident, on perd au maximum les donnees de la derniere journee.
- Les RTO mesures sont tres inferieurs aux cibles car l'infrastructure est legere (base de donnees < 100 Ko, volume < 1 Mo). En production avec des volumes de plusieurs Go, les temps augmenteraient proportionnellement mais resteraient largement sous la cible d'une heure.
- Le scenario ransomware (4) a le meme RTO que la panne disque (3) car le goulot d'etranglement est le demarrage des conteneurs Docker (~15 secondes), pas le transfert depuis MinIO.
- La verification post-restauration (nombre de tables, code HTTP) est automatisee dans les scripts.

---

## 3. Comparaison des solutions de stockage objet

Le sujet propose deux options pour l'externalisation (etape 3) : MinIO auto-heberge (option A) ou stockage cloud public (option B). Nous avons choisi l'option A. Voici la comparaison.

### 3.1 Tableau comparatif

| Critere | MinIO (auto-heberge) | Cloud public (Backblaze B2 / Scaleway) |
|---|---|---|
| **Cout** | Gratuit (open-source, heberge sur la meme machine) | Gratuit jusqu'a un quota (B2 : 10 Go, Scaleway : 75 Go), payant au-dela |
| **Complexite de mise en oeuvre** | Simple : un `docker compose up -d`, un bucket, un `restic init` | Moderee : creation de compte, configuration des cles API, endpoint distant |
| **Souverainete des donnees** | Totale — les donnees restent sur notre infrastructure | Donnees hebergees chez un tiers, soumises a sa politique de confidentialite et a la legislation du pays d'hebergement |
| **Performances** | Excellentes — transfert en reseau local (latence < 1ms) | Variables — dependantes de la bande passante internet (upload souvent limite) |
| **Disponibilite** | Dependante de notre infrastructure (pas de SLA) | Haute disponibilite garantie (SLA > 99.9%) |
| **Resilience reelle** | Faible — si la machine tombe, MinIO tombe aussi | Forte — stockage geographiquement separe, resistant aux sinistres locaux |
| **Scalabilite** | Limitee par le disque local | Quasi-illimitee |
| **Chiffrement** | Assure par Restic (cote client, AES-256) | Assure par Restic + chiffrement cote serveur optionnel |

### 3.2 Justification du choix

Nous avons choisi **MinIO** pour les raisons suivantes :

1. **Contexte pedagogique** : le projet est une SAE, pas une mise en production reelle. L'objectif est de demontrer la maitrise de la regle 3-2-1 et de l'architecture de sauvegarde, pas de fournir une resilience geographique reelle.

2. **Simplicite et reproductibilite** : un `docker compose up -d` suffit pour deployer MinIO. Le setup complet est automatise dans `setup.sh` et fonctionne sur Arch Linux, Debian et Linux Mint. Avec un service cloud, chaque membre du groupe aurait du creer un compte et configurer ses cles API.

3. **Souverainete** : les donnees restent sur notre infrastructure. Pas de risque de fuite vers un tiers, pas de dependance a un service externe.

4. **Cout nul** : pas de carte bancaire ni de quota a surveiller.

### 3.3 Limites reconnues

Dans un contexte de production reelle, MinIO sur la meme machine **ne constitue pas une vraie copie hors site**. Si le serveur brule ou est vole, les deux depots Restic (local et MinIO) sont perdus.

En production, il faudrait soit :
- Deployer MinIO sur un **serveur separe** (autre salle, autre site)
- Utiliser un **stockage cloud** (Backblaze B2, Scaleway, AWS S3) pour la copie 3
- Ou combiner les deux : MinIO local pour la rapidite + cloud pour la resilience geographique

---

*Document redige dans le cadre de la SAE S6.B.01 — BUT Informatique 3A, parcours DACS — Avril 2026*
