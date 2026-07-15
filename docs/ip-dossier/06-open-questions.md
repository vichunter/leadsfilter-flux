# 06 — Open questions, and what is SETTLED

Two lists. The second one exists to stop you re-litigating.

---

## PART 1 — Genuinely open

### O-0 ✅ **CLOSED 2026-07-15** — yes, but only with five extra flags

**Answered offline** — by reading the controller source and by running both instances in a kind replica. It never needed a cluster, let alone prod. Full write-up: **`09-runtime-verification.md`**; ready values: **`lab/values-{hfc,main}.yaml`**; reproduce: **`lab/verify.sh`**.

**The answers:**
1. Does `--ipv4-bind-address` scope healthz (1042)? — **No.** `pkg/controller/controller.go:245` hardcodes the string `"0.0.0.0:%d"`. The flag is consumed **only** by the http/https/TCP/QUIC frontend handlers.
2. Does it scope stat, and does `containerPort.stat` move that bind? — **No and no.** `controller.go:267` hardcodes `"*:%d"`; the main instance rendered `containerPort.stat: 1026` and still bound `*:1024`. **`containerPort.stat` is declaration-only — the R-01 failure, third repeat.**

**But the premise of the question was wrong in three ways:**
- *"there is no flag to move or disable it"* — **`--healthz-bind-port` exists** (`flags.go:105`).
- *"there is no `--stat-bind-port`"* — it is **`--stats-bind-port`**, plural (`flags.go:95`). One letter kept this question "unresolvable".
- *"the second dies with `EADDRINUSE`"* — **it does not.** haproxy binds with **`SO_REUSEPORT`**: both instances bind the same `addr:port`, both pods go `1/1 Running`, and the kernel picks an answerer at random. The failure is **silent**, not loud. (Only the two Go listeners raise `EADDRINUSE`, and the controller merely logs it and keeps running.)

**Also unscoped, and missed by everyone until the dump was read unfiltered:** haproxy **peers** on `<nodeIP>:10000` (`--localpeer-port`), and the Go **default backend** on `:6061` (`--default-backend-port`). Five unscoped listeners total, not one.

**So: the design as written does not work; the design is salvageable.** Give each instance distinct `--healthz-bind-port`, `--stats-bind-port`, `--default-backend-port`, `--localpeer-port`, plus `--controller-port=0`. Verified: zero collisions, both brands served, isolation matrix clean, real client IP at the backend.

**New cost that came with the answer:** those five listeners are all-interfaces, so after migration they are reachable on **both public IPs** (nothing binds them today). They cannot be disabled — the binds are unconditional in the source. → `09` §5. **Decision (user): accept, block with the Hetzner Cloud Firewall.**

### O-1 ✅ **CLOSED 2026-07-15** — no, the redirect does not swallow the ACME path

Tested in the replica by creating the exact shape cert-manager's HTTP-01 solver creates (an Ingress with an `Exact` path per token), with **both** the `www`→apex redirect and `ssl-redirect` live:

```
without the solver Ingress:   apex → 301   www → 301
with    the solver Ingress:   apex → 200   www → 200
```

**The solver wins**, on both names. Mechanism, now understood rather than hoped for: haproxy consults `path-exact.map` **before** the prefix maps, and the redirect annotations attach to *their own* Ingress/backend, not to the frontend — the solver Ingress carries no redirect annotation, so nothing redirects it. See `09-runtime-verification.md` §4.3.

**Residual:** a real Let's Encrypt **staging** issuance including a `www` SAN was not performed (no ACME server in the replica). The mechanism is proven; the belt-and-braces confirmation is still worth doing at cutover.

**Unrelated but found while testing this — a real regression:** `request-redirect` cannot emit `https://` at all, so `https://www.brand.com` → **plaintext** `http://brand.com` → `https://brand.com:443`. nginx's `from-to-www-redirect` preserves the scheme. → `09` §4.2.

<details><summary>Original question (kept for context)</summary>

