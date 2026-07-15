# 09 — Runtime verification of Path B (the dry run, done offline)

**Date:** 2026-07-15 · **Method:** a kind replica of the prod topology, on the workstation. **No production system was contacted.**

This file supersedes the parts of `07-artifacts.md` and `2026-07-09-haproxy-ic-migration.md` that it contradicts. Where they disagree, **this file wins** — it is the only one backed by running processes.

---

## §0. TL;DR

**O-0 is answered. Path B works — but not with the values the dossier had.**

1. `--ipv4-bind-address` scopes **only** the http/https/QUIC frontends. **Five other listeners bind all-interfaces** and are not scoped by it.
2. A port clash between the two instances does **not** raise `EADDRINUSE`. haproxy binds with **`SO_REUSEPORT`**, so both instances bind the same `addr:port`, both pods go `1/1 Running`, and **the kernel picks an answerer at random**. The dossier expected a loud failure; the real failure is silent.
3. The fix is **five extra `extraArgs`** — all five flags exist; the dossier believed two of them did not. See `lab/values-hfc.yaml` / `lab/values-main.yaml`. **This is not a workaround: upstream PR #446 added those flags for exactly this use case** (§6.5).
4. With the fix: **zero collisions, both brands served, isolation matrix clean, the real client IP reaches the backend.** Verified end-to-end.
5. **Two Ingress annotations the plan gets wrong**, both site-breaking, both fixed and verified: `ssl-redirect` needs `ssl-redirect-port: "443"` or every visitor is sent to a dead `:8443` (§4.1); `request-redirect` needs an undocumented **`https://` prefix** or every `www` visit downgrades to plaintext (§4.2).
6. **H5/O-1 — the 30-day landmine — is defused** (§4.3), and the mechanism is understood, not hoped for.
7. **New cost, not previously known:** the five unscoped listeners become **publicly reachable on both public IPs** after the migration. Today nothing binds them. They cannot be disabled — the binds are unconditional in the source, and a maintainer confirms it (§5, §6.5). **Decision (user, 2026-07-15): accept, and block them with the Hetzner Cloud Firewall.**

---

## §1. The lab, and how faithful it is

`docs/ip-dossier/lab/` reproduces it in ~5 minutes. One kind node, both "public" IPs added to its `eth0` as `/32`s — the same shape as `leadsfilter-n1` (`02-verified-facts.md` §1.2).

| | prod | replica | does the difference matter? |
|---|---|---|---|
| k8s | k0s v1.35.2 | kind v1.35.1 | No. hostNetwork binds and the `#117689` defaulter are stock upstream. |
| CNI | kube-router | kindnet | No. A hostNetwork process binds in the host netns; the CNI is not in that path. |
| IPs | `178.156.239.214` / `5.161.26.66` | `192.168.160.90` / `.91` | No. Bind semantics do not depend on the address. |
| node | `leadsfilter-n1` | `ipfix-control-plane` | No — `nodeSelector` adjusted. |
| chart | 1.52.1 → controller 3.2.12 | **identical** | — |
| image | `haproxytech/kubernetes-ingress:3.2.12` | **identical** | — |

**What the replica cannot answer:** the live cutover (conntrack/DNAT race, M10), real traffic volume, and a real Let's Encrypt issuance. Everything else below is a running-process fact.

---

## §2. THE ANSWER TO O-0 — what each listener actually binds

`ss -ltnp` on the node, one instance up, values exactly as `07-artifacts.md` §2 had them:

```
0.0.0.0:1024         haproxy           <- stats,   NOT scoped
0.0.0.0:1042         haproxy           <- healthz, NOT scoped
192.168.160.91:80    haproxy           <- scoped
192.168.160.91:443   haproxy           <- scoped
0.0.0.0:6061         haproxy-ingress   <- Go: local default backend
0.0.0.0:6060         haproxy-ingress   <- Go: controller data (prometheus/pprof)
192.168.160.2:10000  haproxy           <- peers, on the NODE IP
udp 192.168.160.91:443 haproxy         <- QUIC, scoped
```

