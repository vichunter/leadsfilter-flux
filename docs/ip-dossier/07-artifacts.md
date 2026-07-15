# 07 — Artifacts: verified values, reproduction commands, known-good render

Everything here was produced and checked on **2026-07-09** in a scratchpad that **no longer exists**. This file is the durable copy. A future agent can reproduce the whole verification in ~2 minutes instead of rediscovering the method.

> # 🔴 SUPERSEDED — do not deploy the values in §2/§3
>
> **Use `lab/values-hfc.yaml` and `lab/values-main.yaml` instead**, and read **`09-runtime-verification.md`**.
>
> The values below were rendered but never **run**. Running them (2026-07-15, in a local replica) showed they are **missing five `extraArgs`**, without which the two instances silently share the healthz, stats, peers and default-backend listeners via `SO_REUSEPORT` — no error, both pods `1/1 Running`, probes answered by a random instance.
>
> Specifically wrong below: the `containerPort.stat: 1026` / `admin: 6061` mitigation in §3 is **declaration-only and inert** (main rendered 1026 and still bound `*:1024`) — §7.5's own suspicion, confirmed. The §7.5 conclusion that this is unanswerable offline and that no flag exists is **also wrong** on both counts (see `03-refuted.md` **R-15**, **R-16**).
>
> Everything else here — the reproduction commands, the registry check, the render gate, the checklists — is still good and worth using.

---

## §1. Reproduction — chart download & offline render

`helm` was **not** installed on the workstation; the static binary was downloaded to a scratchpad. **`helm template` is fully offline** — no API-server contact, no kubeconfig, nothing installed. (Only `--validate` touches a cluster; never use it here.)

```bash
# 1. helm binary (static, no install needed)
curl -sSL https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz -o helm.tgz
tar xzf helm.tgz && cp linux-amd64/helm ./helm && chmod +x ./helm

# 2. the chart index -> find the right chart (THREE charts live in this repo!)
curl -sS https://haproxytech.github.io/helm-charts/index.yaml -o idx.yaml
grep -nE "^  [a-z][a-z0-9-]*:$" idx.yaml
#   ->  haproxy:                  (standalone HAProxy — NOT ours; caused R-09)
#       haproxy-unified-gateway:  (Gateway API product)
#       kubernetes-ingress:       (ours)

# versions of OUR chart (newest first)
sed -n '/^  kubernetes-ingress:$/,$p' idx.yaml | grep -E "^    (appVersion|version|created|kubeVersion):" | head
#   ->  appVersion: 3.2.12 / created: 2026-07-03 / kubeVersion: '>=1.23.0-0' / version: 1.52.1

# 3. download + extract the chart
curl -sSL https://github.com/haproxytech/helm-charts/releases/download/kubernetes-ingress-1.52.1/kubernetes-ingress-1.52.1.tgz -o ki.tgz
mkdir -p ki && tar xzf ki.tgz -C ki

# 4. THE GATE: render offline, with the REAL cluster's k8s version
#    (--kube-version matters: the QUIC block is gated on semverCompare ">=1.24.0-0")
./helm template haproxy-ingress-hfc ki/kubernetes-ingress \
  -f hfc-values.yaml --kube-version 1.35.2 --namespace haproxy-ingress > render-hfc.yaml

# 5. read what actually rendered
grep -E "^kind:" render-hfc.yaml | sort | uniq -c
awk '/^kind: DaemonSet/,/volumes:/' render-hfc.yaml | grep -E "hostNetwork|dnsPolicy|hostIP|hostPort|containerPort|securityContext|sysctls|^\s+- --"
```

### Reproduction — inspect the image's default user (no docker needed)
```bash
IMG=haproxytech/kubernetes-ingress; TAG=3.2.12
TOKEN=$(curl -sS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMG}:pull" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
# index -> pick linux/amd64 digest -> manifest -> config blob -> .config.User
```
**Result:** `User: None` → **runs as ROOT**; `Entrypoint: ["/start.sh"]`.
(Contrast: the *official* `haproxy:3.2` image used by the edge-lb plan is **non-root UID 99** — do not generalize between images.)

