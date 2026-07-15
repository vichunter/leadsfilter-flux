# UPGRADING — what is pinned, why, and what to re-verify

**Read before bumping the chart, the controller image, or k0s.**

This setup works. It also leans on **five behaviours that the vendor does not document, contradicts, or has an open bug for**. An upgrade can revoke any of them — and the two worst failure modes here are **silent by construction**:

- **`SO_REUSEPORT`** — a port clash between the two instances does not raise `EADDRINUSE`. Both bind, both pods go `1/1 Running`, the kernel answers from a random one.
- **Helm drops unknown value keys without a word** — a renamed key no-ops the thing it was protecting, and the render still looks right.

So "it deployed and the site is up" is **not** evidence that an upgrade was safe. Run the gate.

---

## The gate

```bash
./verify.sh                                        # verify the current pins
CHART_VERSION=1.53.0 ./verify.sh                   # gate a chart bump
CHART_VERSION=1.53.0 IMAGE_PIN=3.3.0 ./verify.sh   # gate chart + controller
```

Offline, ~5 minutes, touches no production, exits non-zero on any regression. It asserts all five fragile behaviours plus the isolation matrix, the ACME path, and the client IP. **A failure means stop, not "adjust the test".**

Both negative controls are known to work — the gate has been shown to *catch* a revoked `https://` prefix and a healthz port clash, not merely to print PASS.

---

## What is pinned, and where

| Layer | Pinned to | Where | If it moves |
|---|---|---|---|
| **Chart** | `1.52.1` | `HelmRelease.spec.chart.spec.version` (prod) · `CHART_VERSION` (lab) | Template/key changes → silent no-ops |
| **Controller image** | `@sha256:3cdf2bb2…` (= tag `3.2.12`) | `controller.image` in `values-{hfc,main}.yaml` | **See below — this is the subtle one** |
| **k8s** | k0s `v1.35.2` | the cluster | Chart allows `>=1.23.0-0`, no upper bound |
| helm (lab only) | `3.16.3` | `verify.sh` | — |
| kubectl / kind / node image (lab only) | `v1.35.1` / `v0.30.0` / `kindest/node:v1.35.1` | `verify.sh` | Harness drift reads as a false regression |

**There is no `helm` binary in prod.** Flux's helm-controller renders the chart with an embedded Helm library; its version is a property of your Flux install, not something these files pin. The `helm` in `verify.sh` is lab tooling only.

### Why the image is pinned separately from the chart

The chart renders:

```gotemplate
image: "{{ $ctlr.image.repository }}:{{ $ctlr.image.tag | default $root.Chart.AppVersion }}"
```

An empty `image.tag` **follows the chart's `appVersion`**. So bumping the chart bumps the controller **binary** implicitly — the very thing whose listener behaviour everything here depends on. Pinning only the chart is not enough.

The chart has **no digest field**. `repository` ending in `@sha256` with the digest as `tag` is the only way to express one. It renders a valid digest reference and **is enforced** — a wrong digest yields `ErrImagePull` (verified, with a negative control). If a future chart adds real digest support or changes that template line, this breaks **loudly** at image pull, which is the acceptable direction.

`sha256:3cdf2bb2…` is the **multi-arch index** digest of `3.2.12`; kubelet resolves it to the amd64 manifest `sha256:1ceabb4c…`. Check what is actually running:

```bash
kubectl -n haproxy-ingress get pod -l app.kubernetes.io/instance=haproxy-ingress-hfc \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
```

**Both instances must always run the identical image.** They share a host netns and a hand-allocated port map, and the whole no-collision argument assumes one set of listener defaults. Never bump one alone.

---

## The five load-bearing behaviours

Each is asserted by `verify.sh`. Each is also a real, documented mistake — see `../03-refuted.md`.

### 1. `--ipv4-bind-address` scopes only 3 of 8 listeners → `A1`, `A2`, `A4`

healthz (`0.0.0.0:1042`), stats (`*:1024`) and peers (`<nodeIP>:10000`) are **hardcoded string literals** in the source; only http/https/QUIC honour the flag. The two instances are kept apart by **distinct ports**, via `--healthz-bind-port`, `--stats-bind-port`, `--localpeer-port`, `--default-backend-port`.

- **Status:** documented flags, and upstream **PR #446** added them for exactly this use case ("it is not possible to simultaneously run two host-mode ingress controllers on the same node…"). The most stable of the five.
- **Fails if:** a flag is renamed/removed, or a **new** listener appears in a future version. A new listener would be all-interfaces by default and would silently clash.
- **Check:** `A1` (no duplicate `addr:port`) and the **whole** `ss -ltnp` dump. `verify.sh` prints it unfiltered on purpose — grepping for expected ports is precisely how the `:10000` peers clash was missed (R-20).

### 2. `containerPort.stat` / `admin` are declaration-only → `A4`

