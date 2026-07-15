# 05 — Sources consulted, and what each actually said

So a future agent doesn't re-fetch these. Grouped by kind. Everything checked **2026-07-09** unless noted.

---

## §1. Source of truth: the chart itself (the only round that was conclusive)

| Artifact | How obtained | What it gave |
|---|---|---|
| Helm index `https://haproxytech.github.io/helm-charts/index.yaml` | `curl` | **Three charts** in one repo: `haproxy` (1.29.0 / appVersion 3.3.10 / image `haproxy-alpine:3.3.6`), `haproxy-unified-gateway`, **`kubernetes-ingress` (1.52.1 / appVersion 3.2.12, created 2026-07-03, `kubeVersion: '>=1.23.0-0'`)**. Index annotation `artifacthub.io/images: docker.io/haproxytech/kubernetes-ingress:3.2.12`. **Reading the wrong section caused R-09.** |
| `kubernetes-ingress-1.52.1.tgz` | `curl` from the GitHub release URL in the index, extracted with `tar` | see below |
| `Chart.yaml` | in tarball | `version: 1.52.1`, `appVersion: 3.2.12`, **`kubeVersion: '>=1.23.0-0'` — minimum only, no upper bound ⇒ k8s 1.35 installs** |
| `values.yaml` | in tarball | `containerPort: {http: 8080, https: 8443, stat: 1024, admin: 6060}`; `kind: Deployment`; `dnsPolicy: ClusterFirst`; `unprivileged: true`; **`allowPrivilegedPorts: false`**; `prometheus.enabled: true`; `pprof.enabled: true`; `publishService.enabled: true`; `service: {enabled: true, type: NodePort, enablePorts.quic: true, externalIPs: []}`; `daemonset: {useHostNetwork, useHostPort, hostIP, hostPorts}`; `ingressClassResource: {name, default, parameters}` — **no `enabled` key** (→ R-06); **no securityContext/runAsUser/capabilities keys anywhere** |
| `templates/_podspec.tpl` | in tarball | The decisive file. `:58` hostNetwork gated by `daemonset.useHostNetwork` (→ R-04). `:106-107` `--http-bind-port`/`--https-bind-port` from `containerPort` (→ Blocker 1). `:108` QUIC gated by `and (semverCompare ">=1.24.0-0") service.enablePorts.quic`, **independent of `service.enabled`** (→ R-07). `:123` `--ingress.class` emitted from `ingressClass`. `:128-129` `--publish-service` gated by `publishService.enabled`. `:134-138` `--prometheus`/`--pprof`. `:160` `extraArgs` appended after built-ins. `:163-175` securityContext **only if `unprivileged`** → `runAsUser: 1000` + `capabilities {drop: ALL, add: NET_BIND_SERVICE}`. `:181-185` `hostPort` gated by `useHostPort`; **`hostIP` only into the port spec** (→ R-01) |
| `templates/_helpers.tpl` | in tarball | `:185` — `allowPrivilegedPorts` is implemented by **injecting sysctl `net.ipv4.ip_unprivileged_port_start=0`** (→ **R-02**, the trap) |
| `README.md` | in tarball | `:346` — *"`controller.allowPrivilegedPorts` — Allow non-root to bind ports < 1024 (auto-enables `net.ipv4.ip_unprivileged_port_start=0`)"* |
| `ci/daemonset-privileged-ports.values.yaml` | in tarball | The vendor's own privileged-ports CI case is **only** `kind: DaemonSet` + `containerPort {http: 80, https: 443, stat: 1024}` — implying the default `unprivileged: true` + `NET_BIND_SERVICE` path binds <1024 |
| Other useful `ci/*.yaml` (not yet mined) | in tarball | `daemonset-hostport-values.yaml`, `daemonset-quic-hostport-values.yaml`, `daemonset-ipfamily-values.yaml`, `daemonset-unprivileged-values.yaml` (this one **does** set `allowPrivilegedPorts: true` — but it is *not* hostNetwork), `daemonset-extraargs-values.yaml`, `daemonset-ingressclass-values.yaml`, `daemonset-publishservice-values.yaml` |
| Docker registry API for `haproxytech/kubernetes-ingress:3.2.12` | token → OCI index → linux/amd64 manifest → config blob, all via `curl` | **`User: None` → runs as ROOT**; `Entrypoint: ["/start.sh"]` ⇒ `unprivileged: false` binds 80/443 cleanly |
| `helm` v3.16.3 | downloaded to scratchpad (not installed on the box) | used **only** for offline `helm template --kube-version 1.35.2` — no cluster contact |