---

## §2. `hfc-values.yaml` — verified-rendering values (homefinanceclub → 5.161.26.66)

```yaml
controller:
  kind: DaemonSet
  dnsPolicy: ClusterFirstWithHostNet
  unprivileged: false
  containerPort:
    http: 80
    https: 443
    stat: 1024
    admin: 6060
  prometheus:
    enabled: false
  pprof:
    enabled: false
  daemonset:
    useHostNetwork: true
    useHostPort: true
    hostIP: 5.161.26.66
    hostPorts:
      http: 80
      https: 443
      stat: 1024
  nodeSelector:
    kubernetes.io/hostname: leadsfilter-n1
  ingressClass: haproxy-hfc
  ingressClassResource:
    name: haproxy-hfc
    default: false
  extraArgs:
    - "--ipv4-bind-address=5.161.26.66"
    - "--disable-ipv6"
  publishService:
    enabled: false
  service:
    enabled: false
    enablePorts:
      quic: false
```

## §3. `main-values.yaml` — (leadsfilter → 178.156.239.214)

Identical except the IP, the class, and the deliberately-distinct `stat`/`admin` ports:

```yaml
controller:
  kind: DaemonSet
  dnsPolicy: ClusterFirstWithHostNet
  unprivileged: false
  containerPort:
    http: 80
    https: 443
    stat: 1026          # distinct from hfc's 1024   (see §7.5 — may be declaration-only!)
    admin: 6061         # distinct from hfc's 6060
  prometheus:
    enabled: false
  pprof:
    enabled: false
  daemonset:
    useHostNetwork: true
    useHostPort: true
    hostIP: 178.156.239.214
    hostPorts:
      http: 80
      https: 443
      stat: 1026
  nodeSelector:
    kubernetes.io/hostname: leadsfilter-n1
  ingressClass: haproxy
  ingressClassResource:
    name: haproxy
    default: false
  extraArgs:
    - "--ipv4-bind-address=178.156.239.214"
    - "--disable-ipv6"
  publishService:
    enabled: false
  service:
    enabled: false
    enablePorts:
      quic: false
```

