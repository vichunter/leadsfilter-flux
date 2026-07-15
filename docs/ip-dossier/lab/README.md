# lab/ — offline replica of the ingress topology

Reproduces the leadsfilter two-IP ingress on a workstation, so Path B can be
tested **without touching production**. Built 2026-07-15; it is what produced
`../09-runtime-verification.md`.

```bash
./verify.sh                                        # ~5 min, needs docker + curl
CHART_VERSION=1.53.0 IMAGE_PIN=3.3.0 ./verify.sh   # gate an upgrade candidate
kind delete cluster --name ipfix                   # tear down
```

**It is also the upgrade gate.** This setup depends on five behaviours the vendor
does not document (or has an open bug for), and the worst failures here are
silent. Before bumping the chart or the image, read **`UPGRADING.md`** and run
this — it exits non-zero on any regression, and it is known to *catch* one, not
just to print PASS.

## What it builds

One kind node with **both "public" IPs on its `eth0` as `/32`s** — the same
shape as `leadsfilter-n1` — and both HAProxy IC instances in `hostNetwork`,
each bound to its own IP, each with its own IngressClass. Two stub backends
(`traefik/whoami`, which echoes the headers it received) stand in for the real
apps, behind Ingresses translated from the real ones.

| | prod | replica |
|---|---|---|
| hfc / homefinanceclub | `5.161.26.66` | `192.168.160.91` |
| main / leadsfilter | `178.156.239.214` | `192.168.160.90` |
| node | `leadsfilter-n1` | `ipfix-control-plane` |
| k8s | k0s v1.35.2, kube-router | kind v1.35.1, kindnet |
| chart / image | 1.52.1 / `kubernetes-ingress:3.2.12` | **identical** |

The k8s/CNI differences do not affect what is under test: a hostNetwork process
binds in the host netns, and the `hostPort` defaulter (#117689) is stock upstream.

## Files

| File | What |
|---|---|
| `values-hfc.yaml` / `values-main.yaml` | **The deliverable.** Runtime-verified values with the real prod IPs and the image pinned by digest. `verify.sh` rewrites the IPs for the replica; use these as-is for prod. |
| **`UPGRADING.md`** | **Read before any version bump.** What is pinned and why, the five undocumented behaviours everything leans on, and the bump procedure. |
| `kind-cfg.yaml` | the one-node cluster |
| `ingress-demo.yaml` | stub backends, the two brand Ingresses, the hand-authored `www` redirect, and a cert-manager-shaped ACME solver Ingress |
| `verify.sh` | builds it, then runs 23 assertions (A1–A10). Doubles as the upgrade gate. Tooling versions are pinned inside it, so the harness cannot drift under the thing it measures. |

## What it asserts

- no two listeners share an `addr:port` (a clash is **silent** — see below)
- the 4-way isolation matrix from `../../adding-hfc-ip.md`
- `/.well-known/acme-challenge/…` survives both redirects (H5/O-1)
- the backend receives the **real client IP** in `X-Forwarded-For`
- it prints the ports that become publicly reachable (`09` §5)

## Two traps this lab exists to catch

1. **A port clash does not raise `EADDRINUSE`.** haproxy binds with
   `SO_REUSEPORT`: both instances bind the same `addr:port`, both pods go
   `1/1 Running`, and the kernel picks an answerer at random. Green everywhere,
   wrong underneath. `--ipv4-bind-address` scopes only 3 of 8 listeners; the
   other five need distinct **ports** per instance.
2. **Never `grep` the listener dump.** The first "no collisions!" reading here
   was produced by grepping for the *expected* ports — which hid `:10000`
   (haproxy peers) entirely. `verify.sh` prints `ss -ltnp` whole, on purpose.
