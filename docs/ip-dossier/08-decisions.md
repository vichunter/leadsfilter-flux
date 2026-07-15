# 08 — Decision log & business context

**Read this before proposing anything.** Several sensible-looking options were already put to the user and **rejected**, with reasons. Re-proposing them wastes a turn and reads as not having done the reading.

---

## §1. Business context (why any of this matters)

The two brands are the two ends of **one** lead pipeline:

| Brand | Role | IP | IngressClass | Backends |
|---|---|---|---|---|
| **homefinanceclub.com** | **лидосборник** — the *collector*. Landing pages/forms/widgets where a person looking for a mortgage/refi leaves their contacts. The lead is written to the DB with contacts, state, loan amount, credit rating, `ad_source`/`ad_campaign_id`, then goes through approval. | `5.161.26.66` | `nginx-hfc` | `hfc-wp` (WordPress), `leadapp-api`, `leadapp-widget`, `serviceroom-*` |
| **leadsfilter.com** | **магазин лидов** — the *marketplace*. Brokers/lenders buy those leads: they configure **filters** (state, loan type, amount, LTV, credit…) and either buy manually via cart or auto-buy via **streamline**. Pricing via `GetLeadPriceAdvA`; shared/exclusive; `max_sales` per lead; balance/credit. | `178.156.239.214` | `nginx` | `leadstore-api`, `leadstore-admin`, `leadstore-portal`, `leadstore-landing`, `leadstore-shared`, `leadsfilter-corp-wp`, `serviceroom-*` |

**Why the client IP matters commercially:** the lead's IP is captured on the collector (`HttpContextMapper.cs:28` writes `lead.ip`) and used for dedup/fraud/quality. A node IP for every lead destroys that signal — the leads all look like they came from one place.

**Why two IPs exist:** to stop a competing lead marketplace from casually noticing that the collector feeds the marketplace, and then poisoning the marketplace with fake leads. (Assessment of whether that works: `01-timeline.md` §7 — short version: weakly, and the durable defence is backend fraud scoring, not obscurity. The user knows this and kept the split anyway.)

---

## §2. Decisions the user made — treat as settled

