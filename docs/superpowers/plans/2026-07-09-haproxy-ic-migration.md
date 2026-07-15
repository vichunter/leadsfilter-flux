# HAProxy Ingress Controller migration (Path B) Implementation Plan

> # 🔴 STOP — this plan predates the runtime verification (2026-07-15)
>
> **Read `docs/ip-dossier/09-runtime-verification.md` before executing any task here.** Path B has now been **run** in an offline replica. Where this plan disagrees with `09`, **`09` wins**, and the ready values are `docs/ip-dossier/lab/values-{hfc,main}.yaml`.
>
> **Three things in this plan are actively harmful as written:**
>
> 1. **The values in Task 2 are missing five `extraArgs`** (`--healthz-bind-port`, `--stats-bind-port`, `--default-backend-port`, `--controller-port=0`, `--localpeer-port`) and the matching probe ports. Without them the two instances **silently share** the healthz/stats/peers/default-backend listeners via `SO_REUSEPORT` — no `EADDRINUSE`, both pods `1/1 Running`, probes answered by a random instance. HIGH 4's "distinct `containerPort.stat`/`admin`" mitigation is **declaration-only and inert** (`09` §2).
> 2. **BLOCKER 1's fix line still says `plus allowPrivilegedPorts: true`** (line ~84). That is **R-02** — it injects a sysctl kubelet forbids on hostNetwork and the pod is rejected. The plan contradicts itself: lines 41 and 79 already say so. Use `unprivileged: false`.
> 3. **MEDIUM 7's fix takes both sites down.** `ssl-redirect: "true"` alone sends every HTTP visitor to `https://<host>:8443` — a closed port. You must also set `haproxy.org/ssl-redirect-port: "443"` (`09` §4.1).
>
> **Also outdated:** the Architecture line and Risks #1/#6 still claim isolation comes from `daemonset.hostIP` (**R-01** — it is a scheduler hint only; the bind is `--ipv4-bind-address`). HIGH 4's QUIC item is closed but its answer is wrong (**R-18** — the args go, the udp/443 bind stays). Task 0 Step 1's "no further key-guessing required" is **R-14**. HIGH 5 (`www` × ACME) is **resolved — it does not bite** (`09` §4.3), but the `request-redirect` replacement needs an undocumented `https://` prefix or every `www` visit downgrades to plaintext (`09` §4.2).
>
> **New hard prerequisite, not anywhere in this plan:** a **Hetzner Cloud Firewall** rule. After migration, ports 1024/1026/1042/1043/6061/6063/10000/10001 are publicly reachable on **both** public IPs and **cannot be disabled** (the binds are unconditional in the controller source; a maintainer confirms it). Nothing binds them today. See `09` §5.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two ingress-nginx controllers with two **haproxytech/kubernetes-ingress** instances (DaemonSet, hostNetwork, each bound to its own public IP via `daemonset.hostIP`), so backends get the real client IP natively — no edge-lb, no PROXY protocol, no cert-manager CoreDNS hairpin — and the stack leaves EOL ingress-nginx.

**Architecture:** Two HAProxy IC HelmReleases, each a DaemonSet in `hostNetwork` pinned to node `leadsfilter-n1`, each binding ONLY its own public IP (`178.156.239.214` / `5.161.26.66`) via the chart's `daemonset.hostIP`, each with its own IngressClass (`haproxy` / `haproxy-hfc`). Because a hostNetwork controller is itself the edge, it sees the real client IP directly (no kube-proxy SNAT) and sets `X-Forwarded-For` itself. TLS terminates at each controller; cert-manager HTTP-01 works with per-domain `ingressClassName` solvers exactly like today. **Cutover is brand-by-brand** (homefinanceclub first as the lower-risk brand, then leadsfilter), so the other brand stays fully live on nginx throughout.

**Tech Stack:** haproxytech/kubernetes-ingress chart (controller v3.2.12, HAProxy 3.2 engine, 2026-07-03), Kustomize/Flux, cert-manager (unchanged, HTTP-01), k0s v1.35.2.

## Version map — read this first (three independent numbers)

The haproxytech Helm repo hosts **three different charts**; do not confuse them:

| Chart | What it is | Chart version | appVersion |
|---|---|---|---|
| `haproxy` | standalone HAProxy | 1.29.0 | 3.3.10 (image `haproxy-alpine:3.3.6`) |
| `haproxy-unified-gateway` | Gateway API product | — | — |
| **`kubernetes-ingress`** | **the ingress controller we want** | **1.52.1** | **3.2.12** |

