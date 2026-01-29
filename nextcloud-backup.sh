#!/bin/bash
# Nextcloud Database Backup
# Exports Dokku postgres DB, gzips, and uploads to Cloudflare R2
# Prunes backups older than 30 days

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    source "$SCRIPT_DIR/config.sh"
else
    echo "Error: config.sh not found" >&2
    exit 1
fi

# Validate required config
for var in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BACKUP_BUCKET; do
    if [[ -z "${!var}" ]]; then
        echo "Error: $var is not set in config.sh" >&2
        exit 1
    fi
done

R2_REGION="${R2_REGION:-auto}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
SERVICE_NAME="${1:-nextcloud-db}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_FILE="/tmp/${SERVICE_NAME}-${TIMESTAMP}.sql.gz"
S3_PATH="s3://${R2_BACKUP_BUCKET}/db-backups/${SERVICE_NAME}/${SERVICE_NAME}-${TIMESTAMP}.sql.gz"

LOG_FILE="$HOME/.homelab/db-backup.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$R2_REGION"

log "Starting backup of '$SERVICE_NAME'..."

# Export and compress
# Support both standalone container (nextcloud-postgres) and Dokku postgres plugin
if docker ps --format '{{.Names}}' | grep -q "^nextcloud-postgres$"; then
    # Standalone postgres container
    docker exec nextcloud-postgres pg_dump -U nextcloud nextcloud | gzip > "$BACKUP_FILE"
else
    # Dokku postgres plugin
    ssh dokku postgres:export "$SERVICE_NAME" | gzip > "$BACKUP_FILE"
fi

if [[ ! -s "$BACKUP_FILE" ]]; then
    log "Error: Backup file is empty"
    rm -f "$BACKUP_FILE"
    exit 1
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log "Backup created: $BACKUP_SIZE"

# Upload to R2
log "Uploading to R2..."
aws s3 cp "$BACKUP_FILE" "$S3_PATH" --endpoint-url "$R2_ENDPOINT"
log "Uploaded to $S3_PATH"

# Clean up local file
rm -f "$BACKUP_FILE"

# Prune backups older than 30 days
log "Pruning backups older than 30 days..."
CUTOFF=$(date -v-30d +%Y%m%d 2>/dev/null || date -d "30 days ago" +%Y%m%d)
aws s3 ls "s3://${R2_BACKUP_BUCKET}/db-backups/${SERVICE_NAME}/" --endpoint-url "$R2_ENDPOINT" | while read -r line; do
    FILE=$(echo "$line" | awk '{print $4}')
    if [[ -z "$FILE" ]]; then continue; fi
    # Extract date from filename (SERVICE-YYYYMMDD-HHMMSS.sql.gz)
    FILE_DATE=$(echo "$FILE" | grep -oE '[0-9]{8}' | head -1)
    if [[ -n "$FILE_DATE" && "$FILE_DATE" < "$CUTOFF" ]]; then
        log "  Pruning: $FILE"
        aws s3 rm "s3://${R2_BACKUP_BUCKET}/db-backups/${SERVICE_NAME}/${FILE}" --endpoint-url "$R2_ENDPOINT"
    fi
done

log "Backup complete!"
