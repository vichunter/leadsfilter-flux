# Migration: ingress-nginx → NGINX Gateway Fabric

## Context

The `kubernetes/ingress-nginx` project was archived on 2026-03-24. No further releases, bugfixes, or security patches will be issued. This repo currently runs two ingress-nginx HelmReleases (main + HFC) serving two domains.

## Decision

Migrate to **NGINX Gateway Fabric (NGF) v2.5.1** using **Gateway API v1.5.1**.

## Versions

| Component              | Version |
|------------------------|---------|
| NGF Helm chart         | 2.5.1   |
| Gateway API CRDs       | v1.5.1  |
| OCI registry           | oci://ghcr.io/nginx/charts/nginx-gateway-fabric |

## Current State

### Infrastructure (`infrastructure/cluster/nginx-ingress/`)
- `source.yaml` — HelmRepository pointing to `https://kubernetes.github.io/ingress-nginx`
- `release.yaml` — HelmRelease `nginx-ingress`, ClusterIP + externalIP `178.156.239.214`, gzip config, server-snippet with custom headers
- `release-hfc.yaml` — HelmRelease `nginx-ingress-hfc`, separate IngressClass `nginx-hfc`, externalIP `5.161.26.66`, same gzip/headers config

### Ingress rules (`apps/lf-prod/ingress/`)
- `leadsfilter.yaml` — Ingress for `leadsfilter.com` (9 path rules), ingressClassName `nginx`, cert-manager annotation
- `homefinanceclub.yaml` — Ingress for `homefinanceclub.com` (5 path rules), ingressClassName `nginx-hfc`, cert-manager annotation

### cert-manager (`infrastructure/cluster/cert-manager-issuer/`)
- `cluster-issuer.yaml` — ClusterIssuer `letsencrypt`, ACME HTTP-01 solver referencing `ingressClassName: nginx` and `ingressClassName: nginx-hfc`

## Target State

### Folder renames
- `infrastructure/cluster/nginx-ingress/` → `infrastructure/cluster/nginx-gateway-fabric/`
- `apps/lf-prod/ingress/` → `apps/lf-prod/gateway/` (split into per-domain subfolders)

### Infrastructure (`infrastructure/cluster/nginx-gateway-fabric/`)

**`source.yaml`** — HelmRepository (OCI) for NGF:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nginx-gateway-fabric
  namespace: flux-system
spec:
  type: oci
  interval: 24h
  url: oci://ghcr.io/nginx/charts
```

**`release.yaml`** — HelmRelease for the main NGF instance:
- chart: `nginx-gateway-fabric` version `2.5.1`
- targetNamespace: `nginx-gateway`
- Gateway API CRDs installed via `gatewayAPI.install: true`
- Service: ClusterIP + externalIPs `178.156.239.214`
- GatewayClass name: `nginx`

**`release-hfc.yaml`** — HelmRelease for the HFC NGF instance:
- Same chart and version
- targetNamespace: `nginx-gateway`
- Gateway API CRDs: `gatewayAPI.install: false` (already installed by main release)
- Service: ClusterIP + externalIPs `5.161.26.66`
- GatewayClass name: `nginx-hfc`

**`kustomization.yaml`** — references all three files

### Gateway resources (`apps/lf-prod/gateway/`)

Split into per-domain subfolders. Shared resources (SnippetsPolicy) live in the root.

#### `apps/lf-prod/gateway/leadsfilter/`

**`gateway.yaml`** — Gateway for leadsfilter.com:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: leadsfilter
  namespace: lf-prod
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      port: 80
      protocol: HTTP
    - name: https
      port: 443
      protocol: HTTPS
      hostname: leadsfilter.com
      tls:
        mode: Terminate
        certificateRefs:
          - name: leadsfilter-tls
    - name: https-www
      port: 443
      protocol: HTTPS
      hostname: www.leadsfilter.com
      tls:
        mode: Terminate
        certificateRefs:
          - name: leadsfilter-tls
```

**`routes.yaml`** — HTTPRoute for leadsfilter.com (9 rules), hostnames `leadsfilter.com` only (www is redirected).

**`www-redirect.yaml`** — HTTPRoute that redirects `www.leadsfilter.com` → `leadsfilter.com` (301) for both HTTP and HTTPS:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: leadsfilter-www-redirect
  namespace: lf-prod
