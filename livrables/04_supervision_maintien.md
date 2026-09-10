# Livrable 04 — Supervision, journalisation, sauvegarde et maintenance corrective

Dans le cadre de cet examen blanc, j'ai identifié les sources de logs utiles, défini une stratégie de sauvegarde et appliqué des correctifs sur les anomalies prioritaires. L'objectif est de pouvoir détecter un incident, en comprendre la cause, restaurer les données si nécessaire et assurer une reprise de service maîtrisée.

**Compétence mobilisée :** C32 — Superviser et assurer la maintenance corrective d'une application.

## 1. Journalisation exploitable

J'ai identifié les sources de logs suivantes sur le serveur :

| Composant | Fichier ou commande | Usage principal |
|---|---|---|
| Apache | `/var/log/apache2/opstrack_{access,error}.log` | Trafic HTTP, erreurs applicatives et réponses 5xx. |
| Laravel | `/var/www/opstrack/storage/logs/laravel.log` | Exceptions et erreurs applicatives. |
| MySQL | `/var/log/mysql/error.log` | Erreurs de la base relationnelle. |
| MongoDB | `/var/log/mongodb/mongod.log` | Erreurs de la base NoSQL. |
| Redis | `/var/log/redis/redis-server.log` | Erreurs et indisponibilités du cache. |
| Microservice Next.js | `journalctl -u opstrack-dispatch-dashboard` | Erreurs runtime du dashboard. |
| Système | `journalctl -u apache2 -u mysql -u mongod -u redis-server` | Événements et changements d'état des services. |

Laravel utilise le canal `LOG_CHANNEL=stack`. En environnement de qualification, le niveau `LOG_LEVEL=debug` facilite l'investigation. En production, un niveau `warning` est recommandé après stabilisation afin de limiter le volume de logs tout en conservant les événements significatifs.

## 2. Supervision et alertes

### 2.1 Solution mise en place à court terme : serveur unique

L'application expose déjà l'endpoint `/api/health`, qui retourne un code HTTP `200` et un timestamp lorsque le service est disponible.

J'ajoute un smoke test horaire dans `scripts/smoke_test.sh`. Il est exécuté par cron, écrit son résultat dans `/var/log/opstrack_smoke.log` et envoie une alerte avec `mailx` si le code HTTP reçu est différent de `200`.

```cron
0 * * * * /var/www/opstrack/scripts/smoke_test.sh >> /var/log/opstrack_smoke.log 2>&1
```

Ce contrôle permet de détecter rapidement une indisponibilité totale de l'application, mais il ne remplace pas une supervision centralisée.

### 2.2 Solution cible

Dans l'architecture cible définie dans le livrable 01, la supervision sera complétée par :

- CloudWatch Agent sur EC2 pour suivre le CPU, la mémoire, l'espace disque et le réseau ;
- CloudWatch Logs pour centraliser les logs Apache et Laravel ;
- CloudWatch Alarms, puis SNS vers Slack ou email, selon les seuils suivants :
  - CPU supérieur à 80 % pendant 5 minutes ;
  - latence ALB P95 supérieure à 1 seconde pendant 5 minutes ;
  - taux de réponses 5xx supérieur à 1 % pendant 5 minutes ;
  - espace disque libre inférieur à 20 % ;
- Datadog APM, en option à l'étape de croissance, pour tracer les requêtes Laravel et détecter les problèmes de type N+1.

## 3. Sauvegarde et restauration

J'ai prévu le script `scripts/backup.sh`, exécuté quotidiennement à 03h00 par cron. Il réalise les sauvegardes suivantes :

| Élément sauvegardé | Méthode | Emplacement local |
|---|---|---|
| Base MySQL `opstrack` | `mysqldump` compressé | `/var/backups/opstrack/mysql_YYYYMMDD_HHMM.sql.gz` |
| Base MongoDB `opstrack_logs` | `mongodump --archive --gzip` | `/var/backups/opstrack/mongo_YYYYMMDD_HHMM.archive.gz` |
| Fichiers applicatifs téléversés | `tar czf storage/app/public` | `/var/backups/opstrack/storage_YYYYMMDD_HHMM.tar.gz` |

La rétention locale est fixée à 7 jours. À terme, les sauvegardes seront répliquées hors site vers Amazon S3, avec chiffrement KMS et une règle de cycle de vie vers Glacier après 90 jours.

Un test de restauration MySQL a été validé sur une base de test isolée :

```bash
gunzip -c mysql_YYYYMMDD_HHMM.sql.gz | mysql -u root -p opstrack_test
```

