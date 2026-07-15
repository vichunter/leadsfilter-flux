# 02 — Verified facts

Every entry states **how** it was verified. **Do not re-verify these.** If you find one is wrong, it belongs in `03-refuted.md`.

Verification date: **2026-07-09** unless noted.

---

## §1. Node & network

### 1.1 The node ✅
`leadsfilter-n1` — **k0s v1.35.2**, single node, CNI **kube-router** (`kube-bridge` 10.244.0.1/24).
*Verified:* `ip -4 addr` output pasted by the user; k0s/kube-router confirmed by `docs/adding-hfc-ip.md` and the `kube-bridge` interface name.

### 1.2 Both public IPs are already on `eth0` ✅ — important
```
eth0: inet 5.161.26.66/32      scope global            valid_lft forever  preferred_lft forever
eth0: inet 178.156.239.214/32  metric 100 scope global dynamic  valid_lft 65061sec
```
*Verified:* `ip -4 addr` on `leadsfilter-n1`.

**Consequences:** a hostNetwork process **can bind both** — no `net.ipv4.ip_nonlocal_bind`, no AnyIP route, no interface surgery. This dissolved what had been "Blocker 3" of the edge-lb plan.

### 1.3 Which IP is "default", and how to tell ✅
- **`178.156.239.214`** = the node's **primary**: marked `dynamic` (Hetzner DHCP), finite lease (`valid_lft 65061sec`), `metric 100`.
- **`5.161.26.66`** = a Hetzner **Floating IP**, added manually: no `dynamic`, `valid_lft forever`. Persisted in **`/etc/netplan/60-floating-ip.yaml`**.
- `ip addr` alone is only an *inference*. The authoritative check is routing: **`ip route get 1.1.1.1`** → the `src` field is the default source IP.

*Verified:* the `ip -4 addr` output + `docs/adding-hfc-ip.md` (which documents creating `60-floating-ip.yaml` and explicitly says never to edit `50-cloud-init.yaml`, which cloud-init owns).

### 1.4 kubelet is pinned to the primary IP ✅
`--node-ip=178.156.239.214`, passed via the **k0s controller systemd unit** (`--kubelet-extra-args`), because `--node-ip` is not part of `KubeletConfiguration` and cannot go in `k0s.yaml`.
*Verified:* `docs/adding-hfc-ip.md` Step 3.
**Why it must stay true:** a hostNetwork pod inherits the node `InternalIP`. If kubelet auto-detected the Floating IP instead (it did once — see `01-timeline.md` §5.3 item 4), kube-proxy routes `.66` traffic to the wrong pod and isolation silently breaks.

### 1.5 Other interfaces ✅
`tun0` (192.168.255.1) and `tun1` (192.168.254.1) — the OpenVPN deployments in `infrastructure/cluster/openvpn/`. Irrelevant to ingress, **but a reason to bind specific IPs rather than `0.0.0.0`**.

### 1.6 Pod egress IP ≠ node default source IP ✅ — non-obvious, remember this
Google's SMTP bounce reported the connecting IP as **`[5.161.26.66]`**, even though the node's DHCP primary / default source is `178.156.239.214` and that is the IP that had been registered in Google Workspace.
*Verified:* verbatim in the postfix maillog: `550-5.7.1 Invalid credentials for relay [5.161.26.66]` — i.e. **Google printed the source IP it saw**.
Also: `curl ifconfig.me` **run on the node** returned `178.156.239.214` — the node's own egress. So the node's egress and a given pod's egress **differ**.
**Rule:** never infer a pod's egress IP from the node's default route. Check from inside the pod (`kubectl exec … curl ifconfig.me`), or read what the remote peer reports.

### 1.7 `inc-n1` is NOT part of this cluster ✅
`inc-n1` (eth0 `46.224.26.190/32`, `enp7s0` 172.20.1.2/32) belongs to a **different project/cluster (`inc`)**. It was inspected by mistake. Ignore it entirely.
*Verified:* stated by the user after the wrong host was pasted.