spec:
  parentRefs:
    - name: leadsfilter
  hostnames:
    - www.leadsfilter.com
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            hostname: leadsfilter.com
            statusCode: 301
```

**`kustomization.yaml`** — references gateway.yaml, routes.yaml, www-redirect.yaml

#### `apps/lf-prod/gateway/homefinanceclub/`

**`gateway.yaml`** — Gateway for homefinanceclub.com, gatewayClassName `nginx-hfc`, cert secret `homefinanceclub-tls`, same listener structure.

**`routes.yaml`** — HTTPRoute for homefinanceclub.com (5 rules), hostnames `homefinanceclub.com` only.

**`www-redirect.yaml`** — HTTPRoute redirecting `www.homefinanceclub.com` → `homefinanceclub.com` (301).

**`kustomization.yaml`** — references all three files.

#### `apps/lf-prod/gateway/` (root)

**`snippets-policy.yaml`** — SnippetsPolicy for custom response headers, targeting both Gateways:
```yaml
apiVersion: gateway.nginx.org/v1alpha1
kind: SnippetsPolicy
metadata:
  name: custom-headers
  namespace: lf-prod
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: leadsfilter
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: homefinanceclub
  snippets:
    - context: http.server.location
      value: |
        add_header X-Request-Time $request_time;
        add_header X-Upstream-Connect-Time $upstream_connect_time;
        add_header X-Upstream-Header-Time $upstream_header_time;
        add_header X-Request-Id $request_id;
        add_header X-Served-At $msec;
        add_header X-Served-At-Iso $time_iso8601;
```

**`kustomization.yaml`** — references `leadsfilter/`, `homefinanceclub/`, and `snippets-policy.yaml`.

### cert-manager issuer update

Update `cluster-issuer.yaml` — replace HTTP-01 ingress solvers with Gateway API solvers:
```yaml
solvers:
  - selector:
      dnsNames:
        - homefinanceclub.com
        - www.homefinanceclub.com
    http01:
      gatewayHTTPRoute:
        parentRefs:
          - name: homefinanceclub
            namespace: lf-prod
  - http01:
      gatewayHTTPRoute:
        parentRefs:
          - name: leadsfilter
            namespace: lf-prod
```

### Kustomization references to update

- `infrastructure/cluster/kustomization.yaml` — rename `nginx-ingress` → `nginx-gateway-fabric`
- `apps/lf-prod/kustomization.yaml` — rename `ingress` → `gateway`

## Files Changed (summary)

| Action  | Path |
|---------|------|
| Delete  | `infrastructure/cluster/nginx-ingress/` (entire folder) |
| Create  | `infrastructure/cluster/nginx-gateway-fabric/source.yaml` |
| Create  | `infrastructure/cluster/nginx-gateway-fabric/release.yaml` |
| Create  | `infrastructure/cluster/nginx-gateway-fabric/release-hfc.yaml` |
| Create  | `infrastructure/cluster/nginx-gateway-fabric/kustomization.yaml` |
| Delete  | `apps/lf-prod/ingress/` (entire folder) |
| Create  | `apps/lf-prod/gateway/kustomization.yaml` |
| Create  | `apps/lf-prod/gateway/snippets-policy.yaml` |
| Create  | `apps/lf-prod/gateway/leadsfilter/gateway.yaml` |
| Create  | `apps/lf-prod/gateway/leadsfilter/routes.yaml` |
| Create  | `apps/lf-prod/gateway/leadsfilter/www-redirect.yaml` |
| Create  | `apps/lf-prod/gateway/leadsfilter/kustomization.yaml` |
| Create  | `apps/lf-prod/gateway/homefinanceclub/gateway.yaml` |
| Create  | `apps/lf-prod/gateway/homefinanceclub/routes.yaml` |
| Create  | `apps/lf-prod/gateway/homefinanceclub/www-redirect.yaml` |
| Create  | `apps/lf-prod/gateway/homefinanceclub/kustomization.yaml` |
| Edit    | `infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml` |
| Edit    | `infrastructure/cluster/kustomization.yaml` |
| Edit    | `apps/lf-prod/kustomization.yaml` |

## Out of Scope
- Changes to application deployments or services
- DNS changes
- Staging environment (lf-stage has no ingress rules currently)
