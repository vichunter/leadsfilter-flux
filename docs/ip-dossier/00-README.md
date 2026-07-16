# IP dossier — index

# 🟢 SOLVED, 2026-07-16 — and not by anything this dossier proposed. Read this box before anything else.

**The real client IP reaches the apps. The fix was two lines, and no migration happened.**

```yaml
# infrastructure/cluster/nginx-ingress/release.yaml and release-hfc.yaml
      service:
        type: ClusterIP
        externalIPs: [...]
        externalTrafficPolicy: Local     # <- this
```
Merged and live on `master` (`1cd48d2`). No new component, no controller swap, no edge, no PROXY protocol, no firewall change, no maintenance window, **no pod restart** — the field only rewrites kube-proxy's iptables chain for the externalIP, so the controllers never moved (`RESTARTS 0`, `AGE 94d` through the change).

**→ The one entry that matters is `03-refuted.md` **R-23**.** Reproduce it in ~2 minutes with `lab-aprime/etp-local-test.sh`.

### 🔴 Most of this dossier argues that the above is impossible. It was wrong, and here is exactly how

`01-timeline.md` §2.2 said — marked **✅ VERIFIED** — *"that field only takes effect for `type: NodePort`/`LoadBalancer`; the Services here are `ClusterIP` with `externalIPs`, so the field is ignored."* That sentence is the **premise of every plan in this repo**, and it was carried into `08-decisions.md` as rejected and into `04-options.md` as *"why the current topology can never work"*.

**Its basis was reading a docs page and two GitHub issues. Nobody ever ran it.** Measured:

| policy | what the pod sees |
|---|---|
| unset (as shipped for months) / `Cluster` | `10.244.0.1` — the kube-bridge |
| **`Local`** | **the client** |

Only the policy field changes between those lines. **The problem was real** — the IP genuinely was masked. **Only the claimed impossibility of fixing it cheaply was false.**

And the two issues the dossier leaned on, once opened rather than cited:
- **ingress-nginx#9749** — a *different hop*. Their client IP **did** reach the controller; the pod *behind* it saw the proxy's address, which is how a reverse proxy works. Their setup was NodePort + hostNetwork + HAProxy on 4 nodes.
- **kubernetes#97073** — exactly our shape, and an **IPVS-only** bug. Its reporter states iptables is correct. This node runs `mode: "iptables"` (read off the node, not assumed).

**The lesson, and it is the third instance in this project:** a claim died because nobody opened the artifact. R-16 (a one-letter typo — `--stat-bind-port` vs `--stats-bind-port` — made O-0 "unresolvable" and blocked Path B for a week), R-23 (a docs page), and an issue cited by its title. **The ✅ recorded how confidently the sentence was written, not whether anyone had run it.**

### ⚠️ Two things that will silently kill the fix. Read them before changing anything

1. **Add a second node → the brand whose controller pod is not on the receiving node dies silently.** `Local` serves traffic **only where a local endpoint exists**. This is safe today *because* the cluster is one node (**O-4, closed by measurement 2026-07-16**). It is a fact about today, not an invariant.
2. **Switch kube-proxy to `ipvs` → the fix stops working**, per kubernetes#97073. It is `iptables` today, set explicitly in the ConfigMap.

### What the rest of this dossier is still for

**The migration plans are the fallback for exactly the two cases above** — the day a second node is added, `externalTrafficPolicy: Local` stops being enough and Path A′ becomes relevant again. It is finished: **Rev 5, four adversarial review rounds, gate `verify-aprime.sh` at 110/0** from a cluster it rebuilds itself. Do not re-derive it under pressure; it is here.

**And the measured facts about this cluster are true regardless of path** — O-4 (one node), the trusted-source value and the command that lies about it (`02-verified-facts.md` §1.6b), who actually SNATs (kube-proxy; kube-router never fires), the CNI conflist. Those cost real hours and they are correct.

**Everything else — Paths A, A′ and B, the `haproxy-ingress` manifests on branch `haproxy-ic-migration-manifests`, R-01…R-22 — is about a road not taken.** Read it as history, not as a plan.

**Session state:** `13-session-2026-07-16.md`. **Path B:** `11-handoff.md`.

---

