#!/usr/bin/env bash
# ~/GetAllSubtitledApp/backup.sh
set -euo pipefail

BACKUP_DIR="${HOME}/GetAllSubtitledApp/backups"
STAMP=$(date +%Y%m%d-%H%M)
ARCHIVE="${BACKUP_DIR}/backup-${STAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

# Stop containers so files are consistent (volumes stay mounted)
docker compose stop backend

# Tar each volume via a temporary container, running as the host user
docker run --rm \
  -u "$(id -u):$(id -g)" \
  -v getallsubtitledapp_sessions:/sessions:ro \
  -v getallsubtitledapp_uploads:/uploads:ro \
  -v getallsubtitledapp_state:/state:ro \
  -v "$BACKUP_DIR":/backup \
  alpine tar czf "/backup/backup-${STAMP}.tar.gz" \
    -C / sessions uploads state

docker compose start backend

echo "Backup written to $ARCHIVE"