| # | Decision | Verbatim / context | Consequence |
|---|---|---|---|
| D-1 | **Keep two IPs**, split via k8s manifests | *"Мы сейчас будем делать один из 2х вариантов разделения айпишников через настройки и манифесты кубера, чтобы реальный айпи доходил до бэка. 2 айпишника пока оставляем."* | Any design must keep per-IP isolation |
| D-2 | **No MetalLB** | *"Метал ЛБ ставить пока не будем."* (independently: L2 doesn't work on Hetzner Cloud anyway) | — |
| D-3 | **No new server** | Hetzner's 15 Jun 2026 price rise: CCX23 $39.99→$102.99 (+158%), CPX41 $46.49→$141.49 (+204%), LB add-on ~$39/mo. *"мы видим, что они оверпрайс (сервера), поэтому остаёмся на том сервере что есть. Он один."* | Single node; both IPs on it |
| D-4 | **No DNS-01 for cert-manager** | *"не хотелось бы по днс сертификаты продлять. Разок я могу прописать днс, но автоматически — нет. Надо оставить по хттп."* | HTTP-01 stays → Path A needs the D3 hairpin; Path B inherits H5 |
| D-5 | **Cloudflare: not now** | *"клаудфлэр пока не рассматриваем"* | Path C parked (not refuted — see `04-options.md`) |
| D-6 | **Don't rename/restructure the nginx controllers** | *"пользуемся тем что есть, чтобы не вносить шум (много времени ушло, чтобы контроллеры заработали и не мешали друг другу, видимо, это хрупкое и лучше не трогать)"* | No `fullnameOverride`, no renames; read Service names from the cluster |
| D-7 | **Site security hardening out of scope** | *"я пока не хочу двигаться в эту сторону (менять сайты для повышения секьюрности)"* — conversion is *"на грани"* | Don't propose captcha/validation work now |
| D-8 | **Leaning to Path B** | *"Я, видимо, склоняюсь к варианту B"* | But O-0 may invalidate B's design — see `06` |
| D-9 | **Name the L4 proxy by role: `edge-lb`** | chosen over `haproxy`/`proxy`/`gateway` so the engine can change without a rename | Path A only |
| D-10 | **Invest in plans + independent review before touching prod** | *"лучше вложиться получше в написание плана и его ревью. И найти слабые места заранее"* — because a prod mistake means rollback or emergency fixing | Both plans got Opus reviews; this dossier exists for the same reason |

---

## §3. Options considered and REJECTED — do not re-propose

| Option | Why rejected | Where |
|---|---|---|
| Tune the current `externalIPs` setup to preserve client IP | **Impossible** — official docs: *"does not allow preserving the source IP … in any manner"* | `01` §2.3 |
| Add headers/annotations at the ingress to carry the real IP | nginx can only forward what it sees; the source is masqueraded before it | `01` §2.1 |
| `externalTrafficPolicy: Local` | Only applies to NodePort/LoadBalancer, not ClusterIP+externalIPs | `01` §2.2 |
| NodePort bound to a specific IP | Not expressible: `nodePort` is a port only; `--nodeport-addresses` is cluster-global | `01` §2.4 |
| MetalLB | L2 broken on Hetzner Cloud (ARP emulated); BGP unavailable; plus D-2 | `01` §2.5 |
| Hetzner Cloud LB | **Dedicated** IP, not a shared pool → doesn't hide the origin; and it's a paid add-on that got more expensive | `01` §2.6 |
| Two hostNetwork **ingress-nginx** controllers | `bind-address` exists but the startup port check ignores it (#2529/#7859) → second crash-loops; plus #117689 | `01` §3 |
| One nginx controller serving both brands by Host | Loses per-IP isolation (D-1); and the user remembers *"ужасные баги"* from merging | `01` §… |
| Migrate to Gateway API / HAProxy Unified Gateway | Unified Gateway is **Gateway-API-only, Ingress not shipped**; Gateway API has **no `from-to-www-redirect` equivalent**, loses snippets, limits regex-rewrite; cert-manager's Gateway support still experimental; **and this team already reverted NGF in one day** | `01` §5.2, §10.1, §10.3 |
| DNS-01 certificates | D-4 | — |
| Cloudflare / CDN fronting | D-5 (parked, not refuted) | `04` Path C |
| Captcha / front-end anti-fraud | D-7 — would cut already-marginal conversion; the right place is backend scoring after capture | `01` §7 |
| `jcmoraisjr/haproxy-ingress` | Not rejected — **held in reserve**. It has a true 1:1 `from-to-www-redirect` (Path B's H5 pain), but is single-maintainer (bus-factor 1), and this team was already burned by a young project (NGF). Its chart was never downloaded/rendered. | `05` §7 |

---

## §4. Things that were *proposed by the assistant and then withdrawn*

Recorded so nobody re-proposes them thinking they were never considered:

| Proposal | Withdrawn because |
|---|---|
| `allowPrivilegedPorts: true` to bind <1024 | It injects a sysctl kubelet **forbids** on hostNetwork → pod rejected (**R-02**) |
| `controller.hostNetwork: true` | Key doesn't exist; Helm drops it silently (**R-04**) |
| `compression-algo`/`compression-type` for gzip | Keys don't exist; compression unsupported (**R-05**) |
| `ingressClassResource.enabled: true` | Key doesn't exist (**R-06**) |
| "The April HAProxy attempt was an ancient version, ignore it" | The chart line is 1.x *today* — it was a **current** controller, and its failure was Blocker 1 (**R-03**) |
| "`daemonset.hostIP` gives per-IP isolation" | It's a scheduler hint only (**R-01**) — the most dangerous one |
| "Config-level unknowns are zero" | The 1042 healthz listener (**R-14**, `07` §7.5) |
| Pin `fullnameOverride` on the nginx controllers | D-6 — user wants no noise; the names are stable under normal ops anyway |
| Two Opus reviews are enough | Each subsequent round still found things; only reading source + rendering was conclusive |

---

## §5. Working agreements with this user

- **Verify, don't assert.** The user repeatedly (and correctly) challenged confident claims — *"ты не скачивал ещё чарт?"*, *"я правильно понимаю, что ключ точно существует?"*, *"что значит «вероятно»??????"*. Every one of those challenges found a real error. **Show the evidence (file:line, rendered output, command output), not a conclusion.**
- **Correct the record loudly.** When a previous statement turns out wrong, say so plainly and fix the artifacts (that's why `03-refuted.md` exists).
- **Prod is sacred.** Nothing is applied without a plan, a rollback, and a maintenance window. Read-only investigation by default; the user says explicitly when writes are allowed.
- **Language:** the user writes in Russian and asked for Russian replies. **Code, configs, commits, plans and this dossier are in English.**
- **Style:** terse, no filler. A "caveman mode" hook is active in the session (drop articles/hedging; keep all technical substance). Auto-disable it for security warnings, irreversible-action confirmations, and multi-step sequences.
- **Config-file comments:** the user explicitly asked for *case-flavoured* comments on timeouts etc. — not doc quotes. E.g. *"client sent nothing and we cut the connection"* vs *"we cut even while the client is actively sending"*. Short comment → same line; longer → line above. The user knows networking well but not HAProxy specifics.

---

## §6. Where every artifact lives

| Artifact | Path |
|---|---|
| This dossier | `leadsfilter-flux/docs/ip-dossier/` |
| Path A plan (edge-lb) | `leadsfilter-flux/docs/superpowers/plans/2026-07-09-edge-lb.md` |
| Path B plan (HAProxy IC migration) | `leadsfilter-flux/docs/superpowers/plans/2026-07-09-haproxy-ic-migration.md` |
| Research (HAProxy IC vs edge-lb; Ingress vs Gateway API; reviews/compat) | `leadsfilter-flux/docs/research/2026-07-09-haproxy-ingress-vs-edge-lb.md` ⚠ has a correction banner (R-01) |
| **The team's own two-IP runbook — required reading** | `leadsfilter-flux/docs/adding-hfc-ip.md` |
| Current controllers | `leadsfilter-flux/infrastructure/cluster/nginx-ingress/{source,release,release-hfc,kustomization}.yaml` |
| ClusterIssuer (HTTP-01, per-domain solvers) | `leadsfilter-flux/infrastructure/cluster/cert-manager-issuer/cluster-issuer.yaml` |
| Ingresses | `leadsfilter-flux/apps/lf-prod/ingress/{leadsfilter,homefinanceclub}.yaml` |
| WordPress's *own* nginx (the `fastcgi_cache` — **not** the ingress) | `leadsfilter-flux/apps/lf-prod/hfc-wp/configmap-nginx.yaml` |
| App: ForwardedHeaders config | `leadstore-back/LeadStore.API/Startup.cs:95-101,116` · `leadstore-back/LeadApp.API/Program.cs:28-32,67` |
| App: where the lead's IP is written | `leadstore-back/LeadApp.API/UseCases/AppSave/Mappers/HttpContextMapper.cs:28` |
| Live prod pricing function dump (other topic) | `leadstore-back/docs/GetLeadPriceAdvA.2026-07-08.sql` |

⚠️ **Path note:** the app repo root is `LeadsStore/leadstore-back` — the old `mortgage-usa/` sub-folder was merged to `master` and **no longer exists**. Strip that segment from any older note.
