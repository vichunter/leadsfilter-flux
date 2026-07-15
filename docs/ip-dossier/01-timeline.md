# 01 — Timeline of the investigation

Chronological. Each step: what was asked → what was checked → what was found → what was concluded → whether that conclusion later held.

Markers used: ✅ = still true · ❌ = later refuted (see `03-refuted.md`) · ⚠️ = true but with a caveat.

---

## §1. The starting complaint

> "Раньше сервис был задеплоен в AWS CloudFront и читал реальные IP юзеров из хедеров. Теперь перенёс в собственный кубер. И айпишники не определяются, потому что нет нужных заголовков."

Two ends were checked in parallel: how the app reads the IP, and what the cluster does to the packet.

### 1.1 App side — checked, and it is NOT the problem ✅

> Paths are relative to the app repo root **`LeadsStore/leadstore-back`** (there is no `mortgage-usa/` sub-folder any more — see `00-README.md`). Line numbers re-verified 2026-07-09 after the consolidation.

- **`LeadStore.API/Startup.cs:95-101`** — `ForwardedHeadersOptions`:
  - `ForwardLimit = 3` (:97)
  - `KnownNetworks`: `10.0.0.0/8` (:98), `172.16.0.0/12` (:99), `192.168.0.0/16` (:100)
  - `ForwardedHeaders = ForwardedHeaders.All` (:101)
  - `app.UseForwardedHeaders()` at **:116**
- **`LeadApp.API/Program.cs:28-32`** + `app.UseForwardedHeaders()` at **:67** — ⚠️ **NOT the same pattern.** It trusts **everything**:
  ```csharp
  options.KnownNetworks.Add(IPNetwork.Parse("0.0.0.0/0"));   // Program.cs:31
  options.ForwardedHeaders = ForwardedHeaders.All;           // Program.cs:32
  ```
  *(An earlier draft of this dossier claimed LeadApp.API used the same private-range list. **Wrong** — that was inferred from a grep that only showed lines 28 and 32, never line 31. Corrected here. See `03-refuted.md` R-12.)*
- IP consumers: `LeadApp.API/Controllers/AppController.cs:66` and `LeadApp.API/UseCases/AppSave/Mappers/HttpContextMapper.cs:28` — both `HttpContext.Connection.RemoteIpAddress`.

**Conclusion ✅ (unchanged all session):** `UseForwardedHeaders` rewrites `RemoteIpAddress` from `X-Forwarded-For`, and both apps trust the network the traffic actually arrives from. **The app configuration is not the bug.** The client IP is destroyed *upstream* of the app.

**But note the asymmetry, it matters later:** `LeadApp.API` trusting `0.0.0.0/0` means it will honour an `X-Forwarded-For` from **any** source. Today that is inert (nginx overwrites XFF with what it sees). The moment a genuinely trusted upstream is introduced — Cloudflare (Path C), or a PROXY-protocol edge (Path A) — this becomes a **client-IP spoofing surface**: anything that can reach that app could forge the visitor IP. Worth tightening to the real upstream's ranges as part of whichever path is chosen. Not a blocker; not yet acted on.

### 1.2 Cluster side — the actual cause ✅

`infrastructure/cluster/nginx-ingress/release.yaml` and `release-hfc.yaml` both configure the controller Service as:

```yaml
controller:
  service:
    type: ClusterIP
    externalIPs:
      - "178.156.239.214"     # release.yaml (main / leadsfilter)
      - "5.161.26.66"         # release-hfc.yaml (hfc / homefinanceclub)
```

Mechanism: a packet to the public IP arrives at the node; kube-proxy's iptables rules match `dst=<publicIP>` in **PREROUTING**, DNAT it to the controller pod, and **MASQUERADE (SNAT)** the source to the node IP (so reply traffic routes back). nginx therefore sees `$remote_addr` = node IP, and writes *that* into `X-Forwarded-For`.

**Conclusion ✅:** nginx faithfully forwards what it sees; it sees a masqueraded IP. This held for the whole session and is the root cause.

### 1.3 Why CloudFront "worked" ✅

CloudFront itself put the real visitor IP into `X-Forwarded-For`. The app read the header. kube-proxy's SNAT was irrelevant because the truth was in the HTTP header, not in the TCP source. (This observation later becomes the entire argument for Path C — Cloudflare.)

---

## §2. Dead ends explored and closed

### 2.1 "Can the ingress just add a header with the real IP?" — **No** ✅

nginx can only write what it observes. The source is already masqueraded before nginx accepts the connection. There is nothing to put in the header. Adding annotations/snippets writes the same node IP.

Headers *would* help if a **trusted upstream proxy** put the real IP in XFF — which is exactly what CloudFront did, and what Cloudflare would do (Path C). With nginx as the edge, there is no such upstream.

### 2.2 `externalTrafficPolicy: Local` — **does not apply** ✅

That field only takes effect for `type: NodePort` / `LoadBalancer`. The Services here are `type: ClusterIP` with `externalIPs`, so the field is ignored. Known upstream confusion: ingress-nginx issue **#9749** ("externalTrafficPolicy: Local not working" behind externalIPs).

### 2.3 Official verdict on `externalIPs` ✅ — the decisive fact

ingress-nginx bare-metal docs, verbatim:

> "The `externalIPs` option causes kube-proxy to route traffic sent to arbitrary IP addresses and on the Service ports to the endpoints of that Service. […] **this method does not allow preserving the source IP of HTTP requests in any manner**, it is therefore **not recommended** to use it despite its apparent simplicity."

**Conclusion ✅:** the current topology is structurally incapable of preserving the client IP. Some component must change. This is the load-bearing justification for the whole project.

### 2.4 NodePort bound to a specific IP — **not expressible in k8s** ✅

- `nodePort` sets only a *port number*; NodePort always listens on all node IPs (`0.0.0.0`), on a high port (30000–32767).
- kube-proxy's `--nodeport-addresses` restricts which IPs NodePorts bind on, but it is **global for all Services** — it cannot map ServiceA→IP1 and ServiceB→IP2.
- So "IP1 → controller A, IP2 → controller B" cannot be expressed by the Service API. The mapping must be done **outside**: a real LB, `externalIPs` (loses client IP), hostNetwork with per-IP binds, or manual DNAT.

