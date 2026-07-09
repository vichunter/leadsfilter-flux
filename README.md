# LeadsFilter Flux

Flux CD v2 GitOps repository managing a single-node Kubernetes cluster (k0s on Hetzner).

Two production domains served from the same node with separate external IPs:
- **leadsfilter.com** — `178.156.239.214`
- **homefinanceclub.com** — `5.161.26.66` (Hetzner Floating IP)

## Repository Structure

```
leadsfilter-flux/
├── clusters/cluster/         # Flux entrypoint — Kustomizations that wire everything together
├── infrastructure/
│   ├── cluster/              # Cluster-wide services (ingress, cert-manager, openvpn, etc.)
│   ├── lf-prod/              # Production namespace definition
│   └── lf-stage/             # Staging namespace definition (empty)
├── apps/
│   ├── lf-prod/              # All production workloads
│   └── lf-stage/             # Staging workloads (empty)
└── docs/                     # Operational guides
```

## Flux Reconciliation Order

```
clusters/cluster/kustomization.yaml  (entrypoint)
  ├── infra-cluster           → infrastructure/cluster/        (nginx, cert-manager, openvpn, etc.)
  │   └── infra-cert-manager-issuer → infrastructure/cluster/cert-manager-issuer/  (depends on cert-manager CRDs)
  ├── infra-lf-prod           → infrastructure/lf-prod/        (namespace creation)
  │   └── apps-lf-prod        → apps/lf-prod/                  (all prod workloads)
  └── infra-lf-stage          → infrastructure/lf-stage/
      └── apps-lf-stage       → apps/lf-stage/
```

All Kustomizations poll every **10 minutes** with `prune: true`.

## Cluster Infrastructure

### Ingress (Dual Controller)

Two separate ingress-nginx instances in the `ingress-nginx` namespace, each bound to its own IP:

| Controller | IngressClass | External IP | Domain |
|---|---|---|---|
| `nginx-ingress` | `nginx` | 178.156.239.214 | leadsfilter.com |
| `nginx-ingress-hfc` | `nginx-hfc` | 5.161.26.66 | homefinanceclub.com |

Both use `service.type: ClusterIP` with `externalIPs` (kube-proxy DNAT). The HFC controller has admission webhooks disabled to avoid port conflicts. Each controller has its own `electionID` to prevent leader lease conflicts.

Both controllers have gzip compression and custom timing headers (`X-Request-Time`, `X-Upstream-Connect-Time`, `X-Upstream-Header-Time`, `X-Request-Id`).

Helm chart: `ingress-nginx` (version `>=4.0.0 <5.0.0`, currently 4.15.1 — final release, project archived March 2026).

See `docs/adding-hfc-ip.md` for the full dual-IP architecture guide.

### TLS Certificates

cert-manager with Let's Encrypt (HTTP-01 challenges). ClusterIssuer `letsencrypt` has domain-specific solvers:
- `homefinanceclub.com` challenges routed through `nginx-hfc`
- Everything else through `nginx`

### Other Infrastructure

| Service | Chart/Image | Namespace | Purpose |
|---|---|---|---|
| cert-manager | `jetstack/cert-manager` >=1.14 | cert-manager | TLS certificate automation |
| reflector | `emberstack/reflector` ^9 | kube-system | Secret/ConfigMap replication across namespaces |
| capacitor | `gimlet-io/capacitor` v0.4.8 | flux-system | Flux dashboard UI |
| backrest | `garethgeorge/backrest:latest` | backrest | Backup management (host data at `/data/`) |
| openvpn-tcp | `kylemanna/openvpn:2.4` | openvpn | VPN access, port 30094/TCP, subnet 192.168.255.0/24 |
| openvpn-udp | `kylemanna/openvpn:2.4` | openvpn | VPN access, port 30094/UDP, subnet 192.168.254.0/24 |

## Production Services

All services run in namespace `lf-prod` on node `leadsfilter-n1`.

### Services With Custom Images (CI/CD via ECR)

These are auto-updated by Flux Image Automation polling AWS ECR every 5 minutes:

| Service | Image (ECR) | Type |
|---|---|---|
| serviceroom-backend | `925375122018.dkr.ecr.us-east-2.amazonaws.com/serviceroom-backend` | Python/Django + Gunicorn |
| serviceroom-frontend | `925375122018.dkr.ecr.us-east-2.amazonaws.com/serviceroom-frontend` | Node/React SPA |
| serviceroom-worker | same as backend | Celery worker |
| serviceroom-beat | same as backend | Celery beat scheduler |