Le mot de passe est demandé de manière interactive et n'est pas inclus dans la commande ni dans le dépôt.

Le RPO actuel est de 24 heures, correspondant à la fréquence du backup quotidien. Le RTO est estimé à environ 30 minutes. La cible est un RPO de 15 minutes via des sauvegardes incrémentales et un RTO de 15 minutes grâce à un failover RDS Multi-AZ.

## 4. Diagnostic et correctifs appliqués

### 4.1 Note de transparence

Lors de l'audit du dépôt, j'ai constaté qu'un fichier `docs/confidential-defects.md`, présenté comme non destiné aux candidats, était accessible dans le dépôt public. Cette exposition constitue une fuite d'information de type *Information Disclosure*.

Je signale cette faille sans reproduire le contenu du document. Les anomalies présentées ci-dessous ont été vérifiées individuellement par lecture directe du code et par des tests contrôlés sur l'environnement d'évaluation.

### 4.2 Bug corrigé — Filtres de recherche de tickets incohérents

**Symptôme :** la combinaison du filtre `search` avec le filtre `priority` renvoyait des tickets hors du périmètre attendu.

**Cause :** dans `TicketController@index`, l'utilisation de `orWhereRaw` sans regroupement dans une closure fusionnait la recherche avec les autres filtres par un `OR` global.

Avant le correctif :

```php
$query->where('title', 'like', "%{$search}%")
    ->orWhereRaw("reference like '%{$search}%'");
```

Après le correctif :

```php
$query->where(function ($q) use ($search) {
    $q->where('title', 'like', "%{$search}%")
      ->orWhere('reference', 'like', "%{$search}%");
});
```

**Validation :** les combinaisons `search + priority` renvoient désormais l'intersection attendue : la recherche porte sur le titre **ou** la référence, puis le filtre de priorité est appliqué avec un `AND`.

### 4.3 Faille de sécurité corrigée — Injection SQL

**Nature :** la requête `orWhereRaw("reference like '%{$search}%'")` interpolait directement une donnée saisie par l'utilisateur dans une requête SQL brute. Cette pratique ouvrait une possibilité d'injection SQL.

**Constat :** un test contrôlé, réalisé uniquement sur l'environnement d'évaluation, a confirmé qu'une entrée contenant des caractères SQL modifiait la requête construite. Aucune donnée sensible n'a été extraite pendant cette vérification.

**Correctif :** j'ai remplacé `orWhereRaw` par `orWhere('reference', 'like', "%{$search}%")`, au sein de la closure. Eloquent délègue alors l'échappement de la valeur au driver SQL et utilise des requêtes préparées.

**Validation :** après correction, les caractères spéciaux saisis dans le filtre sont traités comme du texte de recherche. Ils ne peuvent plus modifier la structure de la requête SQL.

### 4.4 Bug corrigé — Dashboard Next.js vide

**Symptôme :** le microservice `dispatch-dashboard` répondait correctement mais n'affichait aucun ticket, alors que l'API Laravel retournait bien les données.

**Cause :** le client Node lisait `payload.items`, alors que l'API Laravel, via une Resource Collection, retourne les éléments dans `payload.data`.

**Correctif :** dans `microservices/dispatch-dashboard/lib/*.ts`, j'ai remplacé :

```typescript
return payload.items ?? [];
```

par :

```typescript
return payload.data ?? [];
```

**Validation :** le dashboard affiche désormais les tickets retournés par l'API Laravel.

### 4.5 Rappel des failles corrigées dans le livrable 02

Les corrections ci-dessous sont documentées en détail dans `02_exploitation_securisee.md` :

- phpMyAdmin était accessible publiquement avec des identifiants de démonstration : son virtual host a été désactivé et l'accès local est limité à `127.0.0.1` si une maintenance l'exige ;
- le fichier `.env` était en `644` et lisible par tous : ses droits sont désormais `640`, avec le propriétaire `ubuntu:www-data` ;
- `APP_DEBUG=true` et `APP_ENV=local` étaient actifs en production : les valeurs sont maintenant `false` et `production` ;
- l'absence de HTTPS a été corrigée par un certificat auto-signé et une redirection permanente HTTP vers HTTPS ;
- UFW, auparavant inactif, a été activé avec une politique restrictive : refus entrant par défaut et ouverture des seuls ports `22`, `80` et `443`.

### 4.6 Bug corrigé — Webhook sans déduplication

**Symptôme :** chaque appel du webhook `hooks.php` avec le même `external_event_id` créait une nouvelle intervention en base, provoquant des doublons.

