FROM debian:bookworm-slim
# Image de base légère (Debian 12 "bookworm") pour réduire la taille du conteneur

ENV DEBIAN_FRONTEND=noninteractive
# Évite les invites interactives pendant l'installation des paquets

# Installation des outils nécessaires dans le conteneur :
# - ruby        : exécuter le script d’audit script_final.rb
# - busybox     : fournit httpd (petit serveur web) et wget pour le healthcheck
# - iproute2    : commandes réseau (ip, etc.) si besoin dans le script
# - procps      : accès aux infos /proc (top, ps, etc.)
# - gawk / grep : traitement de texte / parsing
# - util-linux  : outils système divers (lsblk, etc.)
# - neofetch    : info système (utile pour debug/affichage)
# - openssh-client : client SSH si besoin pour tests ou extensions futures
# - ca-certificates : certificats racine pour HTTPS
RUN apt-get update && apt-get install -y --no-install-recommends \
    ruby busybox iproute2 procps gawk grep util-linux neofetch \
    openssh-client ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# Nettoie le cache APT pour alléger l’image

WORKDIR /app
# Répertoire de travail par défaut à l’intérieur du conteneur

COPY script_final.rb /app/script_final.rb
# Copie le script d’audit Ruby dans l’image

# Pas de CMD/ENTRYPOINT ici :
# la commande de démarrage (httpd + boucle Ruby) est définie dans docker-compose.yml