Image tag format: `<commit>-<date>.<time>-prod` (e.g. `bbf4f8a-2026-04-03.054236-prod`).

### Services With Standard Base Images (Deployed From Host Storage)

These use generic base images. Application code is mounted from host paths under `/data/lf-prod/`.

**ASP.NET (.NET 8) services** — image: `mcr.microsoft.com/dotnet/aspnet:8.0-bookworm-slim`

| Service | Entrypoint | HTTP | Description |
|---|---|---|---|
| leadstore-api | `./LeadStore.API` | /api | Main API |
| leadstore-admin | `./LeadStore.Admin` | /admin2 | Admin dashboard |
| leadstore-cron | `./LeadStore.Cron` | none | Background jobs |
| leadstore-migrate | `./efbundle` | none | DB migrations (suspended CronJob) |
| leadapp-api | `./LeadApp.API` | /api | HFC widget API |

**Nginx static frontends** — image: `nginx:1.25-alpine-slim`

| Service | Host path | Description |
|---|---|---|
| leadstore-portal | /data/lf-prod/leadstore-portal/app | Customer portal SPA |
| leadstore-landing | /data/lf-prod/leadstore-landing/app | Landing page |
| leadstore-shared | /data/lf-prod/leadstore-shared/wwwroot | Shared static assets |
| leadapp-widget | /data/lf-prod/leadapp-widget/wwwroot | HFC embeddable widget |

**Go microservices** — image: `alpine:3.19.0`

| Service | Host path | Description |
|---|---|---|
| geocoder | /data/lf-prod/geocoder | Address geocoding API |
| zlenders | /data/lf-prod/zlenders | Lender matching API |

### WordPress Sites

**HFC WordPress** (`hfc-wp`) — multi-container pod:
- `nginx:1.28` — web server (port 80)
- `wordpress:6-fpm` — PHP-FPM
- `valkey/valkey:8-alpine` — Redis-compatible cache
- `mariadb:10.11` — database

**Corp WordPress** (`leadsfilter-corp-wp`) — multi-container pod:
- `wordpress:6.5-php8.3-apache` — Apache + PHP
- `mariadb:11.4-noble` — database

### Supporting Services

| Service | Image | Purpose |
|---|---|---|
| postgres | `postgres:16` | LeadStore database (SSL enabled) |
| serviceroom-postgres | `postgres:12.0-alpine` | ServiceRoom database |
| serviceroom-rabbitmq | `rabbitmq:3.8-management` | Message broker for Celery |
| serviceroom-flower | `zoomeranalytics/flower:0.9.1-4.0.2` | Celery monitoring (disabled, 0 replicas) |
| smtp-relay | `boky/postfix` | Email relay via smtp-relay.gmail.com |
| pgadmin | `dpage/pgadmin4:latest` | DB admin UI (disabled, 0 replicas) |

## Ingress Routing

### leadsfilter.com (nginx class, IP 178.156.239.214)

| Path | Backend |
|---|---|
| `/admin2` | leadstore-admin |
| `/api` | leadstore-api |
| `/portal` | leadstore-portal |
| `/shared` | leadstore-shared |
| `/serviceroom/admin` | serviceroom-backend |
| `/serviceroom/api` | serviceroom-backend |
| `/serviceroom` | serviceroom-frontend |
| `/corp` | leadsfilter-corp-wp |
| `/` | leadstore-landing |

### homefinanceclub.com (nginx-hfc class, IP 5.161.26.66)

| Path | Backend |
|---|---|
| `/serviceroom/api/` | serviceroom-backend |
| `/serviceroom/` | serviceroom-frontend |
| `/api/` | leadapp-api |
| `/wapp/` | leadapp-widget |
| `/` | hfc-wp |

