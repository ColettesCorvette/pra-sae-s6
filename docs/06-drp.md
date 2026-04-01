# Disaster Recovery Plan (DRP)

> SAE S6.B.01 — BUT Informatique 3A, parcours DACS — Mars 2026

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Risk Assessment](#2-risk-assessment)
3. [Backup Strategy](#3-backup-strategy)
4. [Recovery Procedures](#4-recovery-procedures)
5. [RTO/RPO Summary Table](#5-rtorpo-summary-table)
6. [Lessons Learned](#6-lessons-learned)
7. [Architecture Diagram](#7-architecture-diagram)

---

## 1. Executive Summary

This document is the Disaster Recovery Plan (DRP) for the containerized infrastructure deployed as part of the SAE S6 project. It covers the BookStack wiki (with MariaDB), the Prometheus/Grafana supervision stack, and the MinIO object storage used for offsite backups.

**Backup strategy**: 3-2-1 rule — 3 copies of all critical data, on 2 different media (local loop device + S3 object storage), with 1 offsite copy (MinIO).

**Key objectives**:
- RPO (Recovery Point Objective): **24 hours** — daily automated backups at 02:00
- RTO (Recovery Time Objective): **< 1 hour** — all tested scenarios recovered in under 30 seconds

**Services covered**: BookStack (web application), MariaDB (database), Grafana (dashboards), MinIO (offsite backup storage).

---

## 2. Risk Assessment

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Disk failure (data loss) | Medium | Critical — all services down, data lost | Local Restic backups on separate loop device + offsite MinIO replication |
| Accidental volume deletion | High | High — database or uploads lost | Automated daily backups, restore scripts tested and documented |
| Ransomware / data encryption | Low | Critical — all local data compromised | Offsite copy on MinIO (separate storage), restore from S3 backend |
| Configuration error | Medium | Medium — service misconfigured | Configuration files included in backup (docker-compose.yml, .env) |
| Backup failure (unnoticed) | Medium | High — false sense of security | Prometheus monitoring, Alertmanager alerts if no backup > 25h or integrity check fails |
| Credential loss (Restic password) | Low | Critical — backups unrecoverable | Password file stored separately (secrets/restic-password), documented in team |

---

## 3. Backup Strategy

### 3-2-1 Rule Implementation

| Copy | Location | Type | Encryption |
|---|---|---|---|
| Copy 1 | Docker volumes (live data) | Production | No |
| Copy 2 | /mnt/restic-backup/repo (loop device) | Local backup | AES-256 (Restic) |
| Copy 3 | s3:http://localhost:9000/restic-backup (MinIO) | Offsite backup | AES-256 (Restic) |

### What is backed up

| Data | Method | Location in snapshot |
|---|---|---|
| MariaDB database | `mariadb-dump --single-transaction` | dumps/bookstack.sql |
| BookStack volume (uploads, config) | tar.gz via Alpine container | volumes/bookstack_data.tar.gz |
| Grafana volume (dashboards) | tar.gz via Alpine container | volumes/grafana_data.tar.gz |
| Configuration files (.env, compose) | File copy | config/ |

### Backup schedule

- **Frequency**: Daily at 02:00 (systemd timer with `Persistent=true`)
- **Retention**: 7 daily + 4 weekly + 12 monthly snapshots
- **Integrity**: `restic check` after every backup (local and remote)
- **Monitoring**: Prometheus metrics + Grafana dashboard + Alertmanager alerts

### Tools

- **Restic** (v0.18+): incremental, encrypted, deduplicated backups
- **MinIO**: S3-compatible self-hosted object storage
- **systemd timer**: scheduling
- **Prometheus + Grafana + Alertmanager**: monitoring and alerting

---

## 4. Recovery Procedures

> **Prerequisites for all procedures**:
> - Access to the Linux deployment machine (root or sudo)
> - The Git repository is cloned (adapt `PROJECT_DIR` if needed)
> - `secrets/restic-password` is present (gitignored file — retrieve from team lead)

Detailed step-by-step procedures are in the [restoration-procedures](restoration-procedures/) directory.

### 4.1. Scenario 1 — Partial file restoration

**Situation**: A specific file has been accidentally deleted or corrupted.

```bash
./scripts/restore/restore-file.sh config/bookstack.env
```

See: [partial-service-restoration.md](restoration-procedures/partial-service-restoration.md)

### 4.2. Scenario 2 — Database restoration

**Situation**: The MariaDB database is corrupted or data was accidentally deleted.

```bash
./scripts/restore/restore-db.sh
```

See: [database-restoration.md](restoration-procedures/database-restoration.md)

### 4.3. Scenario 3 — Full service restoration (disk failure)

**Situation**: The disk containing Docker volumes is lost. Containers and data are inaccessible.

```bash
cd bookstack/ && docker compose down -v && cd ..
./scripts/restore/restore-full.sh
```

See: [full-service-restoration.md](restoration-procedures/full-service-restoration.md)

### 4.4. Scenario 4 — Ransomware (restore from MinIO)

**Situation**: A ransomware has encrypted all local files, including Docker volumes AND the local Restic repository. Only the MinIO offsite copy is intact.

```bash
cd bookstack/ && docker compose down -v && cd ..
./scripts/restore/restore-ransomware.sh
```

See: [ransomware-restoration.md](restoration-procedures/ransomware-restoration.md)

---

## 5. RTO/RPO Summary Table

| Service | RPO Target | RTO Target | RTO Measured | Scenario |
|---|---|---|---|---|
| BookStack (file) | 24h | < 1h | **1 second** | Scenario 1 — partial restore |
| MariaDB (database) | 24h | < 30 min | **1 second** | Scenario 2 — DB restore |
| BookStack (full service) | 24h | < 1h | **21 seconds** | Scenario 3 — disk failure |
| BookStack (from MinIO) | 24h | < 1h | **21 seconds** | Scenario 4 — ransomware |
| Prometheus | N/A | < 15 min | Instant (`docker compose up`) | Stateless — no data to restore |
| Grafana (dashboards) | 24h | < 30 min | Included in scenario 3 | Provisioned via config files |

All measured RTOs are well under the targets defined in the strategy phase.

---

## 6. Lessons Learned

### What worked well

- **Restic** proved to be an excellent choice: incremental, encrypted, fast, and easy to use with both local and S3 backends
- **Docker volume export via Alpine container** solved the root-permission issues cleanly
- **The 3-2-1 strategy** was validated end-to-end: the ransomware scenario successfully restored from MinIO when the local repository was corrupted
- **Automated setup script** (`setup.sh`) enables full environment reproduction on a fresh machine (tested on Arch Linux, Debian, and Linux Mint)
- **Prometheus monitoring** provides immediate visibility on backup health without manual checks

### What failed or caused issues

- **Loop device lost after reboot**: an accidental `dd` while mounted corrupted the filesystem. Fixed by adding an fstab entry and documenting the setup process
- **Restic syntax change** (v0.17+): `--to-repo` became `--from-repo`, causing copy failures. Required investigation and script update
- **Docker volume permissions**: files owned by root inside containers couldn't be backed up directly. Solved by tar export via Alpine container
- **`docker-compose-plugin` not available on Linux Mint/Debian**: setup script had to be adapted for multiple distributions
- **Running backup.sh with sudo**: created root-owned files in reports/ and metrics/, causing permission errors on subsequent runs without sudo

### What could be improved in production

- **MinIO on a separate machine**: currently on the same host, which doesn't provide true offsite protection against hardware failure
- **Alertmanager receiver**: currently empty (no email/Slack configured). In production, alerts should be sent to the on-call team
- **Backup encryption key management**: the Restic password file should be stored in a proper secrets manager (e.g., HashiCorp Vault), not just a chmod 600 file
- **Automated restore testing**: scheduled restore tests (e.g., monthly) to verify backup integrity proactively, not just reactively

---

## 7. Architecture Diagram

```
+-----------------------------------------------------------------------+
|                        PRODUCTION MACHINE                              |
|                                                                        |
|   +-------------+   +--------------+   +------------------------+     |
|   |  BookStack   |   |   MariaDB    |   |  Supervision Stack     |     |
|   |  (web app)   |<->|  (bookstack  |   |  Prometheus / Grafana  |     |
|   |  :6875       |   |   database)  |   |  :9090 / :3000         |     |
|   +------+-------+   +------+-------+   +----------+-------------+     |
|          |                  |                       |                   |
|     Volume:                 |                  Volume:                  |
|     bookstack_data          |                  grafana-data             |
|          |                  | (SQL dump)            |                   |
|          +------------------+---------------+-------+                   |
|                             v                                          |
|                 +------------------------------+                       |
|                 |  backup.sh (daily at 02:00)  |                       |
|                 |  1. mariadb-dump             |                       |
|                 |  2. tar volumes Docker       |                       |
|                 |  3. restic backup (local)    |                       |
|                 |  4. restic copy  (MinIO)     |                       |
|                 |  5. restic forget (retention) |                       |
|                 |  6. restic check (integrity) |                       |
|                 |  7. JSON report + .prom      |                       |
|                 +------------+-----------------+                       |
|                              |                                         |
|              +---------------+---------------+                         |
|              v                               v                         |
|   +--------------------+       +----------------------+                |
|   | Local Restic Repo  |       | MinIO (S3)           |                |
|   | /mnt/restic-backup |       | :9000 (API)          |                |
|   | (loop device 2 GB) |       | :9001 (web console)  |                |
|   | Copy 2 - encrypted |       | Copy 3 - offsite     |                |
|   +--------------------+       +----------------------+                |
|                                                                        |
|   +----------------------------------------------------------------+  |
|   | MONITORING (node_exporter + Prometheus + Grafana)               |  |
|   | Reads metrics/backup.prom -> alerts if backup > 25h or error   |  |
|   +----------------------------------------------------------------+  |
|                                                                        |
|   +----------------------------------------------------------------+  |
|   | SCHEDULING: systemd timer (pra-backup.timer)                   |  |
|   | OnCalendar=*-*-* 02:00:00 — Daily at 2:00 AM                  |  |
|   +----------------------------------------------------------------+  |
+-----------------------------------------------------------------------+
```

### Technical Dependencies

| Component | Depends on | Impact if missing |
|---|---|---|
| BookStack | MariaDB | Starts but shows database error |
| MariaDB | Volume `bookstack_mariadb_data` | Starts with empty database |
| backup.sh | Docker, Restic, jq, BookStack running | May fail partially |
| Prometheus metrics | backup.sh executed at least once | Empty graphs in Grafana |
| Alertmanager alerts | Prometheus + alerts.yml | No alerts sent |
| MinIO replication | secrets/minio-credentials + MinIO running | Replication silently skipped |

---

*Document written as part of SAE S6.B.01 — BUT Informatique 3A, parcours DACS — April 2026*
