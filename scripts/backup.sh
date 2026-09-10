#!/usr/bin/env bash
# Backup quotidien OpsTrack (MySQL + MongoDB + uploads)
# À installer en cron : 0 3 * * * ubuntu bash /var/www/opstrack/scripts/backup.sh
set -euo pipefail

DATE=$(date +%Y%m%d_%H%M)
DIR=/var/backups/opstrack
mkdir -p "$DIR"

# MySQL
mysqldump -uroot -p0000 opstrack | gzip > "$DIR/mysql_${DATE}.sql.gz"

# MongoDB
mongodump --host localhost:27017 --db opstrack_logs --archive --gzip > "$DIR/mongo_${DATE}.archive.gz"

# Uploads (storage)
tar czf "$DIR/storage_${DATE}.tar.gz" -C /var/www/opstrack storage/app/public 2>/dev/null || true

# Rétention 7 jours
find "$DIR" -type f -mtime +7 -delete

echo "[backup $DATE] OK"