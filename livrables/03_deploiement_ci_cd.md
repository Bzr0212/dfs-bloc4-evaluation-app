# Livrable 03 — Déploiement automatisé qualification → production

Dans le cadre de cet examen blanc, j'ai mis en place une chaîne de déploiement automatisée pour OpsTrack. L'objectif est de vérifier le code avant sa mise en production, de limiter les actions manuelles et de pouvoir revenir rapidement à une version fonctionnelle en cas d'incident.

**Compétence mobilisée :** C31 — Automatiser le déploiement d'une application.

## 1. Stratégie retenue

J'ai retenu un déploiement déclenché à chaque `push` sur la branche `main` du dépôt GitHub. Le workflow GitHub Actions exécute d'abord les contrôles qualité, puis se connecte au serveur de production en SSH. Le serveur récupère alors le commit validé depuis GitHub et exécute le script `deploy.sh`.

Cette approche conserve une trace de chaque modification dans Git et dans l'historique GitHub Actions. Elle rend le déploiement reproductible, sans dépendre d'un outil de déploiement tiers coûteux à ce stade du projet.

L'environnement fourni ne comporte pas de serveur de qualification distinct. Dans l'architecture actuelle, les tests automatisés du runner GitHub Actions constituent donc le premier niveau de qualification avant le déploiement en production. Une promotion réelle qualification → production avec approbation manuelle est prévue dans l'architecture cible.

## 2. Outillage

| Outil | Rôle |
|---|---|
| GitHub Actions | Orchestration du pipeline d'intégration et de déploiement continus. |
| GitHub Secrets | Stockage chiffré de la clé SSH et des informations de connexion. |
| SSH | Connexion authentifiée du runner GitHub Actions vers l'instance EC2. |
| Bash | Exécution des scripts `deploy.sh` et `rollback.sh` sur le serveur. |
| Git | Récupération de la version validée depuis le dépôt distant. |
| Composer / Artisan | Installation des dépendances et opérations Laravel. |
| curl | Smoke test de l'API après le déploiement. |

## 3. Pipeline GitHub Actions (`.github/workflows/deploy.yml`)

Le workflow contient deux jobs successifs :

- `quality` : vérifie que le projet peut être installé, que les fichiers PHP sont syntaxiquement valides et que les tests Laravel passent ;
- `deploy` : ne démarre que si `quality` est terminé avec succès. Il lance le déploiement sur le serveur, réalise un smoke test, puis déclenche le rollback si nécessaire.

Les secrets à créer manuellement dans **Settings → Secrets and variables → Actions** sont les suivants :

| Secret | Contenu |
|---|---|
| `SSH_PRIVATE_KEY` | Contenu complet de la clé privée `ubuntu.pem`. Cette clé ne doit jamais être ajoutée au dépôt Git. |
| `SSH_KNOWN_HOSTS` | Empreinte SSH du serveur de production, afin de vérifier son identité avant la connexion. |
| `PROD_HOST` | `13.39.49.139` tant que le DNS n'est pas résolu vers l'instance. |

Le nom de domaine peut être défini comme variable non sensible du workflow :

```yaml
env:
  PROD_DOMAIN: eval-dfs-q-tlp-20265-01.it.students.fr
```

Le déroulement attendu du workflow est le suivant :

```text
push sur main
      ↓
job quality : installation, syntaxe PHP, tests Laravel
      ↓
job deploy : sauvegarde, mise à jour, migrations, caches, reload
      ↓
smoke test HTTP
      ↓
succès : déploiement validé / échec : rollback du code
```

## 4. Déroulement du job `quality`

Avant tout accès à la production, j'exécute les contrôles suivants dans le runner GitHub Actions :

```bash
composer install --no-interaction --prefer-dist
find app config database routes tests -type f -name '*.php' -print0 | xargs -0 -n1 php -l
php artisan test
```

Le job utilise PHP 8.4, conformément à l'environnement prévu pour le projet. Si une commande échoue, GitHub Actions marque le job `quality` en erreur et le job `deploy` ne démarre pas.

## 5. Script de déploiement (`scripts/deploy.sh`)

J'ai prévu un script Bash idempotent sur le serveur. Il réalise les étapes ci-dessous dans cet ordre :

