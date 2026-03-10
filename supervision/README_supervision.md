```markdown
# Supervision centralisée d’une machine Linux avec Prometheus et Grafana

## Sommaire

## Sommaire

- [1. Objectif du projet](#1-objectif-du-projet)
- [2. Vue d’ensemble de larchitecture](#2-vue-densemble-de-larchitecture)
- [3. Description des composants du dépôt](#3-description-des-composants-du-dépôt)
  - [3.1. Agents daudit](#31-agents-daudit-agent_-services-agenta-et-agentb)
  - [3.2. Exporter JSON → métriques Prometheus](#32-exporter-json--métriques-prometheus)
  - [3.3. Serveur Prometheus](#33-serveur-prometheus)
  - [3.4. Grafana et visualisation](#34-grafana-et-visualisation)
  - [3.5. Orchestration Docker](#35-orchestration-docker)
- [4. Détail du script Ruby daudit](#4-détail-du-script-ruby-daudit)
  - [4.1. Constantes et utilitaires](#41-constantes-et-utilitaires)
  - [4.2. Collecte dinformations système](#42-collecte-dinformations-système)
  - [4.3. Détection des services critiques](#43-détection-des-services-critiques)
  - [4.4. Construction du document-json](#44-construction-du-document-json)
- [5. Choix techniques principaux](#5-choix-techniques-principaux)
- [6. Pistes damélioration](#6-pistes-damélioration)


---

## 1. Objectif du projet

Ce projet est la suite d’un premier travail d’**audit système** plus simple.  
L’objectif est de transformer ce script d’audit en une **solution de supervision centralisée** :

- Collecter régulièrement des métriques système sur un hôte Linux (CPU, charge, mémoire, disques, services).  
- Exposer ces données sous forme de JSON via un agent tournant en conteneur.  
- Convertir ce JSON en **métriques au format Prometheus** grâce à un exporter.  
- Stocker et interroger ces métriques avec **Prometheus**.  
- Visualiser l’état de la machine en temps réel dans un **dashboard Grafana**.

---

## 2. Vue d’ensemble de l’architecture

L’architecture repose sur cinq briques principales, toutes orchestrées avec Docker :

- Deux **agents d’audit** (conteneurs `agent_a` et `agent_b`) qui exécutent le script Ruby, lisent les fichiers du système hôte et produisent un fichier `audit.json` servi via HTTP.  
- Un **json_exporter** qui interroge ces endpoints JSON et les traduit en métriques Prometheus.  
- Un **serveur Prometheus** qui interroge régulièrement le json_exporter et stocke les séries temporelles.  
- **Grafana**, configuré pour utiliser Prometheus comme source de données, avec un tableau de bord préconfiguré.  
- Un **réseau Docker dédié** qui interconnecte tous les services de supervision.

Le résultat est une supervision continue de la machine hôte à travers des graphiques et jauges (CPU, RAM, disques, services).

---

## 3. Description des composants du dépôt

### 3.1. Agents d’audit (`agent/`, services `agent_a` et `agent_b`)

- Le dossier `agent/` contient l’image Docker de l’agent :
  - Image de base Debian minimaliste (bookworm-slim).  
  - Installation des outils nécessaires au script d’audit (Ruby, outils système, BusyBox pour le serveur HTTP).  
  - Copie du script `script_final.rb` dans le conteneur.  
- Les services `agent_a` et `agent_b` dans `docker-compose.yml` :
  - Partagent l’espace PID du host et montent la racine du système (`/`) en lecture seule dans `/host`.  
  - Exécutent régulièrement le script Ruby à un intervalle configurable.  
  - Lagent un petit serveur HTTP BusyBox qui sert le fichier `audit.json` sur un port propre à chaque agent.  
  - Exposent leur port HTTP vers l’extérieur et sont reliés au réseau de supervision.

Dans l’état actuel, les deux agents auditent **la même machine hôte** (le même `/host`).

### 3.2. Exporter JSON → métriques Prometheus (`json_exporter/config.yml`)

- Le conteneur `json_exporter` utilise la configuration `json_exporter/config.yml`.  
- Le module `agent` décrit comment lire le JSON produit par le script Ruby et le transformer en métriques :
  - Un bloc `agent_info` expose des informations contextuelles (hostname, OS, kernel) sous forme de labels.  
  - Des blocs pour le CPU, la charge, la mémoire, les disques et les services définissent :
    - Le chemin dans le JSON où lire les données (via expressions de type JSONPath).  
    - Les labels associés (par exemple point de montage et device pour les disques, nom du service pour les services).  
    - Les valeurs numériques qui deviendront des métriques Prometheus (par exemple `usage_percent` pour le CPU, `used_bytes` pour la mémoire et les disques, `up` pour les services).  

Le json_exporter est donc le lien entre le **format JSON du script** et le **format de métriques de Prometheus**.

### 3.3. Serveur Prometheus (`prometheus/prometheus.yml`)

- La configuration globale définit l’intervalle de scrutation (`scrape_interval`) et l’intervalle d’évaluation des règles.  
- Un job dédié (`json_agents`) :
  - Considère chaque URL JSON d’agent comme une « target » logique.  
  - Utilise le endpoint `/probe` du json_exporter, en lui passant la cible réelle comme paramètre.  
  - Utilise des règles de « relabeling » pour :
    - Réécrire l’adresse réelle vers `json_exporter:7979`.  
    - Passer l’URL JSON de l’agent dans un paramètre `target`.  
    - Reporter cette URL dans le label `instance`, qui sert ensuite à distinguer les agents dans Grafana.  
- Un job séparé scrute l’exporter lui-même afin d’avoir des métriques internes sur son fonctionnement.

### 3.4. Grafana et visualisation (`grafana/`)

- Le provisioning de la data source (`grafana/provisioning/datasources/prometheus.yml`) déclare Prometheus comme source de données par défaut :
  - Adresse accessible depuis Grafana (`http://prometheus:9090`).  
  - Accès via proxy (les requêtes passent par le backend Grafana).  