---

## §2. Cluster objects (current, pre-change)

### 2.1 The two ingress-nginx controllers ✅
From `kubectl get svc -A`:

| Service (ns `ingress-nginx`) | ClusterIP | EXTERNAL-IP | Ports |
|---|---|---|---|
| `ingress-nginx-nginx-ingress-controller` | `10.104.135.28` | **`178.156.239.214`** | 80,443 |
| `ingress-nginx-nginx-ingress-hfc-controller` | `10.97.6.254` | **`5.161.26.66`** | 80,443 |
| `ingress-nginx-nginx-ingress-controller-admission` | `10.100.152.45` | — | 443 |

Only **one** admission Service exists because `release-hfc.yaml` sets `controller.admissionWebhooks.enabled: false` (the runbook did that to avoid a `:8443` conflict between the two controllers on one node).

`kube-dns` = **`10.96.0.10`** (ns `kube-system`).

### 2.2 Why the Service names look like that ✅
Formula: **`<targetNamespace>-<HelmRelease.metadata.name>-controller`**.
Flux's helm-controller composes the Helm release name as `<targetNamespace>-<metadata.name>` → `ingress-nginx` + `nginx-ingress` = `ingress-nginx-nginx-ingress`; the chart's fullname template sees the chart name already present and doesn't duplicate it; the chart appends `-controller`. The admission Service is `<fullname>-controller-admission`.
*Verified:* `kubectl get svc -A` (ground truth) cross-read against the HelmReleases.
**An earlier guess (`nginx-ingress-ingress-nginx-controller`) was wrong** — see `03-refuted.md` R-10. **Read names from the cluster; never derive them.**

**They change only if** you change `metadata.name`, `targetNamespace`, `spec.releaseName`, `fullnameOverride`/`nameOverride`, the chart itself, or Flux's naming behaviour across a major upgrade. Pod restarts, reboots, same-version helm upgrades, ClusterIP changes and cert renewals do **not** change them.
**Decision:** leave the names alone for now (user: *"пользуемся тем что есть, чтобы не вносить шум"*). If stability is ever wanted, `controller.fullnameOverride` pins it — but applying it renames (recreates) the Services once.

### 2.3 cert-manager ✅
`infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml` — ClusterIssuer `letsencrypt`, ACME prod (`https://acme-v02.api.letsencrypt.org/directory`), email `vicdevcs@gmail.com`, **HTTP-01 for both domains**, with per-domain solvers:
```yaml
solvers:
  - selector:
      dnsNames: [homefinanceclub.com, www.homefinanceclub.com]
    http01: { ingress: { ingressClassName: nginx-hfc } }
  - http01: { ingress: { ingressClassName: nginx } }     # default solver
```
*Verified:* file read directly.
This multi-solver shape exists **because** of a real outage documented in `docs/adding-hfc-ip.md` Step 6 (a single hard-coded solver class put solver Ingresses on the wrong controller/IP → LE 404 → challenges stuck `pending` for days).

