# Partial Data Restoration

Goal: Restore a specific file or directory that was accidentally deleted or corrupted, using Restic's granular recovery capabilities.

## 1. Prerequisites

The Restic repository must be accessible at /mnt/restic-backup/repo.

The RESTIC_PASSWORD_FILE must be present in the secrets/ directory.

You must know the path of the file or folder within the backup (e.g., config/bookstack.env).

## 2. Execution

Run the automated script by providing the path of the item to restore as an argument:

```bash
# Ensure the script is executable
chmod +x scripts/restore-file.sh

# Example: Restore the BookStack environment configuration file
./scripts/restore-file.sh config/bookstack.env
```
Note: If run without arguments, the script will list the first 30 files available in the latest snapshot to help you find the correct path.

## 3. Manual Checks (Verifications)

File Extraction: Confirm the file exists in the temporary restore directory:

```bash
ls -lh /tmp/restic-restore/
```

Content Integrity: Verify the content of the restored file (e.g., use cat or tail to check if the data is readable).

Manual Deployment: Since the script only extracts the file to a safe staging area, you must manually copy it back to its production location after verification.

## 4. Success Criteria

The script completes with the message "=== Restauration partielle terminée ===". 

The specific file is successfully recovered to /tmp/restic-restore. 

The effective RTO (Recovery Time Objective) is measured and logged by the script.