### 2.5 MetalLB — **does not work on Hetzner Cloud** ✅

MetalLB's own "Cloud Compatibility" doc: ARP is emulated by the virtual network layer, so only platform-assigned IPs resolve; this **breaks MetalLB's L2 mode**, and floating IPs can't be "grabbed" by ARP — you must call the cloud API, which MetalLB can't. BGP isn't available on Hetzner Cloud either. Workaround exists (`invidian/metallb-hcloud-controller`, or the vSwitch route on Hetzner *Dedicated*), but it's an extra moving part.

User independently said "MetalLB ставить пока не будем." Closed.

### 2.6 Hetzner Cloud Load Balancer — **wrong tool for the hiding goal** ✅

Hetzner LB gets its **own dedicated IP** (one per LB), **not** a shared pool. It's still an IP in the customer's Hetzner ASN — it does not hide the origin in the CloudFront sense. It can terminate TLS with a managed Let's Encrypt cert. Useful for HA/client-IP-via-proxy-protocol, useless for anonymity.

---

## §3. ingress-nginx `bind-address` — the "two controllers, two IPs" attempt

Question: can nginx itself bind a specific IP per controller, so two controllers coexist on one node?

**Finding ⚠️:** ingress-nginx **does** have a ConfigMap option `bind-address` ("Sets the addresses on which the server will accept requests instead of `*`").

**But it does not save us:** upstream issues **#2529** and **#7859** — the controller's **startup port-availability check ignores `bind-address`**. It checks port 80 on *all* interfaces. So the first controller takes `178.x:80`, the second sees "Port 80 is already in use" and crash-loops even though *its* `5.x:80` is free. No documented flag disables that check; the `hostIP`-in-podSpec workaround hits k8s **#62112**.

**Conclusion ✅:** two hostNetwork **ingress-nginx** controllers cannot share one node. (This is nginx-specific — see §10, where HAProxy IC *can*, because it takes a real per-instance bind address.)

Also surfaced here: **`kubernetes/ingress-nginx` was archived / went to best-effort ~March 2026** — no further security patches. This became a standing argument for migrating off it.

---

## §4. Cluster topology — discovered the hard way

### 4.1 A wrong node was inspected first ❌→✅

The user first pasted `ip -4 addr` from host **`inc-n1`**:
```
eth0: inet 46.224.26.190/32 metric 100 scope global dynamic
enp7s0: inet 172.20.1.2/32   (private network)
kube-bridge: inet 10.244.0.1/24
```
Neither public IP was present. The assistant concluded **"the cluster is multi-node"** ❌ and added a `nodeSelector` justified by that.

**Refuted by the user:** `inc-n1` belongs to a **different project/cluster** (`inc`). It is not part of leadsfilter at all. The assistant had been reasoning about the wrong machine. See `03-refuted.md` R-08.

Note the `nodeSelector` was *kept* — pinning edge-lb / HAProxy IC to the node that owns the IPs is correct regardless of node count — but the **justification** was rewritten.

### 4.2 The correct node ✅ — and Blocker 3 dissolves

`leadsfilter-n1`:
```
eth0: inet 5.161.26.66/32      scope global            valid_lft forever   preferred_lft forever
eth0: inet 178.156.239.214/32  metric 100 scope global dynamic  valid_lft 65061sec
kube-bridge: inet 10.244.0.1/24
tun1: inet 192.168.254.1 peer 192.168.254.2/32
tun0: inet 192.168.255.1 peer 192.168.255.2/32
```

**Both public IPs are already on `eth0`.** This killed a whole class of worry (see §8, edge-lb Blocker 3): no `ip_nonlocal_bind`, no AnyIP route, no interface surgery. HAProxy can bind them.

How to tell which is the **default** IP (the user asked):
- `178.156.239.214` — `dynamic` (DHCP-assigned by Hetzner), finite `valid_lft` lease, `metric 100` → the server's **primary** IP.
- `5.161.26.66` — no `dynamic`, `valid_lft forever` → **manually added** (the Hetzner Floating IP, persisted in `/etc/netplan/60-floating-ip.yaml`).
- Authoritative check is routing, not `ip addr`: `ip route get 1.1.1.1` → the `src` field is the default source.

`tun0`/`tun1` are the OpenVPN deployments (`infrastructure/cluster/openvpn/`). Irrelevant to ingress, but a reason to bind **specific IPs** rather than `0.0.0.0`.

---

## §5. The project's own history (git) — extremely informative

Searched the Flux repo's git log. Findings:

### 5.1 HAProxy ingress was already tried — and removed ⚠️

`df40563` (2026-04-02) *"remove haproxy ingress, add nginx ingress"*. The diff is just a **directory rename** `haproxy-ingress/` → `nginx-ingress/`, 8 lines changed. The removed config was:

```yaml
# infrastructure/cluster/haproxy-ingress/release.yaml (at df40563^)
chart: kubernetes-ingress
version: ">=1.0.0 <2.0.0"
sourceRef: { kind: HelmRepository, name: haproxytech }
targetNamespace: haproxy-ingress
values:
  controller:
    hostNetwork: true
    service:
      type: ClusterIP
```
Replaced by an identically-shaped ingress-nginx release (`hostNetwork: true`, `type: ClusterIP`). **No reason recorded in the commit message.**

First reading ❌: "an ancient v1.x controller from ~2020, tells us nothing." **This was wrong** — see §10.6 and `03-refuted.md` R-03. The `kubernetes-ingress` **chart** is versioned 1.x *today* (1.52.1), independently of the 3.x controller. So `">=1.0.0 <2.0.0"` was the **current** line and pulled a **current** controller (3.2.x).

Second reading ✅ (and this is the good one): that April config had `hostNetwork: true` with the chart's **default `containerPort` 8080/8443** → HAProxy bound 8080/8443, and **nothing listened on :80/:443**. The site would have appeared dead. **That is exactly Blocker 1 of Path B** (§10.5). The most plausible story: HAProxy IC "didn't work", nobody diagnosed why, it was swapped for nginx within hours. **The history validates our diagnosis rather than warning against the controller.**

