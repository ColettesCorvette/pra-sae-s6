# Ransomware Restoration (from MinIO)

Goal: Restore the BookStack service when both local Docker volumes and the local Restic repository have been compromised. Recovery is performed exclusively from the offsite MinIO (S3) backup.

## 1. Prerequisites

MinIO must be accessible (on the same machine or a separate host).

The file secrets/minio-credentials must be available (retrieve from a secure offsite copy if the local machine is compromised).

The RESTIC_PASSWORD_FILE must be present.

Docker and Docker Compose must be installed on the host machine.

## 2. Execution

First, ensure the compromised stack is fully stopped:

```bash
cd bookstack/ && docker compose down -v && cd ..
```

Then run the ransomware restoration script:

```bash
./scripts/restore/restore-ransomware.sh
```

The script performs the following steps automatically:
1. Loads MinIO credentials from secrets/minio-credentials
2. Connects to the remote Restic repository (s3:http://localhost:9000/restic-backup)
3. Verifies that the remote repository is accessible and lists available snapshots
4. Extracts the latest snapshot from MinIO to a temporary directory
5. Restores configuration files (.env, docker-compose.yml)
6. Launches the Docker stack (BookStack + MariaDB)
7. Waits for MariaDB to be ready
8. Drops and recreates the database, then reinjects the SQL dump
9. Restores the BookStack volume from the tar.gz archive
10. Restarts BookStack to apply the restored data

## 3. Manual Checks (Verifications)

Infrastructure Check: Verify that all containers are up and running:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Web Access: Open your browser at http://localhost:6875 and verify that you can log in and that previously uploaded content is visible.

Restic Local Repository: The local repository must be reinitialized after recovery:

```bash
sudo rm -rf /mnt/restic-backup/repo
sudo ./scripts/setup.sh
```

## 4. Success Criteria

The script completes with the message "=== Restauration depuis MinIO terminée ===".

All Docker containers (bookstack and bookstack_db) are in a "running" state.

Measured RTO: **21 seconds** (target: < 1 hour).
