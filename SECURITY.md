# Security Policy

Politique de sécurité pour OpsTrack Field Service.

## Signaler une vulnérabilité

Si vous découvrez une faille de sécurité :

- Écrire à `security@opstrack.example` (chiffré si possible)
- Ne pas ouvrir de GitHub Issue publique
- Fournir : étapes de reproduction, version affectée, impact estimé
- Un premier accusé de réception sous 48 heures ouvrables

## Versions supportées

Seule la branche `main` reçoit des correctifs de sécurité.

## Mesures en place

- HTTPS obligatoire (TLS 1.2 et 1.3, redirect 301 HTTP vers HTTPS)
- Headers de sécurité : HSTS 1 an, X-Content-Type-Options, X-Frame-Options, Referrer-Policy
- Requêtes SQL préparées via Eloquent ORM (protection injection SQL)
- Authentification API par token Bearer
- Webhook protégé par HTTP Basic Auth (renforcement HMAC planifié)
- Pare-feu UFW actif, deny incoming par défaut, ports 22, 80, 443 autorisés
- Fichier `.env` en 640, propriétaire `ubuntu:www-data`
- `APP_DEBUG=false` et `APP_ENV=production` en production
- Interface phpMyAdmin restreinte à `127.0.0.1`, désactivation du vhost global
- Blocage des fichiers cachés (`.git`, `.env`) au niveau Apache
- Sauvegardes quotidiennes MySQL, MongoDB et storage, rétention 7 jours

## Historique des corrections

Voir `livrables/05_documentation_maintenance/journal_securite.md` pour le journal détaillé des failles identifiées (F-001 à F-010) et leur statut (corrigé, planifié).

## Références

- Livrable 02 : `livrables/02_exploitation_securisee.md` (mise en service HTTPS + hardening)
- Livrable 04 : `livrables/04_supervision_maintien.md` (correctifs bugs et failles)
- Livrable 05 : `livrables/05_documentation_maintenance/journal_securite.md` (journal complet)