### 5.2 Gateway API was already tried — and reverted the same day ✅

- `6dbdad5` (2026-04-13) *"migrate ingress-nginx to NGINX Gateway Fabric 2.5.1"* — body: *"ingress-nginx was archived 2026-03-24 with no further security patches. Replace with NGINX Gateway Fabric using Gateway API v1.5.1."* Converted Ingress→Gateway+HTTPRoute, added www→apex 301s via HTTPRoute, SnippetsPolicy for custom headers, switched the ClusterIssuer to a `gatewayHTTPRoute` solver. Several follow-up fix commits (namespace, `gatewayControllerName`, cert-manager for agent-tls, nginx.config shape…).
- `983791f` (2026-04-13, **same day**) *"revert: rollback NGF migration, restore nginx-ingress"* — body: *"NGINX Gateway Fabric cert-generator creates inconsistent TLS certificates for control plane / data plane communication, making data plane pods unable to connect. Reverting to working nginx-ingress setup until NGF matures."*

**Conclusion ✅:** the Gateway-API *model* wasn't the problem — an NGF control-plane/data-plane cert bug was. But it is a data point that this team already burned a day on a young Gateway-API product.

### 5.3 The runbook `docs/adding-hfc-ip.md` — the scar tissue ✅

Written 2026-04-11 (`126b369`, `2e9ce96`). It documents exactly why today's topology looks the way it does, and it is **required reading**. Key content:

- **Architecture:** two ingress-nginx controllers, `ClusterIP` + `externalIPs`, **deliberately NOT hostNetwork**; isolation via kube-proxy DNAT; classes `nginx` / `nginx-hfc`.
- Hetzner Floating IP attached in console; persisted via **`/etc/netplan/60-floating-ip.yaml`** (never edit `50-cloud-init.yaml` — cloud-init owns it); `chmod 600`; `netplan try`.
- **kubelet pinned** `--node-ip=178.156.239.214` via the k0s systemd unit (`--kubelet-extra-args`), because kubelet auto-detect picked the **wrong** IP.
- Troubleshooting section — the real problems they hit:
  1. **Rolling-update deadlock on hostNetwork** — old and new pod both want `0.0.0.0:80/443`; new can't start until old releases; fixed with `updateStrategy: Recreate`, later removed by dropping hostNetwork.
  2. **Helm three-way merge error** on the `Recreate` switch → needed `spec.upgrade.force: true`.
  3. **hostPort scheduler conflict** — k8s **#117689**: under `hostNetwork: true` the PodSpec defaulter sets `hostPort = containerPort` for every port, at admission level; the chart's `hostPort.enabled: false` **cannot** override it. Two hostNetwork controllers → both claim 80/443/8443 → second Pending. **Their stated fix: don't use hostNetwork with multiple controllers.**
  4. **Wrong node IP → kube-proxy routed to the wrong pod** — the static Floating IP appears in `ip addr` before the DHCP primary (netplan runs before DHCP replies), so kubelet registered `InternalIP = 5.161.26.66`; the hostNetwork primary controller then had pod IP `= .66`, and kube-proxy sent `.66` traffic to the *primary* controller. Fixed by (a) moving off hostNetwork and (b) the `--node-ip` pin.
  5. **Broken Helm release state** after manually deleting a Deployment — the release Secret lives in `flux-system` (`sh.helm.release.v1.<name>.v<rev>`), not the targetNamespace.
  6. **cert-manager challenges stuck `pending`** after splitting controllers — the ClusterIssuer hard-coded one solver class, so solver Ingresses landed on the wrong controller/IP → LE got 404. Fix: per-domain solvers **and** *delete the stuck Order* (cert-manager only reads Issuer config when it **creates** an Order — updating the Issuer does not retro-fix an existing Order).
  7. **Missing `www` DNS stalls a challenge silently** — one Challenge per host in `tls.hosts`; add `www` CNAME → apex; then delete the Order again.

**Why this matters to the current work:** items 1, 3, 4 are exactly the hazards both new paths flirt with. Item 6/7 are exactly the cert-manager traps that Path A's D3 and Path B's H5 must respect.

---

## §6. k0s specifics ✅

