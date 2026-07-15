# HAProxy Kubernetes Ingress vs. ingress-nginx + edge-lb

**Date:** 2026-07-09
**Question:** Can switching to the HAProxy Kubernetes Ingress Controller *replace both* the current two `ingress-nginx` controllers *and* the planned `edge-lb` HAProxy L4 front proxy — solving the real requirements with one component?

> **CORRECTION (2026-07-09, from migration-plan Opus review):** an earlier revision of this doc implied `daemonset.hostIP` gives each instance a "genuinely separate bind socket" / per-IP isolation. **That is wrong.** `daemonset.hostIP` only sets the k8s port-spec `hostIP` (a scheduler hint that defuses #117689); it does **not** set HAProxy's bind address. Real per-IP bind + isolation requires **`--ipv4-bind-address=<ip>` per instance** (default is `0.0.0.0`). Also: the chart default `containerPort` is **8080/8443**, so :80/:443 need `containerPort.http/https` set, and hostNetwork is gated by `daemonset.useHostNetwork` (not `controller.hostNetwork`). See `docs/ip-dossier/03-refuted.md` R-01.

> **SECOND CORRECTION (2026-07-15, from actually running it — this doc is now historical only):** the fix above is **necessary but nowhere near sufficient**, and this doc's central claim needs qualifying.
>
> `--ipv4-bind-address` scopes **only 3 of 8 listeners**. healthz (`0.0.0.0:1042`), stats (`*:1024`), peers (`<nodeIP>:10000`) and two Go listeners bind **all interfaces** — their addresses are string literals in the controller source. Two instances therefore still collide, and **the collision is silent**: haproxy binds with `SO_REUSEPORT`, so both pods go `1/1 Running` and the kernel answers from a random one. Separating them needs **five more flags** (`--healthz-bind-port`, `--stats-bind-port`, `--localpeer-port`, `--default-backend-port`, `--controller-port=0`).
>
> The verdict below — that hostNetwork HAProxy IC preserves the client IP natively and eliminates `edge-lb` — **is correct and has now been proven end-to-end**, not just argued.
>
> **Do not take values from this doc.** Use `docs/ip-dossier/lab/values-{hfc,main}.yaml`; read `docs/ip-dossier/09-runtime-verification.md`. The migration plan this banner used to point at is itself superseded and carries two site-breaking recipes.

## TL;DR / Verdict

**Partly — and not the way the "one universal controller" story implies.**

- The **community HAProxy Kubernetes Ingress Controller** (`haproxytech/kubernetes-ingress`, v3.2, Jan 2026) is production-ready and is the officially recommended immediate replacement for ingress-nginx (which is being retired — see below). It is a real, shipped product.
- **But it cannot do true per-IP isolation from a single instance.** Its bind address is a single global startup flag (`--ipv4-bind-address`, default `0.0.0.0`). There is no per-IngressClass / per-frontend IP binding. So one controller cannot serve `.214 -> magazin` and `.66 -> lidosbornik` with hard isolation. You would still run **two controller instances**, one per IP — same topology as today.
- **What it CAN do that matters:** run each instance on `hostNetwork` bound to its own public IP, making the ingress *itself the edge*. That preserves the real client IP **natively** (no kube-proxy DNAT, no PROXY protocol, no cert-manager self-check hairpin), which **eliminates the need for `edge-lb`**.
- The **"universal/unified controller"** the user remembers is **HAProxy Unified Gateway** (beta Nov 2025, 1.0 GA Mar 2026). It is **Gateway-API-only today**; Ingress support is "later in 2026" and not shipped. Betting a production migration on a ~4-month-old GA that doesn't yet support Ingress is not advisable right now.

**Net:** HAProxy IC realistically lets you drop **edge-lb** and the PROXY-protocol complexity, and it gives you a maintained ingress after ingress-nginx's retirement. It does **not** collapse you to a single component — you still run two ingress instances for the two isolated IPs. Collapsing to literally one component requires Unified Gateway + Gateway API (two `Gateway`s on two IPs), which is too young and Ingress-incomplete to adopt in mid-2026.

---

## The setup / requirements being tested

- Single node `leadsfilter-n1` (Hetzner Cloud, CNI = kube-router), two public IPs on `eth0`: `178.156.239.214` and `5.161.26.66`.
- Per-IP mapping with **isolation** (not just Host-based):
  - `178.156.239.214` -> `leadsfilter.com` (magazin), class `nginx`
  - `5.161.26.66` -> `homefinanceclub.com` (lidosbornik), class `nginx-hfc`
- MUST preserve real client IP to backends.
- cert-manager HTTP-01 (no DNS-01).
- No cloud LB, no MetalLB. GitOps via Flux.
- Current two ingress-nginx controllers are considered fragile.

---

## Q1 — The HAProxy ingress landscape in 2026

There are **two distinct products**, plus the enterprise umbrella:

### (a) HAProxy Kubernetes Ingress Controller — community `haproxytech/kubernetes-ingress`
- **Latest:** v3.2 line (3.2 announced **Jan 13, 2026**; 3.2.x patch releases current). Apache-2.0.
- Mature, ~1,600 commits, 120+ releases. Built on HAProxy + the Data Plane API.
- **This is the production-ready, officially recommended immediate ingress-nginx replacement.**
- v3.2 added: **user-defined annotations** (add annotations out-of-band from releases), **Frontend Custom Resources** (CRDs to configure the HTTP/HTTPS/STATS frontends), and an **Ingress NGINX migration assistant** to ease annotation conversion.
- An **Enterprise** build (HAProxy Enterprise Kubernetes Ingress Controller) also exists (v3.4 planned 2026); same lineage, paid support.

### (b) HAProxy Unified Gateway — the "universal/unified" thing the user remembers
- **Beta:** announced **Nov 11, 2025** at KubeCon NA. **1.0 GA:** announced **March 2026** at KubeCon EU (Amsterdam). Free, open-source.
- Positioned as the "next-generation, built-from-the-ground-up" controller providing **one** way to serve **both Gateway API and Ingress**.
- **Reality check:** 1.0 GA supports **Gateway API only** (spec 1.3/1.4/1.5, TCP + HTTP/S with TLS termination). **Ingress support is roadmapped for "later in 2026" and is not shipped.** So the "unified Ingress + Gateway in one instance" is still marketing/roadmap, not shipped reality as of July 2026.

### (c) HAProxy One (enterprise umbrella)
- = **HAProxy Enterprise** (data plane) + **HAProxy Fusion** (control plane) + **HAProxy Edge** (edge network). The unified Ingress/Gateway capability lands in HAProxy One in 2026. Not relevant to a no-cloud, self-hosted single node unless you buy enterprise.

### Context that changes the calculus: ingress-nginx is retiring
- The community **ingress-nginx** project's best-effort maintenance **stops March 2026** — no new releases, bugfixes, or security updates after that. HAProxy (and others) are courting the migration. So **staying on ingress-nginx is itself a growing liability**, independent of the edge-lb question. HAProxy's own recommended path: adopt the **community HAProxy IC now** (production-ready), move to Unified Gateway/Gateway API later "at your own pace."

---

## Q2 — Can ONE HAProxy IC bind each public IP separately and isolate by IP?

**No, not from a single instance.** This is the decisive finding.

- The controller's public bind address is a **single global** startup flag: `--ipv4-bind-address` (default `0.0.0.0`), plus `--http-bind-port` / `--https-bind-port`. There is **no per-IngressClass or per-frontend IP binding** in the community controller. All ingresses served by an instance share the same main `http`/`https` frontends, hence the same bind address.
- ConfigMap `bind-ip-addr-http` is likewise a **single** value applied to *all* HTTP/S frontends of that instance.
- `frontend-config-snippet` injects directives into the *same* main frontend and applies to *all* traffic; controller routing logic runs *before* the snippet, so you cannot cleanly carve out a second isolated per-IP frontend with its own ingress set that way. (You could bolt `bind 5.161.26.66:80` into the main frontend via a snippet, but then **both** IPs serve **everything** — that is the opposite of isolation.)
- The new v3.2 **Frontend CRDs** configure *the* HTTP/HTTPS/STATS frontends; they are not a mechanism for arbitrary additional per-IP frontends each with an independent routing table.

**Consequence:** to get the required per-IP isolation you run **two HAProxy IC instances**, each with `--ipv4-bind-address` set to its own public IP and its own `--ingress.class` (e.g. `haproxy` / `haproxy-hfc`). That is exactly the two-controller shape you have today with nginx — the controller software changes, the topology does not.

**The only single-controller-does-per-IP path is Gateway API:** a `Gateway` has `spec.addresses`, so you could define two `Gateway`s (one per IP) with their own listeners/routes, both watched by one **Unified Gateway** controller. But that means Gateway API + rewriting all Ingress -> HTTPRoute + cert-manager Gateway support, on a controller whose Ingress support isn't even out. Not viable now.

---

## Q3 — Does hostNetwork ingress preserve client IP natively? (the edge-lb killer)

**Yes.** When the ingress controller runs `hostNetwork: true` and binds directly to the public IP on `eth0`, it *is* the edge:

- Packets arrive on the socket with the **original source IP intact** — there is no kube-proxy DNAT/externalIPs hop, so no SNAT/masquerade to worry about.
- No **PROXY protocol** hop is needed (that was the whole reason for a separate L4 `edge-lb` in front: to carry the client IP across the proxy boundary). With hostNetwork, there is no boundary to cross.
- No **cert-manager self-check hairpin** problem: with an L4 edge doing PROXY protocol, the ACME solver / self-check traffic that loops back can break because the inner ingress expects PROXY headers on a plain HTTP connection. hostNetwork removes that hop entirely.

This is the core insight: **a hostNetwork HAProxy IC replaces edge-lb by being the edge.** (The same is true of ingress-nginx on hostNetwork — but see Q6 for why two hostNetwork instances on one node is the historically painful part.)

---

## Q4 — cert-manager HTTP-01, cleanly?

**Yes, cleanly.** HAProxy IC terminates TLS itself and serves the ACME `/.well-known/acme-challenge/...` path over plain HTTP like any ingress:

- cert-manager creates its temporary solver Ingress/Service/Pod; the HAProxy IC picks it up (matching class) and serves the token. No PROXY-protocol/self-check breakage because there is no L4 pre-hop when running hostNetwork.
- Same class-routing caveat as today applies: with two instances/classes, the **ClusterIssuer needs per-domain solvers** selecting the right `ingressClassName` (this exact gotcha is already documented in `docs/adding-hfc-ip.md`, Step 6). That logic carries over unchanged.
- Watch item: HAProxy's `ssl-redirect` annotation. As with nginx, an over-eager HTTP->HTTPS redirect can bounce the HTTP-01 token; cert-manager's solver ingress normally handles this, but if you set a global redirect, confirm the ACME path is exempt. Standard, well-trodden.

Annotation name differs from nginx: HAProxy uses `ingress.kubernetes.io/ssl-redirect` (default prefix) rather than `nginx.ingress.kubernetes.io/ssl-redirect`.

---

## Q5 — Migration reality: ingress-nginx -> HAProxy IC

**Moderate, mechanical, and officially tooled — but not zero.**

- **IngressClass handling:** you keep the two-class model. Create two HAProxy IC instances, each with its own `--ingress.class` (e.g. `haproxy`, `haproxy-hfc`) and matching `IngressClass` resources; repoint each brand's Ingress `ingressClassName`. Both brands/classes are servable — just by two instances, not one.
- **Annotations differ** (different prefix + different names). Mapping is the main manual work:
  - `nginx.ingress.kubernetes.io/ssl-redirect` -> `ingress.kubernetes.io/ssl-redirect`.
  - `nginx.ingress.kubernetes.io/from-to-www-redirect` -> no 1:1 flag; implement via HAProxy IC request-redirect annotation / a config snippet, or handle www at DNS/redirect level. **Verify per brand.**
  - `nginx.ingress.kubernetes.io/use-regex` + `rewrite-target` -> HAProxy IC has its own path-rewrite / regex annotations; semantics are close but not identical. **Test each path rule.**
  - v3.2's **user-defined annotations** + the **Ingress NGINX migration assistant** are designed exactly for this and reduce (not remove) the manual mapping.
- **Gateway API is optional**, not required, for the community IC — it is a plain Ingress controller. (Gateway API only becomes mandatory if you chase the Unified Gateway path.)
- **Gotchas:** annotation prefix mismatch silently ignores unconverted annotations (fail-open to defaults); default-backend / 404 behavior differs; TLS secret handling and default certificate config differ; the ClusterIssuer per-domain solver mapping must be updated to the new class names.

---

## Q6 — Can a SINGLE HAProxy IC bind 80/443 twice (once per IP) on one node, or does it hit the same port limit?

Two layers to this:

1. **Within one instance:** No — one instance has one global bind address (Q2). It does not bind 80/443 "twice for two isolated IPs." So a single IC does not solve the per-IP requirement.

2. **Two instances on one node (the real comparison to the nginx pain):**
   - At the **Linux socket** level, `bind 178.156.239.214:80` and `bind 5.161.26.66:80` are **different sockets and do not conflict** — a specific-IP bind on :80 doesn't collide with another specific IP on :80. HAProxy IC lets you set that via `--ipv4-bind-address` per instance, so **HAProxy avoids the `0.0.0.0:80` collision that two default hostNetwork instances would hit.** This is a genuine advantage over the naive nginx hostNetwork setup.
   - **However**, the historical blocker documented in `docs/adding-hfc-ip.md` was **not** the socket layer — it was the Kubernetes **hostPort scheduler defaulter** ([k8s #117689](https://github.com/kubernetes/kubernetes/issues/117689)): with `hostNetwork: true`, the API server auto-sets `hostPort = containerPort`, and the scheduler's port-conflict check treats `hostIP` as `0.0.0.0` (overlaps everything), blocking the second pod. **This bites any hostNetwork ingress, HAProxy included, unless the pod spec sets per-port `hostIP` to the specific public IP.** Whether HAProxy IC's Helm chart lets you set `ports[].hostIP` per port is the key thing to verify before committing to the hostNetwork approach. If it doesn't, you're back to the same scheduler fight.
   - The **existing nginx solution sidestepped hostNetwork entirely** (ClusterIP + `externalIPs` per controller) — which is why it then needed edge-lb/PROXY to recover client IP. HAProxy IC on `ClusterIP + externalIPs` would inherit the **same** client-IP-loss problem and would **not** let you drop edge-lb. **Dropping edge-lb requires the hostNetwork path**, which in turn requires solving the #117689 `hostIP` question for two instances.

**Bottom line for Q6:** HAProxy's per-instance bind address removes the *socket-level* 80/443 conflict, but the *Kubernetes hostPort scheduler* conflict for two hostNetwork pods is orthogonal and must be handled with explicit per-port `hostIP` (verify chart support).

---

## Comparison table

| Requirement | HAProxy IC (single instance) | HAProxy IC (two hostNetwork instances) | ingress-nginx x2 + edge-lb (current plan) |
|---|---|---|---|
| Per-IP isolation (.214 vs .66) | ❌ single global bind address | ✅ each instance binds its own IP + class | ✅ two classes + externalIPs (or edge-lb) |
| Number of ingress components | 1 | 2 | 2 + edge-lb (3) |
| Native client IP (no PROXY hop) | ✅ if hostNetwork | ✅ hostNetwork = edge | ❌ needs edge-lb/PROXY to recover it |
| edge-lb still needed? | No | **No — this is the win** | Yes |
| cert-manager HTTP-01 | ✅ clean | ✅ clean, no hairpin | ⚠️ PROXY self-check hairpin risk |
| Two brands/classes served | ❌ (isolation fails) | ✅ | ✅ |
| Maintained upstream (post Mar 2026) | ✅ HAProxy IC active | ✅ | ❌ ingress-nginx maintenance ends Mar 2026 |
| hostPort scheduler conflict (#117689) | N/A (1 pod) | ⚠️ must set per-port `hostIP` | Avoided (no hostNetwork) |
| Gateway API required | No | No | No |
| Migration effort | n/a (doesn't meet req) | Medium (annotations + hostNetwork) | Already partly built |
| "One universal component" | Only via Unified Gateway (Gateway-API-only, Ingress not shipped) | — | — |

---

## Verdict, risks, effort

**Recommendation: don't expect "one HAProxy component." Do consider two hostNetwork HAProxy IC instances to drop edge-lb — but only after verifying the hostPort `hostIP` question.**

Three viable stances:

1. **Best realistic target — two hostNetwork HAProxy IC instances, no edge-lb.**
   Replaces the fragile nginx pair with a maintained controller *and* removes edge-lb + PROXY-protocol complexity by making each ingress the edge with native client IP. This is a real simplification (3 components -> 2) and fixes the ingress-nginx-retirement liability at the same time. **This is the strongest option if the chart supports per-port `hostIP`.**
   - **Top risks:** (a) k8s #117689 hostPort scheduler conflict for two hostNetwork pods — must set `ports[].hostIP` per instance; verify the HAProxy IC Helm chart exposes it. (b) Annotation mapping (`from-to-www-redirect`, `use-regex`/rewrite) needs per-rule testing. (c) hostNetwork rolling-update port-hold during upgrades (same class of issue nginx hit; mitigate with `hostIP`-scoped binds or Recreate). (d) New operational surface for a team that just stabilized nginx.
   - **Effort:** ~2–4 focused days (build two HelmReleases, map annotations, migrate classes, re-issue certs, verify the 4-way isolation matrix), plus a rollback plan.

2. **Keep ingress-nginx + edge-lb (status quo).**
   Lowest immediate effort since it's partly built, but you carry: an extra component (edge-lb), PROXY-protocol/self-check fragility, and a controller whose upstream maintenance ends **March 2026**. Reasonable only as a short bridge.

3. **HAProxy Unified Gateway (one component, Gateway API, two Gateways on two IPs).**
   The only path that is *literally* one component with per-IP isolation. But it's **Gateway-API-only, Ingress support unshipped, GA only since March 2026**, and requires Ingress->HTTPRoute rewrite + cert-manager Gateway support. **Too young and incomplete for this production migration now.** Revisit late 2026 when Unified Gateway ships Ingress support.

**Skeptical summary:** The "universal controller that replaces everything" is real as a *direction* (Unified Gateway) but not as *shippable Ingress reality* in mid-2026. The community HAProxy IC is the pragmatic move: it won't give you one component, but two hostNetwork instances plausibly let you delete **edge-lb** and get off the retiring ingress-nginx — provided the hostPort/`hostIP` detail checks out on the chart.

---

## Sources

- HAProxy Kubernetes Ingress Controller docs — https://www.haproxy.com/documentation/kubernetes-ingress/
- Announcing HAProxy Kubernetes Ingress Controller 3.2 (Jan 13, 2026) — https://www.haproxy.com/blog/announcing-haproxy-kubernetes-ingress-controller-3-2
- Controller startup flags (`--ipv4-bind-address`, `--http-bind-port`, `--ingress.class`, ...) — https://github.com/haproxytech/kubernetes-ingress/blob/master/documentation/controller.md
- ConfigMap options (`bind-ip-addr-http`, `frontend-config-snippet`) — https://www.haproxy.com/documentation/kubernetes-ingress/community/configuration-reference/configmap/
- Ingress annotations reference — https://www.haproxy.com/documentation/kubernetes-ingress/community/configuration-reference/ingress/
- Announcing HAProxy Unified Gateway (Beta) (Nov 11, 2025, KubeCon NA) — https://www.haproxy.com/blog/announcing-haproxy-unified-gateway-beta
- Announcing HAProxy Unified Gateway 1.0 (Mar 2026, KubeCon EU) — https://www.haproxy.com/blog/announcing-haproxy-unified-gateway-1-0
- HAProxy Unified Gateway docs — https://www.haproxy.com/documentation/haproxy-unified-gateway/
- "Ingress NGINX Retirement: Here's Your Path Forward" (maintenance ends Mar 2026) — https://www.haproxy.com/blog/ingress-nginx-is-retiring
- Enable TLS with Let's Encrypt & the HAProxy Ingress Controller (cert-manager HTTP-01) — https://www.haproxy.com/blog/enable-tls-with-lets-encrypt-and-the-haproxy-kubernetes-ingress-controller
- Multi-Tenant Kubernetes Clusters with HAProxy Ingress Controller (per-tenant IP via separate instances) — https://www.haproxy.com/blog/multi-tenant-kubernetes-clusters-with-the-haproxy-kubernetes-ingress-controller
- kube hostPort defaulter under hostNetwork — https://github.com/kubernetes/kubernetes/issues/117689
- GitHub: haproxytech/kubernetes-ingress (Apache-2.0) — https://github.com/haproxytech/kubernetes-ingress

---

## Ingress API vs Gateway API — what we lose if we drop Ingress

*(Added 2026-07-09. This section evaluates moving off the `Ingress` resource entirely, which is what "HAProxy Unified Gateway" would force — see Q1 above.)*

### 1. What each API is, and why Unified Gateway means "no Ingress objects"

- **Ingress API** (`networking.k8s.io/v1`): the original L7 routing resource. **GA since Kubernetes 1.19 (Aug 2020)** and effectively **feature-frozen** — SIG-Network has explicitly stated Ingress will get no new features; everything new goes to Gateway API. It is *maintained* (still shipped in every k8s release, still gets security fixes) but *frozen*. Its power comes almost entirely from **controller-specific annotations**, which are non-portable by design.
- **Gateway API** (`gateway.networking.k8s.io`): the successor, a family of typed CRDs maintained by **Kubernetes SIG-Network** (`kubernetes-sigs/gateway-api`). **Core GA (v1.0) landed Oct 31 2023** (Gateway, GatewayClass, HTTPRoute went `v1`). It has kept moving: **v1.4 (Nov 6 2025)**, **v1.5 (Feb 27 2026)** promoted a batch of features to the Standard channel (ListenerSet, TLSRoute, HTTPRoute CORS filter, client-cert validation, ReferenceGrant), and **v1.6** is current. The API is stable; the *ecosystem completeness* varies wildly by implementation (see below).
- **HAProxy Unified Gateway is Gateway-API-only** (1.0 GA March 2026; Q1). It does not watch `Ingress` objects at all — Ingress support is roadmapped for "later in 2026" and unshipped. So choosing Unified Gateway is not just "a different controller," it is a forced migration of **every** `Ingress` object to `Gateway` + `HTTPRoute`, plus every annotation to either a typed filter or an implementation-specific policy. That is the real cost being weighed here.

### 2. What we LOSE and GAIN moving Ingress -> Gateway API

**Annotations -> typed filters (the good part).** Several things they do with ingress-nginx annotations become **first-class, portable, typed fields** on `HTTPRoute` — no annotations, validated by the API server:

| Their ingress-nginx behavior | Gateway API equivalent | Verdict |
|---|---|---|
| `ssl-redirect` / force HTTP->HTTPS | `HTTPRoute` filter `RequestRedirect` with `scheme: https`, `statusCode: 301` | ✅ First-class, clean |
| `rewrite-target` (simple prefix/path swap) | `URLRewrite` filter (`ReplacePrefixMatch` / `ReplaceFullPath`) | ⚠️ Only prefix/full-path replacement — **no capture-group regex rewrite** |
| `use-regex` + regex path match | `HTTPRoute` path match type `RegularExpression` | ⚠️ **Implementation-specific / optional** — not guaranteed portable; many controllers only do `Exact`/`PathPrefix` |
| `from-to-www-redirect` (auto www<->apex, both directions) | No single equivalent. Must hand-write a dedicated `HTTPRoute` matching the `www.` hostname whose only rule is a `RequestRedirect` setting `hostname` to the apex | ❌ Convenience lost — becomes explicit per-host routes, per direction |
| `configuration-snippet` / raw nginx | Nothing portable — needs an implementation-specific policy CRD or is dropped | ❌ Lost / vendor-specific |

The two that bite them specifically:
- **`from-to-www-redirect`**: ingress-nginx does apex<->www redirection automatically from one annotation. Gateway API has `RequestRedirect` which *can* rewrite the `hostname`, but it is **directional and explicit** — you author a separate `HTTPRoute` for the `www.leadsfilter.com` listener/hostname that redirects to `leadsfilter.com` (301). Doable, but it is now N extra route objects instead of one annotation, and you own the logic.
- **`use-regex` / rewrite**: Gateway API deliberately steers you toward `PathPrefix` matching + `ReplacePrefixMatch`. The `RegularExpression` match type exists but its support is **optional and implementation-defined** — a controller can be fully conformant without it. Any of their rules that rely on nginx regex **with capture groups in the rewrite** have **no guaranteed equivalent** and need redesign or a vendor extension.

**Model differences (mostly a gain for their two-IP problem):**
- **GatewayClass / Gateway / HTTPRoute** split the old monolith by role: the infra owner defines a `Gateway` (listeners, ports, TLS, addresses); app teams attach `HTTPRoute`s. For a single-operator shop this **role separation is overhead, not benefit** — you play all roles.
- **Per-IP binding:** a `Gateway` has `spec.addresses`, but per the spec those addresses apply to the **whole Gateway**, not per-listener — an implementation "MUST bind all Listeners to every address assigned to the Gateway." So the clean way to map two public IPs is **two `Gateway` objects, one per IP** (`.214` and `.66`), each with its own listeners and routes, both served by one controller. **This is the one genuinely attractive property for their setup:** it expresses per-IP isolation *natively in the API* and, unlike the community Ingress controllers (which need two separate controller *instances*, Q2), it could be **one controller watching two Gateways**. Caveat: honoring a **static requested `spec.addresses` is itself implementation-specific** — you must confirm HAProxy Unified Gateway actually programs a caller-supplied IP (many implementations only *report* an assigned address, or need hostNetwork wiring). Unverified for Unified Gateway as of mid-2026.
- **Cross-namespace routing** needs an explicit **`ReferenceGrant`** (an HTTPRoute in ns A referencing a Service/Gateway in ns B must be granted). More secure, more boilerplate. Their current single-namespace-per-brand layout barely needs it.

**cert-manager + Gateway API (the sharp edge):**
- cert-manager supports Gateway API two ways: **gateway-shim** (auto-issues a `Certificate` from annotations on a `Gateway`) and **ACME HTTP-01 via a temporary `HTTPRoute`** instead of a solver `Ingress`.
- It is gated behind **`--enable-gateway-api` / the `ExperimentalGatewayAPISupport` feature gate**, marked **beta since cert-manager 1.15** and **still experimental in 2026** — not yet GA. Open issues in the wild: cert-manager **crashes if the Gateway API CRDs aren't installed**, an **empty-`hostname` listener** validation trap, and — most relevant — cert-manager's own **Nov 26 2025 announcement on ingress-nginx EOL recommends migrating to another *Ingress* controller (it names Traefik) rather than "immediately jumping to Gateway API."** When the certificate tool tells you not to rush to Gateway API, that is a strong tell for a small shop.
- Multi-tenant TLS self-service via Gateway API is still missing pending **XListenerSet** (cert-manager experimental support only in **1.20, Feb 2026**; stable expected 1.21/1.22). Not relevant to two brands you own, but it signals how young this surface is.

**Ecosystem/tooling maturity for a small shop in 2026:** Gateway API the *spec* is mature and GA. **HAProxy Unified Gateway as the *implementation* is ~4 months GA, Gateway-API-only, with unverified static-IP address programming, paired with cert-manager Gateway support that is still experimental.** That stack is **bleeding edge for a two-brand single-node deployment**. `ingress2gateway` **1.0 (Mar 20 2026, SIG-Network)** eases translation (30+ nginx annotations, incl. `use-regex`, path rewrite, CORS) but **explicitly cannot translate `configuration-snippet` and does not cover `from-to-www-redirect`** — it emits warnings and leaves those for manual work.

**Migration cost for their specific annotations:** `ssl-redirect` -> trivial (`RequestRedirect`). Path rewrites -> mostly mechanical *if* they are prefix-shaped; painful if they use regex capture groups. `from-to-www-redirect` -> must be re-authored as explicit per-host redirect routes for each brand. `use-regex` -> depends on whether the target controller supports the optional `RegularExpression` match. Net: **more than an annotation rename — a genuine re-modeling of routing, times two brands.**

### 3. Bottom line

**No — dropping Ingress for Gateway API is not worth it for this setup right now.** The one real prize (native per-IP isolation via two `Gateway`s under a single controller) is undercut by three immaturities stacking on top of each other: Unified Gateway is Gateway-API-only and barely GA, its static-IP address support is unverified, and cert-manager's Gateway HTTP-01 path is still experimental with its own maintainers advising *against* rushing to it. Meanwhile they lose `from-to-www-redirect` as a one-liner and gain no capability their two-brand, single-operator, HTTP-01 setup actually needs. **Ingress remains the pragmatic API for them in 2026** — feature-frozen but stable, fully supported by cert-manager's mature HTTP-01 solver, and served by maintained community HAProxy controllers (next section). Gateway API is the right *destination* to revisit in late 2026/2027 once Unified Gateway ships Ingress + proven static-IP addresses and cert-manager's Gateway support graduates to GA.

---

## Community HAProxy Ingress controllers — deep comparison

*(Added 2026-07-09. There are **two distinct** community HAProxy Ingress controllers. They share a name and heritage but are different codebases, maintainers, and annotation models. Do not conflate them.)*

### A. `haproxytech/kubernetes-ingress` — HAProxy Technologies' own community controller

- **Version/date:** v3.2 line (3.2 announced **Jan 13 2026**), Apache-2.0. Built on HAProxy + the Data Plane API. (This is the controller the main body of this report analyzed.)
- **Maintenance/adoption:** Actively maintained by HAProxy Technologies (the vendor), ~120 releases, and it is **HAProxy's officially recommended immediate ingress-nginx replacement**. Strong production adoption; commercial Enterprise build available.
- **Annotation model & parity with their nginx annotations:** prefix is **`haproxy.org/`** (e.g. `haproxy.org/ssl-redirect`). Concrete parity:
  - `ssl-redirect` -> ✅ `haproxy.org/ssl-redirect` (+ `haproxy.org/ssl-redirect-code`); on by default for TLS ingresses.
  - `from-to-www-redirect` -> ❌ **no equivalent annotation.** Closest is `haproxy.org/request-redirect` (redirect to a different host/port) which you'd hand-configure per host, or handle www at DNS. This confirms Q5's finding.
  - `rewrite-target` -> ❌ **no `rewrite-target`;** instead `haproxy.org/path-rewrite` takes a **regex match + replacement** (e.g. `(.*) /foo\1`). Semantically capable but a **different mental model** — you rewrite the regex form, not nginx's `rewrite-target` + `use-regex` pair.
  - `use-regex` / regex paths -> ✅ via `PathType: ImplementationSpecific`/regex path handling and `path-rewrite` regex. Close, but test each rule.
- **IngressClass / two instances:** ✅ `--ingress.class` per instance + matching `IngressClass`; running **two instances (one per class/IP)** is supported and documented (multi-tenant blog).
- **hostNetwork + per-IP bind:** ✅ per-instance global bind via `--ipv4-bind-address`; run each instance on `hostNetwork` bound to its own public IP (this is the edge-lb-killer from Q3).
- **Native client IP:** ✅ on hostNetwork the controller *is* the edge; original source IP preserved with no PROXY hop.
- **cert-manager HTTP-01:** ✅ clean; terminates TLS, serves `/.well-known/acme-challenge/` like any ingress; per-domain solver must select the right class (same gotcha as today).
- **Helm chart + Flux + `hostIP` (#117689):** chart is `haproxytech/helm-charts` (`kubernetes-ingress`), Flux-friendly HelmRelease. **Update to the open question in Q6:** the chart **does expose `hostIP`** — `daemonset.hostIP` / `deployment.hostIP` (plus `useHostPort`, `useHostNetwork`, `hostPorts.{http,https,stat}`). It is a **single pod-level `hostIP`** (applies to all that pod's hostPorts), **not per-port** — but that is exactly what's needed here: each of the two instances sets its own `hostIP` (`.214` / `.66`), giving two non-conflicting hostPort binds and defusing the #117689 scheduler collision. **This resolves the main open risk in Q6 in HAProxy's favor.**

### B. `jcmoraisjr/haproxy-ingress` — independent long-standing community project

- **Version/date:** **v0.16.1, May 4 2026** (v0.16.0 was Mar 23 2026), embedded **HAProxy 2.8**; v0.17 in alpha. Apache-2.0.
- **Maintenance/adoption:** Long-standing (2,000+ commits, active since ~2017), migrated its engine to **controller-runtime in v0.15**. **Effectively a single-maintainer project (Joao Morais).** Real production adoption and a loyal user base, but **bus-factor 1** is a material risk vs the vendor-backed option A.
- **Annotation model & parity — this is its edge:** prefix is **`ingress.kubernetes.io/`** and its annotation set is the closest of any HAProxy controller to ingress-nginx semantics:
  - `ssl-redirect` -> ✅ `ingress.kubernetes.io/ssl-redirect` (default true, globally overridable via ConfigMap).
  - `from-to-www-redirect` -> ✅ **native `ingress.kubernetes.io/from-to-www-redirect: "true"`** — a **direct 1:1** with the nginx annotation. This is the **only HAProxy controller with a drop-in for it.**
  - `rewrite-target` -> ✅ `ingress.kubernetes.io/rewrite-target`, and with a regex `PathType` it copies path + rewrite-target verbatim (implicit `^` anchor) — behaviorally close to nginx.
  - `use-regex` / regex paths -> ✅ supported via regex path type.
- **IngressClass / two instances:** ✅ IngressClass + `--ingress-class` watch; two instances (one per class/IP) supported.
- **hostNetwork + per-IP bind:** ✅ global per-instance bind via `bind-ip-addr-http` / `bind-ip-addr-tcp`; DaemonSet + `useHostPort` / hostNetwork documented (issues #310/#324 cover client-IP-on-hostNetwork and two-interface binds).
- **Native client IP:** ✅ on hostNetwork; same edge model as option A.
- **cert-manager HTTP-01:** ✅ works as a standard ingress; same per-domain-solver class caveat.
- **Gateway API:** ✅ **v1 support since v0.15** (one deployment can serve Ingress + Gateway API), but **partial** — HTTPRoute Rules/BackendRefs don't support Filters, and Listener port/protocol only implemented for TCPRoute. So its Gateway API is not a substitute for its Ingress path yet.
- **Helm chart + Flux + `hostIP`:** chart at `haproxy-ingress/charts`; DaemonSet + `useHostPort` supported. Per-port `hostIP` exposure is **less clearly documented than option A** — verify before relying on the #117689 workaround (option A's `daemonset.hostIP` is the safer known-good).

### Comparison table

| Dimension | ingress-nginx x2 (today) | haproxytech/kubernetes-ingress | jcmoraisjr/haproxy-ingress | keep nginx + edge-lb |
|---|---|---|---|---|
| Native client IP | ❌ needs edge-lb/PROXY to recover | ✅ hostNetwork = edge | ✅ hostNetwork = edge | ⚠️ recovered via PROXY protocol |
| Per-IP isolation (.214 vs .66) | ✅ two classes + externalIPs | ✅ two instances, per-instance `--ipv4-bind-address` | ✅ two instances, `bind-ip-addr-*` | ✅ edge-lb fronts two IPs |
| cert-manager HTTP-01 ease | ✅ mature (current) | ✅ clean, no hairpin | ✅ clean, no hairpin | ⚠️ PROXY self-check hairpin risk |
| Annotation migration effort | n/a (baseline) | ⚠️ Medium — `haproxy.org/` prefix, `path-rewrite` not `rewrite-target`, **no `from-to-www`** | ✅ **Lowest** — `ingress.kubernetes.io/` prefix, **has `from-to-www-redirect`, `rewrite-target`** | ✅ none (same nginx) |
| Maintenance / EOL status | ❌ **best-effort ends Mar 2026** | ✅ vendor-maintained, active | ✅ active but **single maintainer** | ❌ still on retiring nginx |
| `hostIP` in Helm chart (#117689) | n/a (no hostNetwork) | ✅ `daemonset.hostIP` exposed | ⚠️ verify | n/a |
| Effort to adopt | — | Medium (2–4 days) | Medium, slightly less annotation work | Low now, high debt later |

### Recommendation

**Best replacement target: `haproxytech/kubernetes-ingress` (option A), run as two hostNetwork instances (one per IP).** Rationale: it is **vendor-maintained** (no bus-factor-1 risk), it is HAProxy's officially blessed ingress-nginx successor, and — the deciding new fact — its **Helm chart exposes `daemonset.hostIP`**, which cleanly resolves the #117689 hostPort scheduler conflict that was the main open risk in Q6. It delivers native client IP and lets you delete edge-lb.

**Strongly consider `jcmoraisjr/haproxy-ingress` (option B) if annotation-migration effort dominates the decision** — it is the *only* HAProxy controller with a **1:1 `from-to-www-redirect`** and a real `rewrite-target`, using the same `ingress.kubernetes.io/` prefix family, so it is the lowest-friction paper migration from their current annotations. The trade you accept is **single-maintainer bus factor** and a **less-proven `hostIP` chart story**.

**Top 3 risks (either option):**
1. **hostPort scheduler conflict (#117689)** for two hostNetwork pods on one node — must set per-instance `hostIP` (`.214`/`.66`). Confirmed exposed on option A's chart; **verify on option B's** before committing.
2. **Annotation semantic drift**, concentrated on `from-to-www-redirect` (absent in A, native in B) and regex path-rewrite (`path-rewrite` regex in A vs `rewrite-target` in B) — each brand's redirect/rewrite rules need per-rule testing, not a blind rename.
3. **Operational newness + upgrade port-hold**: two hostNetwork instances hold ports across rolling updates; use `hostIP`-scoped binds and a Recreate/again-verified rollout, on a controller the team hasn't run in production before. For option B specifically, add **single-maintainer sustainability** as a standing risk.

### Sources (added sections)

- Gateway API v1.0 GA (Oct 31 2023) — https://kubernetes.io/blog/2023/10/31/gateway-api-ga/
- Gateway API v1.5: Moving features to Stable (Feb 27 2026) — https://kubernetes.io/blog/2026/04/21/gateway-api-v1-5/
- Gateway API 1.4: New Features (Nov 6 2025) — https://kubernetes.io/blog/2025/11/06/gateway-api-v1-4/
- Gateway API — Gateway resource / addresses semantics — https://gateway-api.sigs.k8s.io/reference/api-types/gateway/
- Gateway API spec (addresses apply to whole Gateway, all listeners) — https://gateway-api.sigs.k8s.io/reference/api-spec/1.5/spec/
- Before You Migrate: Five Surprising Ingress-NGINX Behaviors (Feb 27 2026) — https://kubernetes.io/blog/2026/02/27/ingress-nginx-before-you-migrate/
- Announcing Ingress2Gateway 1.0 (Mar 20 2026) — https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/
- cert-manager Gateway API usage / gateway-shim & HTTP-01 — https://cert-manager.io/docs/usage/gateway/
- cert-manager: Ingress-nginx EOL and Gateway API (Nov 26 2025, recommends another Ingress controller over jumping to Gateway API) — https://cert-manager.io/announcements/2025/11/26/ingress-nginx-eol-and-gateway-api/
- cert-manager ExperimentalGatewayAPISupport (beta since 1.15; XListenerSet in 1.20) — https://github.com/cert-manager/cert-manager/issues/6765
- haproxytech ingress annotations (`haproxy.org/ssl-redirect`, `path-rewrite`, `request-redirect`; no from-to-www) — https://www.haproxy.com/documentation/kubernetes-ingress/community/configuration-reference/ingress/
- haproxytech Helm chart values (`daemonset.hostIP`, `useHostPort`, `hostPorts`) — https://github.com/haproxytech/helm-charts/blob/main/kubernetes-ingress/values.yaml
- jcmoraisjr/haproxy-ingress (Apache-2.0, controller-runtime, Gateway API v1 since v0.15) — https://github.com/jcmoraisjr/haproxy-ingress
- jcmoraisjr/haproxy-ingress releases (v0.16.1, May 4 2026; HAProxy 2.8) — https://github.com/jcmoraisjr/haproxy-ingress/releases
- jcmoraisjr configuration keys (`ssl-redirect`, `from-to-www-redirect`, `rewrite-target`, `bind-ip-addr-http/tcp`) — https://haproxy-ingress.github.io/docs/configuration/keys/
- jcmoraisjr Gateway API support/limitations — https://haproxy-ingress.github.io/docs/configuration/gateway-api/

---

## haproxytech IC — reviews, k0s/k8s compatibility, and operational reality (2026-07-09)

*(Focused follow-up for the concrete migration: k0s v1.35.2 single node, CNI kube-router, Flux GitOps, two `haproxytech/kubernetes-ingress` instances on `hostNetwork` + `daemonset.hostIP` bound to `178.156.239.214` and `5.161.26.66`, replacing two ingress-nginx controllers, cert-manager HTTP-01. This section stress-tests the real shipped product against that plan and separates HAProxy's marketing from user-reported reality.)*

### 1. Compatibility — latest version and the k8s support matrix (the k8s 1.35 question)

- **Latest release (July 2026): `v3.2.12`, released 2026-07-03** (GitHub Releases). The 3.2 line shipped Dec 2025 / announced 2026-01-13 and is on ~monthly patch cadence (3.2.4 Jan, 3.2.5, 3.2.6 Feb 17, … 3.2.10, 3.2.12 Jul). **There is no 3.3 yet.** Underlying engine is **HAProxy 3.2**.
- **Officially supported Kubernetes matrix (from HAProxy's own End-of-Life page):**

  | Controller | Released | EOL | Verified K8s | HAProxy |
  |---|---|---|---|---|
  | **3.2** | 2025-12 | 2027-01 | **1.34, 1.33, 1.32** | 3.2 |
  | 3.1 | 2025-01 | 2026-02 | 1.34, 1.33, 1.32, 1.31, 1.30 | 3.1 |
  | 3.0 | 2024-06 | 2025-06 | 1.30, 1.29, 1.28 | 3.0 |

  **The user's note is confirmed: the latest controller officially tops out at Kubernetes 1.34. Kubernetes 1.35 is NOT listed.** k0s v1.35.2 (k8s 1.35) is one minor above the verified ceiling. HAProxy verifies only the three latest k8s minors at a controller's release time, and 3.2 predates k8s 1.35, so 1.35 was never in-scope for 3.2 — this is a support-matrix lag, not a statement that 1.35 is broken.
- **Is running on 1.35 a real risk or a formality? Overwhelmingly a formality, for THIS controller and workload.** What the controller actually consumes from the API server is all long-GA and **nothing relevant was removed in 1.35**:
  - **Ingress** = `networking.k8s.io/v1` (GA since 1.19; the controller already dropped the old `v1beta1` paths). Stable, not going anywhere.
  - **EndpointSlice** = `discovery.k8s.io/v1` (GA since 1.21). The controller already handles the Endpoints→EndpointSlice transition (changelog: "check for EndpointSlicesMirroring before ignoring Endpoints"). The legacy Endpoints API is *deprecated* (warnings from 1.33) but **still present in 1.35**, so even the fallback path still functions.
  - **Leader election** = `coordination.k8s.io/v1` Lease (GA since 1.19). Unaffected.
  - **IngressClass / IngressClassParams** = `networking.k8s.io/v1`. Stable.
  No API the controller depends on graduated-with-removal or was withdrawn in 1.34→1.35. **The failure mode of "unsupported newer k8s" here is not a crash — it is (a) you are off the vendor's tested/​supported matrix, so a support ticket can be waved away, and (b) latent risk that some *future* 1.3x removes a deprecated API before HAProxy re-verifies.** For a self-hosted, no-paid-support single node that is a low, acceptable risk. **Recommended hedge:** watch for the controller release that lists 1.35 (likely a 3.3 or a late 3.2.x note) and treat 1.35 as "runs fine, unverified" until then. Do a smoke test of Ingress sync + cert issuance after deploy rather than trusting the matrix.

### 2. k0s specifics

- **No haproxytech-on-k0s-specific bug was found** in issues, forums, or blogs. k0s ships **stock upstream Kubernetes** (1.35 here) — the API surface the controller talks to is identical to any other distro, so distro-specific breakage is unlikely.
- k0s **officially documents exposing an ingress controller via `hostNetwork`** (its NGINX Ingress example uses exactly `hostNetwork: true` binding 80/443 on the node), so the hostNetwork edge pattern the plan relies on is a first-class, documented k0s deployment shape — just with a different controller image.
- **kube-router** is k0s's default CNI and also does its service proxy (IPVS) role. This matters **less** in this design precisely because `hostNetwork` bypasses the Service/kube-proxy datapath — packets hit the HAProxy socket on the public IP directly, so kube-router's IPVS service NAT is out of the request path for ingress traffic (it still matters for pod-to-pod and for the controller reaching backend pod IPs / EndpointSlices, which is normal CNI territory and works). No known kube-router⇄haproxytech interaction issue surfaced.
- **k0s caveat unrelated to HAProxy:** k0s manages CoreDNS/kube-proxy/kube-router as reconciled "stack" manifests; don't hand-edit those. Irrelevant to the ingress controller, which is a normal Flux-managed HelmRelease.
- **NLLB (node-local load balancing)** is a k0s multi-node control-plane feature — irrelevant on a single node.

### 3. hostNetwork + `daemonset.hostIP` reality (the #117689 question, verified)

- **The chart exposes `hostIP`.** `haproxytech/helm-charts` `kubernetes-ingress` values include `daemonset.hostIP` (and `daemonset.useHostNetwork`, `daemonset.useHostPort`, `daemonset.hostPorts.{http,https,stat}`). Setting `daemonset.hostIP: 178.156.239.214` on one release and `5.161.26.66` on the other makes each pod's hostPort bind to a **specific** IP.
- **Why this defuses [k8s #117689](https://github.com/kubernetes/kubernetes/issues/117689):** the scheduler's hostPort conflict check treats an unset `hostIP` as `0.0.0.0` (collides with everything), which is what blocks a *second* hostNetwork ingress on the same node. Giving each pod a distinct `hostIP` makes the `(hostIP, hostPort, protocol)` tuples distinct, so the scheduler sees no conflict and the Linux sockets `bind(.214:80)` / `bind(.66:80)` are genuinely separate. **This is the known-good, chart-supported path and it is the single most important reason haproxytech IC fits this two-IP plan cleanly.** Note it is a **pod-level** `hostIP` (applies to all that pod's hostPorts), not per-port — which is exactly right here since each instance owns one IP.
- **DaemonSet vs Deployment:** the chart supports **both** (`kind: DaemonSet` or `Deployment`). On a single node either works; **DaemonSet is the natural choice** (`daemonset.useHostNetwork: true`). Pin each instance to the node via nodeSelector/affinity if the cluster ever grows; on one node it is moot. Each instance gets its own `--ingress.class` + `IngressClass` so they don't fight over the same Ingress objects.
- **Residual gotchas (real, but manageable):**
  - **Rolling-update port hold.** A hostNetwork pod holds `hostIP:80/443` until it terminates; a new pod can briefly fail to bind during a rollout. With distinct `hostIP`s the two instances never collide with *each other*, but each instance can still hiccup against *its own* old pod. Mitigate with a `Recreate`/`maxSurge:0` style rollout or accept a sub-second bind gap. This is inherent to hostNetwork, not HAProxy-specific.
  - **`--http-bind-port` confusion (issue #589):** users hit the container binding 8080 instead of 80. Ensure `daemonset.hostPorts.http: 80` / `https: 443` (and the container ports) are set explicitly rather than assuming defaults.

### 4. Reviews / production feedback — honest severity read

**Vendor marketing:** HAProxy's own benchmark ("twice as fast, lowest CPU vs 4 competitors," ~42k rps vs ingress-nginx ~11.7k, zero errors) is real but is a *vendor* test — treat throughput/latency as directionally true (HAProxy's data plane is genuinely fast and reload-light) but not as a reliability guarantee.

**Shipped reality from GitHub issues (recent, 3.2.x line — the honest part):** the 3.2 series has a visible cluster of **open, unresolved** stability issues from late-2025/early-2026, concentrated around **reloads and the new TCP/CRD machinery**:
- **#765 (Jan 2026, open):** 3.2.10 **reloads every ~10 min with no config change** — controller keeps recomputing a TCP frontend's default backend. High impact on long-lived connections. *TCP-CRD-specific.*
- **#762 (Dec 2025, open):** upgrade 3.1.14→3.2.10 then adding a TCP resource **wedged config deployment** ("unable to find required default_backend"), stuck even after deleting the resource. *TCP-CRD-specific.*
- **#773 (after 3.2.5, open):** `ERROR ingress/ingress.go:145` **right after reload and then every 10–15 min**.
- **#768 (Jan 2026, open, ~9 months reproducible):** **`backend-config-snippet` content and servers intermittently LOST on Ingress recreation / mass pod restart** — backends left with disabled dummy servers until a pod restart. This is the most relevant one to this plan because it hits **config-snippets**, the mechanism you'd lean on for anything not covered by an annotation.
- **#772 (Jan 2026, open, "investigation"):** **memory grows ~8MB/hour** on 3.2.4 in EKS while scanning ~150 ingresses; not reproduced at ~15 ingresses. Suggests a scaling-related leak; **at this deployment's tiny ingress count (two brands, a handful of ingresses) this is unlikely to bite**, but it shows memory hygiene isn't airtight.
- **Upstream #2992:** graceful reload via socket can time out on HAProxy ≥3.2-dev — worth knowing since 3.2 controller bundles HAProxy 3.2.
- Historical memory-leak reports (#99, #312) are old (2019–2021) and not representative of 3.2.

**Interpretation for this migration:** the scariest recent issues (#765, #762, and the reload storms) are **tied to TCP services / the v1→v3 CRD migration**, which **this HTTP-only, cert-manager-HTTP-01 plan does not use** — so they are largely out of scope. The two that *could* touch you are **#768 (config-snippet loss)** and **#772 (memory creep)**, and both are lower-probability at two-brand scale with minimal snippet use. Net: the controller's *HTTP Ingress fast path is solid and battle-tested*; the *new CRD/TCP surface and config-snippet edge cases are where 3.2 is visibly rough*. vcluster's comparison summarizes the tradeoff fairly: HAProxy = high reliability/performance, but richer/more complex config and a **smaller community** than ingress-nginx, so you get less "someone already hit this" coverage. Reddit/HN did not surface concentrated first-hand reliability threads (community is smaller/quieter than nginx's) — absence of noise, not proof of calm.

### 5. cert-manager HTTP-01 — works cleanly, one class gotcha

- **Clean.** The controller terminates TLS and serves `/.well-known/acme-challenge/...` over plain HTTP like any Ingress; cert-manager's temporary solver Ingress/Service/Pod is picked up by whichever HAProxy instance matches the class. **No snippet needed** to serve the ACME path, and **no PROXY-protocol/self-check hairpin** because hostNetwork makes each controller the edge (no L4 pre-hop).
- **The one real gotcha is generic cert-manager, not HAProxy:** with two IngressClasses you MUST steer each domain's solver to the right class. Use **per-solver `http01.ingressClassName`** (or the `acme.cert-manager.io/http01-ingressclassname` annotation) with a domain selector. **Do NOT set both `ingressClassName` and the legacy `class` on the same solver** — cert-manager errors "the fields ingressClassName and class cannot be set at the same time" (issue #6184). Pick `ingressClassName` (modern) consistently. If you set no class, cert-manager creates an unclassed solver that *both* controllers may answer — avoid.
- **ssl-redirect caveat:** a global HTTP→HTTPS redirect can bounce the HTTP-01 token. cert-manager's solver Ingress normally handles this, but if you force redirects, confirm the ACME path is exempt. Standard, well-trodden.

### 6. Annotation migration — exact haproxytech equivalents

Prefix is **`haproxy.org/`**. Concrete mapping from the nginx annotations in use:

| nginx (`nginx.ingress.kubernetes.io/…`) | haproxytech (`haproxy.org/…`) | Notes |
|---|---|---|
| `ssl-redirect` | **`ssl-redirect: "true"`** (+ `ssl-redirect-code: "301"`) | On by default for TLS ingresses; `ssl-redirect-code` default 302 → set 301 if you want permanent. ✅ clean |
| `from-to-www-redirect` | **No equivalent.** Closest = **`request-redirect: "apex.example.com"`** applied to the `www.` host, hand-authored per brand; or handle www at DNS/redirect. ⚠️ **cannot be expressed as one annotation** |
| `use-regex` + `rewrite-target` (with capture groups) | **`path-rewrite: "/foo/(.*) /\1"`** (regex match + replacement, capture groups via `\1`) | Different mental model: one regex-rewrite annotation instead of nginx's `use-regex`+`rewrite-target` pair. Capture groups DO work. Path matching also honors `PathType: ImplementationSpecific`. ⚠️ **test each rule** — semantics close, not identical |
| `server-snippet` (custom **response headers**) | **`response-set-header: Name "value"`** (multiline = multiple headers) | ✅ **First-class and clean** — this is the correct, safe way to add custom response headers; supports multiline for several headers. `request-set-header` for request-side. **You do NOT need a snippet for custom response headers.** |
| `server-snippet` / `configuration-snippet` (arbitrary raw config) | **`backend-config-snippet`** (raw HAProxy directives into the backend section) | ⚠️ **This is the flaky surface (issue #768 — content lost on Ingress recreation).** There is **no `server-snippet` equivalent per se**; frontend-level raw config is `frontend-config-snippet` (global to the instance) or the v3.2 **Frontend CRD**. Minimize reliance here. |

**Cannot be cleanly expressed / caveats:**
- **`from-to-www-redirect`** — no drop-in; becomes explicit per-host `request-redirect`. (This is the single biggest annotation-parity gap; `jcmoraisjr/haproxy-ingress` — see the prior section — is the only HAProxy controller with a true 1:1 for it, if www-redirect ergonomics dominate the decision.)
- **Arbitrary raw config** relies on `backend-config-snippet`, which has the open reliability bug #768; prefer typed annotations (`response-set-header`, `path-rewrite`, `request-redirect`) wherever possible and treat snippets as a last resort.
- v3.2's **user-defined annotations** + the **Ingress-NGINX migration assistant** exist to bridge gaps by generating validated custom annotations/CRDs, but note the roadmap is moving annotations → CRDs during 2026, so expect churn in this area.

### 7. Verdict — is it solid enough to bet two brands on (k8s 1.35 / k0s, 2026)?

**Yes, with eyes open — for this specific HTTP-Ingress + cert-manager-HTTP-01, two-hostNetwork-instance shape.** The fast path this plan uses (L7 HTTP Ingress, TLS termination, `hostIP`-bound hostNetwork edge, HTTP-01) is exactly what the controller does most maturely, and the chart's `daemonset.hostIP` cleanly solves the only hard blocker (#117689). The k8s-1.35 gap is a **support-matrix formality, not a functional breakage**, because every API the controller uses is long-GA and un-removed in 1.35.

**Top 3 risks:**
1. **Off-matrix k8s 1.35 (formality now, latent later).** Runs today; the risk is a *future* k0s minor removing a deprecated API before HAProxy re-verifies, plus "unsupported" if you ever need vendor help. Mitigate: pin/track controller releases, smoke-test after each k0s and controller bump.
2. **`backend-config-snippet` unreliability (#768) + reload-storm class of bugs in 3.2.x.** The reload storms (#765/#762/#773) are TCP-CRD-specific and out of scope for you, but the snippet-loss bug is in scope if you use raw snippets. Mitigate: express everything possible with typed annotations (`response-set-header`, `path-rewrite`, `request-redirect`) and avoid `backend-config-snippet`; the custom-response-header requirement is fully covered by `response-set-header` so this is largely avoidable.
3. **`from-to-www-redirect` has no drop-in** + smaller community than nginx (fewer prior-art answers). Mitigate: hand-author `request-redirect` per brand and test the redirect/rewrite matrix explicitly; budget time for per-rule verification rather than a blind annotation rename.

**Showstopper?** **None found** for this workload. The genuine showstopper-class bugs in 3.2.x are confined to the **TCP/CRD** surface this design doesn't touch. The one thing that would change the verdict is if the migration turns out to *require* heavy `backend-config-snippet` use (then #768 becomes a real hazard and `jcmoraisjr/haproxy-ingress` deserves a second look for its closer nginx-annotation parity). For a plain two-brand HTTP ingress with custom response headers, ssl-redirect, and path rewrites, **haproxytech IC 3.2.12 on k0s 1.35 is a defensible production bet** — provided you smoke-test the off-matrix k8s version and lean on typed annotations over snippets.

### Sources (this section)

- Latest release v3.2.12 (2026-07-03) — https://github.com/haproxytech/kubernetes-ingress/releases
- Supported Kubernetes matrix / EOL (3.2 → K8s 1.34/1.33/1.32) — https://www.haproxy.com/documentation/kubernetes-ingress/community/end-of-life-dates/
- Changelog (drops Ingress v1beta1; EndpointSlicesMirroring handling; v1→v3 CRD deprecations) — https://www.haproxy.com/documentation/kubernetes-ingress/community/changelog/
- Announcing 3.2 (user-defined annotations, Frontend CRD, runtime cert updates, nginx migration assistant) — https://www.haproxy.com/blog/announcing-haproxy-kubernetes-ingress-controller-3-2
- Ingress annotations reference (`ssl-redirect`, `request-redirect`, `path-rewrite`, `response-set-header`, `backend-config-snippet`) — https://www.haproxy.com/documentation/kubernetes-ingress/community/configuration-reference/ingress/
- Helm chart values (`daemonset.hostIP`, `useHostNetwork`, `useHostPort`, `hostPorts`) — https://github.com/haproxytech/helm-charts/blob/main/kubernetes-ingress/values.yaml
- k8s #117689 hostPort defaulter under hostNetwork — https://github.com/kubernetes/kubernetes/issues/117689
- k0s NGINX Ingress via hostNetwork (documented pattern) — https://docs.k0sproject.io/head/examples/nginx-ingress/
- kube-router user guide (default CNI + IPVS service proxy in k0s) — https://www.kube-router.io/docs/user-guide/
- K8s v1.33: Endpoints deprecation / EndpointSlices — https://kubernetes.io/blog/2025/04/24/endpoints-deprecation/
- Issue #765 — 3.2.10 reloads every 10 min (TCP default-backend recompute), open Jan 2026 — https://github.com/haproxytech/kubernetes-ingress/issues/765
- Issue #762 — 3.1.14→3.2.10 upgrade wedges config on TCP resource, open Dec 2025 — https://github.com/haproxytech/kubernetes-ingress/issues/762
- Issue #768 — backend-config-snippet + servers lost on Ingress recreation, open Jan 2026 — https://github.com/haproxytech/kubernetes-ingress/issues/768
- Issue #772 — memory grows ~8MB/h on 3.2.4 EKS at ~150 ingresses, open Jan 2026 — https://github.com/haproxytech/kubernetes-ingress/issues/772
- Issue #773 — post-reload ERROR ingress.go:145 every 10–15 min after 3.2.5 — https://github.com/haproxytech/kubernetes-ingress/issues/773
- Issue #589 — `--http-bind-port=80` binds 8080 (hostNetwork bare-metal) — https://github.com/haproxytech/kubernetes-ingress/issues/589
- Upstream haproxy #2992 — graceful reload timeout on HAProxy ≥3.2-dev — https://github.com/haproxy/haproxy/issues/2992
- cert-manager #6184 — `ingressClassName` vs `class` mutual-exclusion on HTTP-01 solver — https://github.com/cert-manager/cert-manager/issues/6184
- cert-manager HTTP-01 config (`ingressClassName`, `http01-ingressclassname` annotation) — https://cert-manager.io/docs/configuration/acme/http01/
- HAProxy vendor benchmark (twice as fast, lowest CPU vs 4 competitors) — https://www.haproxy.com/company/news/haproxy-kubernetes-ingress-controller-twice-as-fast-with-lowest-cpu-vs-four-competitors
- vcluster: NGINX vs Traefik vs HAProxy ingress comparison — https://www.vcluster.com/blog/nginx-vs-traefik-vs-haproxy-comparing-kubernetes-ingress-controllers