### O-1 🔴 H5 — does the `www` redirect swallow the ACME challenge path? *(the silent landmine)*
**Applies to:** Path B primarily; Path A's D3 too.
**Why it's dangerous:** it **passes the cutover** (existing certs are valid for ~30 more days) and then the `www` SAN **fails to renew** weeks later, silently. This is the one failure that a green cutover will not reveal.
**What's known:** ingress-nginx renders `from-to-www-redirect` as a **separate server block with an unconditional `return 301`, no `/.well-known/` carve-out** (#6853, #11315), and cert-manager's self-check **follows redirects**. Counter-evidence: external LE validation already traverses the same redirect **and certs do issue today** — an all-or-nothing Order couldn't be Ready otherwise. So it probably holds. **Probably is not good enough for a 30-day fuse.**
**How to settle:** with the redirect Ingress live, from a throwaway pod curl `/.well-known/acme-challenge/probe` for **all four** names — expect **404** everywhere (a **301** on a `www` name = confirmed broken). Then force a **Let's Encrypt STAGING** issuance that **includes a `www` SAN** → `Ready=True`.
**Escape hatches if broken:** scope the redirect away from `.well-known`; drop the redirect during issuance; or switch to `jcmoraisjr/haproxy-ingress` (has a true 1:1 `from-to-www-redirect`).
</details>

### O-2 🟡 Runtime behaviour of Path B — **mostly answered in a replica**, cutover still open
Answered 2026-07-15 in the kind lab (`09-runtime-verification.md`, `lab/`):
- does the pod schedule and **actually bind** `<ip>:80/443`? — ✅ yes, `192.168.160.91:80` / `:443`, not `0.0.0.0`, not 8080
- does the second instance come up without `EADDRINUSE`? — ✅ **with the five extra flags**. Without them there is no `EADDRINUSE` either — there is `SO_REUSEPORT`, which is worse (O-0)
- does traffic flow, and does the app see the **real client IP**? — ✅ `X-Forwarded-For: <real client>`, both instances
- does the 4-way **isolation matrix** hold? — ✅ own IP → 301, wrong IP → 404, both directions

**Still open (a replica cannot answer):** the cutover itself — conntrack/DNAT race (M10), the seconds-long blip, real traffic volume/memory/reload cadence, and a real LE staging issuance.

**The originally-proposed dry run is no longer the decider** — it was meant to settle O-0, which is now settled offline. It is still worth doing as the last check before the flip, but it is confirmation, not discovery.

### O-3 ✅ **CLOSED 2026-07-15** — no, it does not, and `containerPort.stat` does not move it either
`--ipv4-bind-address` does **not** scope the stat listener: `pkg/controller/controller.go:267` hardcodes `"*:%d"`. And `containerPort.stat` never reaches the bind — the main instance rendered `containerPort.stat: 1026` and bound `*:1024` anyway. **The HIGH-4 mitigation as written is inert.** The real control is `--stats-bind-port` (plural) in `extraArgs`. Note `--stats-bind-port=0` is **not** a way to disable it: haproxy rejects the config (`'bind' invalid port '0'`) and the instance never binds 80/443. → `09` §2, §4.4.

### O-4 🟡 Node count of the leadsfilter cluster — never actually confirmed
`kubectl get nodes -o wide` was **never run**. The single-node assumption comes from the user's statement ("он один"). It doesn't change any decision (the `nodeSelector` pins to `leadsfilter-n1` either way), but it is an unverified premise. **One command settles it.** *(Reminder: `inc-n1` is a different cluster — R-08.)*

### O-5 🟡 Is the `5.161.26.66` netplan entry actually present *now*?
`docs/adding-hfc-ip.md` documents creating `/etc/netplan/60-floating-ip.yaml`, and `ip addr` shows the address with `valid_lft forever` (consistent with a static config). **Not directly verified this session** — `cat /etc/netplan/60-floating-ip.yaml` was never run. If it were only a live `ip addr add`, a reboot loses the IP. One command.

### O-6 🟡 Path A only: which in-cluster clients hit the controller Services on 80/443?
Once `use-proxy-protocol: true` is on, **any** connection without a PROXY header breaks. An inventory was **planned but never executed**: grep the repo for `ingress-nginx-nginx-ingress-controller`, `ingress-nginx-nginx-ingress-hfc-controller`, the ClusterIPs `10.104.135.28` / `10.97.6.254`, and the public hostnames; and grep current nginx access logs for pod-CIDR (10.x) sources on :80/:443. *(A pod calling the **public hostname** is fine — it traverses edge-lb. Only direct ClusterIP/Service-name callers break.)* Moot if Path B is chosen.

