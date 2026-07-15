# 03 — Refuted claims ⚠️ READ THIS FIRST

Claims that were **made and believed during the session, then disproven**. Some were the assistant's own; some came from a research doc; two survived a deep adversarial review and were only caught by reading source.

**Why this file exists:** several of these wrong claims are *still written down elsewhere* (research doc, older plan revisions, this session's earlier messages). If you re-read those without this file, you will re-adopt a refuted belief and burn a cycle — or worse, ship it.

Format: **Claim → why it looked right → how it died → what's actually true → cost if believed.**

---

## R-01 🔴 "`daemonset.hostIP` gives each instance its own bind socket / per-IP isolation"

**Claimed by:** the HAProxy-vs-edge-lb research report (`docs/research/2026-07-09-haproxy-ingress-vs-edge-lb.md`), then propagated into the migration plan and into the assistant's summaries to the user.

**Why it looked right:** the key exists, is named `hostIP`, and setting it *does* solve the visible symptom everyone knew about (k8s #117689, two hostNetwork pods refusing to schedule). It reads like "bind this instance to this IP."

**How it died:** the Opus review of the migration plan read `templates/_podspec.tpl` and found `hostIP` is rendered **only into the Kubernetes port spec** (`{{- if $hostIP }}hostIP: {{ $hostIP }}` inside the ports loop). It never becomes a controller argument. The controller's own default is `--ipv4-bind-address=0.0.0.0`. Later independently confirmed by downloading the chart and by rendering.

**What's actually true:**
- `daemonset.hostIP` buys **exactly one thing**: it makes the scheduler's `(hostIP, port)` tuples distinct so both DaemonSet pods can schedule on one node (#117689). Keep it for that.
- **Real per-IP binding requires `--ipv4-bind-address=<ip>` per instance** via `controller.extraArgs`.

**Cost if believed:** catastrophic. Both instances would bind `0.0.0.0` → the second pod dies with `EADDRINUSE`, **and every IP serves both brands** (isolation — the entire point — gone). Concretely: **bringing up the homefinanceclub instance would have taken leadsfilter.com down.**

**Where the wrong version may still be read:** the research doc. A correction banner was added at its top, but the body still describes the hostIP mechanism optimistically. Trust the banner and this file.

---

## R-02 🔴 "`allowPrivilegedPorts: true` is the fix for binding ports <1024" — *the assistant's own fix, and it would have broken the pod*

**Claimed by:** the assistant, after reading `values.yaml` and seeing the key name.

**Why it looked right:** the key is literally called `allowPrivilegedPorts`, it defaults to `false`, and the problem was literally "cannot bind a privileged port". The README even says *"Allow non-root to bind ports < 1024"*. It was written into the plan as the Blocker-1 fix, replacing an earlier (also wrong) claim about `NET_BIND_SERVICE`.

**How it died:** downloading the chart and reading `templates/_helpers.tpl:185` + `README.md:346`. The mechanism is: it **injects the sysctl `net.ipv4.ip_unprivileged_port_start=0`** into the pod. And namespaced `net.*` sysctls are **forbidden on hostNetwork pods** — kubelet rejects the pod outright with `SysctlForbidden` (k8s #103298). This is the *same* fact the earlier edge-lb review had already established for a different image, and it was not connected.

**What's actually true:**
- **Never set `allowPrivilegedPorts: true` together with hostNetwork.** It doesn't help; it makes kubelet refuse the pod.
- The chart has **no `securityContext` / `runAsUser` / capabilities values at all**. Instead: `unprivileged: true` renders `runAsUser: 1000` + `capabilities: {drop:[ALL], add:[NET_BIND_SERVICE]}`; `unprivileged: false` renders **no securityContext at all**.
- The controller image `haproxytech/kubernetes-ingress:3.2.12` has **no `USER` → runs as root** (verified via the registry API). So **`unprivileged: false` is correct and simplest** — root binds 80/443, no caps, no sysctl.

**Cost if believed:** the pod never starts (`SysctlForbidden`), during a production cutover, while chasing a symptom you'd already "fixed".

**Meta-lesson:** the assistant proposed a fix from a *key name and a README sentence*. Both were accurate in isolation and still produced a broken configuration, because the *implementation* was incompatible with hostNetwork. Read the template.

---

## R-03 🔴 "The April 2026 HAProxy ingress attempt used an ancient v1.x controller, so it tells us nothing"

**Claimed by:** the assistant, when explaining commit `df40563` ("remove haproxy ingress, add nginx ingress"). Stated confidently, twice, as the answer to *"почему мы снесли haproxy ingress"*.

**Why it looked right:** the old HelmRelease pinned `version: ">=1.0.0 <2.0.0"`. Charts named `1.x` for an ingress controller *look* ancient, and the assistant pattern-matched to "chart 1.x ⇒ controller ~1.5–1.7, circa 2020–2021".

**How it died:** downloading the Helm index. The **`kubernetes-ingress` chart is versioned 1.x *today*** — the current chart is **1.52.1**. Chart version and controller version are **independent number lines**.

**What's actually true:**
- `">=1.0.0 <2.0.0"` is the **current** major line. In April 2026 it resolved to a then-current chart (~1.49–1.51) → controller **3.2.x**. They ran a **modern** controller.
- **And the far more useful conclusion:** their April values were `controller: {hostNetwork: true, service: {type: ClusterIP}}` with the chart's **default `containerPort` 8080/8443**. Under hostNetwork that means HAProxy bound **8080/8443** and **nothing answered :80/:443**. The site would look dead. **That is Path B's Blocker 1, exactly.** The likely history: "haproxy ingress doesn't work" → swapped for nginx within hours → no diagnosis recorded.

**Cost if believed:** you'd dismiss the only piece of first-hand evidence you have — and it happens to *confirm* the blocker you're trying to fix. You might also mis-scope risk ("we tried HAProxy and it failed" reads as a red flag against the product; it isn't).

---

## R-04 🔴 "`controller.hostNetwork: true`"

**Claimed by:** the assistant, in the first draft of the migration plan.

**Why it looked right:** it's how many charts spell it, and Helm accepts it **silently**.

**How it died:** Opus review, then confirmed in `values.yaml` / `_podspec.tpl:58`.

**What's actually true:** the key is **`controller.daemonset.useHostNetwork: true`** (and `controller.deployment.useHostNetwork` for the Deployment kind). Also set **`controller.dnsPolicy: ClusterFirstWithHostNet`**, or the hostNetwork pod uses the host resolver and cannot resolve cluster Services.

**Cost if believed:** Helm drops the unknown key without a word → the pod runs **without** hostNetwork → **no native client IP**, i.e. the migration achieves nothing while appearing to succeed, and the port model is wrong on top.

**This is the canonical example of the session's core lesson:** *Helm does not validate unknown value keys.* Always `helm template` and read the rendered manifest.

---

## R-05 🔴 "gzip maps to `compression-algo` / `compression-type` ConfigMap keys"

**Claimed by:** the assistant, in the migration plan's first draft (as the mapping for `use-gzip`).

**How it died:** Opus review — neither key exists in the ConfigMap reference, the annotations reference, nor `values.yaml`. HTTP compression in this controller is an **open feature request (upstream #196)**; the only route is raw `backend-config-snippet`, which this plan forbids (upstream #768, snippet loss).

**What's actually true:** **compression is not supported** by haproxytech IC via config keys. Since the audit rates gzip non-critical, **drop it** — do not leave dead keys implying it works. Separately: **`use-gunzip` has no equivalent at all** — HAProxy compresses but never *de*compresses. Practical impact low (it only matters if a backend pre-compresses for a client that sent no `Accept-Encoding`).

**Cost if believed:** silently uncompressed responses plus dead config that a future reader trusts.

---

## R-06 🔴 "`controller.ingressClassResource.enabled: true`"

**Claimed by:** the assistant (pattern-matched from ingress-nginx, which does have that key).

**How it died:** reading `values.yaml` — the block is only `{name, default, parameters}`.

**What's actually true:** there is **no `enabled` key**. Setting it is silently dropped. Same trap family as R-04.

---

## R-07 🔴 "`service.enablePorts.quic` only gates the Service port, not the controller's QUIC listener"

**Claimed by:** the assistant, when the Opus review left "how do we disable the QUIC listener?" as an open question — the assistant asserted the flag was Service-only and flagged the QUIC listener as unresolved.

**How it died:** reading `_podspec.tpl:108` — the QUIC **arguments** (`--quic-bind-port`, `--quic-announce-port`) are gated on `and (semverCompare ">=1.24.0-0" .Capabilities.KubeVersion.Version) $ctlr.service.enablePorts.quic`, and that condition is evaluated **independently of `service.enabled`**. Confirmed by rendering: with `enablePorts.quic: false` the QUIC args vanish.

**What's actually true:** **`service.enablePorts.quic: false` does disable the controller's QUIC listener** — you must set it explicitly (default is `true`), *even though the Service itself is disabled*.

**Cost if believed:** you'd carry a phantom "unsolved" item, and — worse — if left at its default, both instances would get `--quic-bind-port=443` and fight over **udp/443**.

---

## R-08 🔴 "The cluster is multi-node"

**Claimed by:** the assistant, after the user pasted `ip -4 addr` from host `inc-n1` (eth0 `46.224.26.190`), which had **neither** public IP. The assistant concluded there must be several nodes and rewrote plan justifications around it.

**How it died:** the user: *"inc-n1 — это другой кластер, другой проект."*

**What's actually true:** `inc-n1` belongs to the unrelated `inc` project. The leadsfilter cluster's relevant node is **`leadsfilter-n1`**, which has **both** public IPs on `eth0`.

**What survived:** the `nodeSelector: kubernetes.io/hostname: leadsfilter-n1` that had been added — it is correct regardless of node count (it pins the pod to the node that owns the IPs). Only the **justification** was wrong.

**Cost if believed:** wrong mental model of the topology; wasted design effort on DaemonSet-across-nodes and floating-IP-failover scenarios that don't apply.

**Lesson:** confirm *which host you are looking at* before reasoning from its output. Node count for this cluster was never actually confirmed with `kubectl get nodes -o wide` — see `06-open-questions.md`.

---

## R-09 🔴 "Controller 3.3.10 exists — so the research saying 'latest is 3.2.12, no 3.3' was wrong"

**Claimed by:** the assistant, on first reading the Helm index (it saw `appVersion: 3.3.10` near the top and announced the research was contradicted).

**How it died:** looking at which chart that entry belonged to. The index's first section is the **`haproxy`** chart (standalone HAProxy), not `kubernetes-ingress`.

**What's actually true:** the repo hosts **three charts** — `haproxy` (1.29.0 / appVersion 3.3.10), `haproxy-unified-gateway`, and **`kubernetes-ingress` (1.52.1 / appVersion 3.2.12)**. The research was **right**: for the ingress controller, 3.2.12 (2026-07-03) is current; there is no 3.3 line for it.

**Cost if believed:** you'd pin a non-existent version, or distrust a correct research doc.

**Bonus fact worth keeping:** even within the `haproxy` chart, `appVersion: 3.3.10` disagrees with its own image annotation `haproxy-alpine:3.3.6`. **Trust `artifacthub.io/images`, not `appVersion`.**

---

## R-10 🔴 "The controller Service is named `nginx-ingress-ingress-nginx-controller`"

**Claimed by:** the assistant, deriving the name from the chart's fullname convention using `HelmRelease.metadata.name` (`nginx-ingress`).

**How it died:** `kubectl get svc -A`.

**What's actually true:**
- `ingress-nginx-nginx-ingress-controller` (main)
- `ingress-nginx-nginx-ingress-hfc-controller` (hfc)
- Formula: **`<targetNamespace>-<HelmRelease.metadata.name>-controller`** — Flux's helm-controller prefixes the release name with `targetNamespace`, which the assistant hadn't accounted for.

**Cost if believed:** an haproxy.cfg pointing at a non-existent backend → the edge-lb never reaches the controllers.

**Lesson:** the name is the output of a chain (Flux release naming → chart fullname template → suffix). Too many layers to derive reliably. **Read it from the cluster.**

---

## R-11 🟡 "The edge-lb `defaults` block has a duplicated `timeout` directive"

**Claimed by:** the assistant, in a self-flagged note inside the edge-lb plan ("reviewer: verify there is exactly one of each; the draft has a stray duplicate").

**How it died:** the Opus review actually checked: each of `timeout connect/client/server/tunnel/client-fin` appears **exactly once**. There was **no duplicate**.

**What's actually true:** the *comments* for `timeout server` and `timeout tunnel` were **swapped**. Both were `1h`, so there was **zero runtime effect** — but the labels were misleading and would have caused a wrong edit later. Fixed.

**Why it's recorded:** it's the opposite failure mode from the rest of this file — a *false alarm* that cost review attention. Semantics confirmed correct: in TCP mode `timeout tunnel` **is** the effective idle timeout once the session is established (it governs WebSocket/SSE/long-poll), and the "make edge timeouts longer than any ingress timeout" principle is sound.

---

## R-12 🟡 "`LeadApp.API` configures ForwardedHeaders the same way as `LeadStore.API` (private ranges)"

**Claimed by:** the assistant, in §1 of the investigation and in the first draft of this dossier.

**Why it looked right:** a grep showed `LeadApp.API/Program.cs:28` (`Configure<ForwardedHeadersOptions>`) and `:32` (`ForwardedHeaders.All`) — the same shape as LeadStore.API. The assistant **never read line 31** and filled the gap from memory.

**How it died:** re-verifying paths after the repo consolidation (`mortgage-usa/` folder removed) — the grep this time showed the actual line:
```csharp
options.KnownNetworks.Add(IPNetwork.Parse("0.0.0.0/0"));   // LeadApp.API/Program.cs:31
```

**What's actually true:**
- `LeadStore.API/Startup.cs:98-100` trusts **private ranges only** (`10/8`, `172.16/12`, `192.168/16`), `ForwardLimit = 3`.
- `LeadApp.API/Program.cs:31` trusts **`0.0.0.0/0` — everything.**

**Does it change the diagnosis?** No — the root cause is still upstream (nginx has nothing truthful to put in XFF). But it's a **client-IP spoofing surface** the moment a trusted upstream exists (Cloudflare, or a PROXY-protocol edge): anything that can reach LeadApp.API could forge the visitor IP. Worth tightening as part of whichever path is chosen.

**Lesson:** "same shape" from a partial grep is not verification.

---

## R-13 🟡 Reviewer suggestion: "check the controller's `10254` healthz instead of no active check"

**Claimed by:** the first Opus review of the edge-lb plan (offered as a better alternative to running no health check).

**How it died:** the controller Services expose **only 80 and 443** (`kubectl get svc -n ingress-nginx` → `PORT(S): 80/TCP,443/TCP`). Port `10254` is not on the Service, so an HAProxy backend `check port 10254` against the Service DNS name cannot work.

**What's actually true:** **no active check** is the right call here — a single backend per instance on a single node has nothing to fail over to, a bare `check` would arrive **without** a PROXY header and spam nginx with `broken header`, and `send-proxy-v2` on checks has a known spec bug (haproxy #511, opnsense/plugins #2909).

**Why it's recorded:** even a strong review can propose something the local topology forbids. Check the reviewer too.

---

## R-14 🔴 "Path B's config-level unknowns are zero" — *the assistant's own claim, refuted an hour later by the assistant*

**Claimed by:** the assistant, after downloading the chart, rendering both instances, and inspecting the image. Stated to the user as: *"Config-уровень: неизвестных больше НЕТ"* and *"Путь B из «теоретически возможного» стал проверенным на бумаге до последнего ключа."*

**Why it looked right:** every key had been checked against the templates; the render was clean; the last named open item (the container user) had just been closed via the registry API. It genuinely felt exhaustive.

**How it died:** while copying the render into the dossier, the `livenessProbe` line was actually *read*:
```yaml
livenessProbe:
  httpGet: { path: /healthz, port: 1042 }
```
**1042 appears nowhere in our values.** Chart `README.md:362`: *"Default port is `1042` — the controller's built-in `/healthz` listener **bound unconditionally by the binary (independent of `containerPort`)**."* And `documentation/controller.md` has **no flag** for it.

**What's actually true:** two questions remain, and they are **not** answerable offline (see `07-artifacts.md` §7.5):
1. Does `--ipv4-bind-address` scope the **healthz (1042)** listener, or does it bind `0.0.0.0:1042` on both instances → second pod `EADDRINUSE`, with **no flag to move or disable it**?
2. Does it scope the **stat** listener — and does `containerPort.stat` actually move that bind? There is **no `--stat-bind-port`**; `containerPort` is proven to drive only `--http-bind-port`/`--https-bind-port`. **So the HIGH-4 "distinct stat/admin ports" fix may be declaration-only — the exact R-01 failure mode, repeated.**

**Cost if believed:** you'd walk into the cutover believing the design is proven, and discover at the worst moment that two instances cannot share the host netns — which would invalidate Path B's two-instance design outright.

**Why it's the most instructive entry here:** the claim was made *after* the most rigorous verification of the whole session (source read + rendered + registry-inspected). It was still wrong, because **the render was skimmed for what was expected rather than read for what was there**. The blocker was sitting in the output the assistant had already produced.

---

## R-15 🔴 "The 1042 healthz question cannot be settled offline — only `ss` on a running pod answers it"

**Claimed by:** the assistant, in `06-open-questions.md` O-0 and `07-artifacts.md` §7.5, as the reason the whole of Path B was blocked. Repeated in `00-README.md` as *"the immediate next action — one command, and it decides Path B"* (a command to be run **on the prod node**).

**Why it looked right:** the docs are genuinely silent, the chart README genuinely misdescribes the listener, and `documentation/controller.md` genuinely has no `--healthz-*` entry in the table that was read. Offline evidence had been exhausted *within the chart*.

**How it died (2026-07-15):** two ways, both offline. (a) The controller **source** answers it outright — `pkg/controller/controller.go:245` hardcodes `fmt.Sprintf("0.0.0.0:%d", healthzPort)`. (b) A **kind replica** of the topology (one node, two IPs on `eth0`, both instances in hostNetwork) reproduces the exact `ss -ltnp` output the question asked for, in 5 minutes, touching nothing. See `09-runtime-verification.md` and `lab/`.

**What's actually true:** the question was never prod-only. The dossier stopped at "the chart doesn't say", and treated the vendor's docs+chart as the boundary of what could be known offline. The source was public; the topology was replicable.

**Cost if believed:** you gate the entire migration on a production experiment — and, worse, you'd have run that experiment with values that **look fine** (`SO_REUSEPORT` → both pods `1/1 Running`) and concluded Path B was proven.

**Lesson:** "only prod can answer this" is a claim like any other, and it deserves the same skepticism as "the key exists". Before accepting it: is the source public? can the topology be faked locally?

---

## R-16 🔴 "There is **no flag** for the healthz listener, and no `--stat-bind-port`"

**Claimed by:** the assistant, `07-artifacts.md` §7.5 — *"Checked `documentation/controller.md` for an escape: there is **no flag** for the healthz listener or its port"* and *"There is **no `--stat-bind-port`**"*.

**How it died:** `docker run --rm --entrypoint /haproxy-ingress-controller haproxytech/kubernetes-ingress:3.2.12 --help`:
```
--healthz-bind-port=      port to listen on for probes
--stats-bind-port=        port to listen on for stats page
--localpeer-port=         port to listen on for local peer (default: 10000)
--controller-port=        port to listen on for controller
--default-backend-port=   port to use for default service
```
All five exist (`pkg/utils/flags.go:94,95,99,105` + `--default-backend-port`).

**What's actually true:** `--healthz-bind-port` exists. The stats flag is **`--stats-bind-port`** — *plural*. The dossier searched for the singular and concluded from the miss. **A one-letter typo is what made O-0 "unresolvable" and blocked Path B.**

**Cost if believed:** Path B gets abandoned (or bet on prod) over a problem that five documented flags solve.

**Lesson:** the binary's own `--help` is cheaper and more authoritative than the docs page, and it was never consulted. Ask the artifact, not the prose about the artifact.

---

## R-17 🔴 "Two instances colliding on 1042 ⇒ the second pod dies with `EADDRINUSE`"

**Claimed by:** `06` O-0 and `07` §7.5 — the assumed failure mode, and the reason the collision was considered *detectable*.

**How it died:** running it. Both instances bound `0.0.0.0:1042` **simultaneously** — two sockets, two inodes, two pod cgroups — and both pods went `1/1 Running`:
```
0.0.0.0:1042  haproxy pid=5604 (main)  ino:75034677
0.0.0.0:1042  haproxy pid=5102 (hfc)   ino:75025538
```
haproxy sets **`SO_REUSEPORT`** (its seamless-reload mechanism), so the kernel accepts both and load-balances across them.

**What's actually true:** the collision is **silent**. Nothing errors, nothing crash-loops, everything reports healthy — and probes/stats are answered by a randomly-chosen instance. Since both pods are hostNetwork, **both pods' IP is the node InternalIP**, so kubelet probes the *same* socket group for both: a probe result cannot be attributed to the pod it was meant for. Only the two **Go** listeners (6060/6061) raise a real `EADDRINUSE`, and the controller just logs it (`builder.go:260,289`) and keeps running with that function silently dead.

**Cost if believed:** you'd deploy the second instance expecting a loud failure if anything was wrong, get green pods, and ship it.

---

## R-18 🟡 "`enablePorts.quic: false` disables the QUIC listener" — *R-07, half wrong*

**Claimed by:** R-07 in this very file, as a *correction* of an earlier error — and it was verified by rendering.

**How it died:** `ss -lunp` on the node. **udp/443 is open on both IPs**, and `haproxy.cfg` contains `bind quic4@<ip>:443 ... alpn h3`.

**What's actually true:** R-07 was right that the flag gates the controller **args** (they do vanish from the podspec) — and wrong that this removes the listener. With the args absent the controller falls back to its default QUIC bind. **Practical impact: none for collisions** — the QUIC bind *is* scoped by `--ipv4-bind-address`, so the instances don't fight. But udp/443 is open and `alt-svc: h3` is advertised, which nobody planned.

**Why it's instructive:** R-07 was produced by the most trusted method available at the time (read the template, render it). The render was *right about the args and silent about the config*. The rendered podspec is not the rendered haproxy config.

---

## R-19 🔴 "MEDIUM 7's fix: add `ssl-redirect: true` to both brands"

**Claimed by:** the migration plan (MEDIUM 7), and `04-options.md` — presented as the fix for silently losing HTTPS-forcing.

**How it died:** applying it. Every HTTP visitor gets:
```
Location: https://homefinanceclub.com:8443/
```
Cause: `pkg/annotations/common/main.go:69` → `"ssl-redirect-port": "8443"` is the annotation's **default**, and it ignores `--https-bind-port=443`.

**What's actually true:** you must also set **`haproxy.org/ssl-redirect-port: "443"`**. The plan's fix, applied as written, **takes both sites down for every HTTP visitor** — while looking like the careful thing to do.

**Cost if believed:** a cutover that 301s all plaintext traffic into a closed port.

---

## R-20 🟡 The assistant's own "no collisions" claim — *R-14, repeated verbatim, by the next assistant*

**Claimed by:** the assistant, 2026-07-15, after applying four extra flags and checking the result: *"Оба инстанса живут в одном netns без единой коллизии"*.

**How it died:** the user pushed back on the evidence. The unfiltered dump showed:
```
192.168.160.2:10000  haproxy pid=7363 (hfc)
192.168.160.2:10000  haproxy pid=7365 (main)
```
**haproxy peers** — a seventh listener nobody had ever mentioned — still colliding on the node IP.

**What's actually true:** the claim was produced by `ss -ltnp | grep -E ':(80|443|1024|1026|1042|1043|6060|6061|6063)\s'` — a grep for the ports the assistant **expected**, which structurally cannot show a port it didn't know about. The fix is `--localpeer-port` (a fifth flag).

**Why it's here:** this is R-14's exact mechanism — *"the output was skimmed for what was expected rather than read for what was there"* — committed by someone who had just read R-14 and written a summary of it. Being able to recite the lesson is not the same as applying it.

**Rule this leaves behind:** **never grep a listener dump.** Print `ss -ltnp` and `ss -lunp` whole and read every line. `lab/verify.sh` does this deliberately.

---

## Pattern across all of these

Six verification rounds, and **every round found something**:

| Round | Method | Found |
|---|---|---|
| 1 | Reading vendor docs | `--ipv4-bind-address` exists ✅ — and **`--ipv6-bind-address: ::`** (a *new* blocker the review missed) |
| 2 | Reading `values.yaml` | `allowPrivilegedPorts` exists → produced **R-02 (a wrong fix)**; `ingressClassResource.enabled` doesn't exist (R-06); prometheus/pprof default true |
| 3 | **Downloading the chart** | R-01 confirmed, **R-02 killed**, R-07 killed, `publishService` found, R-03 rewritten |
| 4 | **`helm template`** | every fix confirmed in the rendered manifest; tuples distinct |
| 5 | **Registry API** | image is root → `unprivileged: false` correct |
| 6 | Re-checking repo paths | **R-12** (a fact "known" since the first hour was wrong) |

**Docs lied by omission. A deep adversarial Opus review missed two things (the IPv6 bind, and R-02's sysctl mechanism). Only reading the actual source and rendering the actual output ended it.**

**The rule this leaves behind:** on this stack, `helm template` + reading the rendered YAML is **mandatory** before any commit — it is offline, free, and it is the only step that has ever been conclusive.