**Subject:** everything investigated about the two public IPs, the loss of the real client IP after the move off AWS CloudFront, and the candidate fixes.

**Session date:** 2026-07-09 (one long session). Written so a future agent can pick this up **without re-doing any of the verification below**.

**Repo paths referenced throughout:**
- Flux repo: `leadsfilter-flux` (this repo)
- App repo: **`LeadsStore/leadstore-back`** — this is the repo **root** (contains `.git`, `CLAUDE.md`, `MEMORY.md`, `LeadStore.API/`, `LeadApp.API/`, …), branch `master`, single worktree.
  - ⚠️ **Path correction:** the `mortgage-usa/` sub-folder that existed earlier is **gone** — that branch was merged to `master` and everything consolidated into `leadstore-back/`. There are **no** nested per-branch folders. Older notes (and the first draft of this dossier) referenced `leadstore-back/mortgage-usa/...`; **strip the `mortgage-usa/` segment**. Only the solution file keeps the legacy name (`LeadStore--Mortgage-USA.sln`).

---

## Read in this order

0. **`09-runtime-verification.md` — the newest and most authoritative file.** Path B was actually **run** (offline, in a kind replica). Where any other file disagrees with it, **09 wins**. Ready-to-use values live in **`lab/`**; `lab/verify.sh` rebuilds the whole proof in ~5 minutes.
1. **`03-refuted.md` — READ THIS FIRST of the rest.** Twenty claims that were made and later **disproven**, including several of the assistant's own "fixes" (one would have broken the pod; one would have taken both sites down). Several of these wrong claims are still written down in *other* documents here (research doc, older plan revisions). If you skip this file you will re-adopt a refuted belief.
2. `01-timeline.md` — the chronological narrative. What was asked, what was found, what was concluded, and what the next step was. This is the main file.
3. `02-verified-facts.md` — the hard facts, each with **how it was verified**. Do not re-verify these.
4. `04-options.md` — the three candidate paths (A edge-lb / B HAProxy IC / C Cloudflare), their exact state and blockers.
5. `06-open-questions.md` — what is genuinely still unknown (**O-0 is a blocker**), and an explicit list of what is **settled** (don't re-open).
6. `07-artifacts.md` — the verified values files, the reproduction commands, the known-good render, and **§7.5: the late blocker**. Use this instead of re-deriving config.
7. `08-decisions.md` — the user's explicit decisions and rejected options, with rationale. Read before proposing anything.
8. `05-sources.md` — every external doc / GitHub issue / source file consulted, and what it actually said.

---

## TL;DR — state at end of session

**The problem.** The stack used to sit behind AWS CloudFront, which put the real visitor IP in `X-Forwarded-For`. After the move to a self-hosted k0s cluster, the apps see a node/cluster IP instead of the real client IP. The apps' `ForwardedHeaders` config is **fine**; the loss happens *before* the ingress controller: both public IPs are wired as Kubernetes `Service.externalIPs`, and kube-proxy SNATs (masquerades) the source before the packet reaches nginx. The official ingress-nginx docs state plainly that `externalIPs` **"does not allow preserving the source IP of HTTP requests in any manner."** So the current topology can never preserve client IP — it must change.

**Why there are two public IPs.** `178.156.239.214` → `leadsfilter.com` (the lead *marketplace*), `5.161.26.66` → `homefinanceclub.com` (the lead *collector*). They are deliberately split so a casual competitor cannot trivially see that the collector feeds the marketplace (and then stuff it with fake leads). See `01-timeline.md` §7 for the analysis of whether that actually works (short answer: weakly, and the real defence is backend fraud scoring — but the user chose to keep the split).

**Three candidate paths, all researched:**

| Path | What | State |
|---|---|---|
| **A — edge-lb** | One HAProxy L4 proxy (hostNetwork) in front, per-IP binds, PROXY protocol to the two existing nginx controllers | Plan written + **2 Opus reviews**. Blockers fixed on paper. Keeps EOL nginx. Needs a CoreDNS hairpin (D3) for cert-manager. |
| **B — HAProxy IC** | Replace both nginx controllers with two `haproxytech/kubernetes-ingress` instances (hostNetwork, each bound to its own IP) | ✅ **Runtime-verified 2026-07-15 in a local replica** — O-0 and O-1 both closed, values corrected (5 extra flags + 2 annotation fixes). Native client IP **proven**. See `09-runtime-verification.md` + `lab/`. |
| **C — Cloudflare** | Front everything with a CDN on shared anycast IPs | Researched. Would dissolve the whole problem *and* meet the origin-hiding goal, free. **User deferred it** ("Cloudflare пока не рассматриваем"). |

**Where it stands:** the user leans to **B**. Plan: `docs/superpowers/plans/2026-07-09-haproxy-ic-migration.md`.
Plan A: `docs/superpowers/plans/2026-07-09-edge-lb.md`.
Research: `docs/research/2026-07-09-haproxy-ingress-vs-edge-lb.md` (⚠ contains one corrected error — see `03-refuted.md` R-01).

Ready-to-use verified values + reproduction commands: **`07-artifacts.md`** (the scratchpad they were made in is gone; this is the durable copy).

### ✅ O-0 is CLOSED (2026-07-15) — Path B works, and none of it needed prod

**Read `09-runtime-verification.md` first.** The blocker was settled **offline**, two ways: by reading the controller's Go source, and by rebuilding the whole topology in a kind replica (`lab/verify.sh`, ~5 min, one node, both IPs on `eth0`, both instances in hostNetwork).

The answers, in short:
- `--ipv4-bind-address` scopes **3 of 8 listeners**. healthz, stats, peers, and two Go listeners bind all-interfaces.
- A clash does **not** raise `EADDRINUSE` — haproxy uses **`SO_REUSEPORT`**, both bind, both pods go green, and the kernel answers from a random one. **Silent, not loud.**
- The escape flags the dossier said didn't exist **do** exist: `--healthz-bind-port`, `--stats-bind-port` (*plural* — the singular typo is what made this "unresolvable"), `--localpeer-port`, `--controller-port`, `--default-backend-port`. Upstream **PR #446** added them precisely so two hostNetwork instances can share a node.

**With the corrected values (`lab/values-{hfc,main}.yaml`): zero collisions, both brands served, isolation matrix clean, and the real client IP arrives at the backend — the whole point of the project, proven.**

**The next action is no longer a question, it's the cutover.** Remaining unknowns are cutover-only: the conntrack/DNAT race (M10), a real LE staging issuance, and behaviour under real traffic. Plus one **new hard prerequisite**: a **Hetzner Cloud Firewall** rule, because five listeners become publicly reachable on both public IPs after the migration and **cannot be disabled** (`09` §5).

---

## The single most important lesson from this session

**On this stack, "I wrote the values key" ≠ "it will do that."**

Helm silently drops unknown keys. Vendor docs lag. A deep adversarial review still missed things. Every round of verification found something new — six rounds, six findings — and the findings only stopped once the chart was **downloaded and rendered** and the image config was **read from the registry**.

Concretely, during this session:
- a `values` key that doesn't exist (`controller.hostNetwork`) was going to silently no-op the whole point of the migration;
- a fix the assistant proposed (`allowPrivilegedPorts: true`) would have made kubelet **reject the pod**;
- the central isolation mechanism everyone believed in (`daemonset.hostIP`) **does not do what was claimed**.

**Mandatory gate before any commit on path B:** `helm template` the real chart with the real values and read the rendered manifest. It is offline and safe. See `02-verified-facts.md` §5 for the exact command and the verified output.

---

## Scope note

This dossier covers **the IP / client-IP / ingress problem only**. Two other topics from the same session are out of scope here:
- **LeadStore pricing SQL** (`GetLeadPriceAdvA`, the "can a lead sell for $0" question, the `WHERE`-less `SELECT … FROM filters` bug) — see `leadstore-back/docs/GetLeadPriceAdvA.2026-07-08.sql` (the live prod dump taken that day) next to `GetLeadPriceAdvA.sql` and `GetLeadPriceAdvA.before_remove_fields.sql`.
- **The SMTP relay / Google Workspace bounce investigation** — **except** for the one finding that is IP-topological and *is* recorded here (`02-verified-facts.md` §1.6: pod egress IP ≠ node default source IP). That one matters because it proves you cannot infer a pod's egress IP from the node's default route.
