# MariaDB Database Restoration

Goal: Restore the BookStack database after a corruption or accidental deletion.

## 1. Prerequisites

Ensure the Restic repository is mounted/accessible at /mnt/restic-backup/repo.

The RESTIC_PASSWORD_FILE must be present.

The database container (bookstack_db) must be running (even if empty).

## 2. Execution

Run the automated restoration script:

```bash
./scripts/restore/restore-db.sh
```

## 3. Manual Checks (Verifications)

Logs Check: Ensure the script output displays "Tables trouvées: X" (where X > 0).

Application Check: Open your browser at http://localhost:6875 and verify that your pages and images are visible.

Database Check: Run the following command to see if the tables exist:

```bash
docker exec bookstack_db mariadb -u root -p[password] -e "USE bookstack; SHOW TABLES;"
```

## 4. Success Criteria

The script finishes with "=== Restauration terminée ===".

The BookStack dashboard is accessible without database connection errors.

Measured RTO: **1 second** (target: < 30 minutes).