- Un dashboard exporté au format JSON est fourni :
  - Affichage des charges CPU sous forme de jauges.  
  - Utilisation de la mémoire en pourcentage.  
  - Utilisation des disques par point de montage.  
  - État des services critiques (up/down) dans le temps.  

Grâce à cette configuration, un Grafana « prêt à l’emploi » est disponible dès le démarrage des conteneurs.

### 3.5. Orchestration Docker (`docker-compose.yml`)

Le fichier `docker-compose.yml` regroupe l’ensemble de la stack :

- Déclaration d’un réseau `monitoring` pour isoler la supervision.  
- Volume persistant pour Grafana (`grafana-data`) afin de conserver la configuration et les dashboards.  
- Services :
  - `agent_a` et `agent_b` : agents d’audit, avec montage de la racine du host en lecture seule, serveur HTTP, healthchecks et redémarrage automatique.  
  - `json_exporter` : exporte les métriques Prometheus à partir des endpoints JSON des agents.  
  - `prometheus` : instance Prometheus configurée avec le fichier de scraping du projet.  
  - `grafana` : interface de visualisation, préconfigurée pour utiliser Prometheus.

---

## 4. Détail du script Ruby d’audit

### 4.1. Constantes et utilitaires

- `SKIP_FS`  
  Liste des types de systèmes de fichiers à ignorer lors de l’inventaire des disques (tmpfs, proc, sysfs, etc.).  
  Permet d’éviter d’inclure des pseudo-filesystems sans intérêt pour l’usage disque réel.

- `SKIP_MOUNT_PREFIXES`  
  Liste de préfixes de points de montage à exclure (par exemple `/proc`, `/sys`, `/dev/pts`, etc.), pour ne garder que les systèmes de fichiers pertinents du point de vue de l’utilisateur.

- `SERVICE_CANDIDATES`  
  Dictionnaire associant un label de service (par exemple `sshd`) à une liste de noms de processus possibles.  
  Sert de base pour détecter si un service critique est en cours d’exécution.

- `HOST`  
  Chemin racine du système hôte tel qu’il est vu depuis le conteneur (`/host`).  
  Toutes les lectures de fichiers système se font via ce préfixe.

- `run(cmd)`  
  Exécute une commande dans le shell, renvoie sa sortie standard nettoyée.  
  Utilisé comme « plan B » quand une lecture directe de fichier ne suffit pas (par exemple `chroot` dans le système hôte).

- `safe_read(path)`  
  Tente de lire un fichier, renvoie `nil` en cas d’erreur.  
  Permet de gérer les cas où certains fichiers système n’existent pas ou sont inaccessibles.

### 4.2. Collecte d’informations système

- `meta`  
  Récupère les métadonnées de la machine auditée :
  - Hostname (fichier `/etc/hostname` du host, ou commande `hostname` dans un `chroot`).  
  - Nom du système d’exploitation à partir de `/etc/os-release`.  
  - Version du noyau via `uname -r` dans le host.  
  - Timestamp de génération du rapport.  
  Retourne un objet structuré regroupant ces informations.

