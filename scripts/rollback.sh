#!/usr/bin/env bash
# Rollback à la release précédente (via git reflog)
set -euo pipefail
cd /var/www/opstrack
PREV=$(sudo -u ubuntu git reflog --pretty=format:"%H" main | sed -n '2p')
[ -n "$PREV" ] || { echo "Pas de release précédente"; exit 1; }
sudo -u ubuntu git reset --hard "$PREV"
sudo -u ubuntu composer install --no-dev --optimize-autoloader --no-interaction
sudo -u ubuntu php artisan migrate --force
sudo -u ubuntu php artisan config:cache
sudo systemctl reload apache2 && sudo systemctl restart opstrack-dispatch-dashboard
echo "Rollback OK vers $PREV"