---

## §2. haproxytech controller documentation

**`documentation/controller.md`** (upstream `haproxytech/kubernetes-ingress`) — flags of the **ingress-controller binary** (not of `haproxy`):

| Flag | Default | Note |
|---|---|---|
| `--ipv4-bind-address` | `0.0.0.0` | *"Customize the IPv4 binding address."* — **the fix for R-01** |
| `--ipv6-bind-address` | **`::`** | **found the IPv6 blocker here** — the Opus review had missed it |
| `--disable-ipv4` / `--disable-ipv6` | `false` | |
| `--http-bind-port` | `8080` | independently confirms Blocker 1 |
| `--https-bind-port` | `8443` | |
| `--ingress.class` | — | still the correct flag in v3.x (no `--ingressclass` rename) |
| `--empty-ingress-class` | `false` | good default: each instance ignores the other's Ingresses |

**Community Ingress annotations reference** — `haproxy.org/` prefix. Confirmed: `ssl-redirect` (**default false**), `ssl-redirect-code`, `request-redirect` (**host or host:port only**, does **not** force scheme, code is a **separate** `request-redirect-code`), `response-set-header` (syntax `Name "value"`), `path-rewrite`. **No `from-to-www-redirect` equivalent.** ~48 annotations, **none for compression**.

---

## §3. GitHub issues — what each established

| Issue | Established |
|---|---|
| **haproxytech/kubernetes-ingress #589** | Under hostNetwork the controller binds the default **8080/8443**; several users had to raise capabilities. → Blocker 1 |
| **haproxytech/kubernetes-ingress #196** | **HTTP compression is an open feature request** — unsupported → R-05 |
| **haproxytech/kubernetes-ingress #768** | `backend-config-snippet` loss — the reason to use typed annotations only |
| **haproxytech/kubernetes-ingress #765 / #762 / #773** | Reload storms — **TCP-CRD-specific**, out of scope for HTTP-only |
| **haproxytech/kubernetes-ingress #772** | Memory creep at ~150 ingresses — irrelevant at our scale |
| **kubernetes/kubernetes #117689** | Under `hostNetwork` the PodSpec **defaulter sets `hostPort = containerPort`** at admission → two hostNetwork pods collide; a chart's `hostPort.enabled: false` cannot override it. *(The team already hit this — `adding-hfc-ip.md`.)* |
| **kubernetes/kubernetes #103298** | Namespaced `net.*` sysctls are **forbidden on hostNetwork pods** (`SysctlForbidden`) → kills R-02 **and** the edge-lb `ip_unprivileged_port_start` idea |
| **kubernetes/kubernetes #56374** | Kubernetes does **not** populate *ambient* capabilities → `capabilities.add: NET_BIND_SERVICE` alone does not survive a non-root UID (needs file-caps) |
| **kubernetes/kubernetes #62112** | `hostIP` + `hostPort` workaround is buggy — blocked the ingress-nginx `bind-address` route |
| **nginx/kubernetes-ingress #3714** | Same `ip_unprivileged_port_start`-forbidden-on-hostNetwork finding, from the nginx side |
| **kubernetes/ingress-nginx #2529** | **`bind-address` is not respected by the startup port-availability check** → the second hostNetwork controller crash-loops although *its* IP:80 is free |
| **kubernetes/ingress-nginx #7859** | Same: chart option `bind-address` not honoured at startup, nginx fails |
| **kubernetes/ingress-nginx #9749** | "externalTrafficPolicy: Local not preserving client IP" behind externalIPs — the common confusion |
| **kubernetes/ingress-nginx #6023** | externalIP does not preserve source IP |
| **kubernetes/ingress-nginx #6136** | "Preserve client IP address" |
| **kubernetes/ingress-nginx #6853 / #11315** | **`from-to-www-redirect` renders a separate server block with an unconditional `return 301` and no `/.well-known/` carve-out** → the Path-A/Path-B `www`×ACME landmine |
| **kubernetes/ingress-nginx #11365** | proxy-protocol vs HTTP-01 |
| **cert-manager/cert-manager #466** | **`proxy_protocol` mode breaks the HTTP01 challenge Check stage** — the core Path-A problem |
| **cert-manager/cert-manager #4286** | Request for a custom DNS server for the self-check ⇒ proves the **default is cluster DNS** → D3 is not a no-op |
| **cert-manager/cert-manager #1292** | Request to skip the self-check per solver — i.e. **there is no supported skip flag** |
| **cert-manager/cert-manager #6184** | Don't set both `ingressClassName` and the legacy `class` on a solver |
| **haproxy/haproxy #511** | PROXY-protocol v2 **health-check** header doesn't follow the spec |
| **opnsense/plugins #2909** | You cannot configure proxy-protocol separately for health checks |
| **fluxcd/flux2 #293** | *"Kubernetes only allows updating a single resource at a time and the updates are **not dependency ordered**"* → the "atomic single commit" cutover is a fiction |
| **compumike/hairpin-proxy #10** | Its `cluster.local` rewrite breaks **DNS-01** challenges |
| **kube-router #376 / #511** | hostNetwork-pod → ClusterIP SNAT quirks — the reason the D3 hairpin is *plausible but unproven* here |

