# Full service restoration

Goal: Fully recover the BookStack service (containers, configuration, and data) after a total system failure or accidental deletion of Docker volumes and containers.

## 1. Prerequisites

The Restic repository must be accessible at /mnt/restic-backup/repo.

The RESTIC_PASSWORD_FILE must be present.

Docker and Docker Compose must be installed on the host machine.

## 2. Execution

This script automates the extraction of the full snapshot, the restoration of configuration files, the restart of the Docker stack, and the reinjection of all data.

```bash
# Ensure the script is executable
chmod +x scripts/restore-full.sh

# Run the full restoration process
./scripts/restore-full.sh
```

## 3. Manual Checks (Verifications)

Infrastructure Check: Verify that all containers are up and running:

```bash
docker compose -f bookstack/docker-compose.yml ps
```

Database Check: Ensure the SQL dump was correctly reinjected by checking the table count in the logs (should match your previous backups).

Web Access: Open your browser at http://localhost:6875 and verify that you can log in and that previously uploaded images/attachments are visible.

HTTP Status: Check if the service returns a 200 OK status:

```bash
curl -I http://localhost:6875
```



```bash
docker exec bookstack_db mariadb -u root -p[password] -e "USE bookstack; SHOW TABLES;"
```

## 4. Success Criteria

The script completes with the message "=== Restauration complète terminée ===".

All Docker containers (bookstack and bookstack_db) are in a "running" state.

The effective RTO (Recovery Time Objective) is measured and compared to the target defined in the strategy phase.