- Cluster is **k0s v1.35.2**, single node, CNI **kube-router** (`kube-bridge`).
- kubelet flags go through the k0s controller systemd unit (`--kubelet-extra-args=--node-ip=…`), *not* `k0s.yaml` (`--node-ip` isn't part of `KubeletConfiguration`).
- **CoreDNS is a k0s-managed "stack"** — k0s reconciles it and will **revert live edits**. This matters for Path A's D3 (which needs a CoreDNS `hosts{}` block): a raw `kubectl edit cm coredns` gets undone. Must use the k0s-supported mechanism or Flux.

---

## §7. The real reason for two IPs — and whether it works

The user revealed the actual motive: keep unsophisticated competitors (other lead marketplaces) from noticing that `homefinanceclub.com` (collector) feeds `leadsfilter.com` (marketplace) — and then poisoning the marketplace with fake leads.

**Assessment given (and not contested):**
- Two IPs on one box is **weak** for that goal. Common-ownership links survive via: same ASN/netblock + reverse-IP, passive DNS, **Certificate Transparency logs** (their LE certs for both hosts are already public), nameserver pivot, WHOIS, shared analytics/GTM/Ads/Pixel IDs, shared privacy-policy text, and — decisively — one shared k8s cluster, shared `serviceroom-backend`/`leadapp-api`, and one shared SMTP relay sending `info@` for **both** domains through **one** Google Workspace account.
- **But** against the stated threat model (low-skill, cursory look) the IP split is also the *least useful* layer: such an adversary won't reverse-IP at all. The cheap, high-value measures are: no cross-links between the brands, **separate analytics/GTM/Ads IDs** (a view-source giveaway), separate WHOIS privacy, never naming both brands together.
- **The durable defence against fake-lead stuffing is backend fraud scoring, not obscurity** — and it costs zero conversion, because it runs *after* capture. The user's objection ("капча убьёт конверсию, она и так на грани") is answered by separating **capture** (keep frictionless) from **qualification** (score before the lead enters the marketplace), using the existing `approval_status` / `manual_approve` / `DuplicateLeadFinder` machinery, plus zero-friction signals (honeypot, fill-time, invisible Turnstile/reCAPTCHA-v3 *score only*), and async server-side checks (phone/email validity, IP reputation, rate-limit, anomaly quarantine).
- Compliance sidebar: US lead-gen (TCPA / FTC / RESPA-GLBA for mortgage PII) pushes toward **disclosure** of who leads are shared with; deliberately hiding the path is a legal risk, not a best practice.

**Decision by user:** keep the two IPs anyway; do the IP separation via k8s manifests. Security hardening of the sites is explicitly **out of scope for now** ("я пока не хочу двигаться в эту сторону").

---

## §8. Path A — edge-lb (HAProxy L4 in front)

**Design.** One HAProxy pod, `hostNetwork`, TCP mode, binds `178.156.239.214:80/443` and `5.161.26.66:80/443` separately, forwards each to the matching controller's ClusterIP Service with **PROXY protocol v2** (`send-proxy-v2`); both controllers get `use-proxy-protocol: "true"` and lose their `externalIPs`. TLS keeps terminating at the controllers. Naming chosen: **`edge-lb`** (role-based: an L4 edge load balancer / front proxy — the role a cloud LB or MetalLB would play).

Plan file: `docs/superpowers/plans/2026-07-09-edge-lb.md`.

### 8.1 Timeout design (user asked for a documented config)

TCP mode is inherently minimal — no HTTP-level timeouts exist. Only `connect` / `client` / `server` / `tunnel` / `client-fin` matter, and they are **inactivity** timeouts, not session-length caps. Principle adopted: **edge-lb timeouts must exceed the largest ingress timeout**, so the controller always decides first and edge-lb only reaps genuinely dead connections (not infinite — that leaks FDs). `timeout tunnel` is the important one in TCP mode (governs WebSocket/SSE/long-poll idle once established). Also: don't set an aggressive `hard-stop-after`, or a config reload kills long connections.

### 8.2 Backend addressing

Backends are the **existing** controller Services, addressed by cluster DNS (not hard-coded ClusterIP), with a `resolvers` section pointing at kube-dns `10.96.0.10` so a Service re-creation doesn't need a manual reload. `hold valid 10s` = how long a good DNS answer is trusted.

Service names were **read from the cluster, not guessed** — an early guess was wrong (see §9).

### 8.3 Opus review #1 of Path A — three blockers

1. **BLOCKER — HAProxy can't bind 80/443.** The official `haproxy` image has run as **non-root (UID 99) since 2.4**. The documented escape `--sysctl net.ipv4.ip_unprivileged_port_start=0` is **forbidden on hostNetwork pods** (kubelet → `SysctlForbidden`; k8s #103298, nginx/kubernetes-ingress #3714), and `capabilities.add: [NET_BIND_SERVICE]` alone does **not** survive a non-root UID (k8s doesn't set *ambient* caps — k8s #56374). → Fix: `securityContext.runAsUser: 0`.
2. **BLOCKER — the "atomic single-commit cutover" is a fiction.** The controllers are `HelmRelease`s (helm-controller) while edge-lb is plain manifests (kustomize-controller) — Flux does **not** dependency-order across them (fluxcd/flux2 #293); and even inside one helm upgrade, the ConfigMap reload (proxy-protocol) and the Service reprogram (externalIPs) run on independent loops. Because kube-proxy's externalIP DNAT fires in **PREROUTING**, while externalIPs still exist the traffic never reaches HAProxy — so if proxy-protocol turns on first, live users get `broken header` = **hard outage**. → Fix: **Commit A** (deploy edge-lb, prove it binds, while nginx still owns the IPs → zero traffic to it) then **Commit B** (the flip, manually sequenced in a window). A seconds-long blip is unavoidable; say so.
3. **BLOCKER — public IPs must be locally deliverable** after externalIPs are removed. → **Dissolved**: both are already on `eth0` (§4.2).

Plus: `use-proxy-protocol` is **all-or-nothing** (any non-PROXY connection to the controller's 80/443 breaks → inventory in-cluster callers); readiness probe on `tcpSocket: 443` is wrong (spawns a real PROXY-headed backend connection every cycle and reports healthy even if nginx is down → use a `monitor-uri` frontend bound to `127.0.0.1:8404`); no active `check` is correct here (a bare `check` arrives without a PROXY header → `broken header` noise; `send-proxy-v2` on checks has a spec bug — haproxy #511, opnsense/plugins #2909; and the controller's `10254` healthz is **not exposed on the Service**, so the reviewer's "check 10254" suggestion doesn't apply); PROXY-header spoofing trust (any pod reaching the ClusterIP can forge a client IP); conntrack/RLIMIT_NOFILE/log-volume notes; **no** redirect-loop risk (a pure L4 proxy injects no `X-Forwarded-Proto`, so `ssl-redirect` behaves normally — don't "fix" it by adding `use-forwarded-headers`); single-pod SPOF and a `Recreate` micro-outage on every config edit.

Also corrected: the assistant's own note claiming a **duplicate** `timeout` directive in the `defaults` block was **wrong** — there was no duplicate; the *comments* for `timeout server` and `timeout tunnel` were swapped (both `1h`, so zero runtime effect). See `03-refuted.md` R-11.

### 8.4 The cert-manager landmine (Path A's worst problem)

`use-proxy-protocol: "true"` makes the controller reject **any** connection without a PROXY header. cert-manager's HTTP-01 does an **in-cluster self-check** that fetches the challenge URL with a plain request → `broken header` → self-check fails → **certificates stop issuing/renewing**. Confirmed: cert-manager **#466**, ingress-nginx **#11365**, and a detailed writeup (techblog.schwarz). The current issuer (`infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml`) uses **HTTP-01 for both domains**, so this bites.

Nastiness: the **cutover would look green** (existing certs are valid) and TLS would die silently ~30 days later at renewal.

Three remediations were defined:
- **D1 — switch to DNS-01.** Structurally immune (never touches the ingress path). Needs a cert-manager-supported DNS provider + API token. **Rejected by the user:** "не хотелось бы по днс сертификаты продлять… Разок я могу прописать днс, но автоматически — нет."
- **D2 — hairpin-proxy** (`compumike/hairpin-proxy`, or the Go reimplementation "ouroboros" used by Cozystack). Rewrites cluster-internal DNS so internal requests pass through a small PROXY-adding proxy. Extra component; edits CoreDNS; known issue #10 where its `cluster.local` rewrite breaks DNS-01.
- **D3 — CoreDNS `hosts{}` rewrite (CHOSEN).** Point in-cluster lookups of the four names at the public IP that edge-lb owns, so the self-check hairpins out through edge-lb and *gets* a PROXY header. No extra component. Works because both IPs are local on `eth0`.

### 8.5 Opus review #2 (of D3 specifically)

- **Q3 answered — D3 is not a no-op ✅.** cert-manager's HTTP-01 reachability test builds a custom resolving dialer **only when `dnsServers` is non-empty**; otherwise it uses Go's default resolver → the pod's `/etc/resolv.conf` → **CoreDNS**. That list comes from `--acme-http01-solver-nameservers`, whose **default is empty**. (Sources: cert-manager `pkg/issuer/acme/http/http.go`; controller CLI docs; issue #4286 asking for a custom-DNS flag; a NAT-loopback-via-CoreDNS writeup.) **So the override does reach the self-check — provided this install doesn't set that flag and the pod uses `ClusterFirst`.** → became a required pre-check.
- **Q2 answered ✅.** `hosts{}` is the right plugin (over `template`/`rewrite`); CoreDNS plugin order is fixed by the compiled `plugin.cfg`, **not** textual position, so `hosts` always runs before `kubernetes`/`forward`. **`fallthrough` is mandatory** — without it `hosts` becomes authoritative for the whole `.` zone and NXDOMAINs everything (cluster-wide DNS outage).
- **HIGH-1 — the hairpin is unproven on kube-router** and is the single most likely first-run failure. Both public IPs are real `/32`s on `eth0`, so the kernel installs `local` routes and a pod packet to them is delivered locally; `rp_filter` is unlikely to drop it (it bites on asymmetric *forwarding*, not local delivery). The real hazard is kube-router SNAT quirks (kube-router #376, #511) — harmless for a self-check (the challenge doesn't care about the client IP), but **untested**. Pre-checks added: `ip route get <ip>` must say `local … dev lo`; check `rp_filter` (prefer loose `=2`); optionally `log_martians` + watch `dmesg`.
- **HIGH-3 — the plan tested only the apex names.** `www` is precisely the name at risk (see below) and homefinanceclub wasn't tested at all. → test **all four** names.
- **Q4 — the `from-to-www-redirect` × ACME interaction.** There is **no built-in acme-challenge exemption** in ingress-nginx. `ssl-redirect` is fine (the solver location has redirect effectively off). But `from-to-www-redirect` renders a **separate server block with an unconditional `return 301`**, with no `/.well-known/` carve-out (ingress-nginx #6853, #11315), and cert-manager's self-check **follows redirects**. Saving grace: external LE validation already traverses the same redirect and certs **do** currently issue (an all-or-nothing Order couldn't be Ready otherwise) — so in practice the solver server suppresses the redirect during the challenge window. **Parity holds, but the plan never tested it.**
- **M1 — AAAA gap.** `hosts{}` defines only A records; with `fallthrough`, an AAAA query escapes to the public resolver. If either domain has a real AAAA, the self-check may pick IPv6 — an address edge-lb doesn't bind. → verify no AAAA exists.
- **L1 — CoreDNS ownership.** Confirm who reconciles it (on **k0s: k0s does**, and will revert live edits).
- **L2 —** `hosts{}` also reads `/etc/hosts`; add `no_reverse`.

**Verdict on Path A:** mechanically sound, **not proven safe** until the hairpin is tested end-to-end (all four names → `404`, then a **staging** issuance including a `www` SAN → `Ready=True`).

---

## §9. A naming lesson (small but it cost a round-trip)

The assistant guessed the controller Service names as `nginx-ingress-ingress-nginx-controller`. **Wrong.** Real names (from `kubectl get svc -A`):
- `ingress-nginx-nginx-ingress-controller` (main, externalIP `178.156.239.214`)
- `ingress-nginx-nginx-ingress-hfc-controller` (hfc, externalIP `5.161.26.66`)
- `ingress-nginx-nginx-ingress-controller-admission` (webhook; hfc has `admissionWebhooks.enabled: false`, hence only one)

**Why:** Flux's helm-controller composes the Helm release name as `<targetNamespace>-<HelmRelease.metadata.name>` = `ingress-nginx` + `nginx-ingress` = `ingress-nginx-nginx-ingress`; the chart's fullname template sees the chart name already present and doesn't duplicate; the chart appends `-controller`. The formula is `<targetNamespace>-<release name>-controller`. The stutter comes from someone naming the release the mirror-image of the namespace.

These names change only if you change `metadata.name`, `targetNamespace`, `releaseName`, `fullnameOverride`/`nameOverride`, the chart, or (potentially) upgrade Flux's naming behaviour. Normal ops (restarts, reboots, same-version upgrades, cert renewals, ClusterIP changes) do **not** change them. **Decision: don't pin/rename them now** — user: "пользуемся тем что есть, чтобы не вносить шум."

---

## §10. Path B — migrate to HAProxy Ingress Controller

### 10.1 What the "universal controller" actually is ✅

The user remembered HAProxy moving to a new architecture. It is **HAProxy Unified Gateway** — beta Nov 2025 (KubeCon NA), **1.0 GA March 2026** (KubeCon EU). It is **Gateway-API-only**; Ingress support is roadmapped "later 2026" and **not shipped**. → **Not adoptable** for an Ingress-based setup.

The production replacement is the community **`haproxytech/kubernetes-ingress`** (Apache-2.0, vendor-maintained).

### 10.2 The decisive architectural insight ✅

A **hostNetwork ingress controller is itself the edge** → it sees the real client IP directly (no kube-proxy SNAT) and sets `X-Forwarded-For` itself. That means: **no edge-lb, no PROXY protocol, and no cert-manager hairpin** — Path A's entire fragile chain evaporates. Plus it gets off EOL nginx.

One controller **cannot** do per-IP isolation (its bind address is one global startup flag), so **two instances** are still needed — same topology as today, one per IP.

### 10.3 Ingress vs Gateway API — decided: stay on Ingress ✅

- Ingress API: GA and feature-frozen. Gateway API: GA v1.0 Oct 2023, v1.5 (Feb 2026).
- Annotation fate if migrating to Gateway API: `ssl-redirect` → first-class `RequestRedirect` (clean); `rewrite-target` → `URLRewrite` but **prefix/full-path only, no capture-group regex**; `use-regex` → `RegularExpression` match is **optional/implementation-specific**; **`from-to-www-redirect` → no equivalent** (hand-authored routes); `configuration-snippet` → **lost**.
- Per-IP: `Gateway.spec.addresses` is per-Gateway, so two Gateways *could* express per-IP natively — but static-IP programming is implementation-specific and **unverified** for Unified Gateway.
- cert-manager + Gateway API (`gateway-shim`, `ExperimentalGatewayAPISupport`, beta since 1.15) is **still experimental in 2026**; cert-manager's own Nov-2025 EOL post advises migrating to **another Ingress controller**, not to Gateway API.
- Plus this team already reverted NGF (§5.2).
- **Verdict:** don't drop Ingress now; revisit Gateway API late 2026/2027.

### 10.4 What nginx features are *actually* used — the migration surface is tiny ✅

Audited the whole repo:
- **Ingress annotations, all of them:** `use-regex` ×2, `from-to-www-redirect` ×2, `ssl-redirect` ×1.
- **Controller config (identical on both):** `use-gzip`, `use-gunzip`, `gzip-level: 5`, `gzip-min-length: 1000`, `gzip-types: …`; `server-snippet` with six `more_set_headers` diagnostic headers (`X-Request-Time $request_time`, `X-Upstream-Connect-Time`, `X-Upstream-Header-Time`, `X-Request-Id $req_id`, `X-Served-At $msec`, `X-Served-At-Iso $time_iso8601`).
- **Not used at all:** caching, Lua, ModSecurity/WAF, external auth, rate-limiting, canary, gRPC specials, mirroring, `configuration-snippet`.
- **The `fastcgi_cache` found in the repo is NOT the ingress** — it lives in `apps/lf-prod/hfc-wp/configmap-nginx.yaml`, i.e. the **WordPress pod's own nginx** (php-fpm cache). Untouched by any ingress migration.
- Paths: leadsfilter → `/admin2 /api /portal /shared /serviceroom/admin /serviceroom/api /serviceroom /corp /`; homefinanceclub → `/serviceroom/api/ /serviceroom/ /api/ /wapp/ /` (note the trailing slashes).

**Conclusion ✅:** nothing nginx-exclusive is in use. The user is on nginx by inertia, not necessity.

### 10.5 Opus review of Path B — three blockers, and one of them was catastrophic

1. **BLOCKER 1 — dead entrypoint.** Chart default `containerPort` is **8080/8443**; under hostNetwork there is no port-mapping, so HAProxy binds **8080/8443** and **nothing answers :80/:443** (upstream #589). → set `containerPort.http: 80 / https: 443`.
2. **BLOCKER 2 — `daemonset.hostIP` does NOT give isolation ❌.** It renders only into the k8s **port spec** — a scheduler hint. HAProxy's own default is `--ipv4-bind-address=0.0.0.0`. So **both** instances would bind `0.0.0.0` → second pod `EADDRINUSE`, **and every IP would serve both brands**. Worse: bringing up the hfc instance would have **taken leadsfilter down**. → the real fix is `--ipv4-bind-address=<ip>` per instance via `extraArgs`; `hostIP` is still needed, but **only** to make the scheduler's `(hostIP,port)` tuples distinct (#117689). *This error originated in the research doc and propagated into the plan.*
3. **BLOCKER 3 — `controller.hostNetwork` is not a key ❌.** Helm silently drops it → the pod would run **without** hostNetwork → no native client IP (the whole point). → `controller.daemonset.useHostNetwork: true` + `controller.dnsPolicy: ClusterFirstWithHostNet`.

Plus: **HIGH 4** secondary listeners collide in the shared netns (stat 1024, admin 6060, metrics, QUIC udp/443). **HIGH 5** the hand-authored www redirect can 301 the ACME path → the `www` SAN stalls at renewal ~30 days later (passes cutover, fails later — the classic silent landmine); `request-redirect` takes a **host or host:port only**, does **not** force scheme, and the code is a **separate** annotation (nginx's `from-to-www` used 308). **MEDIUM 6** `compression-algo`/`compression-type` are **not real keys** (compression unsupported — #196), and `use-gunzip` has no equivalent at all. **MEDIUM 7** `ssl-redirect` **defaults to false** and `leadsfilter.yaml` has **no** ssl-redirect annotation today (it relies on nginx's implicit behaviour) → HTTPS-forcing would be silently lost. **MEDIUM 8** duplicate `--ingress.class` (chart emits it from `ingressClass`). **MEDIUM 9** the `response-set-header` example was malformed (`Name "value"` is the syntax; `%[unique-id]` renders empty without `unique-id-format`). **MEDIUM 10** conntrack/DNAT race at cutover. **MEDIUM 11** the path list missed `/serviceroom/admin`; `Prefix` (`path_beg`) semantics differ from `use-regex`. **LOW** DaemonSet image-bump bind gap; disable the Service and **never** add `externalIPs`; k8s 1.35 off-matrix is a formality; `df40563` is not a config template.

### 10.6 Verification round 1 — the controller's own flag docs

Checked `documentation/controller.md` upstream because the whole Blocker-2 fix rested on one flag existing.

| Flag | Default | Notes |
|---|---|---|
| `--ipv4-bind-address` | `0.0.0.0` | **exists** — "Customize the IPv4 binding address." |
| `--ipv6-bind-address` | `::` | ← **new problem found here** |
| `--disable-ipv6` | `false` | |
| `--http-bind-port` | `8080` | independently confirms Blocker 1 |
| `--https-bind-port` | `8443` | |
| `--ingress.class` | — | correct flag name in v3.x |
| `--empty-ingress-class` | `false` | good default: each instance ignores the other's Ingresses |

These are flags of the **ingress-controller binary**, **not** of `haproxy` itself (haproxy binds whatever its generated config says; the controller renders the `bind` lines).

**NEW BLOCKER 2b (missed by the Opus review):** `--ipv6-bind-address` defaults to `::`, so both instances would also bind `:::80/:::443` → second pod `EADDRINUSE` **even with distinct IPv4 binds**; and with Linux's default `net.ipv6.bindv6only=0`, a `::` bind **also accepts IPv4** → brand isolation leaks. → `--disable-ipv6` per instance.

### 10.7 Verification round 2 — reading `values.yaml`

Confirmed `daemonset.{useHostNetwork,useHostPort,hostIP,hostPorts}`, `containerPort.{http:8080,https:8443,stat:1024,admin:6060}`, `dnsPolicy: ClusterFirst`, `extraArgs: []`, `service.{enabled:true,type:NodePort,enablePorts.quic:true,externalIPs:[]}`, `ingressClass`/`ingressClassResource`, `nodeSelector`, `config`.

Three findings:
- **`ingressClassResource.enabled` does not exist** (only `{name, default, parameters}`) — the plan had it; Helm would silently drop it. Removed.
- **No `securityContext`/`runAsUser`/capabilities block** — instead `unprivileged: true`, `allowPrivilegedPorts: false`, `enableRuntimeDefaultSeccompProfile`, `allowPrivilegeEscalation`.
- `prometheus.enabled: true` and `pprof.enabled: true` **by default** → *more* listeners to collide (HIGH 4 worse than thought).

At this point the assistant "fixed" Blocker 1 with **`allowPrivilegedPorts: true`** ❌ — **wrong, and harmful.** See next round.

### 10.8 Verification round 3 — downloading the chart (the round that ended the guessing)

Downloaded `kubernetes-ingress-1.52.1.tgz` and read the templates. This is where it all resolved:

- `_podspec.tpl:58` — `{{- if $useHostNetwork }}hostNetwork: true{{- end }}`, fed from `daemonset.useHostNetwork` → **Blocker 3 fix correct**.
- `_podspec.tpl:106-107` — `- --http-bind-port={{ $ctlr.containerPort.http }}` / `--https-bind-port={{ … }}` → **containerPort drives the real bind. Blocker 1 confirmed.**
- `_podspec.tpl:181-185` — `hostPort` gated by `$useHostPort`; **`hostIP` rendered only into the port spec** → **Blocker 2 confirmed: hostIP never reaches HAProxy's bind.**
- `_podspec.tpl:108` — QUIC args gated on `and (semverCompare ">=1.24.0-0" …) $ctlr.service.enablePorts.quic`, evaluated **independently of `service.enabled`** → **`service.enablePorts.quic: false` DOES disable the QUIC listener.** (This *refutes* the assistant's earlier claim that `enablePorts.quic` only gates the Service — R-07.)
- `_podspec.tpl:123` — `--ingress.class` emitted from `controller.ingressClass` → don't duplicate in `extraArgs` (MEDIUM 8 confirmed).
- `_podspec.tpl:128-129` — **`--publish-service` gated by `publishService.enabled`, which defaults to `true`** → it would point at the Service we disable. **New finding** → `publishService.enabled: false`.
- `_podspec.tpl:134-138` — `--prometheus` / `--pprof` gated by the (default-true) `prometheus.enabled` / `pprof.enabled`.
- `_podspec.tpl:160` — `extraArgs` appended **after** the built-ins → our `--ipv4-bind-address` / `--disable-ipv6` land fine.
- `_podspec.tpl:163-175` — the securityContext block is rendered **only if `unprivileged`**; it sets `runAsUser: 1000` and `capabilities: {drop: [ALL], add: [NET_BIND_SERVICE]}`.
- `_helpers.tpl:185` + `README.md:346` — **`allowPrivilegedPorts` works by injecting the sysctl `net.ipv4.ip_unprivileged_port_start=0`.** And namespaced `net.*` sysctls are **forbidden on hostNetwork pods** (kubelet → `SysctlForbidden`). ⇒ **the assistant's `allowPrivilegedPorts: true` fix would have made the pod be rejected.** ❌ See R-02.
- `ci/daemonset-privileged-ports.values.yaml` (the vendor's own CI case) contains **only**:
  ```yaml
  controller:
    kind: DaemonSet
    containerPort: { http: 80, https: 443, stat: 1024 }
  ```
  i.e. defaults elsewhere — implying the `unprivileged: true` + `NET_BIND_SERVICE` path does bind <1024.
- `Chart.yaml`: `name: kubernetes-ingress`, `version: 1.52.1`, `appVersion: 3.2.12`, **`kubeVersion: '>=1.23.0-0'` — a minimum with NO upper bound** ⇒ **k8s 1.35 installs cleanly**; "off-matrix" is a vendor *support-doc* statement, not a chart constraint.

### 10.9 The version confusion — resolved ✅

The repo hosts **three charts**, which is what tripped the assistant up (it briefly read the `haproxy` chart's entries and thought controller 3.3.10 existed ❌ — R-09):

| Chart | What | Chart ver | appVersion |
|---|---|---|---|
| `haproxy` | standalone HAProxy | 1.29.0 | 3.3.10 (image annotation says `haproxy-alpine:3.3.6` — even *these* disagree) |
| `haproxy-unified-gateway` | Gateway API product | — | — |
| **`kubernetes-ingress`** | **the ingress controller** | **1.52.1** | **3.2.12** (2026-07-03) |

For our chart: **chart 1.52.1 → controller 3.2.12 → HAProxy 3.2.x engine (inside the image)**. `image.tag` defaults to appVersion → `docker.io/haproxytech/kubernetes-ingress:3.2.12` (confirmed via the index's `artifacthub.io/images` annotation). Lesson: trust the image annotation over `appVersion`.

**And this is what rewrote the history:** the chart line is **1.x today**, so the April pin `">=1.0.0 <2.0.0"` was the **current** line → it ran a **current** controller with `hostNetwork` and default `containerPort` → **nothing on :80/:443** → Blocker 1. See R-03.

### 10.10 Verification round 4 — rendering both instances offline

`helm` isn't installed on the workstation; the binary (v3.16.3) was downloaded into the scratchpad. `helm template` is **offline** — no API-server contact, no kubeconfig, nothing installed (only `--validate` would touch a cluster; it was not used). Rendered with `--kube-version 1.35.2` so version-gated templates (QUIC) match the real cluster.

Result (both instances):
```
hfc :  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy-hfc
       --ipv4-bind-address=5.161.26.66      --disable-ipv6
main:  --http-bind-port=80  --https-bind-port=443  --ingress.class=haproxy
       --ipv4-bind-address=178.156.239.214  --disable-ipv6
```
- `hostNetwork: true` ✅ · `dnsPolicy: ClusterFirstWithHostNet` ✅
- **No** `--quic-*`, **no** `--prometheus`, **no** `--pprof`, **no** `--publish-service` ✅
- **No** Service object, **no** sysctls, **no** securityContext ✅
- `nodeSelector: kubernetes.io/hostname: leadsfilter-n1` ✅
- Scheduler tuples distinct → **#117689 defused**: `hfc (5.161.26.66, 80/443/1024)` vs `main (178.156.239.214, 80/443/1026)` ✅
- `--ingress.class` emitted exactly once per instance, distinct classes ✅

### 10.11 Verification round 5 — the container's default user (last config unknown)

`unprivileged: false` makes the chart render **no securityContext**, so the container runs as the **image's** default user. If that were non-root, the <1024 bind would fail (exactly the edge-lb trap).

Queried the Docker registry API directly (token → manifest index → amd64 manifest → config blob):
```
haproxytech/kubernetes-ingress:3.2.12 (linux/amd64)
User       : None          <-- no USER  =>  runs as ROOT
Entrypoint : ["/start.sh"]
```
**✅ `unprivileged: false` is correct** — root, binds 80/443, no caps/sysctl needed.

**Contrast worth remembering:** the *official* `haproxy:3.2` image (Path A's edge-lb) is **non-root UID 99**; the **haproxytech controller image is root**. Different images, different defaults — do not generalize.

---

## §11. Path C — Cloudflare (raised late, deferred)

The user proposed fronting everything with a reverse proxy on a **shared IP pool** with free certs — i.e. what CloudFront used to do — and asked whether Hetzner's LB gives a shared IP.

- **Hetzner LB: dedicated IP, not shared** → doesn't hide the origin. Wrong tool.
- **Cloudflare free** is the direct CloudFront equivalent: shared anycast IPs across **all** proxied hostnames, free Universal SSL, real client IP via `CF-Connecting-IP`/`X-Forwarded-For`.
- **Why it would dissolve the whole project:** with a CDN in front, the real IP arrives in an **HTTP header** again → kube-proxy's SNAT stops mattering → **no edge-lb, no PROXY protocol, no HAProxy migration, no hostNetwork**. Keep today's nginx; just trust Cloudflare's ranges. And with a **Cloudflare Origin Certificate** (free, 15-year, Full-strict) even **cert-manager/HTTP-01 disappears** — killing Path A's D3 hairpin and Path B's H5 landmine at once.
- **Caveat that makes or breaks it:** a CDN only hides the origin if the origin **firewall allowlists only Cloudflare** *and* the currently-exposed IPs are **rotated** — `178.156.239.214` / `5.161.26.66` are already public via passive DNS and **Certificate Transparency** (their LE certs are logged). Otherwise the hiding is theatre.
- **Strongest variant:** **Cloudflare Tunnel** (`cloudflared`) — origin dials **out**; no inbound public IP or open ports at all; nothing to scan.
- **Free-tier limits (user asked):** there is **no published bandwidth cap because there isn't one**. The real boundary is **content type** — Self-Serve ToS §2.8 forbids using the CDN as a video-streaming / large-file-distribution / object-storage service. Real reports: **15–20 TB/month on free** running for months without issue. Enforcement is soft: they **ask** you to upgrade; they do **not** cut traffic or bill overage (unlike Vercel). For HTML/API/WordPress lead-gen traffic this is effectively unlimited; only bulk media through the CDN cache would trigger it (→ use R2/Stream for that).
- Other options noted: keep AWS CloudFront (ACM certs), Fastly, Bunny.net, Azure Front Door; self-hosted `frp`/tunnels (but then the front IP is yours again → less anonymity).
- Risks: dependency on Cloudflare; they see all traffic (PII) — though AWS CloudFront was the same posture; **bot challenges could hurt conversion** → keep security low / off on lead-capture paths; the CF IP list must be kept current for XFF trust.

**Status:** explicitly deferred — *"клаудфлэр пока не рассматриваем"*. Recorded because it is, on the evidence gathered, the cheapest and lowest-risk answer to both the client-IP problem **and** the original origin-hiding goal.

---

## §12. Where the session ended

- User leans to **Path B**. Path B's plan is verified down to the last chart key; **config-level unknowns are zero**.
- Remaining risk on B is **runtime only**: H5 (`www` redirect vs the ACME path — the ~30-day silent landmine), M7 (add explicit `ssl-redirect` to **both** brands), M11 (path precedence when dropping `use-regex`), M10 (conntrack/DNAT race at cutover), and simply "does it bind and does traffic flow".
- **Proposed next step:** a dry run — deploy the hfc instance while nginx still owns `5.161.26.66` via externalIP (so HAProxy receives no traffic), and confirm the pod schedules and binds `5.161.26.66:80/443`. Prove the bind before the flip. *Not yet done.*