---

## §4. Official documentation

| Doc | Key content |
|---|---|
| **ingress-nginx — Bare-metal considerations** | The decisive quote: `externalIPs` *"**does not allow preserving the source IP of HTTP requests in any manner**, it is therefore not recommended"*. Also: `externalTrafficPolicy: Local` is the way to preserve source IP **for NodePort**, at the cost of dropping traffic to nodes without a controller pod; and **DaemonSet + `hostNetwork: true`** is the standard bare-metal alternative (pods inherit the node IP; only one controller pod per node). |
| **ingress-nginx — ConfigMap reference** | `bind-address` exists ("addresses on which the server will accept requests instead of `*`"); the addresses must exist at runtime or the controller crash-loops |
| **MetalLB — Cloud Compatibility** | ARP is emulated by cloud virtual networks ⇒ **L2 mode is broken on Hetzner Cloud**; floating IPs need a proprietary API call MetalLB can't make. Workarounds: `invidian/metallb-hcloud-controller`, or Hetzner **Dedicated** + vSwitch |
| **MetalLB — Installation/requirements** | k8s ≥1.13; `strictARP: true` if kube-proxy is in IPVS mode; a pool of routable IPs; speaker memberlist on **7946** TCP+UDP; BGP mode needs a BGP router |
| **cert-manager — HTTP01 docs & controller CLI** | `--acme-http01-solver-nameservers` **defaults to empty** ⇒ the self-check uses the pod resolver ⇒ **CoreDNS** ⇒ D3 works |
| **cert-manager — `pkg/issuer/acme/http/http.go`** | The reachability test builds a custom resolving dialer **only when `dnsServers` is non-empty** — the mechanical proof of the above |
| **CoreDNS `hosts` plugin** | Static name→A mappings; **`fallthrough` is mandatory** or `hosts` becomes authoritative for the whole zone (NXDOMAIN everything); plugin order is fixed by the compiled `plugin.cfg`, **not** by position in the Corefile; `no_reverse` suppresses PTR |
| **Cloudflare — IP addresses / Protect your origin** | Shared anycast ranges used by **all** proxied hostnames; proxied (orange-cloud) records hide the origin; **allowlist Cloudflare IPs at the origin** or it's not hidden; BYOIP/static IPs are Enterprise-only |
| **Hetzner Cloud Load Balancer** | Own **dedicated** IP per LB (not a shared pool); can generate a Let's Encrypt cert or take an uploaded one |
| **Hetzner price adjustment (15 June 2026)** | Dedicated-vCPU lines re-priced hard: **CCX23 $39.99 → $102.99 (+158%)**, **CPX41 $46.49 → $141.49 (+204%)**; LB add-on ~$39/mo. The cheap shared `CX` line survived (CX33 4/8 ≈ €6.49). This is why "just add a second server" was rejected |
| **HAProxy releases** | 3.4 is the newest LTS (3.4.2, 2026-07-03); **3.2 LTS** (3.2.21, EOL 2030-Q2) chosen for the edge-lb image because 3.4 was days old |
| **Docker Hub — official `haproxy` image** | Runs as **non-root `USER haproxy` (UID 99) since 2.4** → why edge-lb needs `runAsUser: 0`. **Contrast with the haproxytech controller image, which is root.** |

---

## §5. Third-party writeups (useful, not authoritative)

