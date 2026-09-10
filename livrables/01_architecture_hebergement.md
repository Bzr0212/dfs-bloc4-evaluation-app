# Livrable 01 — Architecture cible et hébergement

**Compétence évaluée** : C29 (Sélectionner une plateforme d'hébergement adaptée aux exigences techniques, économiques, qualitatives et réglementaires)

**Application** : OpsTrack Field Service
**Candidat** : Thélia Beauzor
**Date** : 10 septembre 2026

---

## 1. Contexte et hypothèses

OpsTrack Field Service est positionnée comme une application SaaS multi-tenant de gestion d'interventions terrain (tickets, techniciens, sites, webhook de statut externe). La cible commerciale sur 12 à 24 mois est une base clientèle B2B européenne, avec un dimensionnement projectionnel de plusieurs dizaines à quelques centaines de clients, chacun exploitant l'application avec ses propres utilisateurs et données.

L'architecture proposée ci-dessous n'est pas exigée en implémentation pendant l'épreuve. La contrainte actuelle impose une machine unique en production (EC2 t3 sur eu-west-3). La cible formalisée ici est projective, dimensionnée pour supporter la croissance et les exigences RGPD.

Hypothèses de charge à 18 mois :

- ~200 tenants actifs
- ~2 000 utilisateurs concurrents en pic
- ~50 000 tickets/mois créés et manipulés
- Volume MongoDB (logs et événements) estimé à ~2 Go/mois

## 2. Diagramme d'architecture cible

```
                            Internet
                                │
                                ▼
                    ┌────────────────────────┐
                    │  Route 53 (DNS + WAF)  │
                    │  + CloudFront (CDN)    │
                    └───────────┬────────────┘
                                │
                    ┌───────────▼────────────┐
                    │   ALB (Application     │
                    │   Load Balancer)       │
                    └─────┬──────────────┬───┘
                          │              │
                  ┌───────▼──────┐ ┌─────▼─────────┐
                  │ EC2 Auto     │ │ Vercel        │
                  │ Scaling      │ │ (Next.js      │
                  │ Group        │ │ dispatch-     │
                  │ (Laravel/PHP)│ │  dashboard)   │
                  └──┬────┬──────┘ └───────┬───────┘
                     │    │                │
                     │    │   VPC privé    │
    ┌────────────────▼────▼────────────────▼────────────┐
    │                                                    │
    │  ┌───────────┐  ┌───────────┐  ┌──────────────┐  │
    │  │ RDS MySQL │  │ ElastiCache│  │ MongoDB      │  │
    │  │ Multi-AZ  │  │ Redis HA   │  │ Atlas (via   │  │
    │  │           │  │            │  │ PrivateLink) │  │
    │  └───────────┘  └───────────┘  └──────────────┘  │
    │                                                    │
    │        Secrets Manager  •  S3 (backups + uploads)  │
    │                                                    │
    └────────────────────────────────────────────────────┘

Observabilité : CloudWatch + CloudTrail + Datadog (option)
CI/CD : GitHub Actions → CodeDeploy → EC2 ASG
```

## 3. Choix de la plateforme

**Retenu : AWS eu-west-3 (Paris)** pour l'infrastructure principale, complété par MongoDB Atlas (région Paris) et Vercel pour le microservice Next.js.

Motifs :

- Écosystème mature avec services managés couvrant l'ensemble des besoins (compute, DB relationnelle, cache, monitoring, secrets, WAF, CDN)
- Région Paris permet un argumentaire RGPD solide (résidence des données en France, DPA AWS)
- Autoscaling natif nécessaire pour supporter une charge SaaS multi-tenant imprévisible
- Certifications (ISO 27001, SOC 2, HDS partiel) exploitables commercialement en B2B

Écartés :

- **OVH Public Cloud** : souveraineté française plus forte mais offre managée moins riche sur les briques MongoDB et Redis HA, écosystème observabilité moins outillé
- **VPS simple (Scaleway, DigitalOcean)** : n'offre pas l'élasticité et la séparation des composants requises pour la promesse SaaS multi-tenant
- **Azure / GCP** : équivalents fonctionnels d'AWS mais sans avantage différenciant, et sans base d'expertise interne côté équipe

## 4. Composants et services retenus

| Composant applicatif | Service cible | Rôle | Justification |
|---|---|---|---|
| Front + API Laravel | EC2 Auto Scaling Group + ALB | Servir HTTP, scaling horizontal | Découpage entre trafic entrant (ALB) et compute (EC2) permet le zero-downtime deploy |
| Microservice Next.js | Vercel (Enterprise) | Dashboard dispatch | Vercel est natif Next.js, edge global, coût quasi nul en early stage |
| MySQL | RDS MySQL 8 Multi-AZ | Données transactionnelles | Multi-AZ = failover automatique, backups PITR, patching géré |
| MongoDB | MongoDB Atlas M10 (Paris, PrivateLink) | Journaux techniques et événements | Atlas fournit une UX Mongo native, monitoring intégré, coût plus contenu que DocumentDB |
| Redis | ElastiCache Redis (Multi-AZ) | Cache applicatif, sessions | HA géré, snapshots quotidiens |
| Uploads + backups | S3 (SSE-KMS) | Stockage objet | Coût faible, lifecycle policy pour archivage Glacier après 90j |
| Secrets | AWS Secrets Manager | .env, credentials DB, tokens API | Rotation automatique, audit CloudTrail |
| DNS + edge | Route 53 + CloudFront + AWS WAF | Résolution, CDN, protection L7 | Bundle cohérent, règles WAF communes (SQLi, XSS, bot) |

## 5. Élasticité et résilience

- **App Laravel** : Auto Scaling Group avec 2 instances minimum, scaling policy sur CPU > 70% et latence ALB > 500ms. Deploy CodeDeploy en blue/green pour éviter les fenêtres d'indisponibilité.
- **RDS Multi-AZ** : bascule automatique en cas de défaillance de l'AZ primaire (RTO < 60s), reader replica optionnel en cas de charge lecture significative.
- **ElastiCache** : cluster Redis en mode replication group (1 primary + 1 replica).
- **MongoDB Atlas** : replica set M10 minimum, backup continu, PITR sur 7 jours.
- **Vercel** : élasticité gérée par la plateforme, pas d'intervention.

## 6. Sécurité

- **Réseau** : VPC dédié, subnets publics (ALB uniquement) et privés (EC2, RDS, Cache), aucune base de données exposée à Internet
- **IAM** : rôles par service, principe du moindre privilège, MFA obligatoire sur les comptes console, pas de clés d'accès long terme pour les workloads (IAM Instance Profile)
- **Chiffrement** : at-rest via KMS sur RDS, ElastiCache, S3, EBS ; in-transit via TLS 1.2+ obligatoire partout
- **WAF** : règles managées AWS (OWASP top 10, bots, exploitation courante), rate limiting sur les endpoints publics
- **Secrets** : centralisés dans Secrets Manager, injection au démarrage des instances, rotation automatique tous les 90 jours pour les credentials BDD
- **Audit** : CloudTrail activé sur toute la région, logs exportés vers S3 en write-once (Object Lock)
- **Gestion des accès humains** : SSO via AWS IAM Identity Center, revue trimestrielle des permissions

## 7. Sauvegarde et reprise

| Composant | Fréquence | Retention | Restauration testée |
|---|---|---|---|
| RDS MySQL | Snapshots automatiques quotidiens + PITR 7j | Snapshots 35j | Exercice trimestriel sur env de test |
| MongoDB Atlas | Continue (change stream) | PITR 7j + snapshots 30j | Restore mensuel vers cluster jetable |
| Redis | Snapshots quotidiens | 7j | Non critique (données reconstructibles) |
| S3 | Versioning activé + Object Lock sur logs | Indéfini pour audits, 90j pour uploads utilisateur | Vérif intégrité mensuelle |

RTO cible : 1h. RPO cible : 15 minutes.

## 8. Supervision

- **CloudWatch** : métriques infrastructure (CPU, RAM, IOPS, latence ALB), logs applicatifs (Laravel + Nginx + PHP-FPM), alarmes SNS → Slack équipe ops
- **Health check ALB** sur `/api/health` toutes les 30s, sortie de rotation automatique si 3 échecs consécutifs
- **CloudTrail** : traçabilité de toute action API AWS
- **Datadog** (option Growth) : APM Laravel (traces, requêtes N+1), monitoring Vercel unifié, dashboards custom par tenant
- **Alertes prioritaires** : 5xx > 1% sur 5min, latence P95 > 1s, échec de connexion DB, remplissage disque > 80%

## 9. Conformité RGPD

- **Résidence des données** : eu-west-3 pour AWS, région Paris pour MongoDB Atlas, région iad1 évitée sur Vercel (edge FR privilégié)
- **DPA** : signé avec AWS, MongoDB Inc, Vercel Inc (couverture SCC pour transferts éventuels)
- **Chiffrement** : at-rest et in-transit sur toutes les briques stockant des données personnelles
- **Traçabilité** : logs d'accès conservés 12 mois (CloudTrail + logs applicatifs), procédure d'export et de suppression documentée pour le droit à l'oubli
- **Registre des traitements** : maintenu par le DPO, mis à jour à chaque évolution fonctionnelle impactant les données personnelles
- **Sous-traitants** : liste tenue à jour et accessible aux clients dans le contrat, notification 30 jours avant tout ajout

## 10. Chaîne CI/CD (haut niveau, détaillée au livrable 03)

- **Source** : GitHub, branche `main` pour prod, `develop` pour qualif
- **Build** : GitHub Actions (composer install, tests unitaires PHPUnit, lint PHPStan, build assets Vite)
- **Artefact** : archive versionnée poussée sur S3
- **Déploiement qualif** : automatique sur push `develop`, via CodeDeploy sur l'ASG qualif
- **Déploiement prod** : manuel après validation qualif, blue/green deploy, smoke test post-déploiement, rollback un clic
- **Microservice Next.js** : déploiement Vercel géré par leur intégration GitHub native (preview branch + prod)

## 11. Chiffrage annuel indicatif

Dimensionnement early phase (2 EC2 t3.medium, RDS db.t3.small Multi-AZ, ElastiCache cache.t3.small, MongoDB Atlas M10, S3 modéré, trafic 200 Go/mois) :

| Poste | Coût mensuel estimé |
|---|---|
| EC2 (2× t3.medium 24/7 + ASG headroom) | 90 € |
| RDS MySQL Multi-AZ | 75 € |
| ElastiCache Redis | 45 € |
| MongoDB Atlas M10 (Paris) | 60 € |
| ALB + CloudFront + Route 53 | 30 € |
| S3 (stockage + PUT/GET) | 15 € |
| Vercel (plan Pro) | 20 € |
| CloudWatch (logs, alarmes) | 15 € |
| **Total mensuel** | **~350 €** |
| **Total annuel** | **~4 200 € / an** |

Scaling attendu jusqu'à ~15 000 €/an à charge cible (200 tenants). Le poste principal de croissance sera RDS (montée en gamme d'instance et lecture replica).

## 12. Ce qui n'est pas en place aujourd'hui

Cette architecture est projective. L'environnement de production actuel (contrainte imposée par le sujet) repose sur une seule instance EC2 avec Apache, MySQL, MongoDB et Redis en colocalisation. Les écarts documentés :

- Pas de séparation des composants : la charge de l'un peut impacter les autres
- Pas de HA : perte d'instance = perte de service
- Pas d'autoscaling : la charge en pic doit être absorbée par le dimensionnement statique
- Backups en local uniquement : perte simultanée du serveur = perte des données
- Supervision limitée aux logs locaux

Ces écarts sont traités dans le livrable 02 par des mesures de mitigation applicables à l'environnement contraint (backup offsite manuel, hardening, HTTPS).

---

## Références internes

- Livrable 02 : mise en oeuvre concrète sur l'environnement actuel
- Livrable 03 : détail de la chaîne CI/CD
- Livrable 04 : supervision et incidents