- `read_load`  
  Lit le fichier `/proc/loadavg` du host, extrait les trois valeurs de charge moyenne (1, 5 et 15 minutes).  
  Retourne un objet avec les trois valeurs, prêtes à être exposées comme métriques.

- `read_mem`  
  Parse le fichier `/proc/meminfo` du host pour obtenir :  
  - La mémoire totale disponible.  
  - La mémoire disponible (ou mémoire libre si l’information n’est pas disponible).  
  - Le swap total et libre.  
  Calcule la mémoire réellement utilisée et le swap utilisé, en bytes.  
  Retourne un objet contenant ces quatre grandeurs (total, utilisé, swap total, swap utilisé).

- `read_cpu_times`  
  Lit la ligne `cpu` de `/proc/stat` du host pour récupérer les temps cumulés (user, nice, system, idle, iowait, etc.) depuis le démarrage.  
  Calcule deux valeurs :  
  - `idle` : temps total passé en idle (idle + iowait).  
  - `total` : somme de tous les temps CPU.  
  Sert de base pour le calcul du pourcentage d’utilisation CPU sur un intervalle.

- `read_cpu_usage_percent(interval = 0.5)`  
  Mesure l’utilisation CPU sur un court intervalle :
  - Lit une première fois les temps CPU (`read_cpu_times`).  
  - Patiente pendant `interval` secondes.  
  - Relit les temps CPU.  
  - Calcule la variation totale et la variation de temps idle, puis en déduit la fraction de temps occupé.  
  - Convertit cette fraction en pourcentage, arrondi à deux décimales.  
  Retourne ce pourcentage, ou `nil` si le calcul n’est pas possible.

- `read_cpu`  
  Appelle `read_cpu_usage_percent`, force la valeur à `0.0` en cas d’échec, puis renvoie un objet structuré contenant ce pourcentage.  
  C’est cette valeur qui sera exposée comme métrique de charge CPU par l’exporter.

- `read_disks`  
  - Lit la liste des systèmes de fichiers montés à partir de `/proc/1/mounts` du host (ou via une commande `chroot` si nécessaire).  
  - Pour chaque montage :
    - Ignore les types de FS ou points de montage qui figurent dans les listes d’exclusion.  
    - Vérifie que le répertoire correspondant existe sur le host.  
    - Utilise la commande `df` en bytes pour obtenir la taille totale et l’espace utilisé.  
  - Construit une liste d’objets contenant, pour chaque point de montage retenu :
    - Le chemin de montage.  
    - Le device associé.  
    - La taille totale et l’espace utilisé.  

### 4.3. Détection des services critiques

- `host_process_index`  
  Parcourt les répertoires `/host/proc/<PID>/comm` et `/host/proc/<PID>/cmdline` pour :
  - Constituer un ensemble des noms de commande (`comm`).  
  - Constituer une liste de lignes de commande complètes (`cmdline`).  
  Ces deux collections fournissent différentes « signatures » permettant de reconnaître les services.

- `read_services_map(candidates)`  
  Pour chaque service dans `SERVICE_CANDIDATES` :
  - Vérifie si l’un des noms de processus associés est visible dans les listes renvoyées par `host_process_index`.  
  - Dans le cas particulier de `systemd-journald`, considère le service comme actif si le socket du journal systemd existe.  
  Retourne une liste d’objets `{ name: ..., up: 0/1 }` indiquant si chaque service est considéré comme actif (1) ou inactif (0).

### 4.4. Construction du document JSON

- Code principal en fin de script :
  - Force le fuseau horaire.  
  - Construit un objet `result` contenant les sous-blocs :
    - `meta` (informations générales sur la machine).  
    - `cpu`, `load`, `mem`, `disk`, `services` (chacun provenant des fonctions dédiées).  
  - Écrit ce résultat dans `/app/audit.json`, avec un format JSON lisible.  
  - Affiche un message pour indiquer que le fichier a été généré.

C’est ce fichier JSON qui sera ensuite servi via HTTP par l’agent et consommé par le json_exporter.

---

## 5. Choix techniques principaux

- **Montage du système hôte dans le conteneur**  
  En montant `/` du host dans `/host` et en utilisant `pid: "host"`, le script peut :
  - Lire directement les fichiers de `/proc` du host.  
  - Avoir une vision fidèle des processus et des montages du système réel.  
  Ce choix simplifie la logique, mais suppose que le conteneur a des privilèges élevés.

- **Utilisation d’un format JSON intermédiaire**  
  Le script Ruby écrit un JSON structuré plutôt que d’exposer directement des métriques au format texte Prometheus.  
  Cela permet de :
  - Garder le script simple et indépendant de Prometheus.  
  - Déléguer la traduction au json_exporter, qui est fait pour ça et configurable sans changer le code.

