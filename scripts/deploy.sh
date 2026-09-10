#!/usr/bin/env bash
# Déploiement OpsTrack en production
# Usage : bash deploy.sh [branche]
set -euo pipefail

APP_ROOT="/var/www/opstrack"
BRANCH="${1:-main}"
RELEASE_ID="$(date +%Y%m%d_%H%M%S)"

log() { printf "\033[1;34m[deploy]\033[0m %s\n" "$*"; }

log "Contrôles préalables"
command -v git      >/dev/null || { echo "git manquant"; exit 1; }
command -v composer >/dev/null || { echo "composer manquant"; exit 1; }
command -v php      >/dev/null || { echo "php manquant"; exit 1; }
mysql -uroot -p0000 -e "SELECT 1" >/dev/null 2>&1 || { echo "MySQL HS"; exit 1; }
redis-cli ping | grep -q PONG || { echo "Redis HS"; exit 1; }

log "Backup pré-déploiement"
mkdir -p /var/backups/opstrack
mysqldump -uroot -p0000 opstrack | gzip > "/var/backups/opstrack/predeploy_${RELEASE_ID}.sql.gz"

log "Pull du code"
cd "$APP_ROOT"
sudo -u ubuntu git fetch origin
sudo -u ubuntu git reset --hard "origin/${BRANCH}"

log "Dépendances"
sudo -u ubuntu composer install --no-dev --optimize-autoloader --no-interaction

log "Migrations"
sudo -u ubuntu php artisan migrate --force

log "Cache"
sudo -u ubuntu php artisan config:cache
sudo -u ubuntu php artisan route:cache
sudo -u ubuntu php artisan view:cache

log "Reload services"
sudo systemctl reload apache2
sudo systemctl restart opstrack-dispatch-dashboard

log "Enregistrement release"
echo "$RELEASE_ID" | sudo tee "$APP_ROOT/.last-release" > /dev/null

log "Déploiement OK : $RELEASE_ID sur branche $BRANCH"