1. Vérifier la disponibilité de Git, Composer, PHP, MySQL et Redis.
2. Enregistrer le commit actuellement déployé dans `.previous-release`.
3. Créer un dump MySQL horodaté dans `/var/backups/opstrack/` avant toute migration.
4. Exécuter `git fetch origin main`, puis positionner le dépôt sur le commit de `origin/main`.
5. Installer les dépendances avec `composer install --no-dev --optimize-autoloader`.
6. Appliquer les migrations Laravel avec `php artisan migrate --force`.
7. Reconstruire les caches Laravel : configuration, routes et vues.
8. Recharger Apache et redémarrer le microservice Next.js.
9. Enregistrer le commit déployé dans `.last-release`.

Les contrôles préalables sont exécutés avant toute modification du code. Si l'un d'eux échoue, le script s'arrête immédiatement grâce à `set -euo pipefail`.

```bash
set -euo pipefail

command -v git >/dev/null
command -v composer >/dev/null
command -v php >/dev/null
mysqladmin ping -h 127.0.0.1 --silent
redis-cli ping | grep -q PONG
```

## 6. Smoke test post-déploiement

Après le déploiement, le runner GitHub Actions vérifie que l'API répond correctement sur l'endpoint de santé :

```bash
curl -sk \
  --resolve "$PROD_DOMAIN:443:$PROD_HOST" \
  -o /dev/null \
  -w "%{http_code}" \
  "https://$PROD_DOMAIN/api/health"
```

L'option `--resolve` est nécessaire dans cet environnement car le DNS du domaine attribué ne pointe pas encore vers l'instance EC2. Le résultat attendu est `200`. Toute autre valeur est considérée comme un échec de mise en service.

## 7. Rollback (`scripts/rollback.sh`)

Si le smoke test échoue après le déploiement, le workflow se reconnecte au serveur et exécute `rollback.sh`. Le script récupère le commit stocké dans `.previous-release`, replace le dépôt sur cette version, réinstalle les dépendances, reconstruit les caches et recharge Apache ainsi que le microservice Next.js.

```bash
PREVIOUS_COMMIT=$(cat /var/www/opstrack/.previous-release)
git reset --hard "$PREVIOUS_COMMIT"
composer install --no-dev --optimize-autoloader --no-interaction
php artisan config:cache
php artisan route:cache
php artisan view:cache
sudo systemctl reload apache2
sudo systemctl restart opstrack-nextjs
```

Le rollback automatique concerne le code et les caches. Une migration de base de données ne peut pas toujours être annulée automatiquement, notamment lorsqu'elle supprime ou transforme des données. En cas d'échec lié aux migrations, je restaure donc le dump MySQL créé avant le déploiement, après validation de l'incident.

## 8. Conduite en cas d'échec

| Échec constaté | Action appliquée |
|---|---|
| Le job `quality` échoue | Le job `deploy` ne démarre pas. La production n'est pas impactée. |
| La connexion SSH est refusée | Aucun rollback n'est nécessaire. Je vérifie la clé `SSH_PRIVATE_KEY`, le secret `SSH_KNOWN_HOSTS`, l'utilisateur SSH et les règles UFW. |
| `deploy.sh` échoue avant la mise à jour du dépôt | Le script s'arrête ; le code en production reste inchangé. |
| `deploy.sh` échoue après la bascule du code mais avant la migration | Le workflow exécute le rollback du code vers `.previous-release`. |
| Une migration échoue | Je conserve le dump pré-déploiement et je restaure la base si nécessaire, car le rollback SQL doit être contrôlé. |
| Le smoke test retourne une valeur différente de `200` | Le workflow déclenche automatiquement le rollback du code et des services. |

## 9. Limites et améliorations prévues

- L'environnement fourni ne comprend pas de serveur de qualification distinct. À terme, la cible prévoit une promotion qualification → production avec une approbation manuelle GitHub Actions.
- Le déploiement est effectué sur place : il peut provoquer une micro-coupure lors du rechargement des services. Une stratégie blue/green n'est pas encore mise en œuvre.
- Les secrets sont stockés dans GitHub Secrets. Leur migration vers AWS Secrets Manager est prévue dans l'architecture cible.
- Le rollback du code est automatisé, mais les migrations de base de données doivent rester rétrocompatibles ou être restaurées à partir du backup MySQL pré-déploiement.