**`--ipv4-bind-address=192.168.160.91` scoped 3 of 8 listeners.**

Confirmed in the source (`src-ic` @ `v3.2.12`, commit `9e4b6b9`) — the addresses are **string literals**, the flag is never consulted:

| Listener | Owner | Code | Address |
|---|---|---|---|
| healthz | haproxy frontend | `pkg/controller/controller.go:245` | `fmt.Sprintf("0.0.0.0:%d", healthzPort)` |
| stats | haproxy frontend | `pkg/controller/controller.go:267` | `fmt.Sprintf("*:%d", c.osArgs.StatsBindPort)` |
| stats v6 | haproxy frontend | `pkg/handler/http-bind.go:74` | `":::1024"` — **hardcoded, ignores `--stats-bind-port`** |
| controller data | Go `net.Listen` | `pkg/controller/builder.go:251` | `":"+ControllerPort` / `"[::]:"+…` |
| default backend | Go `ListenAndServe` | `pkg/controller/builder.go:288` | `":"+DefaultBackendPort` |
| peers | haproxy | base cfg + `--localpeer-port` | `<nodeIP>:10000` |

`--ipv4-bind-address` is consumed **only** by `pkg/controller/handler.go:38,48,72,103` and `pkg/gateways/gateways.go:278` — every one an haproxy-config handler for the HTTP/HTTPS/TCP/QUIC frontends.

**The chart README is wrong.** It calls 1042 "the controller's built-in /healthz listener bound unconditionally **by the binary**". It is not a Go listener at all — it is a `bind` line the controller injects into `haproxy.cfg`; the **haproxy engine** owns the socket. The port *is* movable (`--healthz-bind-port`); only the address is not.

### §2.1 The failure mode is silent, not loud — this is the important part

Two instances, dossier values, both with distinct `--ipv4-bind-address`:

```
0.0.0.0:1024   haproxy pid=5604  (main)   ino:75034680
0.0.0.0:1024   haproxy pid=5102  (hfc)    ino:75025541
0.0.0.0:1042   haproxy pid=5604  (main)   ino:75034677
0.0.0.0:1042   haproxy pid=5102  (hfc)    ino:75025538
```

Two sockets, two inodes, two pod cgroups, **one addr:port. No `EADDRINUSE`.** haproxy sets `SO_REUSEPORT` (its normal seamless-reload mechanism), so the kernel accepts both and load-balances new connections across them.

**Why that is dangerous here.** Both pods are hostNetwork, so **both pods' IP is the node InternalIP** — in prod, `178.156.239.214` for *both*. kubelet probes `podIP:1042`. Therefore **both instances' liveness/readiness/startup probes hit the same reuseport group**, and the answer comes from whichever socket the kernel picks. A probe result cannot be attributed to the pod it was meant for. Observed verbatim in a pod event:

```
Startup probe failed: Get "http://192.168.160.2:1042/healthz": dial tcp 192.168.160.2:1042: connect: connection refused
```

(that is the node IP, not the instance IP — kubelet has no other address to use).

The Go listeners fail differently — they use plain `net.Listen`, so the second instance **does** get `EADDRINUSE`, and the controller only logs it:

```
ERROR  controller/builder.go:260  listen tcp4 :6060: bind: address already in use
ERROR  controller/builder.go:289  listen tcp4 :6061: bind: address already in use
```

Pod stays `1/1 Running`. **`:6061` is the local default backend** — so with the dossier's values, the second instance's default backend is dead and its `haproxy.cfg` still points at `local-service`, i.e. the *first* instance's Go process. A silent cross-instance dependency.

---

## §3. The fix — five flags, all of which exist

```yaml
extraArgs:
  - "--ipv4-bind-address=<this instance's IP>"
  - "--disable-ipv6"
  - "--healthz-bind-port=1042"      # other instance: 1043
  - "--stats-bind-port=1024"        # other instance: 1026
  - "--default-backend-port=6061"   # other instance: 6063
  - "--controller-port=0"           # 0 disables the Go listener outright (builder.go:165)
  - "--localpeer-port=10000"        # other instance: 10001
```