### Why each non-obvious line is there
| Line | Reason |
|---|---|
| `unprivileged: false` | renders **no securityContext** → runs as the image's user = **root** → binds 80/443. **Never** use `allowPrivilegedPorts: true` (R-02: it injects a sysctl kubelet forbids on hostNetwork) |
| `containerPort.http/https: 80/443` | the chart default is **8080/8443**; it feeds `--http-bind-port`/`--https-bind-port` — the *actual* bind |
| `daemonset.useHostNetwork` | the real key; `controller.hostNetwork` **does not exist** (R-04) |
| `dnsPolicy: ClusterFirstWithHostNet` | else a hostNetwork pod can't resolve cluster Services |
| `daemonset.hostIP` | **scheduler tuples only** (#117689). It does **NOT** set the bind (R-01) |
| `extraArgs: --ipv4-bind-address` | **the actual per-IP bind + brand isolation** |
| `extraArgs: --disable-ipv6` | `--ipv6-bind-address` defaults to `::` → both would bind `:::80` → `EADDRINUSE`, and with `bindv6only=0` a `::` bind also accepts IPv4 → isolation leak |
| `publishService.enabled: false` | default `true` emits `--publish-service` pointing at the Service we disable |
| `service.enabled: false` | isolation is the bind, not kube-proxy. **Never** add `externalIPs` here |
| `service.enablePorts.quic: false` | gates the controller's **QUIC args**, independently of `service.enabled` (R-07). Default `true` → both bind udp/443 |
| `prometheus/pprof: false` | both default **true** → extra listeners in the shared netns |
| no `--ingress.class` in extraArgs | the chart already emits it from `controller.ingressClass` |
| no `ingressClassResource.enabled` | that key **does not exist** (R-06) |
| no compression keys | unsupported by this controller (#196) |

---

## §4. Known-good render output (diff yours against this)

```
hfc :  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy-hfc
       --ipv4-bind-address=5.161.26.66      --disable-ipv6
main:  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy
       --ipv4-bind-address=178.156.239.214  --disable-ipv6
```

Rendered kinds (hfc): `DaemonSet`, `ConfigMap`, `IngressClass`, `Secret`, `Job`, `ServiceAccount`×2, `ClusterRole`×2, `ClusterRoleBinding`×2 — **no Service**.

DaemonSet excerpt (verbatim, hfc):
```yaml
kind: DaemonSet
metadata:
  name: haproxy-ingress-hfc-kubernetes-ingress
  namespace: haproxy-ingress
  labels:
    helm.sh/chart: kubernetes-ingress-1.52.1
    app.kubernetes.io/version: "3.2.12"
spec:
  updateStrategy:
    type: RollingUpdate          # note: image bumps => brief bind gap (LOW 12)
  template:
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
        - name: kubernetes-ingress-controller
          image: "docker.io/haproxytech/kubernetes-ingress:3.2.12"
          args:
          - --default-ssl-certificate=haproxy-ingress/haproxy-ingress-hfc-kubernetes-ingress-default-cert
          - --configmap=haproxy-ingress/haproxy-ingress-hfc-kubernetes-ingress
          - --http-bind-port=80
          - --https-bind-port=443
          - --ingress.class=haproxy-hfc
          - --log=info
          - --ipv4-bind-address=5.161.26.66
          - --disable-ipv6
          ports:
            - { name: admin, containerPort: 6060,                hostIP: 5.161.26.66 }   # note: no hostPort
            - { name: http,  containerPort: 80,  hostPort: 80,   hostIP: 5.161.26.66 }
            - { name: https, containerPort: 443, hostPort: 443,  hostIP: 5.161.26.66 }
            - { name: stat,  containerPort: 1024, hostPort: 1024, hostIP: 5.161.26.66 }
          livenessProbe:
            httpGet: { path: /healthz, port: 1042, scheme: HTTP }    # <-- see §7.5 !!
      nodeSelector:
        kubernetes.io/hostname: leadsfilter-n1
```

**Verified absent:** `--quic-bind-port`, `--quic-announce-port`, `--prometheus`, `--pprof`, `--publish-service`, `securityContext`, `sysctls`, `Service`.

**Scheduler tuples distinct → #117689 defused:**
`hfc (5.161.26.66, 80/443/1024)` vs `main (178.156.239.214, 80/443/1026)`

---

## §5. Verification checklist (offline, before any commit)

- [ ] `helm template` renders without error, with `--kube-version 1.35.2`
- [ ] `hostNetwork: true` present
- [ ] `dnsPolicy: ClusterFirstWithHostNet` present
- [ ] `--http-bind-port=80` and `--https-bind-port=443` (**not** 8080/8443)
- [ ] `--ipv4-bind-address=<the instance's own IP>` present
- [ ] `--disable-ipv6` present
- [ ] `--ingress.class=<class>` present **exactly once**
- [ ] **no** `--quic-*`, **no** `--prometheus`, **no** `--pprof`, **no** `--publish-service`
- [ ] **no** `Service` object; **no** `sysctls`; **no** `securityContext`
- [ ] `nodeSelector` pins `leadsfilter-n1`
- [ ] the two instances' `(hostIP, port)` tuples are all distinct

## §6. Runtime checklist (only a cluster can answer these)

- [ ] pod schedules on `leadsfilter-n1`, doesn't CrashLoop
- [ ] `ss -ltnp` on the node shows the bind on **`<ip>:80`/`<ip>:443`** — **not** `0.0.0.0:80`, **not** `:8080`
- [ ] the **second** instance starts without `EADDRINUSE`
- [ ] **§7.5** — what address is `:1042` bound on? and the stat port?
- [ ] 4-way isolation matrix (from `docs/adding-hfc-ip.md`) holds
- [ ] the app logs the **real client IP**
- [ ] a **staging** cert including a **`www`** SAN reaches `Ready=True`

---

## §7.5 🔴 LATE FINDING — the built-in `/healthz` listener on **1042**

> **RESOLVED 2026-07-15 — and this section's own conclusions were wrong.** Read `09-runtime-verification.md` §2. In short: `--ipv4-bind-address` does **not** scope healthz (confirmed — `controller.go:245` hardcodes `0.0.0.0`); `containerPort.stat` is **declaration-only** (confirmed — the suspicion below was right). But: **`--healthz-bind-port` exists**, the stats flag is **`--stats-bind-port`** (*plural* — the singular searched for below is why this was declared unresolvable), the question was **answerable offline** all along, and a clash produces **`SO_REUSEPORT`, not `EADDRINUSE`** — silent, not loud. Kept below as written, because how this was reasoned about matters more than the conclusion. See `03-refuted.md` R-15/R-16/R-17.

Spotted only when reading the rendered DaemonSet (the probe pointed at a port that appears **nowhere** in our values).

**Chart `README.md:362`, verbatim:**
> `controller.livenessProbe` / `readinessProbe` / `startupProbe` — Probe definitions. Default port is `1042` — **the controller's built-in `/healthz` listener bound unconditionally by the binary (independent of `containerPort`)**.

`values.yaml:159` says the same. So **the binary always binds 1042**, and `containerPort` cannot move it.

**Checked `documentation/controller.md` for an escape:** there is **no flag** for the healthz listener or its port. The port flags are only `--http-bind-port`, `--https-bind-port`, `--quic-bind-port`, `--quic-announce-port`, `--default-backend-port`. And the docs **do not state whether `--ipv4-bind-address` applies to all listeners or only the HTTP/HTTPS frontends.**

### Why this is a real blocker for the two-instance model
Under hostNetwork both instances share the host netns:
- **If `--ipv4-bind-address` scopes the healthz listener** → each binds `<own-ip>:1042` → fine.
- **If it does not** → both bind `0.0.0.0:1042` → the **second instance dies with `EADDRINUSE`**, and there is **no flag to move or disable it**.

**This cannot be settled offline.** Docs are silent; no flag exists; only `ss -ltnp` on a running pod answers it.

### The same doubt contaminates the `stat` mitigation
`containerPort` is proven to drive the bind **only** via `--http-bind-port` / `--https-bind-port`. There is **no `--stat-bind-port`** in the arg list. So `containerPort.stat: 1026` may be **declaration-only** — changing the podSpec port while the binary still binds its own stat port. **That is exactly the R-01 failure mode** (we changed a declaration and assumed it changed a bind). The HIGH-4 "give distinct stat/admin ports" fix is therefore **unproven** and possibly ineffective.

### Consequence for the plan
The earlier claim that Path B's **"config-level unknowns are zero"** is **wrong** (recorded as R-14). Two unresolved runtime questions remain, and together they decide whether **two haproxytech instances can coexist in one host netns at all**:
1. Does `--ipv4-bind-address` scope the **healthz (1042)** listener?
2. Does it scope the **stat** listener — and does `containerPort.stat` actually move that bind?

**If both answer "no", Path B's two-instance design does not work as written**, and the options become: find an undocumented flag; run one instance non-hostNetwork; or fall back to Path A / Path C.

### How to settle it — cheaply and safely
The **dry run already proposed** answers both, and answers them *without touching production*: deploy **one** instance (hfc) while nginx still owns `5.161.26.66` via `externalIPs` — kube-proxy's PREROUTING DNAT means HAProxy receives **no traffic** — then on the node:
```bash
ss -ltnp | grep -E ':(80|443|1024|1042|6060)\b'
```
Read which **address** each listener bound. That single command decides Path B's viability. **Do this before writing any more plan.**

**Meta-note for whoever reads this:** this was the **seventh** verification round, and it found a blocker after the assistant had already declared the configuration fully verified. The pattern in `03-refuted.md` held one more time.