### 2.4 The Ingress objects ✅
- `apps/lf-prod/ingress/leadsfilter.yaml` — class `nginx`; hosts `leadsfilter.com`, `www.leadsfilter.com`; TLS secret `leadsfilter-tls`; annotations: `use-regex: "true"`, `from-to-www-redirect: "true"`, `cert-manager.io/cluster-issuer: letsencrypt`. **No `ssl-redirect` annotation** (it relies on nginx's implicit TLS redirect). Paths: `/admin2`, `/api`, `/portal`, `/shared`, `/serviceroom/admin`, `/serviceroom/api`, `/serviceroom`, `/corp`, `/`.
- `apps/lf-prod/ingress/homefinanceclub.yaml` — class `nginx-hfc`; hosts `homefinanceclub.com`, `www.homefinanceclub.com`; TLS secret `homefinanceclub-tls`; annotations: `use-regex`, `from-to-www-redirect`, **`ssl-redirect: "true"`**, cluster-issuer. Paths (note trailing slashes): `/serviceroom/api/`, `/serviceroom/`, `/api/`, `/wapp/`, `/`.

*Verified:* files read directly.

---

## §3. What ingress-nginx features are actually in use ✅

Audited the entire Flux repo by grep.

**Every Ingress annotation present, with counts:**
```
2  nginx.ingress.kubernetes.io/use-regex
2  nginx.ingress.kubernetes.io/from-to-www-redirect
1  nginx.ingress.kubernetes.io/ssl-redirect
```
That is the complete list.

**Controller `config:` (identical in `release.yaml` and `release-hfc.yaml`):**
```yaml
use-gzip: "true"
use-gunzip: "true"
gzip-level: "5"
gzip-min-length: "1000"
gzip-types: "text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript image/svg+xml image/x-icon image/bmp"
server-snippet: |
  more_set_headers "X-Request-Time: $request_time";
  more_set_headers "X-Upstream-Connect-Time: $upstream_connect_time";
  more_set_headers "X-Upstream-Header-Time: $upstream_header_time";
  more_set_headers "X-Request-Id: $req_id";
  more_set_headers "X-Served-At: $msec";
  more_set_headers "X-Served-At-Iso: $time_iso8601";
```

**NOT used anywhere at the ingress layer:** caching, Lua, ModSecurity/WAF, external auth, rate-limiting, canary, gRPC specials, mirroring, `configuration-snippet`.

**⚠️ The `fastcgi_cache` in the repo is NOT the ingress.** It lives in `apps/lf-prod/hfc-wp/configmap-nginx.yaml` — the **WordPress pod's own nginx** (php-fpm cache: `fastcgi_cache_path … keys_zone=hfc-wp:4m max_size=200m`, `fastcgi_cache_valid 200 24h`, `fastcgi_cache_bypass $skip_cache`). It is unaffected by any ingress-controller change. Do not confuse them.

**Conclusion ✅:** nothing nginx-exclusive is in use. The migration surface is tiny (see `04-options.md` for the mapping).

---

## §4. haproxytech chart facts — from the downloaded chart, not from docs

Downloaded `kubernetes-ingress-1.52.1.tgz` from `https://haproxytech.github.io/helm-charts` and read `Chart.yaml`, `values.yaml`, `templates/_podspec.tpl`, `templates/_helpers.tpl`, `README.md`, `ci/*.yaml`.

### 4.1 Version map ✅ — three separate numbers
The repo hosts **three charts**; the index's top entries are the `haproxy` chart, which is what caused an early misread (R-09):

| Chart | What | Chart version | appVersion |
|---|---|---|---|
| `haproxy` | standalone HAProxy | 1.29.0 | 3.3.10 (image annotation: `haproxy-alpine:3.3.6`) |
| `haproxy-unified-gateway` | Gateway-API product | — | — |
| **`kubernetes-ingress`** | **the ingress controller** | **1.52.1** | **3.2.12** (created 2026-07-03) |

For our chart: **chart `1.52.1` → controller `3.2.12` → HAProxy 3.2.x engine (inside the image)**.
`image.repository: docker.io/haproxytech/kubernetes-ingress`, `image.tag: ""` → defaults to appVersion. The index annotation confirms: `artifacthub.io/images: docker.io/haproxytech/kubernetes-ingress:3.2.12`.
**Lesson:** `appVersion` can lag reality (the `haproxy` chart says 3.3.10 but ships 3.3.6) — trust `artifacthub.io/images`.

### 4.2 `kubeVersion: '>=1.23.0-0'` ✅ — no upper bound
*Verified:* `Chart.yaml`.
⇒ **k8s 1.35 installs cleanly.** The vendor's *support-matrix doc* topping out at 1.34 is a support statement, not a chart constraint. Off-matrix = no vendor ticket, not a functional risk. Every API the controller consumes (Ingress/IngressClass `networking.k8s.io/v1`, EndpointSlice `discovery.k8s.io/v1`, Lease) is long-GA and un-removed in 1.35.

### 4.3 Template facts (`templates/_podspec.tpl`) ✅

| Line | What it proves |
|---|---|
| `:58` | `{{- if $useHostNetwork }}hostNetwork: true{{- end }}`, fed from **`daemonset.useHostNetwork`** → the correct key (**not** `controller.hostNetwork`) |
| `:70` | `dnsPolicy: {{ $ctlr.dnsPolicy }}` |
| `:106-107` | `- --http-bind-port={{ $ctlr.containerPort.http }}` / `--https-bind-port={{ … }}` → **`containerPort` drives the real bind** |
| `:108` | QUIC args gated on `and (semverCompare ">=1.24.0-0" …) $ctlr.service.enablePorts.quic` — **independent of `service.enabled`** |
| `:119-120` | `--quic-bind-port` / `--quic-announce-port` |
| `:123` | `--ingress.class` emitted from `controller.ingressClass` → **do not duplicate in `extraArgs`** |
| `:128-129` | `--publish-service` gated by **`publishService.enabled`** |
| `:134-138` | `--prometheus` / `--pprof` gated by `prometheus.enabled` / `pprof.enabled` |
| `:160` | `{{- range $ctlr.extraArgs }}` → extraArgs appended **after** built-ins |
| `:163-175` | securityContext rendered **only if `unprivileged`**; sets `runAsUser: 1000`, `capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}` |
| `:181-185` | `hostPort` gated by `$useHostPort`; **`hostIP` rendered only into the port spec** → it never reaches HAProxy's bind |

### 4.4 `values.yaml` defaults that matter ✅
```yaml
controller:
  kind: Deployment                 # must set DaemonSet
  containerPort: { http: 8080, https: 8443, stat: 1024, admin: 6060 }   # !!! not 80/443
  dnsPolicy: ClusterFirst
  extraArgs: []
  unprivileged: true
  allowPrivilegedPorts: false      # DANGEROUS with hostNetwork — see 4.6
  prometheus: { enabled: true }    # extra listener
  pprof:      { enabled: true }    # extra listener
  publishService: { enabled: true }
  ingressClass: haproxy
  ingressClassResource: { name: haproxy, default: false, parameters: {} }   # NOTE: no `enabled` key
  daemonset:  { useHostNetwork: false, useHostPort: false, hostIP: null,
                hostPorts: { http: 80, https: 443, stat: 1024 } }
  deployment: { …same host* keys… }
  service:
    enabled: true
    type: NodePort
    externalIPs: []
    enablePorts: { http: true, https: true, quic: true, stat: true, admin: true }
```
**`controller.ingressClassResource.enabled` DOES NOT EXIST** — only `{name, default, parameters}`. Setting it is silently dropped (the classic trap).

### 4.5 Controller CLI flags (upstream `documentation/controller.md`) ✅
These belong to the **ingress-controller binary**, *not* to `haproxy` (haproxy binds whatever the generated config says; the controller renders the `bind` lines).

| Flag | Default |
|---|---|
| `--ipv4-bind-address` | `0.0.0.0` |
| `--ipv6-bind-address` | **`::`** |
| `--disable-ipv4` | `false` |
| `--disable-ipv6` | `false` |
| `--http-bind-port` | `8080` |
| `--https-bind-port` | `8443` |
| `--ingress.class` | (none) |
| `--empty-ingress-class` | `false` |

### 4.6 🔴 `allowPrivilegedPorts` is a trap under hostNetwork ✅
`README.md:346` — *"Allow non-root to bind ports < 1024 (**auto-enables `net.ipv4.ip_unprivileged_port_start=0`**)"*, and `_helpers.tpl:185` computes `$needPrivPorts := and unprivileged allowPrivilegedPorts (not (hasKey $sysctls "net.ipv4.ip_unprivileged_port_start"))` → it **injects a `net.ipv4.*` sysctl**.
Namespaced `net.*` sysctls are **forbidden on hostNetwork pods** — kubelet rejects the pod with `SysctlForbidden` (k8s #103298; also hit by nginx/kubernetes-ingress #3714).
⇒ **`allowPrivilegedPorts: true` + hostNetwork = pod rejected.** Never use it here.

The vendor's own `ci/daemonset-privileged-ports.values.yaml` contains **only**:
```yaml
controller:
  kind: DaemonSet
  containerPort: { http: 80, https: 443, stat: 1024 }
```
i.e. defaults everywhere else — implying the `unprivileged: true` + `NET_BIND_SERVICE` path does bind <1024.

### 4.7 The controller image runs as **root** ✅
Queried the Docker registry API directly (auth token → OCI index → linux/amd64 manifest → config blob):
```
docker.io/haproxytech/kubernetes-ingress:3.2.12  (linux/amd64)
User       : None            <-- no USER set  =>  ROOT
Entrypoint : ["/start.sh"]
```
⇒ With `unprivileged: false` (chart renders **no** securityContext) the container runs as **root** and binds 80/443 with no capability/sysctl workaround. **This is the chosen setting.**

**Contrast — do not generalize between images:** the *official* `haproxy:3.2` image (used by Path A's edge-lb) runs **non-root (UID 99)** since 2.4, which is why *that* plan needs `securityContext.runAsUser: 0`. Same vendor, opposite defaults.

---

## §5. The verified render (Path B) ✅ — reproduce this before any commit

`helm` is not installed on the workstation; v3.16.3 was downloaded to the scratchpad. **`helm template` is fully offline** — no API-server contact, no kubeconfig, nothing installed. (Only `--validate` would touch a cluster; it was not used.) `--kube-version 1.35.2` is required so version-gated templates (QUIC) render as they would on the real cluster.

```bash
helm template haproxy-ingress-hfc <chart> -f hfc-values.yaml \
  --kube-version 1.35.2 --namespace haproxy-ingress
```

**Verified output, both instances:**
```
hfc :  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy-hfc
       --ipv4-bind-address=5.161.26.66      --disable-ipv6
main:  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy
       --ipv4-bind-address=178.156.239.214  --disable-ipv6
```
- `hostNetwork: true` ✅ · `dnsPolicy: ClusterFirstWithHostNet` ✅
- **no** `--quic-*` · **no** `--prometheus` · **no** `--pprof` · **no** `--publish-service` ✅
- **no** `Service` object · **no** `sysctls` · **no** `securityContext` ✅
- `nodeSelector: kubernetes.io/hostname: leadsfilter-n1` ✅
- **Scheduler `(hostIP,port)` tuples distinct → k8s #117689 defused:**
  `hfc (5.161.26.66, 80/443/1024)` vs `main (178.156.239.214, 80/443/1026)` ✅
- `--ingress.class` emitted exactly once per instance, distinct classes ✅

Rendered kinds: `DaemonSet`, `ConfigMap`, `IngressClass`, `Secret`, `Job`, `ServiceAccount`×2, `ClusterRole`×2, `ClusterRoleBinding`×2 — **no Service**.

---

## §6. The `#117689` mechanic (worth internalising) ✅

Under `hostNetwork: true` the Kubernetes PodSpec **defaulter sets `hostPort = containerPort` for every declared container port**, at admission level. A chart's `hostPort.enabled: false` **cannot** override it (that toggle only controls what the chart *renders*).
⇒ two hostNetwork pods declaring 80/443 present identical `(0.0.0.0, 80)` tuples → the scheduler blocks the second one as *"didn't have free ports for the requested pod ports"*.
**Setting a distinct `hostIP` per instance makes the tuples distinct**, which is the *only* thing `hostIP` buys you. It does **not** affect what the process binds.
*Verified:* `docs/adding-hfc-ip.md` troubleshooting (they hit it with nginx and gave up on hostNetwork because of it) + k8s issue #117689 + the chart template reading above.

---

## §7. Prior art in this repo (git) ✅

| Commit | Date | What |
|---|---|---|
| `730ee4e` | — | initial install from lf-v3 |
| `df40563` | 2026-04-02 | *"remove haproxy ingress, add nginx ingress"* — a directory rename `haproxy-ingress/`→`nginx-ingress/`, 8 lines. Old values were **only** `controller: {hostNetwork: true, service: {type: ClusterIP}}`, chart `kubernetes-ingress` pinned `">=1.0.0 <2.0.0"`. **No reason recorded.** |
| `126b369` | 2026-04-11 | docs: how to add a second public IP with isolated ingress |
| `2e9ce96` | 2026-04-11 | docs/adding-hfc-ip: cert-manager multi-class solver + stuck Order |
| `6dbdad5` | 2026-04-13 | *"migrate ingress-nginx to NGINX Gateway Fabric 2.5.1"* (Gateway API v1.5.1) — Ingress→Gateway+HTTPRoute, www→apex 301 via HTTPRoute, SnippetsPolicy, cert-manager `gatewayHTTPRoute` solver |
| `983791f` | 2026-04-13 (**same day**) | *"revert: rollback NGF migration"* — body: *"NGF cert-generator creates inconsistent TLS certificates for control plane / data plane communication, making data plane pods unable to connect. Reverting … until NGF matures."* |

**The `df40563` reading that matters ✅:** because the chart line is **1.x today**, `">=1.0.0 <2.0.0"` was the **current** line → April ran a **current** controller (3.2.x) with `hostNetwork` and the **default `containerPort` 8080/8443** → **nothing listened on :80/:443**. That is Path B's Blocker 1 exactly. The most plausible history: it "didn't work", nobody diagnosed it, nginx went in within hours. **This validates the blocker; it is not evidence against HAProxy IC.**

---

## §8. `docs/adding-hfc-ip.md` — required reading ✅

The project's own runbook for the two-IP setup. Verified by reading it in full. Contents that bear on any new plan:

- **Design intent:** *strict isolation* — each domain reachable **only** from its own IP; verified with a 4-way matrix:
  ```
  curl -I -H "Host: leadsfilter.com"     http://178.156.239.214/   # 308 → https
  curl -I -H "Host: leadsfilter.com"     http://5.161.26.66/       # 404
  curl -I -H "Host: homefinanceclub.com" http://178.156.239.214/   # 404
  curl -I -H "Host: homefinanceclub.com" http://5.161.26.66/       # 308 → https
  ```
  **Reuse this matrix to validate any replacement.**
- Both controllers deliberately **not** hostNetwork; isolation via kube-proxy DNAT on `externalIPs`.
- Second controller needs a distinct `ingressClass`, a **unique `electionID`** (else the two fight over the same leader lease and one never becomes ready), and `admissionWebhooks.enabled: false` (to avoid the `:8443` conflict).
- Troubleshooting entries (all real incidents): hostNetwork rolling-update deadlock → `Recreate`; Helm 3-way merge error → `spec.upgrade.force: true`; **hostPort scheduler conflict #117689**; **wrong node IP → kube-proxy routed `.66` to the wrong pod**; broken Helm release state (release Secret lives in `flux-system`, `sh.helm.release.v1.<name>.v<rev>`); **cert-manager stuck Order** (updating the Issuer does **not** retro-fix an existing Order — you must **delete the Order**); **missing `www` DNS stalls a challenge silently** (one Challenge per host in `tls.hosts` → add `www` CNAME → apex → delete the Order again).

---

## §9. k0s specifics ✅

- kubelet flags go through the k0s systemd unit, not `k0s.yaml`.
- **CoreDNS is a k0s-managed "stack": k0s reconciles it and reverts live edits.** A raw `kubectl edit cm coredns` will be undone. Any CoreDNS change (Path A's D3 needs one) must go through the k0s-supported mechanism or Flux.
- k0s ships stock Kubernetes; no known haproxytech-on-k0s issue was found.
