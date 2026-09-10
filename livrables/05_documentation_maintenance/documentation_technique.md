# Documentation technique — OpsTrack Field Service

## Vue d'ensemble

OpsTrack Field Service est une application Laravel 12 en PHP 8.4 de gestion d'interventions terrain. Elle est complétée par un microservice Next.js pour le tableau de bord de dispatch et un webhook PHP destiné à l'ingestion d'événements externes.

Les données métier sont stockées dans MySQL. MongoDB est utilisé pour les logs applicatifs et Redis pour le cache.

## Arborescence du code métier

```text
opstrack/
├── app/
│   ├── Http/
│   │   ├── Controllers/
│   │   │   ├── DashboardController.php        # Tableau de bord principal
│   │   │   ├── WebhookController.php          # Traitement des événements externes
│   │   │   └── Api/
│   │   │       ├── TicketController.php       # CRUD tickets, filtres et recherche
│   │   │       ├── TechnicianController.php
│   │   │       └── ExternalContextController.php # Enrichissement Open-Meteo
│   │   ├── Requests/                          # Validation des entrées API
│   │   └── Resources/                         # Sérialisation JSON API
│   ├── Models/                                # Ticket, Intervention, Site, Technician, User
│   └── Services/
│       └── EventLogService.php                # Journalisation vers MongoDB
├── config/
├── database/migrations/
├── microservices/dispatch-dashboard/          # Front Next.js dédié
├── public/hooks.php                           # Point d'entrée webhook
├── routes/
│   ├── api.php                                # Routes /api/v1, authentifiées
│   └── web.php                                # Route / et dashboard
└── scripts/                                   # deploy.sh, rollback.sh, backup.sh
```

## Composants d'infrastructure

| Composant | Version | Rôle | Configuration |
|---|---|---|---|
| Apache | 2.4 | Reverse proxy et service PHP | `/etc/apache2/sites-available/opstrack.conf` |
| PHP-FPM | 8.4 | Exécution Laravel | `/etc/php/8.4/fpm/` |
| MySQL | 8.0 | Données métier | Port 3306, accessible localement uniquement. |
| MongoDB | 7.0 | Logs applicatifs | Port 27017, accessible localement uniquement. |
| Redis | 7.0 | Cache et sessions | Port 6379, accessible localement uniquement. |
| Node.js + Next.js | 20 + 14 | Microservice de dispatch | Port 3000, proxifié par Apache sous `/dispatch-dashboard`. |

## Dépendances applicatives principales

- Laravel 12 ;
- `laravel/mongodb` pour la connexion à MongoDB ;
- `guzzlehttp/guzzle` pour l'appel à Open-Meteo ;
- Next.js 14 pour le microservice de dispatch.

La liste complète des dépendances est disponible dans `composer.lock` et dans `microservices/dispatch-dashboard/package.json`.

## Variables d'environnement critiques

- `APP_URL`, `APP_ENV=production`, `APP_DEBUG=false` ;
- `DB_*` pour MySQL, `MONGODB_*` pour MongoDB et `REDIS_*` pour Redis ;
- `OPSTRACK_API_TOKEN` pour l'authentification API ;
- `WEBHOOK_BASIC_USER` et `WEBHOOK_BASIC_PASSWORD` pour `hooks.php`.

Le fichier `.env` est en droits `640`, doit rester hors du dépôt Git et ne doit jamais être transmis dans cette documentation.

## Points d'entrée applicatifs

Voir `api.md` pour le détail des endpoints et des mécanismes d'authentification.