…plus the probes must follow `--healthz-bind-port` (`controller.livenessProbe/readinessProbe/startupProbe.httpGet.port`), or the main instance probes hfc's listener.

Full files: **`lab/values-hfc.yaml`**, **`lab/values-main.yaml`**.

**Verified result — every `addr:port` exactly once, no collisions:**

```
192.168.160.90:80    main      192.168.160.91:80    hfc
192.168.160.90:443   main      192.168.160.91:443   hfc
0.0.0.0:1026 stats   main      0.0.0.0:1024 stats   hfc
0.0.0.0:1043 healthz main      0.0.0.0:1042 healthz hfc
0.0.0.0:6063 defbe   main      0.0.0.0:6061 defbe   hfc
192.168.160.2:10001  main      192.168.160.2:10000  hfc
udp .90:443 QUIC     main      udp .91:443 QUIC     hfc
:6060 — gone entirely (--controller-port=0)
```
Both pods `1/1 Running`, zero bind errors in either log.

### §3.1 Verified behaviour with the fix

| Test | Result |
|---|---|
| **Client IP reaches the backend** (the entire point) | ✅ `X-Forwarded-For: 192.168.160.3` = the real client. Both instances. No PROXY protocol, no edge-lb, no hairpin. |
| **4-way isolation matrix** (`docs/adding-hfc-ip.md`) | ✅ own IP → 301, wrong IP → **404**, both directions |
| **HTTP→HTTPS redirect** | ✅ after adding `ssl-redirect-port` — see §4.1 |
| **www → apex** | ⚠️ works, but downgrades the scheme — §4.2 |
| **ACME path reachable (H5 / O-1)** | ✅ **solved** — §4.3 |
| `X-Forwarded-Proto: https` set by the controller | ✅ |

---

## §4. Findings the plan does not have

### §4.1 🔴 `ssl-redirect` sends every visitor to **:8443**

`haproxy.org/ssl-redirect: "true"` (which MEDIUM 7 tells us to add to **both** brands) renders:

```
http-request redirect location https://%[hdr(host),field(1,:)]:8443%[capture.req.uri] code 301
```

→ `Location: https://homefinanceclub.com:8443/`. **The site is dead for every HTTP visitor.** Cause: `pkg/annotations/common/main.go:69` — `"ssl-redirect-port": "8443"` is the annotation's default, and it ignores `--https-bind-port=443`.

**Fix (verified):** add `haproxy.org/ssl-redirect-port: "443"` → `Location: https://homefinanceclub.com:443/`. Works. (Cosmetically worse than nginx, which emits no port; functionally identical.)

### §4.2 ✅ The www redirect — **use an undocumented `https://` prefix**

Following the docs, this is a regression. `documentation/annotations.md:1378` says *"Possible values: host, host:port"*, *"Port alone is not allowed"* — no scheme. And indeed:

| Annotation | `https://www/` → |
|---|---|
| `request-redirect: homefinanceclub.com` | `301 http://homefinanceclub.com/` — **HTTPS→HTTP downgrade** |
| `request-redirect: homefinanceclub.com:443` | `301 http://homefinanceclub.com:443/` — **nonsense: plaintext on 443** |
| + `ssl-redirect` on the www Ingress | unchanged; `http://www/` 301s to `https://www:443/`, keeping `www` |

**The docs are out of date.** The annotation *does* parse a scheme — `pkg/annotations/ingress/hostRedirect.go:54`:

```go
case strings.HasPrefix(input, HTTPS_PREFIX):
    a.parent.redirect.SSLRequest = true
    a.parent.redirect.Host = a.parent.redirect.Host[len(HTTPS_PREFIX):]
```

Added by commit `9338c489` *"MINOR: add scheme support in HTTP(S) redirects"* (2024-02-19), in response to issue **#613** *"'request-redirect' annotation always redirects to http"* — **which is still open**, so the bug reads as unfixed. The feature shipped and was never documented.

**Verified working:**