- **Séparation des rôles**  
  - Agent : collecte et expose les données brutes.  
  - json_exporter : conversion JSON → métriques.  
  - Prometheus : collecte et stockage.  
  - Grafana : visualisation.  
  Cette séparation rend le système modulaire et facilement extensible.

- **Intervalle de mesure CPU court et scrutation régulière**  
  - Le script calcule l’usage CPU sur un court intervalle (par défaut 0,5 seconde) pour obtenir une mesure « instantanée ».  
  - Prometheus scrute les agents toutes les 10–15 secondes, ce qui donne un compromis raisonnable entre précision et charge.

---

## 6. Pistes d’amélioration

### 6.1. Limitation actuelle : deux agents sur la même machine

Dans la version actuelle, `agent_a` et `agent_b` montent tous les deux la **même racine de host** et partagent l’espace PID du même système.  
Concrètement, ils auditent exactement la **même machine** :

- Même hostname, même kernel, même `/proc`, mêmes systèmes de fichiers, mêmes services.  
- Les seules différences possibles viennent du moment exact où le script est exécuté (légères variations sur CPU et load).

Pour un usage réel, deux agents identiques sur la même machine apportent peu de valeur :

- Ils doublent les ressources consommées pour un bénéfice limité.  
- Ils peuvent même prêter à confusion dans les dashboards Grafana (deux « instances » qui représentent en fait le même host).

### 6.2. Vers un audit de deux machines différentes (1 agent par machine)

Pour auditer deux machines distinctes, une approche plus pertinente serait :

1. **Déployer un agent par machine**  
   - Machine 1 : déployer le conteneur `agent` (avec la même image et le même script Ruby), qui monte `/` de la machine 1 et expose `audit.json` via HTTP.  
   - Machine 2 : faire la même chose, mais sur la machine 2.  
   L’image `agent` reste la même, seule la machine hôte change.

2. **Centraliser la collecte dans Prometheus**  
   - Sur une machine dédiée (ou sur l’une des deux), déployer `json_exporter`, `prometheus` et `grafana`.  
   - Dans la configuration de Prometheus :
     - Remplacer les cibles actuelles (`http://agent_a:9101/audit.json`, `http://agent_b:9102/audit.json`) par les URLs HTTP réelles pointant vers les deux machines (par exemple `http://machine1:9101/audit.json` et `http://machine2:9101/audit.json`).  
     - Garder le même mécanisme de module `agent` dans le json_exporter.  
   - Le label `instance` permettra alors de distinguer clairement « machine1 » et « machine2 » dans les dashboards.

3. **Adapter l’orchestration en conséquence**  
   - Sur chaque machine auditée :
     - Un déploiement simple ne contient que l’agent (script + serveur HTTP).  
   - Sur la machine de supervision :
     - Le `docker-compose` central peut se limiter à `json_exporter`, `prometheus` et `grafana`.  
   - Une variante consiste à maintenir un `docker-compose` par machine (stack complète), mais à configurer Grafana pour interroger plusieurs Prometheus ; cette solution est plus lourde pour un TP.

4. **Évolution possible du code**  
   Le script Ruby n’a pas besoin de modification majeure pour auditer d’autres machines :  
   - Il suffit qu’il soit exécuté sur la machine cible, avec un montage de sa racine dans `/host`.  
   - Les métriques resteront cohérentes et comparables entre machines (mêmes noms, mêmes unités).  

### 6.3. Autres axes d’amélioration

- **Sécurisation**  
  - Ajouter de l’authentification et éventuellement du chiffrement pour l’accès à Grafana et Prometheus.  
  - Limiter les droits des conteneurs agents si le contexte de production le permet.

- **Extensibilité des métriques**  
  - Ajouter de nouvelles métriques (température, réseau, journaux d’application).  
  - Rendre la liste des services surveillés configurable via un fichier au lieu de constants en dur.

- **Factorisation et mutualisation**  
  - Utiliser des variables et des templates dans Grafana pour rendre le dashboard immédiatement réutilisable sur un grand nombre d’agents/machines.  
  - Prévoir un mécanisme d’ajout automatique de nouvelles cibles dans Prometheus (service discovery, fichiers générés, etc.).

---

Ce rapport résume le fonctionnement et la logique de chaque composant du projet, ainsi que le rôle de chaque fonction du script Ruby, tout en proposant des pistes concrètes pour faire évoluer cette architecture vers une supervision multi-machines plus pertinente.
```