### O-7 🟡 Path A only: on k0s, how do you legitimately patch CoreDNS?
k0s manages CoreDNS as a **stack and reverts live edits**. The D3 `hosts{}` block must go in via a k0s-supported mechanism or Flux. **The exact mechanism was never established.** Moot if Path B is chosen.

### O-8 🟢 `LeadApp.API` trusts `0.0.0.0/0`
`LeadApp.API/Program.cs:31`. Inert today, but a **client-IP spoofing surface** as soon as a trusted upstream exists (Cloudflare, or a PROXY-protocol edge): anything that can reach the app could forge the visitor IP. Should be tightened to the real upstream's ranges as part of whichever path is chosen. Not a blocker. See R-12.

### O-9 🟢 Does any backend force-gzip for clients that don't accept it?
Only matters because HAProxy **cannot** decompress (no `use-gunzip` equivalent). Impact assessed as low. Unverified.

### O-10 🟢 Do the domains have AAAA records?
Only matters for Path A's D3 (an AAAA would let the self-check pick an IPv6 that edge-lb doesn't bind). `dig +short AAAA` on all four names. Not run.

---

## PART 2 — SETTLED. Do not re-open.

Each of these cost real time. They are answered.

| Question | Answer | Where |
|---|---|---|
| Is the app's ForwardedHeaders config the bug? | **No.** Both apps read XFF correctly; the IP is destroyed upstream | `02` §… / `01` §1.1 |
| Can we fix this with headers/annotations on the ingress? | **No** — nginx can only forward what it sees, and the source is already masqueraded | `01` §2.1 |
| Will `externalTrafficPolicy: Local` help? | **No** — only applies to NodePort/LoadBalancer, not ClusterIP+externalIPs | `01` §2.2 |
| Can `externalIPs` ever preserve client IP? | **No** — official docs: *"does not allow preserving the source IP … in any manner"* | `01` §2.3 |
| Can a NodePort bind one specific IP? | **No** — port only; `--nodeport-addresses` is cluster-global | `01` §2.4 |
| MetalLB on Hetzner Cloud? | **L2 doesn't work** (ARP emulated); BGP unavailable. Also user-rejected | `01` §2.5 |
| Does Hetzner LB give a shared/anonymous IP? | **No — dedicated IP per LB.** Wrong tool for hiding | `01` §2.6, `04` Path C |
| Two hostNetwork **ingress-nginx** controllers on one node? | **No** — `bind-address` exists but the startup port check ignores it (#2529/#7859); plus #117689 | `01` §3 |
| Are both public IPs on the node's interface? | **Yes**, both on `eth0` — no interface work needed | `02` §1.2 |
| Which IP is the node's primary/default? | **`178.156.239.214`** (DHCP `dynamic`, lease, `metric 100`); `5.161.26.66` is the static Floating IP | `02` §1.3 |
| Is `inc-n1` part of this cluster? | **No** — different project/cluster | R-08 |
| Can you infer a pod's egress IP from the node's default route? | **No** — Google saw the smtp-relay as `5.161.26.66` while the node's default source is `178.x` | `02` §1.6 |
| What are the controller Service names? | `ingress-nginx-nginx-ingress-controller` / `…-hfc-controller`; formula `<targetNamespace>-<release>-controller`. **Read them, don't derive** | `02` §2.2, R-10 |
| Is the "universal controller" adoptable? | **No** — HAProxy Unified Gateway is **Gateway-API-only**; Ingress not shipped | `01` §10.1 |
| Should we move to Gateway API? | **No, not now** — `from-to-www-redirect` has no equivalent, snippets are lost, regex-rewrite limited, cert-manager Gateway support still experimental; and this team already reverted NGF in a day | `01` §5.2, §10.3 |
| Do we need nginx specifically (caching? special features)? | **No.** Only gzip + ssl-redirect + use-regex + from-to-www + 6 debug headers. **No caching at the ingress** — the `fastcgi_cache` is the WordPress pod's own nginx | `02` §3 |
| Latest `kubernetes-ingress` version? | **chart 1.52.1 → controller 3.2.12 → HAProxy 3.2.x**. There is **no** 3.3 controller (3.3.10 belongs to the *other* chart) | `02` §4.1, R-09 |
| Does k8s 1.35 break the chart? | **No** — `kubeVersion: '>=1.23.0-0'`, no upper bound. "Off-matrix" = no vendor ticket, not a functional risk | `02` §4.2 |
| Does `daemonset.hostIP` give per-IP isolation? | **NO.** Port-spec/scheduler only. Need `--ipv4-bind-address` | **R-01** |
| Does `--ipv4-bind-address` exist, and on which binary? | **Yes**, default `0.0.0.0`, on the **ingress-controller binary** (not `haproxy`) | `02` §4.5 |
| Is IPv6 a problem? | **Yes** — `--ipv6-bind-address` defaults to `::` → collision + IPv4 leak → **`--disable-ipv6`** | `01` §10.6 |
| Does `allowPrivilegedPorts: true` fix the <1024 bind? | **NO — it breaks the pod** (injects a sysctl forbidden on hostNetwork) | **R-02** |
| Then how does the controller bind 80/443? | `containerPort: {http: 80, https: 443}` + **`unprivileged: false`**; the image has **no `USER` → root** | `02` §4.7 |
| Is `controller.hostNetwork` a valid key? | **No** — `daemonset.useHostNetwork` (+ `dnsPolicy: ClusterFirstWithHostNet`) | **R-04** |
| Does `service.enablePorts.quic: false` disable the QUIC listener? | **Yes** — it gates the controller **args**, independently of `service.enabled` | **R-07** |
| Does the chart support gzip? | **No** — unsupported (#196). Drop it | **R-05** |
| Does `ingressClassResource.enabled` exist? | **No** | **R-06** |
| Why was HAProxy ingress removed in April? | Almost certainly **Blocker 1**: `hostNetwork` + default `containerPort` 8080/8443 → nothing on :80/:443. It was a **current** controller, not an ancient one | **R-03** |
| Is that history a red flag against HAProxy IC? | **No — it validates our diagnosis** | R-03 |
| Is the Path-A cutover atomic if it's one commit? | **No** — helm-controller and kustomize-controller reconcile independently (flux2 #293) | `04` Path A |
| Does the official `haproxy` image run as root? | **No — UID 99** since 2.4 → edge-lb needs `runAsUser: 0`. *(The haproxytech controller image **is** root — don't generalize)* | `04`, `02` §4.7 |
| Is Cloudflare free capped by bandwidth? | **No cap.** The limit is **content type** (ToS §2.8: no video/large-file distribution). 15–20 TB/mo on free is normal; enforcement is a polite upgrade request, no cutoff/overage | `04` Path C |
| Does splitting two IPs actually hide the collector→marketplace link? | **Weakly.** ASN/reverse-IP, passive DNS, **CT logs**, nameserver pivot, shared analytics IDs, one shared cluster/backend/SMTP all link them. The IP split is the *least* useful layer against the stated (low-skill) threat model | `01` §7 |
| Will a captcha be needed (and kill conversion)? | **No** — separate **capture** (frictionless) from **qualification** (score before the lead reaches the marketplace) using the existing `approval_status` / `manual_approve` / `DuplicateLeadFinder`, plus zero-friction signals | `01` §7 |

---

## The one process rule to carry forward

**`helm template` + read the rendered manifest, before every commit.** It is offline, free, and it is the only method that has ever been conclusive here. Docs omitted things; `values.yaml` key names actively misled (R-02); a deep adversarial Opus review still missed two items (the IPv6 bind; R-02's sysctl mechanism). Reading the rendered YAML ended the guessing in one round.

Corollary: **Helm does not validate unknown value keys.** A typo or a plausible-but-nonexistent key (R-04, R-06) fails **silently** and can no-op the entire purpose of a change while everything looks green.