```yaml
haproxy.org/request-redirect: "https://homefinanceclub.com"   # NOT "…:443" — the port becomes part of the host
```
```
https://www/  -> 301  Location: https://homefinanceclub.com/
http://www/   -> 301  Location: https://homefinanceclub.com/
ACME www/apex -> 200 / 200   (still reachable — §4.3 holds)
```
Rendered: `http-request redirect location https://homefinanceclub.com%[capture.req.uri] code 301`.

**This is better than the nginx behaviour it replaces:** no downgrade, no port suffix, and `http://www` reaches `https://apex` in **one** hop instead of two. Note it *forces* https rather than preserving the scheme (`pkg/ingress/ingress.go` attaches a non-`SSLRedirect` redirect to **both** frontends) — which is what we want here anyway.

**Caveat:** undocumented ⇒ no contract. Re-run `lab/verify.sh` after any controller bump. If it ever regresses, the escape hatch is `frontend-config-snippet` with a raw `http-request redirect prefix …`.

### §4.3 ✅ H5 / O-1 — the 30-day landmine is DEFUSED

The fear: the www 301 swallows `/.well-known/acme-challenge/…`, the `www` SAN passes cutover and fails at renewal ~30 days later, silently.

**Tested** by creating the exact shape cert-manager's HTTP-01 solver creates (an Ingress with an `Exact` path per token):

```
without the solver Ingress:   apex → 301   www → 301
with    the solver Ingress:   apex → 200   www → 200
```

**The solver wins.** Mechanism: haproxy consults `path-exact.map` before the prefix maps, and the redirect annotations are attached to *their own* Ingress/backend, not to the frontend. The solver Ingress carries no redirect annotation, so nothing redirects it.

O-1 can be closed. A staging issuance is still the belt-and-braces confirmation, but the mechanism is now understood rather than hoped for.

### §4.4 🔴 `--stats-bind-port=0` wedges the instance

Tempting way to kill the stats listener. It produces an **invalid haproxy config**:

```
config parsing [...haproxy.cfg...:79] 'bind' invalid port '0'
ERROR controller/controller.go:182 unable to Sync HAProxy configuration !!
```

The whole sync fails → **the instance never binds 80/443** → that brand is down. The pod stays `Running` (0/1). Do not do this.

### §4.5 🟡 ConfigMap snippet changes are written but **not reloaded**

`stats-config-snippet` renders into `haproxy.cfg` and the controller logs `configmap ... updated` — but **no reload follows**, so the running haproxy keeps the old config indefinitely. Only a pod restart applies it. Verified: cfg mtime `14:19:23`, last `Reloading HAProxy` `14:13:11`; the snippet only took effect after `rollout restart`.

*(This nearly produced a false finding here: the first two snippet experiments "failed" purely because the process had never re-read the file.)*

### §4.6 ✅ The stats page **can** be locked with auth — via `stats-config-snippet` (new finding)

Not in the dossier, not in the plan, and not obvious: the `stats` **frontend** is reachable by the `stats-config-snippet` ConfigMap key (`documentation/annotations.md:646` — *"Defines a group of configuration directives to insert in the stats frontend"*, `configmap` scope only). Native `stats` directives placed there **do** take effect.

**Verified working — HTTP basic auth on the stats page:**

```yaml
# ConfigMap of the instance (the one named by --configmap)
data:
  stats-config-snippet: |
    stats auth admin:s3cret
```
```
GET http://<ip>:1024/            -> 401     (no credentials)
GET http://<ip>:1024/  -u admin:s3cret -> 200
GET http://<ip>:1024/metrics     -> 200     <- NOT covered, see below
hfc apex                         -> 301     (brand unaffected)
:1042/healthz                    -> 200     (probes unaffected)
```

**Verified working — a source ACL instead of auth:**

```yaml
  stats-config-snippet: |
    http-request deny unless { src 127.0.0.0/8 10.0.0.0/8 }
```
```
GET http://<ip>:1024/            -> 403
GET http://<ip>:1024/metrics     -> 200     <- still not covered
```

**Three caveats, all verified:**