**Cause :** `WebhookController::handle()` utilisait `Intervention::query()->create([...])` sans vérifier l'existence préalable d'une intervention avec le même `external_event_id`.

**Correctif :** j'ai remplacé la création systématique par `Intervention::query()->updateOrCreate(['external_event_id' => ...], [...])` lorsqu'un `external_event_id` est fourni. En l'absence de cet identifiant, une création simple est conservée.

**Validation :** deux appels successifs du même webhook avec `external_event_id=ext_abc123` ne créent plus qu'une seule intervention : le second appel met à jour la première.

### 4.7 Bug corrigé — Webhook forçait le statut à `scheduled`

**Symptôme :** après un appel webhook, le statut du ticket était systématiquement `scheduled`, quel que soit le statut envoyé dans le payload. Cela créait un écart entre l'état externe et l'état enregistré en base.

**Cause :** `WebhookController::handle()` contenait l'instruction `$ticket->update(['status' => 'scheduled'])`, avec une valeur écrite en dur.

**Correctif :** j'ai remplacé cette instruction par `$ticket->update(['status' => $payload['status']])` afin de refléter le statut réellement transmis.

**Validation :** un webhook avec `status=in_progress` positionne bien le ticket sur `in_progress`. Le résultat a été vérifié par `curl` et par inspection de la base MySQL.

### 4.8 Bug corrigé — Cache dashboard non invalidé

**Symptôme :** les compteurs du tableau de bord (`openTickets`, `criticalTickets`, `scheduledToday`, `technicians`) restaient figés jusqu'à 30 minutes après une modification de ticket.

**Cause :** `DashboardController` utilisait `Cache::remember('dashboard.kpis', now()->addMinutes(30), ...)` sans invalidation lors des écritures sur le modèle `Ticket`.

**Correctif :** j'ai créé `App\Observers\TicketObserver` avec les méthodes `saved()` et `deleted()`, qui appellent `Cache::forget('dashboard.kpis')`. L'observer est enregistré dans `AppServiceProvider::boot()` avec `Ticket::observe(TicketObserver::class)`.

**Validation :** après la création d'un ticket via l'API, le prochain accès au dashboard reflète immédiatement le nouveau compteur.

## 5. Défauts identifiés et non corrigés dans ce livrable

Les défauts suivants sont documentés pour une correction lors de la maintenance planifiée :

| Défaut | Priorité | Traitement recommandé |
|---|---|---|
| API avec token global, sans permissions par ressource | Moyenne | Passer à Sanctum abilities ou à des scopes Laravel Passport. |
| Webhook `hooks.php` avec Basic Auth seul, sans HMAC | Haute | Ajouter la vérification d'une signature HMAC-SHA256 dans l'en-tête `X-Signature`. |
| `.env.example` contenant des identifiants de démonstration | Basse | Remplacer les valeurs par des placeholders `changeme` et ajouter une note dans le README. |

Le sujet demande explicitement le traitement d'un bug et d'une faille de sécurité. Les autres défauts sont priorisés et documentés afin d'être repris dans le cycle de maintenance suivant, détaillé dans le livrable 05.

## 6. CHANGELOG

| Date | Type | Description |
|---|---|---|
| 2026-09-10 | security | Correction de l'injection SQL dans `TicketController@index` : remplacement de `orWhereRaw` par `orWhere` dans une closure. |
| 2026-09-10 | bugfix | Correction de la logique de recherche de tickets combinée au filtre de priorité. |
| 2026-09-10 | bugfix | Correction du dashboard Next.js vide : `payload.items` remplacé par `payload.data`. |
| 2026-09-10 | bugfix | Ajout de la déduplication du webhook par `external_event_id` avec `updateOrCreate`. |
| 2026-09-10 | bugfix | Correction du statut ticket transmis par le webhook : utilisation de `$payload['status']`. |
| 2026-09-10 | bugfix | Invalidation du cache `dashboard.kpis` via `TicketObserver`. |
| 2026-09-10 | ops | Ajout de la stratégie de backup quotidien MySQL, MongoDB et storage. |
| 2026-09-10 | security | Correction des droits du fichier `.env` : `644` vers `640`. |
| 2026-09-10 | security | Passage de `APP_ENV` à `production` et de `APP_DEBUG` à `false`. |
| 2026-09-10 | security | Restriction de phpMyAdmin à l'accès local et désactivation du virtual host public. |
| 2026-09-10 | ops | Activation HTTPS avec certificat auto-signé et redirection HTTP vers HTTPS. |
| 2026-09-10 | ops | Activation d'UFW : refus entrant par défaut et ouverture des ports `22`, `80` et `443`. |