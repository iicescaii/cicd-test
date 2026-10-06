#!/usr/bin/env bash
# Backs up the PRODUCTION Postgres database.
# - Runs automatically before every production deploy (called by deploy.sh).
# - Can also run nightly from cron:   0 2 * * * /opt/app/backup-db.sh >> /opt/app/backups/backup.log 2>&1
#
# Needs /opt/app/backup.env (only on the VPS, never in GitHub, chmod 600) with ONE line:
#   BACKUP_DATABASE_URL=postgres://USER:PASSWORD@localhost:5432/DBNAME
#
# Optional settings (environment variables):
#   PG_IMAGE   Postgres client image; same major version as the server or newer (default postgres:16)
#   KEEP_DAYS  How many days of backups to keep (default 14)
#
# Assumes Postgres is reachable on localhost from the VPS (installed directly, or a container
# with its port published on 127.0.0.1). If Postgres runs in a container with no published port,
# replace the pg_dump line with:  docker exec <postgres-container> pg_dump -U USER -Fc DBNAME > "$FILE"
#
# Restore (test this once during the pilot!):
#   docker run --rm -i --network host postgres:16 \
#     pg_restore --clean --if-exists -d "postgres://USER:PASSWORD@localhost:5432/DBNAME" < backups/<file>.dump
set -euo pipefail

cd /opt/app
# No backup settings = no backup = no production deploy. Fail loudly instead of skipping.
if [ ! -f backup.env ]; then
  echo "ERROR: /opt/app/backup.env not found, so the database can't be backed up." >&2
  echo "Create it (see the top of this file) before deploying to production." >&2
  exit 1
fi

PG_IMAGE="${PG_IMAGE:-postgres:16}"
KEEP_DAYS="${KEEP_DAYS:-14}"
mkdir -p backups
FILE="backups/db-$(date +%Y%m%d-%H%M%S).dump"

# Remove a half-written file if anything fails
trap 'rm -f "$FILE"' ERR

# The URL is passed with --env-file so the password never appears in the command line
docker run --rm --network host --env-file backup.env "$PG_IMAGE" \
  sh -c 'pg_dump --format=custom "$BACKUP_DATABASE_URL"' > "$FILE"

[ -s "$FILE" ] || { echo "Backup file is empty"; rm -f "$FILE"; exit 1; }
chmod 600 "$FILE"

find backups -name 'db-*.dump' -mtime +"$KEEP_DAYS" -delete

echo "Database backup saved: $FILE ($(du -h "$FILE" | cut -f1))"
echo "Tip: also copy backups off this server (another machine or cloud storage)."