1. **A pod restart is mandatory.** The controller writes the snippet into `haproxy.cfg` and logs `configmap ... updated`, but does **not** reload haproxy for it (§4.5). Until `kubectl rollout restart`, the running process keeps the old config and the mitigation is *silently absent while looking applied in the file*. This is exactly how two experiments here produced a wrong "it doesn't work" reading.
2. **`/metrics` cannot be covered by either form.** The snippet block is rendered *below* `http-request use-service prometheus-exporter if { path /metrics }`, so the exporter answers before any snippet rule runs. There is no insertion point above it.
3. This is the `config-snippet` family the plan otherwise avoids (upstream #768 is about **`backend-config-snippet`** loss). `stats-config-snippet` is a different key, but treat it with the same suspicion and re-verify after any chart/controller bump.

**Verdict:** useful defence-in-depth for the stats *page*, and cheap. **Not a substitute for the firewall** — `/metrics` leaks the same backend names and stays open (§5).

### §4.7 🟡 R-07 is half wrong — QUIC still listens

`service.enablePorts.quic: false` **does** remove the `--quic-*` args from the podspec (the dossier verified that correctly). But the controller still renders `bind quic4@<ip>:443` into `haproxy.cfg`, and **udp/443 is open**:

```
UNCONN 192.168.160.90:443 haproxy      UNCONN 192.168.160.91:443 haproxy
```
`alt-svc: h3=":443"; ma=60` is advertised on every HTTPS response. Harmless for collisions (the QUIC bind **is** scoped by `--ipv4-bind-address`), but "the QUIC listener is disabled" is false.

---

## §5. 🔴 Ports that become publicly reachable after the migration

**Today (nginx + `externalIPs`) nothing binds these.** After Path B, each is open on **both public IPs** — `0.0.0.0` means every address, so each instance answers on the *other brand's* IP too.

| Port | What | Auth | Can it be closed? |
|---|---|---|---|
| **1024** (hfc), **1026** (main) | HAProxy **stats page** + **`/metrics`** | **none** | **No.** See below. |
| **1042** (hfc), **1043** (main) | `/healthz` | none | **No.** Needed by kubelet probes; address not configurable. |
| **6061** (hfc), **6063** (main) | Go local default backend (404 server) | none | No flag to disable. Only movable, or bypassed by setting `--default-backend-service`. |
| **10000** (hfc), **10001** (main) | HAProxy **peers** (stick-table sync), bound to `<nodeIP>` = **`178.156.239.214`** | none | No flag to disable; only `--localpeer-port` moves it. |
| **udp/443** ×2 | QUIC/h3 | n/a | Scoped per IP; `enablePorts.quic: false` does **not** remove it (§4.6). |
| — | Go controller-data (6060) | — | ✅ **Closed** by `--controller-port=0`. The only one that can be. |

### Why stats cannot be turned off — the source, verbatim

`pkg/controller/controller.go:267` — the bind is created with **no condition at all**:

```go
logger.Panic(c.haproxy.FrontendBindCreate(
    "stats",
    models.Bind{
        BindParams: models.BindParams{
            Name:   "stats",
            Thread: c.osArgs.StatsBindThread,
        },
        Address: fmt.Sprintf("*:%d", c.osArgs.StatsBindPort),
    },
))
```

There is no `if`, no feature flag, no ConfigMap key. The `stats` frontend is also pre-declared in the image's base config (`fs/usr/local/etc/haproxy/haproxy.cfg:74`) with `stats enable` / `stats uri /`. `--stats-bind-port` moves the port; `0` is invalid (§4.4). **The listener always exists.**

The same reasoning holds for healthz (`controller.go:245`, hardcoded `0.0.0.0`) and peers (base config + `--localpeer-port`).

### What partial mitigation exists (and where it stops)

**`stats-config-snippet` locks the stats page — see §4.6 for the working recipe, the mandatory pod restart, and the proof.** Summary: `stats auth …` → 401, or `http-request deny unless { src … }` → 403. **`/metrics` stays 200 either way** — the prometheus exporter is rendered above the snippet block and answers first.

And `/metrics` leaks exactly what the two-IP split exists to hide:

```
proxy="demo_svc_hfc-app_80"     <- backend names, i.e. which brand this instance serves
proxy="haproxy-ingress_svc_default-local-service_http"
```

Reachable at `http://<either public IP>:1024/metrics`. **So the snippet is not sufficient; a firewall is required regardless.**

### Decision (user, 2026-07-15)

The IPs are properly separated for traffic (§3.1), so exposure is handled at the network edge: **Hetzner Cloud Firewall**, which currently does not expose these ports. Requirement for the cutover: **allow inbound 80/443 (tcp, and udp/443 if QUIC is wanted) only; deny everything else** — specifically 1024, 1026, 1042, 1043, 6061, 6063, 10000, 10001. This is a **hard prerequisite of Path B**, not a nice-to-have; it did not exist as a requirement under the current `externalIPs` topology because nothing was listening.

---

## §6. What this does to the dossier's claims

| Claim | Where | Verdict |
|---|---|---|
| "Does `--ipv4-bind-address` scope healthz? Unanswerable offline" | `06` O-0, `07` §7.5 | **Answerable offline** — source + a kind replica. Answer: **no**. |
| "There is **no flag** to move or disable the 1042 listener" | `06` O-0, `07` §7.5 | **Wrong.** `--healthz-bind-port` exists (`flags.go:105`). |
| "There is **no `--stat-bind-port`**" | `07` §7.5 | **Wrong** — the flag is **`--stats-bind-port`** (plural, `flags.go:95`). One letter cost this question its "unresolvable" status. |
| "`containerPort.stat` may be declaration-only" | `07` §7.5 | **Confirmed.** main rendered `containerPort.stat: 1026` and still bound `*:1024`. Third repeat of the R-01 failure. |
| "If both answers are no, Path B's two-instance design does not work as written" | `06` O-0 | **Half right.** The design as *written* does not work; the design is *salvageable* with five flags. |
| "The second pod dies with `EADDRINUSE`" | `06` O-0 | **Wrong for haproxy's listeners** — `SO_REUSEPORT`, no error. Right only for the Go listeners, which log and limp. |
| "`enablePorts.quic: false` disables the QUIC listener" | **R-07** | **Wrong.** Args go; the bind stays. Collision-free only because that bind *is* scoped. |
| "H5: probably holds, but probably is not good enough" | `06` O-1 | **Resolved: it holds.** Solver Ingress beats both redirects. |
| "Config-level unknowns are zero" | R-14 | Still wrong, and now for four more reasons (§4.1, §4.2, §4.5, §5). |

**The pattern held one more time.** Round 8 (source) and round 9 (running it) each found blockers that rounds 1–7 — including two Opus reviews and a full offline render — did not. And this session repeated the R-14 mistake verbatim: the first "no collisions!" claim came from a `grep` for *expected* ports, which hid `:10000`. Only `ss -ltnp` with **no filter** showed it.

**Rule to add:** never grep a listener dump. Print it whole and read every line.

---

## §6.5 Upstream says the five-flag fix **is the design** (not a workaround)

Checked after the fact, and it reframes everything above.

**Issue [#348](https://github.com/haproxytech/kubernetes-ingress/issues/348)** (2021-07-21) — *"(Multiple ingress same node) vs (stats port 1024 and healthz port 1042)"*. A user hit **our exact wall**: stats/healthz bind `0.0.0.0`, plus "an additional uncontrolled port (127.0.0.1:10000)", and asked to bind them per-IP like http/https.

It was closed by **[PR #446](https://github.com/haproxytech/kubernetes-ingress/pull/446)** (merged 2022-06-23 by maintainer oktalz), whose body reads verbatim:

> *"Currently, it is not possible to simultaneously run two **host-mode** ingress controllers on the same node, because the binds `127.0.0.1:10000` (local peer), `*:1024` (stats), and `0.0.0.0:1042` (health) are hardcoded. This PR allows using custom ports for local peer, stats and healthz. Fixes #348"*

Read that carefully: a user asked for **per-IP binding** and upstream answered with **per-port separation**, deliberately. `--localpeer-port`, `--stats-bind-port`, `--healthz-bind-port` exist *precisely so that two hostNetwork instances can share a node*. Our configuration is not a clever hack around a limitation — **it is the sanctioned design, and this is the use case it was built for.** (Earlier still: **#139** *"Listen on custom ports"*, 2020-01-20, opened by a HAProxy person with the same multi-instance-DaemonSet motivation.)

Also: **[PR #568](https://github.com/haproxytech/kubernetes-ingress/pull/568)** (merged 2023-10-10) moved the healthz/stats binds out of the shipped base config and into runtime injection (`setToReady()`) *to prevent first-start port conflicts under hostNetwork* — which is exactly why the image's `haproxy.cfg` declares `frontend healthz` / `frontend stats` with **no bind lines**.

**What upstream does *not* know:** that a missed port flag fails **silently** via `SO_REUSEPORT` instead of erroring. A search for `reuseport|SO_REUSEPORT|EADDRINUSE|address already in use` finds nothing relevant. PR #568's own thread quotes the loud failure (`[ALERT] cannot bind socket (Address in use) for [127.0.0.1:1042]`) — which happens when a **non-haproxy** process holds the port. Two haproxy instances both set `SO_REUSEPORT`, so the kernel shares the port instead of erroring. **The silent mode is unreported upstream.** → hence the explicit no-duplicates assertion in `lab/verify.sh`.

**And there is no version to upgrade into:** branches are `master, v1.4…v1.11, v3.0, v3.1, v3.2`. **No v3.3, no v3.4.** 3.2.12 (2026-07-03) is the tip of the newest line. No open feature request for per-IP aux binds — #348 *was* the ask, and it was answered with ports and closed.

**Stats cannot be disabled — maintainer-confirmed.** ivanmatmati on issue [#614](https://github.com/haproxytech/kubernetes-ingress/issues/614) (2024-02-19): *"the stats frontend can't be disabled. If you want to create your backend, you can."* and (2024-02-21): *"You have several options. Among them, you can secure the ingress with authentication or with allow and deny lists of IPs or CIDRs."* — i.e. upstream's own answer is §4.6's snippet. This corroborates the `--stats-bind-port=0` result independently.

**A dead end worth recording** (it looks like a solution): the **Frontend CR** advertises `cr-frontend-stats` with a `binds:` map taking `address`/`port`. It cannot override the wildcard — `pkg/handler/frontends.go` merges with the **live** frontend as the override source (`mergo.MergeWithOverwrite`), and `binds` is keyed by name, so the runtime-injected `stats`/`*:1024` bind wins. The docs concede it: *"the original configuration can only be amended not replaced."* *(Read, not run — treat as ~85%.)*

**`jcmoraisjr/haproxy-ingress` — the reserve option, now unnecessary.** On the merits it is technically better for this shape: `bind-ip-addr-{http,stats,healthz,prometheus,tcp}` make **every** listener IP-bindable, its prometheus listener is off by default, and **`redirect-from`** (not `from-to-www-redirect` — that name is ingress-nginx's and never existed there) *"preserv[es] protocol, path and query string"*. But: v0.16.1 (2026-05-04), **bus factor 1** (jcmoraisjr has 1,856 commits; the next human has 16), no `master` commits since 2026-06-13, two open security issues, and the FAQ states *"There is currently no paid support"*. Given §4.2 is solved with an annotation prefix, trading a vendor-backed controller for this is not justified. Keep it in reserve.

---

## §7. Still unverified (a cluster is required)

- The cutover itself: conntrack/DNAT race (M10), and the seconds-long blip.
- A real Let's Encrypt **staging** issuance including a `www` SAN (mechanism now understood — §4.3 — but not exercised against the real ACME server).
- Behaviour under real traffic: memory, reload cadence, log volume.
- Whether prod's `LeadApp.API` (`0.0.0.0/0`, R-12) should be tightened before the ingress starts setting XFF itself.
- `M11` path precedence for the **real** path lists (the replica used them, all returned the right backend, but the apps are stubs).
