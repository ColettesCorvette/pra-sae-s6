# Full Service Restoration

Goal: Fully recover the BookStack service (containers, configuration, and data) after a total system failure or accidental deletion of Docker volumes and containers.

## 1. Prerequisites

The Restic repository must be accessible at /mnt/restic-backup/repo.

The RESTIC_PASSWORD_FILE must be present.

Docker and Docker Compose must be installed on the host machine.

## 2. Execution

First, ensure the old stack is fully stopped:

```bash
cd bookstack/ && docker compose down -v && cd ..
```

Then run the full restoration:

```bash
./scripts/restore/restore-full.sh
```

The script performs the following steps automatically:
1. Extracts the latest Restic snapshot to a temporary directory
2. Restores the configuration files (.env, docker-compose.yml)
3. Launches the Docker stack (BookStack + MariaDB)
4. Waits for MariaDB to be ready (up to 30 seconds)
5. Drops and recreates the database, then reinjects the SQL dump
6. Restores the BookStack volume from the tar.gz archive
7. Restarts BookStack to apply the restored data

## 3. Manual Checks (Verifications)

Infrastructure Check: Verify that all containers are up and running:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Web Access: Open your browser at http://localhost:6875 and verify that you can log in and that previously uploaded content is visible.

HTTP Status: Check if the service responds:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:6875
```

Expected: 302 (redirect to login page) or 200.

## 4. Success Criteria

The script completes with the message "=== Restauration complète terminée ===".

All Docker containers (bookstack and bookstack_db) are in a "running" state.

Measured RTO: **21 seconds** (target: < 1 hour).