They set the k8s port spec and **never reach the bind**. Only `--stats-bind-port` moves the real socket. Do not "simplify" the values by trusting `containerPort` again — that is the R-01 failure mode, and it has now been made three times.

### 3. `--controller-port=0` disables the Go listener → `A3`

Gated on `!= 0` (`builder.go:165`). The only aux listener that can be closed at all. If a bump reintroduces `:6060`, that is one more public port and one more clash surface.

### 4. 🔴 UNDOCUMENTED: `request-redirect` accepts an `https://` prefix → `A7`

The `www`→apex redirect depends on it. Shipped in commit `9338c489` (2024-02-19), but:
- the docs still say *"Possible values: host, host:port"* — no scheme;
- issue **#613** (*"'request-redirect' annotation always redirects to http"*) is **still open**, so it reads as an unfixed bug.

**Zero contract. This is the most likely of the five to regress.** If it does, every `https://www.brand.com` visit is 301'd to plaintext `http://brand.com` — a downgrade, and nothing errors. Never write `https://host:443` — the port becomes part of the host and you get `http://host:443`.
**Escape hatch:** `frontend-config-snippet` with a raw `http-request redirect prefix …`.

### 5. 🔴 `ssl-redirect-port` must be `"443"` → `A8`

`haproxy.org/ssl-redirect` defaults to port **8443** (`annotations/common/main.go:69`) and **ignores `--https-bind-port`**. Without the explicit override every HTTP visitor is sent to `https://<host>:8443` — a closed port, i.e. the site is down for plaintext traffic.

**Watch:** PR **#788** (*"Revise SSL Redirection on default HTTPS port"*, open, un-merged, twice stale-botted) changes exactly this. If it merges, re-check `A8` — the emitted `Location` may change shape.

### Bonus, not a dependency but assert it anyway → `A5`

**The image runs as root** (no `USER`), which is why `unprivileged: false` binds 80/443 with no capability or sysctl. If a future image adds a `USER`, that bind fails. **Never** "fix" it with `allowPrivilegedPorts: true` — it injects a `net.ipv4.*` sysctl that kubelet forbids on hostNetwork pods, and the pod is rejected (R-02).

---

## Things that will look like regressions but are not

- **QUIC on udp/443** is present despite `service.enablePorts.quic: false`. The flag removes the controller args; the `quic4@<ip>:443` bind stays. It is scoped per IP, so it does not clash. (R-18)
- **`stats` cannot be disabled.** The bind is unconditional in the source, and a maintainer confirms it (issue #614). `--stats-bind-port=0` is **not** the way — haproxy rejects the config (`'bind' invalid port '0'`) and the instance never binds 80/443, while the pod stays `Running`.
- **`ssl-redirect` emits `https://host:443/`**, not a bare `https://host/`. Cosmetically worse than nginx, functionally identical.
- **ConfigMap snippet changes do not reload haproxy.** The controller rewrites `haproxy.cfg` and logs `configmap … updated`, but the running process keeps the old config until a pod restart. If you change `stats-config-snippet`, `kubectl rollout restart` or you are testing nothing.

---

## Procedure for a version bump

1. **Read the upstream changelog** for anything touching binds, ports, listeners, annotations, or the `unprivileged`/`image` values.
2. **Re-pin the image digest** for the new tag:
   ```bash
   TOKEN=$(curl -sS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:haproxytech/kubernetes-ingress:pull" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
   curl -sS -o /dev/null -D - -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
     "https://registry-1.docker.io/v2/haproxytech/kubernetes-ingress/manifests/<NEW_TAG>" | grep -i docker-content-digest
   ```
3. **Render and diff the args**, before installing anything:
   ```bash
   helm template x haproxytech/kubernetes-ingress --version <NEW> -f values-hfc.yaml --kube-version 1.35.2 \
     | grep -E '^\s+- --'
   ```
   A **missing** arg means Helm silently dropped a renamed key. That is the classic trap (R-04, R-06) and it is invisible at deploy time.
4. **Run the gate:** `CHART_VERSION=<NEW> ./verify.sh`. All assertions must pass.
5. **Read the listener dump by eye**, whole. The gate asserts against *known* ports; only a human notices a **new** listener.
6. Only then: bump the `HelmRelease`, one brand first, soak, then the other.
7. **If a new public listener appeared → update the Hetzner Cloud Firewall** before the flip (`../09-runtime-verification.md` §5).

## If you are considering a major bump

There is **no newer line**: branches are `master, v1.4…v1.11, v3.0, v3.1, v3.2`. **No v3.3, no v3.4.** `3.2.12` (2026-07-03) is the tip. If a 3.3/3.4 appears, treat every item above as unknown again — `verify.sh` is the cheapest way to find out, and it is the only artifact here that cannot lie to you.
