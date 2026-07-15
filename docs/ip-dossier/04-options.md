# 04 — The candidate paths

Three were researched. **A** and **B** have written, reviewed plans. **C** was deferred by the user but is recorded because the evidence favours it.

Common constraint set (from the user, explicit):
- Keep **two public IPs**, each mapped to its brand, with **isolation** (wrong IP → 404, not the other brand).
- **Preserve the real client IP** to the backends. That is the whole point.
- One node. **No MetalLB.** No new server (Hetzner raised prices sharply). Flux GitOps.
- cert-manager stays on **HTTP-01** — DNS-01 is rejected: *"Разок я могу прописать днс, но автоматически — нет."*
- The existing ingress-nginx setup is considered **fragile and hard-won** → minimise gratuitous change (no renames).
- Site-level security hardening (captcha etc.) is **out of scope for now**.

---

## Why the current topology can never work ✅

Both controller Services are `type: ClusterIP` + `externalIPs`. kube-proxy DNATs in **PREROUTING** and **masquerades** the source, so nginx sees a node IP and writes *that* into `X-Forwarded-For`. The ingress-nginx bare-metal docs are explicit:

> "this method **does not allow preserving the source IP of HTTP requests in any manner**, it is therefore **not recommended**"

`externalTrafficPolicy: Local` does not apply (that field is only for `NodePort`/`LoadBalancer`). NodePort cannot be bound to a specific IP (only a port; kube-proxy's `--nodeport-addresses` is global). **So something must change** — this is not tunable.

---

## Path A — `edge-lb` (HAProxy L4 in front of the two nginx controllers)

**Plan:** `docs/superpowers/plans/2026-07-09-edge-lb.md` · **Reviews:** 2 × Opus.

**Design.** One HAProxy pod, `hostNetwork`, **TCP mode**, pinned to `leadsfilter-n1`; binds `178.156.239.214:80/443` and `5.161.26.66:80/443` as separate frontends; forwards each to the matching controller's ClusterIP Service with **PROXY protocol v2** (`send-proxy-v2`). Both controllers: `externalIPs` removed, `use-proxy-protocol: "true"` added. TLS keeps terminating at the controllers. Name `edge-lb` chosen by role (an L4 edge load balancer — the role a cloud LB or MetalLB would play), not by implementation.

```
client → HAProxy (hostNetwork, sees real src)
           ├─ bind 178.156.239.214:443 → be_main  (send-proxy-v2)
           └─ bind 5.161.26.66:443      → be_hfc   (send-proxy-v2)
                     ↓ PROXY header
           ingress-nginx (use-proxy-protocol: true) → app sees real IP in XFF
```

### Why it's viable
- **Only one hostNetwork pod** → it does *not* re-enter the #117689 minefield the team already hit (that needs *two* hostNetwork pods fighting for 80/443).
- Both public IPs are already on `eth0` → binds work, no interface surgery.
- The controllers are barely touched (remove `externalIPs`, add one config key) — matches the "don't disturb the fragile setup" constraint.
- Reuses the team's own proven fix for the hostNetwork rolling-update deadlock: `strategy: Recreate`.

### Blockers found & fixed (on paper)
1. **Bind 80/443** — the official `haproxy` image is **non-root (UID 99) since 2.4**; the sysctl escape is forbidden on hostNetwork; `NET_BIND_SERVICE` alone doesn't survive a non-root UID (no ambient caps). → `securityContext.runAsUser: 0`.
2. **The cutover is NOT atomic** — controllers are HelmReleases (helm-controller), edge-lb is manifests (kustomize-controller); Flux doesn't dependency-order across them (flux2 #293), and even inside one helm upgrade the ConfigMap reload and Service reprogram are independent. → **Commit A** (deploy edge-lb and *prove it binds* while nginx still owns the IPs, so it gets zero traffic) → **Commit B** (the flip, manually sequenced in a window). A seconds-long blip is unavoidable; the plan says so.
3. **IPs must be locally deliverable** → **dissolved** (already on `eth0`).

### Design details worth keeping
- **Timeouts:** TCP mode has no HTTP-level timeouts — only `connect/client/server/tunnel/client-fin`, and they are **inactivity** timeouts, not session caps. Principle: **edge timeouts must exceed the largest ingress timeout**, so the controller always decides first and edge-lb only reaps dead connections (not infinite — FD leak). **`timeout tunnel` is the important one in TCP mode** (WebSocket/SSE/long-poll idle once established). Don't set an aggressive `hard-stop-after` — a reload would kill long connections.
- **Backends by DNS**, not hard-coded ClusterIP, with `resolvers` → kube-dns `10.96.0.10`, `hold valid 10s`.
- **No active health check** (see `03-refuted.md` R-13 for why the 10254 idea doesn't apply).
- **Readiness probe** must hit a `monitor-uri` frontend on `127.0.0.1:8404` — *not* `tcpSocket: 443` (which spawns a real PROXY-headed backend connection every cycle and reports healthy even when nginx is down).
- **No redirect-loop risk**: a pure L4 proxy injects no `X-Forwarded-Proto`; nginx derives scheme from its own listener. Don't "fix" this by adding `use-forwarded-headers`.

### Path A's real weakness — cert-manager
`use-proxy-protocol: "true"` makes the controller reject **any** connection lacking a PROXY header. cert-manager's HTTP-01 does an **in-cluster self-check** without one → `broken header` → **certs stop renewing** (cert-manager #466, ingress-nginx #11365). The cutover looks green (existing certs are valid); **TLS dies silently ~30 days later.**

Remediations considered:
| | | Verdict |
|---|---|---|
| **D1** | switch to DNS-01 | Structurally immune, cleanest — **rejected by user** (can't automate DNS) |
| **D2** | `hairpin-proxy` (or Go rewrite "ouroboros") | Works; extra component; edits CoreDNS; its `cluster.local` rewrite is known to break DNS-01 (issue #10) |
| **D3** | **CoreDNS `hosts{}` rewrite — CHOSEN** | Point the four names at the public IP edge-lb owns → the self-check hairpins out through edge-lb and *gets* a PROXY header. No extra component. Works because both IPs are local. |

**D3's own findings (2nd Opus review):**
- ✅ **It is not a no-op:** cert-manager's self-check uses a custom resolver **only** if `--acme-http01-solver-nameservers` is set; the default is empty → it uses the pod resolver → **CoreDNS**. (Must still verify this install doesn't set that flag and uses `ClusterFirst`.)
- ✅ `hosts{}` is the right plugin; CoreDNS plugin order is fixed by the compiled `plugin.cfg`, **not** textual position. **`fallthrough` is mandatory** — without it `hosts` becomes authoritative for `.` and NXDOMAINs everything (cluster-wide DNS outage).
- 🔴 **On k0s, CoreDNS is a k0s-managed stack — k0s reverts live edits.** Must patch via the k0s mechanism or Flux.
- 🔴 **HIGH-1: the pod→own-public-IP hairpin is unproven on kube-router** and is the single most likely first-run failure. Both IPs are real `/32`s on `eth0` so the kernel installs `local` routes and delivery *should* work; `rp_filter` bites on asymmetric *forwarding*, not local delivery; kube-router SNAT quirks (#376, #511) are harmless for a self-check. **But nothing else exercises this leg** — external traffic never hairpins.
- 🔴 **HIGH-3: test all four names**, not just apex. `www` is precisely the name at risk, because `from-to-www-redirect` renders a **separate server block with an unconditional `return 301`** and **no `.well-known` carve-out** (ingress-nginx #6853, #11315), and cert-manager **follows redirects**. Parity argument: external LE validation already traverses the same redirect and certs *do* issue today — so it should hold. It was never tested.
- 🟡 **AAAA gap:** `hosts{}` defines only A; with `fallthrough` an AAAA escapes to the public resolver → the self-check could pick an IPv6 edge-lb doesn't bind. Verify no AAAA exists.
- 🟡 Add `no_reverse` to `hosts{}`.

**Gates before trusting A:** `ip route get <ip>` shows `local … dev lo`; `rp_filter` loose; all four names return **404** on `/.well-known/acme-challenge/probe` (a **301** on a `www` name = the redirect ate the ACME path); then a **staging** issuance including a `www` SAN → `Ready=True`.

### Path A scorecard
| | |
|---|---|
| Client IP | via PROXY protocol |
| Components | 2× nginx + edge-lb + a CoreDNS hairpin |
| nginx EOL (archived ~Mar 2026) | **you stay on it** |
| Disturbs the fragile setup | minimally |
| Effort | plan ready; one maintenance window |
| Worst risk | the D3 hairpin (unproven on kube-router) + a k0s-reverted CoreDNS edit |

---

## Path B — migrate to `haproxytech/kubernetes-ingress` ← **user leans here**

**Plan:** `docs/superpowers/plans/2026-07-09-haproxy-ic-migration.md` · **Review:** 1 × Opus + chart downloaded + both instances rendered + image inspected.

**Design.** Replace both nginx controllers with **two haproxytech IC instances**, each a DaemonSet in `hostNetwork`, pinned to `leadsfilter-n1`, each bound to **its own** public IP via `--ipv4-bind-address`, each with its own IngressClass (`haproxy` / `haproxy-hfc`). **Cutover brand-by-brand** (homefinanceclub first — lower risk), so the other brand stays fully live on nginx throughout.

### The key insight
**A hostNetwork ingress controller is itself the edge** → it sees the real client IP directly (no kube-proxy SNAT) and sets `X-Forwarded-For` itself. Therefore: **no edge-lb, no PROXY protocol, and no cert-manager hairpin.** Path A's entire fragile chain evaporates. Plus it gets off EOL nginx.

**Why two hostNetwork controllers work here but not with nginx:** nginx binds `0.0.0.0` (its `bind-address` option exists but its startup port check ignores it — upstream #2529/#7859), so two instances collide. haproxytech IC takes a real **per-instance bind address** (`--ipv4-bind-address`), so their sockets don't overlap; and distinct `daemonset.hostIP` makes the scheduler's `(hostIP,port)` tuples distinct, defusing #117689.

### Verified-correct values (both instances) — see `02-verified-facts.md` §4-5
```yaml
controller:
  kind: DaemonSet
  dnsPolicy: ClusterFirstWithHostNet      # required with hostNetwork
  unprivileged: false                      # image is root ⇒ binds 80/443, no caps/sysctl
  containerPort: { http: 80, https: 443, stat: 1024, admin: 6060 }   # default is 8080/8443!
  prometheus: { enabled: false }           # default true → extra listener
  pprof:      { enabled: false }           # default true → extra listener
  daemonset:
    useHostNetwork: true                   # NOT controller.hostNetwork
    useHostPort: true
    hostIP: 5.161.26.66                    # scheduler tuple only (#117689)
    hostPorts: { http: 80, https: 443, stat: 1024 }
  nodeSelector: { kubernetes.io/hostname: leadsfilter-n1 }
  ingressClass: haproxy-hfc
  ingressClassResource: { name: haproxy-hfc, default: false }   # no `enabled` key exists
  extraArgs:
    - "--ipv4-bind-address=5.161.26.66"    # THE actual bind + isolation
    - "--disable-ipv6"                     # else both bind :::80 → EADDRINUSE + leak
  publishService: { enabled: false }       # default true → points at the disabled Service
  service:
    enabled: false                         # isolation is the bind, not kube-proxy
    enablePorts: { quic: false }           # default true → both would bind udp/443
```
**MAIN instance:** same, with `178.156.239.214`, class `haproxy`, and **distinct** `containerPort.stat`/`admin` (e.g. 1026/6061) + `hostPorts.stat: 1026`.
**Pin:** chart **`1.52.1`** (→ controller 3.2.12 → HAProxy 3.2.x). **Never** `allowPrivilegedPorts: true` (R-02).

### Blockers found & fixed
1. **containerPort 8080/8443** → nothing on :80/:443 (#589) → set 80/443.
2. **`hostIP` ≠ isolation** → `--ipv4-bind-address` per instance (R-01 — the catastrophic one).
3. **`controller.hostNetwork` isn't a key** → `daemonset.useHostNetwork` (R-04).
4. **2b — IPv6:** `--ipv6-bind-address` defaults to `::` → both bind `:::80` → `EADDRINUSE`, and with `bindv6only=0` a `::` bind **also accepts IPv4** → isolation leak → `--disable-ipv6`. *(Found by reading the flag docs; the Opus review missed it.)*
5. **Secondary listeners** (stat/admin/metrics/QUIC) collide in the shared netns → disable prometheus/pprof/QUIC, distinct stat/admin.
6. **`publishService`** default true → points at the disabled Service → off.

### Annotation migration — the surface is tiny
| In use (nginx) | Critical? | HAProxy IC |
|---|---|---|
| `use-gzip` + params | no | **unsupported** (#196) → **drop** |
| `use-gunzip` | no | **no equivalent** (HAProxy never decompresses) → drop |
| `ssl-redirect` | **yes** | `haproxy.org/ssl-redirect: "true"` + `ssl-redirect-code: "301"` — **default is false**, and **leadsfilter has no such annotation today** (it relies on nginx's implicit redirect) → must be added to **both** brands or HTTPS-forcing is silently lost |
| `use-regex` (paths) | yes | drop; `Prefix` = `path_beg`. Test each path, incl. `/serviceroom/admin` and the trailing-slash forms |
| `from-to-www-redirect` | **yes** | **no drop-in.** Hand-author a separate `www.*` Ingress with `haproxy.org/request-redirect: "<apex>"` + `request-redirect-code: "301"` (value is host or host:port only; it does **not** force scheme; the code is a separate key — nginx's version used 308) |
| `server-snippet` (6 debug headers) | no | `response-set-header` exists (syntax `Name "value"`), but the nginx `$`-vars have no clean HAProxy fetch → **drop** (diagnostic only) |
| caching / Lua / WAF / auth / rate-limit / canary / gRPC / mirror | **none used** | n/a |

**Avoid `backend-config-snippet`** (upstream #768, snippet loss). Everything needed maps to typed annotations — that's what keeps this migration low-risk.

### Path B's real weakness — H5
The hand-authored `www` redirect can 301 the `/.well-known/acme-challenge` path → the **`www` SAN stalls at renewal ~30 days after a green cutover**. Only a **staging issuance including a `www` SAN, with the redirect live** proves it. If it does redirect: scope the redirect away from `.well-known`, or reconsider `jcmoraisjr/haproxy-ingress` (which has a true 1:1 `from-to-www-redirect`).

### Known upstream issues (assessed, mostly out of scope)
Open 3.2.x issues: reload storms (#765, #762, #773) — **TCP-CRD-specific, out of scope for HTTP-only**; config-snippet loss (#768) — **avoided by using typed annotations**; memory creep (#772) — only at ~150 ingresses, we have ~2. cert-manager HTTP-01 works cleanly; one gotcha: steer via `http01.ingress.ingressClassName` and **never** set both `ingressClassName` and the legacy `class` (#6184).

### Path B scorecard
| | |
|---|---|
| Client IP | **native** (no PROXY, no hairpin) |
| Components | 2× HAProxy IC (that's all) |
| nginx EOL | **you leave it** |
| Disturbs the fragile setup | **replaces it** |
| Effort | ~2–4 days, brand-by-brand |
| Config-level unknowns | **zero** (chart read + rendered + image inspected) |
| Worst risk | H5 (`www` × ACME, silent at +30d); then plain runtime behaviour |

---

## Path C — Cloudflare (deferred by the user, but the evidence favours it)

**Status:** *"клаудфлэр пока не рассматриваем"*. Recorded because it answers **both** goals at once, for free.

**What it is.** Front both domains with Cloudflare (proxied/orange-cloud). Shared anycast IPs across **all** proxied hostnames → the origin IP is hidden and the front IP identifies nobody. Free Universal SSL. Real client IP arrives in **`CF-Connecting-IP` / `X-Forwarded-For`**.

**Why it dissolves the whole project.** With a CDN in front, the truth is back **in an HTTP header** — exactly as it was under CloudFront. kube-proxy's SNAT stops mattering. That means: **no edge-lb, no PROXY protocol, no HAProxy migration, no hostNetwork, no CoreDNS hairpin.** Keep today's nginx; just trust Cloudflare's ranges. And with a **Cloudflare Origin Certificate** (free, 15-year, Full-strict) **cert-manager/HTTP-01 disappears too** — killing Path A's D3 *and* Path B's H5 in one move.

It also serves the **original motive** for the two IPs (hiding the collector→marketplace link) far better than two IPs on one box ever could.

**The caveat that decides it.** A CDN hides the origin **only if**:
1. the origin firewall **allowlists only Cloudflare**, and
2. the **currently-exposed IPs are rotated** — `178.156.239.214` / `5.161.26.66` are already public via passive DNS and **Certificate Transparency** (their Let's Encrypt certs are permanently logged). Without rotation the hiding is theatre.

**Strongest variant:** **Cloudflare Tunnel** (`cloudflared`) — the origin dials **out**; no inbound public IP, no open ports, nothing to scan.

**Free-tier limits (the user asked).** There is **no published bandwidth cap because there is no cap**. The boundary is **content type**: Self-Serve ToS **§2.8** forbids using the CDN as a video-streaming / large-file-distribution / object-storage service. Real reports: **15–20 TB/month on free** for months, no issue. Enforcement is **soft** — they *ask* you to upgrade; they do **not** cut traffic or bill overage (unlike Vercel). For HTML/API/WordPress lead-gen traffic this is effectively unlimited; only bulk media through the CDN cache would trigger it (→ R2/Stream for that).

**Alternatives in the same category:** keep AWS CloudFront (ACM certs), Fastly, Bunny.net, Azure Front Door. Self-hosted tunnels (`frp`) work but then the front IP is yours again → less anonymity.
**Not in this category:** **Hetzner Cloud LB** — it gets its **own dedicated IP**, not a shared pool; it does not hide anything. Wrong tool.

**Risks to weigh:** dependency on Cloudflare; they see all traffic (mortgage PII) — though AWS CloudFront was the same posture; **bot challenges could hurt conversion** (the user's live concern — margins are thin) → keep security settings low/off on lead-capture paths; the CF IP list must be kept current for XFF trust; and note **`LeadApp.API` currently trusts `0.0.0.0/0`** (R-12), which should be tightened to CF ranges if this path is taken.

---

## Head-to-head

| | **A: edge-lb** | **B: HAProxy IC** | **C: Cloudflare** |
|---|---|---|---|
| Client IP | PROXY protocol | native | header from CDN |
| edge-lb needed | yes | no | no |
| cert-manager pain | D3 hairpin (k0s reverts CoreDNS) | H5 www×ACME | **none** (Origin Cert) |
| Leaves EOL nginx | no | **yes** | no (but nginx stops being the edge) |
| Hides the origin | no | no | **yes** (if locked + IPs rotated) |
| Cost | free | free | free |
| Effort | 1 window | ~2–4 days | ~1 day + DNS + firewall + IP rotation |
| Config unknowns left | few | **zero** | not yet planned |
| Status | plan + 2 reviews | **plan + review + rendered** ← leaning | **deferred by user** |

**Honest reading:** B is architecturally the cleanest of the two the user is willing to do, and is now verified to the last chart key. C would make the entire problem — and the original obfuscation goal — go away for free, and is the only option that addresses *why* the two IPs exist in the first place. It is deferred, not refuted.