Both domains have TLS (Let's Encrypt) and www-to-non-www redirect.

## Storage

All persistent data lives on the host filesystem under `/data/`:

```
/data/
├── lf-prod/
│   ├── postgres/              # LeadStore PostgreSQL data + SSL certs
│   ├── serviceroom-postgres/  # ServiceRoom PostgreSQL data
│   ├── serviceroom-rabbitmq/  # RabbitMQ data
│   ├── leadstore-api/         # .NET app binaries
│   ├── leadstore-admin/
│   ├── leadstore-cron/
│   ├── leadstore-migrate/
│   ├── leadstore-portal/      # nginx config + SPA files
│   ├── leadstore-landing/
│   ├── leadstore-shared/
│   ├── leadapp-api/
│   ├── leadapp-widget/
│   ├── geocoder/
│   ├── zlenders/
│   ├── hfc-wp/                # www/ (PHP+nginx) + mysql/ (MariaDB data)
│   ├── leadsfilter-corp-wp/   # www/ + db/ + apache2/
│   └── pgadmin/
├── openvpn-tcp/pki/
├── openvpn-udp/pki/
└── backrest-data/
```

**Important**: this is a single-node setup. If the node dies, all data is lost unless restored from backrest backups.

## Secrets

Secrets are **not stored in git**. They must be created manually on the cluster:

| Secret | Namespace | Used by |
|---|---|---|
| `leadstore` | lf-prod | leadstore-api, admin, cron, migrate |
| `geocoder` | lf-prod | geocoder |
| `zlenders` | lf-prod | zlenders |
| `serviceroom` | lf-prod | serviceroom-backend, worker, beat, postgres, rabbitmq |
| `hfc-wp-mysql` | lf-prod | hfc-wp (MariaDB) |
| `leadsfilter-corp-wp` | lf-prod | leadsfilter-corp-wp (MariaDB + WordPress) |
| `ecr-credentials-leadsfilter` | lf-prod | ServiceRoom image pulls (AWS ECR) |
| `letsencrypt-account-key` | cert-manager | cert-manager ACME account |

## How To

### Deploy changes

Push to `master`. Flux reconciles within 10 minutes. To force immediate reconciliation:

```bash
flux reconcile kustomization infra-cluster --with-source
flux reconcile kustomization apps-lf-prod --with-source
```

Or reconcile a specific Helm release:

```bash
flux reconcile helmrelease nginx-ingress -n flux-system
```

### Add a new service

1. Create a directory in `apps/lf-prod/<service-name>/` with `deployment.yaml`, `service.yaml`, and `kustomization.yaml`
2. Add the directory to `apps/lf-prod/kustomization.yaml` resources list
3. If the service needs an ingress path, add it to `apps/lf-prod/ingress/leadsfilter.yaml` or `homefinanceclub.yaml`
4. Create any required secrets on the cluster manually
5. Push to master

### Run database migrations

```bash
kubectl create job leadstore-migrate-$(date +%s) --from=cronjob/leadstore-migrate-manual -n lf-prod
```

### Check Flux status

```bash
flux get kustomizations
flux get helmreleases -A
flux get images all -A
```

### Access cluster services

Connect via OpenVPN (port 30094 TCP or UDP on 178.156.239.214), then access internal services directly via ClusterIP.

## Ingress Migration Notes

### ingress-nginx end-of-life (March 2026)

The community `kubernetes/ingress-nginx` project is archived. No further security patches. Current version 4.15.1 is final.

This does **not** affect the commercial F5/NGINX Ingress Controller (separate project).

### NGINX Gateway Fabric — do not use

In April 2026 we attempted migrating to NGINX Gateway Fabric (NGF) 2.x. The migration failed after extensive troubleshooting due to:

- **cert-generator bug**: NGF's built-in cert-generator creates inconsistent TLS certificates (ca.crt and tls.crt are different self-signed certs instead of a proper CA chain). This breaks gRPC communication between control plane and data plane pods.
- **Poor multi-instance support**: Running two NGF instances (for two IPs/domains) requires setting `nginxGateway.gatewayControllerName` to unique values — poorly documented and easy to get wrong.
- **Confusing Helm values**: `certGenerator.enable` (not `enabled`) — wrong key silently ignored.
- **Immutable selector issues**: Namespace changes break deployments due to Kubernetes immutable `spec.selector`.
- **Overall immaturity**: Too many undocumented edge cases for production use.

The rollback to ingress-nginx was done in commit `983791f`.

### Future migration path

When ready to migrate off ingress-nginx, consider **HAProxy Unified Gateway** (GA 1.0, based on HAProxy 3.2 LTS):
- Supports both Gateway API and Ingress in a single controller (Ingress support coming 2026)
- HAProxy itself is battle-tested (since 2000)
- Built-in gzip compression and timing headers
- Gradual migration possible — no need to switch everything at once

Wait for the Ingress support to land and for the product to stabilize before attempting migration.