| Source | What it added |
|---|---|
| techblog.schwarz — "Receiving the client ip when using cert-manager's http01 challenge and ExternalDNS" | The canonical description of proxy-protocol × HTTP-01 self-check failure and the hairpin-proxy remedy |
| therubyist.org — "cert-manager, NAT loopback and CoreDNS" (2021) | A working precedent for exactly the **D3** approach (CoreDNS hosts-override → hairpin); also warns the CoreDNS ConfigMap can be reverted by the distro (they hit it on k3s — we have the same on **k0s**) |
| Cozystack — "PROXY-protocol and the hairpin-NAT fix" (updated 2026-06) | Uses a Go reimplementation of hairpin-proxy called **ouroboros** — evidence the pattern is alive and that upstream's Ruby original is stale |
| stackharbor.com — "Origin IP still exposed behind Cloudflare" | How origins leak despite a CDN: passive DNS, **Certificate Transparency**, direct scanning ⇒ **you must rotate the already-exposed IPs**, not just proxy the DNS |
| Easton blog — Cloudflare free-tier limits (2026-05) | *"CDN and DNS's 'unlimited' is real — as long as you don't host videos and large files"* |
| Cloudflare Community — "Are there limits to the amount of traffic in the Free and Pro SKUs" | No published cap; Cloudflare may **ask** you to upgrade for disproportionate use but **does not cut traffic or bill overage**; real reports of **15–20 TB/month** on free |
| 0xpatrik — "OSINT Primer: Domains" / HackerTarget / whoisfreaks | How common ownership is actually linked: reverse-IP, **ASN/netblock**, passive DNS, **nameserver pivot**, **Certificate Transparency**, shared analytics IDs ⇒ why two IPs on one box is weak obfuscation |
| leadgen-economy.com | Lead-economy structure (generators → brokers/networks/exchanges → buyers); industry norms lean **transparent**, not obscured |
| VersionLog / endoflife.date | HAProxy LTS cadence: even branches (3.0/3.2/3.4) = LTS, 5 years; odd (3.1/3.3) = 12–18 months |

---

## §6. In-repo sources (read in full — do not skip)

| File | Why it matters |
|---|---|
| **`docs/adding-hfc-ip.md`** | **The single most valuable in-repo document.** The team's own runbook for the two-IP setup + a troubleshooting section of real incidents: hostNetwork rolling-update deadlock, Helm 3-way merge error, **#117689 hostPort conflict**, **wrong node IP → kube-proxy routed to the wrong pod**, broken Helm release state, **cert-manager stuck Order** (you must *delete the Order*), **missing `www` DNS stalls a challenge**. Contains the **4-way isolation matrix** — reuse it to validate any replacement. |
| `infrastructure/cluster/nginx-ingress/release.yaml`, `release-hfc.yaml` | The current controllers: `ClusterIP` + `externalIPs`, gzip config, `server-snippet` debug headers; hfc has `admissionWebhooks.enabled: false` and a distinct `electionID` |
| `infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml` | ClusterIssuer `letsencrypt`, **HTTP-01**, per-domain solvers by `dnsNames` |
| `apps/lf-prod/ingress/leadsfilter.yaml`, `homefinanceclub.yaml` | The Ingresses, their annotations and paths (note: leadsfilter has **no** `ssl-redirect`) |
| `apps/lf-prod/hfc-wp/configmap-nginx.yaml` | The `fastcgi_cache` lives **here** — the WordPress pod's own nginx, **not** the ingress. Don't confuse them. |
| Git history | `df40563` (haproxy removed), `6dbdad5`/`983791f` (NGF migrated + reverted same day), `126b369`/`2e9ce96` (the runbook) — see `02-verified-facts.md` §7 |
| App repo `LeadsStore/leadstore-back` | `LeadStore.API/Startup.cs:95-101,116` (private ranges); `LeadApp.API/Program.cs:28-32,67` (**`0.0.0.0/0`** — R-12); `LeadApp.API/Controllers/AppController.cs:66`; `LeadApp.API/UseCases/AppSave/Mappers/HttpContextMapper.cs:28` |

---

## §7. Sources that were *not* consulted (gaps, if you need more)

- `kubectl get nodes -o wide` on the leadsfilter cluster — **never actually run**; node count is assumed to be 1 from the user's statement (see `06-open-questions.md`).
- The haproxytech **support matrix** page itself (the "tops out at k8s 1.34" claim came from the research agent, not from a first-hand read). Moot: `Chart.yaml`'s `kubeVersion: '>=1.23.0-0'` was read directly and has no upper bound.
- `jcmoraisjr/haproxy-ingress` — evaluated only via the research agent's summary (v0.16.1, May 2026, single maintainer, **has** a true `from-to-www-redirect` and `rewrite-target`). Its chart/templates were **not** downloaded or rendered. If H5 forces a controller change, this is the first thing to verify properly.
- HAProxy Unified Gateway — only the "Gateway-API-only, Ingress not shipped" fact; not evaluated further (correctly, for now).