For our chart the three numbers are:
1. **Chart version `1.52.1`** — versions the *packaging* (templates) only. Its own 1.x line, unrelated to the controller's 3.x numbering.
2. **appVersion = controller version `3.2.12`** — the ingress-controller binary. `image.tag` defaults to appVersion → pulls `docker.io/haproxytech/kubernetes-ingress:3.2.12` (confirmed via the index's `artifacthub.io/images` annotation).
3. **HAProxy engine version** — bundled *inside* the controller image (controller 3.2.x is built around the HAProxy 3.2.x engine). Never appears in the chart.

So: **chart 1.52.1 → controller 3.2.12 → HAProxy 3.2.x engine.** Caution: appVersion can lag the real image (the `haproxy` chart says appVersion 3.3.10 while its image annotation says 3.3.6) — trust the `artifacthub.io/images` annotation, not appVersion.

## Chart facts — VERIFIED by downloading and reading the chart (2026-07-09)

Downloaded `kubernetes-ingress-1.52.1.tgz` from the haproxytech repo and read `templates/_podspec.tpl`, `templates/_helpers.tpl`, `values.yaml`, `README.md`, and the vendor's own `ci/*.yaml`. Facts (no longer assumptions):

- **Pin: chart `1.52.1` → appVersion (controller) `3.2.12`** (2026-07-03). NOTE the chart line is **1.x**, versioned independently of the 3.x controller.
- **`publishService.enabled` defaults to `true`** → emits `--publish-service=<ns>/<svc>` at a Service we disable. Must set `publishService.enabled: false`.
- **`kubeVersion: '>=1.23.0-0'`** — a **minimum only, no upper bound** → k8s **1.35 installs fine**; "off-matrix" is a vendor *support-doc* statement, not a chart constraint.
- **`hostNetwork` gating confirmed:** `_podspec.tpl` → `{{- if $useHostNetwork }}hostNetwork: true{{- end }}`, fed from `daemonset.useHostNetwork`. Blocker-3 fix is correct.
- **`hostIP` confirmed as port-spec only** (`{{- if $hostIP }}hostIP: {{ $hostIP }}` inside the ports loop) — it never reaches HAProxy's bind. Blocker 2 stands.
- **Bind ports confirmed:** `- --http-bind-port={{ $ctlr.containerPort.http }}` / `--https-bind-port={{ ... }}` → `containerPort` drives the actual bind. Blocker 1 stands.
- **`--ingress.class` is emitted by the chart** from `controller.ingressClass` → do NOT duplicate it in `extraArgs` (MEDIUM 8 confirmed).
- **`extraArgs` are appended after the built-in args** → `--ipv4-bind-address` / `--disable-ipv6` land correctly.
- **QUIC — RESOLVED:** args are gated on `and (k8s>=1.24) service.enablePorts.quic`, evaluated **independently of `service.enabled`** → must set `service.enablePorts.quic: false` or both instances bind udp/443.
- **🔴 `allowPrivilegedPorts: true` MUST NOT be used with hostNetwork** — `_helpers.tpl` implements it by injecting sysctl `net.ipv4.ip_unprivileged_port_start=0`, and namespaced `net.*` sysctls are **forbidden on hostNetwork pods** (kubelet → `SysctlForbidden`). *(This corrects an earlier fix in this very plan, which would have broken the pod.)* Use `unprivileged: false` (root, no securityContext rendered) or rely on the default `unprivileged: true` path (runAsUser 1000 + `NET_BIND_SERVICE`) — **test which actually binds 80**.
- **Historical correction:** the removed April config (`df40563`) pinned chart `">=1.0.0 <2.0.0"` — that is the **current** 1.x line, so it pulled a *current* controller (3.2.x), **not** an ancient one as previously stated. Its values were `hostNetwork: true` + default `containerPort` 8080/8443 → **nothing would have listened on :80/:443**. That is Blocker 1 exactly, and is the most plausible reason HAProxy IC "didn't work" and was swapped for nginx. The history *validates* the blocker rather than warning against the controller.

## Local render — VERIFIED OUTPUT (2026-07-09, `helm template`, no cluster contact)

Rendered BOTH instances offline (`helm template ... --kube-version 1.35.2`) with the values below. Confirmed in the output:

```
hfc :  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy-hfc
       --ipv4-bind-address=5.161.26.66      --disable-ipv6
main:  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy
       --ipv4-bind-address=178.156.239.214  --disable-ipv6
```
- `hostNetwork: true` ✅ · `dnsPolicy: ClusterFirstWithHostNet` ✅
- NO `--quic-*` ✅ · NO `--prometheus` ✅ · NO `--pprof` ✅ · NO `--publish-service` ✅
- NO `Service` object ✅ · NO `sysctls` ✅ · NO `securityContext` (so: image's default user — see open item) 
- `nodeSelector: kubernetes.io/hostname: leadsfilter-n1` ✅
- **Scheduler (hostIP,port) tuples are distinct → #117689 defused:**
  `hfc (5.161.26.66, 80/443/1024)` vs `main (178.156.239.214, 80/443/1026)` ✅
- `--ingress.class` emitted exactly once per instance, distinct classes ✅

**Reproduce this gate before any commit** (offline, safe):
```bash
helm template haproxy-ingress-hfc haproxytech/kubernetes-ingress --version 1.52.1 \
  -f hfc-values.yaml --kube-version 1.35.2 --namespace haproxy-ingress
```

### RESOLVED — container user (checked via the Docker registry API, 2026-07-09)

Inspected the image config blob of `docker.io/haproxytech/kubernetes-ingress:3.2.12` (linux/amd64) directly from the registry:
```
User       : None        <-- no USER set  =>  runs as ROOT
Entrypoint : ["/start.sh"]
```
**Conclusion:** with `unprivileged: false` the chart renders **no securityContext**, and the image's default user is **root** → binding 80/443 works with no capability or sysctl workaround. The plan's `unprivileged: false` is correct.

Contrast worth remembering: the *official* `haproxy:3.2` image (used by the edge-lb plan) runs as **non-root UID 99**, which is why that plan needs `runAsUser: 0`. The **haproxytech controller image is root by default** — different images, different defaults; do not generalize between them.

Fallback if this ever changes: use the default `unprivileged: true` path (chart sets `runAsUser: 1000` + `capabilities.add: [NET_BIND_SERVICE]`; the vendor's own `ci/daemonset-privileged-ports.values.yaml` sets only `containerPort: {http:80, https:443, stat:1024}` with all other defaults, implying it binds). **Never** `allowPrivilegedPorts: true` here — it injects a `net.ipv4.*` sysctl that kubelet forbids on hostNetwork pods.

## Review status (Opus, 2026-07-09) — 3 blockers fixed, isolation mechanism corrected

The first draft would have failed on first run. Corrections folded in below:
- **BLOCKER 1 — dead entrypoint.** Chart default `containerPort` is **8080/8443** (confirmed in the real `values.yaml` AND upstream `controller.md`: `--http-bind-port` default 8080, `--https-bind-port` default 8443), and under hostNetwork HAProxy binds those directly → nothing on :80/:443. Fix: `containerPort.http: 80 / https: 443` **plus `allowPrivilegedPorts: true`**. **Correction (2026-07-09):** the review said "ensure NET_BIND_SERVICE" — there is **no securityContext/capabilities block in this chart at all**; the real gate is the `unprivileged` / `allowPrivilegedPorts` value pair. Without `allowPrivilegedPorts: true` the &lt;1024 bind fails regardless of containerPort. (upstream #589)
- **BLOCKER 2 — `daemonset.hostIP` does NOT set the bind address.** It is only a scheduler hint on the port spec; without `--ipv4-bind-address=<ip>` per instance, both bind `0.0.0.0` → second pod `EADDRINUSE` **and every IP serves both brands (isolation gone)**. Bringing up the hfc instance would then take leadsfilter down too. Fix: `extraArgs: ["--ipv4-bind-address=<ip>"]` per instance. `hostIP` is still needed, but only to make the scheduler tuples distinct (#117689). *(This corrects the research doc, which wrongly claimed hostIP gives socket isolation.)*
- **BLOCKER 2b — IPv6 collides too (found 2026-07-09 by checking upstream `controller.md`; missed by the review).** `--ipv6-bind-address` defaults to **`::`**, so both instances also bind `:::80/:::443` → second pod `EADDRINUSE` even with distinct `--ipv4-bind-address`; and with `net.ipv6.bindv6only=0` (Linux default) a `::` bind **also accepts IPv4**, leaking brand isolation. Fix: add `--disable-ipv6` per instance (or a distinct IPv6 each). **Verified upstream:** `--ipv4-bind-address` (default `0.0.0.0`), `--ipv6-bind-address` (default `::`), `--disable-ipv6` (default `false`), `--http-bind-port` (default `8080`), `--https-bind-port` (default `8443`) are all flags of the **ingress-controller binary** (not `haproxy`), passed via `controller.extraArgs`.
- **BLOCKER 3 — wrong key.** `controller.hostNetwork` doesn't exist → silently dropped → not hostNetwork at all. Correct: `controller.daemonset.useHostNetwork: true` + `controller.dnsPolicy: ClusterFirstWithHostNet`.
- **HIGH 4 — secondary port collisions (worse than first thought; verified against values.yaml).** Beyond stat(1024)/admin(6060), the chart defaults **`prometheus.enabled: true`** (metrics on the stat port) and **`pprof.enabled: true`** (pprof on the admin port) — more listeners colliding in the shared host netns. Fix: `prometheus.enabled: false` + `pprof.enabled: false` (or distinct `containerPort.stat`/`admin` per instance). **Open:** `service.enablePorts.quic` only gates the **Service** port, not the controller's QUIC listener — still need to find how to disable the QUIC/udp-443 listener itself (`controller.quic.announcePort` exists; mechanism unconfirmed).
- **NOTE — `ingressClassResource.enabled` does not exist** in this chart (only `{name, default, parameters}`). Do not set it; Helm silently drops unknown keys — the same trap as Blocker 3. **Gate:** always `helm template` and diff the rendered manifest; never trust that a values key took effect.
- **HIGH 5 — www redirect breaks HTTP-01 renewal.** `request-redirect` on the www host can 301 the `/.well-known/acme-challenge` path → the `www` SAN challenge stalls ~30 days later (passes cutover, fails at renewal). Must staging-test the www re-issue with the redirect live.
- **MEDIUM 6 — no compression keys.** `compression-algo/type` are NOT real keys (compression unsupported, #196) → drop gzip entirely (non-critical). `use-gunzip` has no equivalent.
- **MEDIUM 7 — ssl-redirect default is false** and leadsfilter has NO ssl-redirect annotation today (relies on nginx implicit) → add `haproxy.org/ssl-redirect: "true"` explicitly to BOTH brands or lose HTTP→HTTPS.
- **MEDIUM 8/9** — drop duplicate `--ingress.class` (chart emits it from `ingressClass`); drop the malformed `response-set-header` debug block.
- **MEDIUM 10 — cutover conntrack/DNAT race** — flush conntrack + verify externalIP DNAT gone + scale retiring nginx to 0 in the window.
- **MEDIUM 11** — path list missed `/serviceroom/admin`; test prefix precedence + trailing-slash semantics when dropping `use-regex`.
- **LOW** — disable the Service (`service.enabled: false`, never `externalIPs`); DaemonSet image-bump bind gap; k8s 1.35 off-matrix = formality; df40563 (v1.x) is not a config template.

## Global Constraints

- **k0s v1.35.2** — the vendor's *support matrix doc* tops at k8s 1.34, but the **chart's own `kubeVersion` is `>=1.23.0-0` — a minimum with NO upper bound** (verified in `Chart.yaml`), so 1.35 installs cleanly. Every API it uses (Ingress/IngressClass `networking.k8s.io/v1`, EndpointSlice `discovery.k8s.io/v1`, Lease) is long-GA and un-removed in 1.35. Off-matrix = no vendor support ticket, not a functional risk.
- **Pin the chart to `1.52.1`** (→ controller 3.2.12 → HAProxy 3.2.x engine). Do NOT use a floating range — note the April attempt's `">=1.0.0 <2.0.0"` is this same live 1.x line, not an "old" pin.
- **Two public IPs already on `eth0` of `leadsfilter-n1`** (`178.156.239.214` DHCP primary, `5.161.26.66` Floating IP via `/etc/netplan/60-floating-ip.yaml`). kubelet is pinned `--node-ip=178.156.239.214` (k0s systemd unit). Both must stay true — a hostNetwork pod inherits the node InternalIP.
- **Use typed annotations only — avoid `backend-config-snippet`** (upstream reliability issue #768). Everything this setup needs maps to typed annotations (see Task 2 mapping table).
- **Per-IP isolation must hold**: each IP reaches only its brand; the wrong IP returns 404/default. Verify with the isolation matrix after each cutover.
- **cert-manager stays on HTTP-01**; steer each domain via `http01.ingress.ingressClassName`; never set both `ingressClassName` and the legacy `class` on a solver (upstream #6184).
- **Production cutover of the public entrypoint** — brand-by-brand, each in a maintenance window, each with a tested rollback (git revert restores that brand's nginx controller + externalIP).
- All new-file comments in English.

## Feature audit (why this migration is low-surface)

Confirmed from the repo — the ONLY ingress-nginx features in use:

| In use (nginx) | Business-critical? | HAProxy IC equivalent |
|---|---|---|
| `use-gzip` + gzip params | no | **unsupported** — haproxytech IC has no compression config keys (upstream #196); only via forbidden `backend-config-snippet`. **Drop gzip** (non-critical per audit) |
| `use-gunzip` (decompress) | no | **no equivalent** — HAProxy compresses but never decompresses. Impact low; safe drop |
| `ssl-redirect` | yes | `haproxy.org/ssl-redirect: "true"` |
| `use-regex` (paths) | yes | HAProxy path matching / `haproxy.org/path-rewrite` (regex-capable; **test each path**) |
| `from-to-www-redirect` | yes | **NO drop-in** → hand-author `haproxy.org/request-redirect` per host |
| `server-snippet` → 6 `X-*` debug headers | no (diagnostic) | `haproxy.org/response-set-header` (typed; or drop) |
| caching / Lua / WAF / auth / rate-limit / canary / gRPC / mirror / config-snippet | **none used** | n/a |

Note: the `fastcgi_cache` in `apps/lf-prod/hfc-wp/configmap-nginx.yaml` is the **WordPress pod's own nginx**, not the ingress controller — untouched by this migration.

---

## File Structure

**New:**
- `infrastructure/cluster/haproxy-ingress/source.yaml` — HelmRepository `haproxytech`.
- `infrastructure/cluster/haproxy-ingress/release-hfc.yaml` — HAProxy IC for homefinanceclub (`5.161.26.66`, class `haproxy-hfc`).
- `infrastructure/cluster/haproxy-ingress/release-main.yaml` — HAProxy IC for leadsfilter (`178.156.239.214`, class `haproxy`).
- `infrastructure/cluster/haproxy-ingress/kustomization.yaml`.

**Modified:**
- `infrastructure/cluster/kustomization.yaml` — add `haproxy-ingress/` (initially only the HelmRepository + hfc release; main added at its cutover).
- `apps/lf-prod/ingress/homefinanceclub.yaml` — `ingressClassName: nginx-hfc` → `haproxy-hfc`; re-express annotations; add per-host www redirect.
- `apps/lf-prod/ingress/leadsfilter.yaml` — `ingressClassName: nginx` → `haproxy` (at its cutover); same annotation work.
- `infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml` — point each domain's solver at the new class.
- `infrastructure/cluster/nginx-ingress/release-hfc.yaml` / `release.yaml` — removed at decommission (Task 9), not before.

---

### Task 0: Prerequisites & version pin

- [x] **Step 1: DONE (2026-07-09).** Chart downloaded and templates read; both instances rendered offline. Pin = chart **1.52.1** (controller 3.2.12). All value keys verified against `_podspec.tpl`/`_helpers.tpl` — see "Version map", "Chart facts", and "Local render" sections above. No further key-guessing required.

- [x] **Step 1b: DONE (2026-07-09).** Container-user question settled by inspecting the image config from the registry: `haproxytech/kubernetes-ingress:3.2.12` has **no `USER` → runs as root**, so `unprivileged: false` (no securityContext rendered) binds 80/443 cleanly. See "RESOLVED — container user" above. Runtime proof remains Task 5 Step 2 (log shows bind on `<ip>:80/443`).
- [ ] **Step 2:** Confirm node facts still hold:
```bash
kubectl get node leadsfilter-n1 -o wide           # INTERNAL-IP = 178.156.239.214
ssh leadsfilter-n1 ip -4 addr show eth0           # both public IPs present
```
- [ ] **Step 3:** Record decisions at the top of this file: chart version pin; whether to keep the 6 debug `X-*` headers (re-express) or drop them.

---

### Task 1: Add the haproxytech HelmRepository (no controller yet — safe)

**Files:** Create `infrastructure/cluster/haproxy-ingress/source.yaml`, `kustomization.yaml`; modify `infrastructure/cluster/kustomization.yaml`.

- [ ] **Step 1:** Write `source.yaml`:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: haproxytech
  namespace: flux-system
spec:
  interval: 24h
  url: https://haproxytech.github.io/helm-charts
```
- [ ] **Step 2:** Write `infrastructure/cluster/haproxy-ingress/kustomization.yaml` listing only `source.yaml` for now:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - source.yaml
```
- [ ] **Step 3:** Add `- haproxy-ingress/` to `infrastructure/cluster/kustomization.yaml`.
- [ ] **Step 4: Commit & verify the repo resolves:**
```bash
git add infrastructure/cluster/haproxy-ingress/ infrastructure/cluster/kustomization.yaml
git commit -m "haproxy-ic: add helm repository (no controller yet)"
git push && flux reconcile source helm haproxytech -n flux-system
```
Expected: HelmRepository READY. No workload deployed yet.

---

### Task 2: Author the HFC controller HelmRelease (deployed, but not yet owning the IP)

**Files:** Create `infrastructure/cluster/haproxy-ingress/release-hfc.yaml`.

**Interfaces / key values:** DaemonSet, hostNetwork, `hostIP: 5.161.26.66`, IngressClass `haproxy-hfc`, its own controllerClass, gzip, the debug headers (if kept) as a global `response-set-header`. Pin the chart.

- [ ] **Step 1:** Write `release-hfc.yaml`:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: haproxy-ingress-hfc
  namespace: flux-system
spec:
  interval: 1h
  chart:
    spec:
      # CHART version 1.52.1 → controller (appVersion) 3.2.12 → HAProxy 3.2.x
      # engine. Pin exactly; do NOT use a floating range (the old April
      # release used ">=1.0.0 <2.0.0", which is this same live 1.x line).
      chart: kubernetes-ingress
      version: "1.52.1"
      sourceRef:
        kind: HelmRepository
        name: haproxytech
        namespace: flux-system
  targetNamespace: haproxy-ingress
  install:
    createNamespace: true
  values:
    controller:
      kind: DaemonSet
      # BLOCKER 3: hostNetwork is gated by daemonset.useHostNetwork, NOT
      # controller.hostNetwork (that key is silently dropped by Helm).
      dnsPolicy: ClusterFirstWithHostNet          # required with hostNetwork for cluster DNS
      # BLOCKER 1: chart default containerPort is 8080/8443; under hostNetwork
      # HAProxy binds these directly → nothing on :80/:443. Set 80/443.
      # stat/admin MUST differ from the MAIN instance (HIGH 4 — shared netns).
      containerPort:
        http: 80
        https: 443
        stat: 1024
        admin: 6060
      # BLOCKER 1 — binding <1024. VERIFIED by reading the chart templates:
      #   * `allowPrivilegedPorts: true` must NOT be used here. _helpers.tpl
      #     implements it by injecting the sysctl
      #     net.ipv4.ip_unprivileged_port_start=0 — and namespaced net.*
      #     sysctls are FORBIDDEN on hostNetwork pods (kubelet rejects the pod
      #     with SysctlForbidden). It would actively break us.
      #   * With `unprivileged: true` (default) _podspec.tpl sets
      #     runAsUser:1000 + capabilities add NET_BIND_SERVICE. That MAY bind
      #     80/443 if the image has file-caps on the binary — the vendor's own
      #     ci/daemonset-privileged-ports.values.yaml sets ONLY containerPort
      #     80/443 and nothing else, which suggests it works.
      #   * Safest for hostNetwork: `unprivileged: false` → no securityContext
      #     block is rendered at all → runs as root → binds 80/443 outright.
      # DECIDE + TEST this one (see Task 0). Starting with root is lower risk.
      unprivileged: false
      # HIGH 4: both default to true and add MORE listeners (metrics on the
      # stat port, pprof on the admin port) that collide in the shared host
      # netns. Disable on at least one instance, or give distinct ports.
      prometheus:
        enabled: false
      pprof:
        enabled: false
      daemonset:
        useHostNetwork: true
        useHostPort: true
        # hostIP makes the (hostIP,port) scheduler tuples distinct so BOTH
        # DaemonSet pods schedule on the one node (#117689). It does NOT set
        # HAProxy's bind address — see extraArgs.
        hostIP: 5.161.26.66
        hostPorts:
          http: 80
          https: 443
          stat: 1024
      nodeSelector:
        kubernetes.io/hostname: leadsfilter-n1
      ingressClass: haproxy-hfc
      # NOTE (verified): the real values.yaml has only {name, default,
      # parameters} here — there is NO `enabled` key. Do not add one; Helm
      # silently drops unknown keys (the Blocker-3 trap).
      ingressClassResource:
        name: haproxy-hfc
        default: false
      # BLOCKER 2: THE actual per-IP bind + brand isolation. Without this
      # HAProxy binds 0.0.0.0 → EADDRINUSE on the 2nd pod AND both IPs serve
      # both brands. Do NOT also put --ingress.class here (chart emits it
      # from ingressClass above — MEDIUM 8 duplicate).
      extraArgs:
        - "--ipv4-bind-address=5.161.26.66"
        # BLOCKER 2b: --ipv6-bind-address defaults to "::" — BOTH instances
        # would also bind :::80/:::443 → second pod EADDRINUSE even with
        # distinct IPv4 binds. Worse, with net.ipv6.bindv6only=0 (Linux
        # default) a "::" bind ALSO accepts IPv4 → brand isolation leaks.
        # Disable v6 on both instances (or give each a distinct IPv6).
        - "--disable-ipv6"
      # publishService defaults to TRUE and emits --publish-service=<ns>/<svc>
      # pointing at the Service we disable below → the controller would be told
      # to publish Ingress status via a non-existent Service. Turn it off.
      # (Ingress ADDRESS status stays empty — cosmetic; cert-manager doesn't
      # need it.) VERIFIED: with this false, the flag disappears from the render.
      publishService:
        enabled: false
      # No Service — isolation is via --ipv4-bind-address, not kube-proxy.
      # NEVER add externalIPs (would reintroduce the DNAT collision).
      service:
        enabled: false
        # HIGH 4 / QUIC — RESOLVED by reading _podspec.tpl: the QUIC args are
        # gated on `and (k8s>=1.24) service.enablePorts.quic`, and that flag is
        # checked INDEPENDENTLY of service.enabled. Left at its default (true)
        # both instances would get --quic-bind-port=443 → both bind udp/443 →
        # collision. Setting this false removes the QUIC args entirely.
        enablePorts:
          quic: false
      # HIGH 4: disable QUIC (udp/443 would collide with the other instance).
      # Confirm the exact key against `helm show values` (e.g.
      # service.enablePorts.quic: false and/or dropping quic extraArgs).
      # MEDIUM 6: NO compression keys — compression is unsupported by this
      # controller (upstream #196); gzip dropped (non-critical per audit).
      # MEDIUM 9: NO response-set-header debug block — the 6 nginx $-vars have
      # no clean HAProxy fetch; dropped (diagnostic only).
```
> **NOTE (must-verify before commit):** every value KEY above is version-specific — run `helm show values haproxytech/kubernetes-ingress --version <pin>` (Task 0) and confirm each path exists: `daemonset.useHostNetwork`, `daemonset.useHostPort`, `daemonset.hostIP`, `daemonset.hostPorts.*`, `containerPort.*`, `service.enabled`, the QUIC-disable key, and that `--ipv4-bind-address` is accepted (default `0.0.0.0`, from `controller.md`). Also confirm the chart's `securityContext` grants `NET_BIND_SERVICE` for the &lt;1024 bind (BLOCKER 1 / #589); add it if missing.

**MAIN instance (`release-main.yaml`, Task 7):** identical shape but `hostIP`/`--ipv4-bind-address` = `178.156.239.214`, class `haproxy`, and **distinct** `containerPort.stat`/`admin` (e.g. 1026/6061) + `hostPorts.stat: 1026` so the two hostNetwork instances don't collide on the stat/admin/metrics ports (HIGH 4).

- [ ] **Step 2:** Do NOT add it to the kustomization yet. Commit the file alone:
```bash
git add infrastructure/cluster/haproxy-ingress/release-hfc.yaml
git commit -m "haproxy-ic: author HFC controller (not wired yet)"
```

---

### Task 3: Prepare the HFC Ingress on the new class + hand-authored www redirect (in a branch/staged file, applied at cutover)

**Files:** Modify `apps/lf-prod/ingress/homefinanceclub.yaml` (staged — applied in Task 5).

- [ ] **Step 1:** Produce the target Ingress: change `ingressClassName: nginx-hfc` → `haproxy-hfc`; translate annotations:
  - `ssl-redirect: "true"` → `haproxy.org/ssl-redirect: "true"` + `haproxy.org/ssl-redirect-code: "301"`. **MEDIUM 7:** the haproxytech default is `false`, so set it EXPLICITLY (and on leadsfilter too, which has no such annotation today and relies on nginx's implicit redirect — else HTTPS-forcing is silently lost).
  - `use-regex: "true"` → remove; **MEDIUM 11:** these are `Prefix` paths — verify each still matches and precedence holds. HFC paths incl. trailing slashes: `/serviceroom/api/`, `/serviceroom/`, `/api/`, `/wapp/`, `/`. Test exact-boundary requests (`/api` vs `/api/`).
  - `from-to-www-redirect: "true"` → **hand-author** a separate `www.homefinanceclub.com` Ingress with `haproxy.org/request-redirect: "homefinanceclub.com"` + `haproxy.org/request-redirect-code: "301"` (value is host or host:port only; code is a separate key — confirm vs chart docs).
- [ ] **Step 2 (HIGH 5 — critical): confirm the www redirect does NOT swallow the ACME path.** cert-manager issues a challenge per SAN incl. `www`; if the www→apex 301 catches `/.well-known/acme-challenge/…`, the `www` challenge stalls (passes cutover, fails at renewal ~30 days). Before trusting it, force a **staging** re-issue that includes the `www` SAN with the redirect Ingress live and confirm `Ready=True`. If it redirects the ACME path, scope the redirect to exclude `.well-known` or drop it during issuance (or reconsider `jcmoraisjr/haproxy-ingress`, which has a true 1:1 `from-to-www-redirect`).
- [ ] **Step 3:** Keep staged (do not push to the live path until Task 5). Dry-run render locally if practical.

---

### Task 4: Point cert-manager's HFC solver at the new class (staged with Task 5)

**Files:** Modify `infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml`.

- [ ] **Step 1:** Change the homefinanceclub solver's `http01.ingress.ingressClassName: nginx-hfc` → `haproxy-hfc`. Keep the default solver (leadsfilter) on `nginx` until Task 7. Ensure every host in the Ingress `tls.hosts` (apex + www) is in the selector `dnsNames` (per the runbook's known trap).

---

### Task 5: CUTOVER homefinanceclub (5.161.26.66) — maintenance window

**Files:** add `release-hfc.yaml` to `haproxy-ingress/kustomization.yaml`; remove `externalIPs` from `nginx-ingress/release-hfc.yaml`; apply the staged Ingress (Task 3) and issuer (Task 4).

**The blip is unavoidable:** nginx-hfc owns `5.161.26.66` via kube-proxy externalIP; HAProxy-hfc wants to bind `5.161.26.66:80/443` in hostNetwork. They cannot both hold the IP. Remove the nginx externalIP and bring up HAProxy-hfc together, in one window. leadsfilter stays fully live on nginx throughout.

- [ ] **Step 1:** Single commit: add `release-hfc.yaml` to the haproxy kustomization; delete `service.externalIPs` from `nginx-ingress/release-hfc.yaml`; switch `homefinanceclub.yaml` to `haproxy-hfc`; switch the issuer HFC solver to `haproxy-hfc`.
```bash
git add infrastructure/cluster/haproxy-ingress/kustomization.yaml \
        infrastructure/cluster/nginx-ingress/release-hfc.yaml \
        apps/lf-prod/ingress/homefinanceclub.yaml \
        infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml
git commit -m "haproxy-ic: cutover homefinanceclub to HAProxy IC on 5.161.26.66"
git push
```
- [ ] **Step 2:** Reconcile and watch, in order:
```bash
flux reconcile kustomization <infra-kustomization> --with-source
kubectl -n ingress-nginx get svc nginx-ingress-hfc... # EXTERNAL-IP -> <none>
kubectl -n haproxy-ingress get pod -o wide            # haproxy-hfc DaemonSet pod Running on leadsfilter-n1
kubectl -n haproxy-ingress logs ds/... --tail=80      # bound 5.161.26.66:80/443 (NOT 8080/8443, NOT 0.0.0.0), no EADDRINUSE
```
- [ ] **Step 2b (MEDIUM 10 — clear the DNAT/conntrack race):** the externalIP DNAT runs in PREROUTING before local delivery, and conntrack entries persist after the rule is deleted. In the window:
```bash
ssh leadsfilter-n1 'iptables-save -t nat | grep 5.161.26.66'   # expect: no externalIP DNAT rule left
# optionally scale the retiring nginx-hfc to 0 first to avoid a dying-pod race, then:
ssh leadsfilter-n1 'conntrack -D -d 5.161.26.66 2>/dev/null'    # flush stale entries so new conns hit HAProxy
```
- [ ] **Step 3: Verify — client IP, TLS, isolation:**
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://homefinanceclub.com/         # 200/redirect as before
curl -I -H "Host: homefinanceclub.com" http://178.156.239.214/                 # 404 (isolation: not served on the other IP)
curl -I http://www.homefinanceclub.com/                                        # 301 -> apex (www redirect works)
```
Confirm the **app** logs the real client IP (submit a test lead on homefinanceclub, check `X-Forwarded-For` = your source IP, not a node/10.x IP). Force a **staging** cert issuance including the `www` SAN and confirm `Ready=True` (proves HTTP-01 works natively — no PROXY, no hairpin).

**Rollback (rehearse first):** `git revert HEAD && git push && flux reconcile ...` restores nginx-hfc + its externalIP `5.161.26.66` and the old class/solver. leadsfilter was never touched.

---

### Task 6: Soak homefinanceclub 24–48h

- [ ] **Step 1:** Watch haproxy-hfc logs/memory; confirm no reload storms (out-of-scope TCP bugs shouldn't apply — verify), correct client IP, cert renews. Only after this is clean, proceed to the main brand.

---

### Task 7: Author + prepare the MAIN controller (leadsfilter, 178.156.239.214)

**Files:** Create `infrastructure/cluster/haproxy-ingress/release-main.yaml` (mirror of hfc: `hostIP: 178.156.239.214`, class `haproxy`, `--ingress.class=haproxy`); stage `apps/lf-prod/ingress/leadsfilter.yaml` on class `haproxy` with translated annotations + www redirect; prepare issuer default solver → `haproxy`.

- [ ] **Step 1:** Copy `release-hfc.yaml` → `release-main.yaml`, changing `hostIP`, `ingressClass`/`ingressClassResource.name` to `haproxy`, `--ingress.class=haproxy`, HelmRelease `metadata.name: haproxy-ingress-main`. Keep the same gzip/header config.
- [ ] **Step 2:** Stage the leadsfilter Ingress translation (same annotation mapping as Task 3; note leadsfilter serves `/admin2 /api /portal /shared /serviceroom/... /corp /`).

---

### Task 8: CUTOVER leadsfilter (178.156.239.214) — maintenance window

Same shape as Task 5 for the main brand: single commit adds `release-main.yaml` to the haproxy kustomization, removes `externalIPs` from `nginx-ingress/release.yaml`, switches `leadsfilter.yaml` to class `haproxy`, and switches the issuer default solver to `haproxy`. Reconcile, watch bind on `178.156.239.214`, verify client IP / TLS staging / isolation matrix (all four combos), rehearse rollback (`git revert`).

- [ ] **Steps:** mirror Task 5 Steps 1–3 with main-brand values. **Extra care:** this is the primary node IP — confirm the hostNetwork pod binding `178.156.239.214:80/443` does not clash with anything else on the node (`ss -ltnp` pre-check; only the retiring nginx externalIP path should free up).

---

### Task 9: Decommission ingress-nginx

**Files:** delete `infrastructure/cluster/nginx-ingress/` (both releases, source), remove it from `infrastructure/cluster/kustomization.yaml`. Delete leftover Helm release Secrets in `flux-system` if Flux doesn't (`sh.helm.release.v1.nginx-ingress*`).

- [ ] **Step 1:** Only after BOTH brands are soaked and green. Commit the removal; verify no `ingress-nginx` namespace workloads remain and both sites still serve.

---

## Risks / weak spots (attack list for the reviewer)

1. **Chart value paths for `daemonset.hostIP` / per-instance class / `response-set-header`** — must be verified against the pinned chart's `helm show values`; wrong keys = silent no-op (e.g. instance binds `0.0.0.0` → clashes with the other instance / breaks isolation). Highest-churn risk.
2. **k8s 1.35 off-matrix** — formality now; could bite on a future controller/k8s bump. Pin versions; watch release notes.
3. **Cutover blip + hostIP bind vs nginx externalIP overlap** — the IP can't be held by both; the single-commit + manual window mitigates but a brief outage per brand is unavoidable. Rollback must be rehearsed.
4. **`from-to-www-redirect` re-authoring** — no drop-in; the hand-authored redirect must reproduce exact direction/permanence and NOT catch the ACME path. Test `www` + `/.well-known/acme-challenge` behavior.
5. **`use-regex` path semantics differ** — HAProxy path matching/rewrite is not nginx regex; each path must be tested (their paths are simple prefixes, low risk, but verify `/serviceroom/api` vs `/serviceroom` ordering).
6. **Isolation via hostIP** — confirm the wrong-IP request returns 404, not the other brand (the whole point). Test the 4-way matrix after each cutover.
7. **cert-manager solver class + www SAN** — reuse the runbook lessons (multi-solver per class, every tls.host in selector, delete stuck Order to force re-read).
8. **DaemonSet vs Deployment / node pinning** — two DaemonSets each land one pod on the single node; confirm both schedule and neither is Pending on hostPort (should be defused by distinct hostIP).
9. **backend-config-snippet avoidance** — do not use it (#768); if any requirement forces it, reconsider `jcmoraisjr/haproxy-ingress`.
10. **Debug headers** — some nginx vars have no HAProxy equivalent; decide keep-subset vs drop; don't block the migration on cosmetic headers.

## Self-Review (author pass)

- **Spec coverage:** replaces both nginx controllers with two hostNetwork HAProxy IC instances (Tasks 2/5/7/8), native client IP (hostNetwork, no edge-lb/PROXY), per-IP isolation via hostIP, cert-manager HTTP-01 unchanged (Task 4), annotation mapping for the exact features in use (audit table), off EOL nginx (Task 9), brand-by-brand staged cutover with rollback. ✅
- **Placeholder scan:** `<PINNED_CHART_VERSION>` and the chart value-key verification are intentionally gated on Task 0's `helm show values` — flagged as must-verify, not lazy TODO. The www-redirect/response-header exact syntax is explicitly "confirm from chart docs" because it is version-specific.
- **Consistency:** IPs, classes (`haproxy` / `haproxy-hfc`), node name, and cert-manager selectors are consistent across tasks and match cluster reality.
