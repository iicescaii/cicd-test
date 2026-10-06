#!/usr/bin/env bash
# CD on the Linux server (WSL for the test, the VPS later). Copy to /opt/app/.
# Checks GHCR for new :staging and :production images and restarts ONLY the one that changed.
#
# Every 5 minutes (crontab -e):
#   */5 * * * * /opt/app/pull-deploy.sh >> /opt/app/deploy.log 2>&1
# Instantly: the deploy-instant job in ci.yml / promote.yml runs this on a self-hosted runner.
set -euo pipefail
cd /opt/app

# Only one run at a time (cron and the instant job can overlap)
exec 9>.deploy.lock
flock -n 9 || { echo "$(date '+%F %T') another deploy is running, skipping"; exit 0; }

log() { echo "$(date '+%F %T') $*"; }

IMAGE=$(grep -E '^IMAGE=' .env | cut -d= -f2- || true)
[ -n "$IMAGE" ] || { log "ERROR: put IMAGE=ghcr.io/owner/repo in /opt/app/.env"; exit 1; }

for ENV_NAME in staging production; do
  SVC="app-${ENV_NAME}"

  if ! docker pull -q "${IMAGE}:${ENV_NAME}" >/dev/null 2>&1; then
    log "${ENV_NAME}: nothing to pull yet, or no access to GHCR. Skipping"
    continue
  fi

  NEW=$(docker image inspect --format '{{.Id}}' "${IMAGE}:${ENV_NAME}")
  RUNNING=$(docker inspect --format '{{.Image}}' "$SVC" 2>/dev/null || true)
  if [ "$NEW" = "$RUNNING" ]; then
    continue   # already running the latest image
  fi

  # Safety net: back up the production database first. No backup = no production switch.
  if [ "$ENV_NAME" = production ]; then
    if ! bash ./backup-db.sh; then
      log "production: backup FAILED, production NOT updated (will retry next run)"
      continue
    fi
  fi

  docker compose up -d --no-deps "$SVC"
  REV=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${IMAGE}:${ENV_NAME}")
  # Timing check: how long after GitHub built the image did it go live here?
  BUILT=$(docker image inspect --format '{{.Created}}' "${IMAGE}:${ENV_NAME}")
  AGE=$(( $(date +%s) - $(date -d "$BUILT" +%s 2>/dev/null || date +%s) ))
  log "${ENV_NAME}: now running ${REV:-${NEW:7:12}} (live $((AGE / 60))m $((AGE % 60))s after the image was built)"
done

# Meeting requirement "prune": remove old images so the disk doesn't fill up
docker image prune -f >/dev/null
