# Adding a second public IP to the cluster

This document describes how to attach a second Hetzner Floating IP to the
single-node k0s cluster and use it as an independent entry point served by its
own ingress-nginx controller. The goal is strict isolation: each domain is
only reachable from its own IP, and never from the wrong one.

Example used below:

- Primary IP `178.156.239.214` — serves `leadsfilter.com` / `www.leadsfilter.com`
- Secondary Floating IP `5.161.26.66` — serves `homefinanceclub.com` / `www.homefinanceclub.com`

## Architecture

Both domains are served from the same node, but by **two separate
ingress-nginx controllers**, each with its own `IngressClass`:

- `nginx` — default class, bound to `178.156.239.214` via `Service.externalIPs`
- `nginx-hfc` — second class, bound to `5.161.26.66` via `Service.externalIPs`

Neither controller uses `hostNetwork`. Each is a normal pod with a cluster IP,
and kube-proxy installs iptables DNAT rules that forward traffic arriving on
the node's external IPs to the respective pod. This gives clean isolation:

- Traffic hitting `.214:80/443` can only reach the `nginx` controller.
- Traffic hitting `.66:80/443` can only reach the `nginx-hfc` controller.
- Each controller only picks up `Ingress` resources whose `ingressClassName`
  matches its class.

Ingress resources pin themselves to one controller via `ingressClassName`.

## Step 1 — Attach the Floating IP at the Hetzner level

1. Buy/create a Floating IP in the Hetzner Cloud console.
2. Attach it to the target server in the console. Without this step, Hetzner
   will not route packets for this IP to the server even if the OS is
   configured correctly.

## Step 2 — Bind the IP on the host (netplan)

Hetzner's cloud-init already manages the primary IP through
`/etc/netplan/50-cloud-init.yaml`. Do **not** edit that file — it is owned by
cloud-init and will be overwritten. Instead, add a separate netplan file with
a higher priority number so it is applied after cloud-init's:

`/etc/netplan/60-floating-ip.yaml`:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      addresses:
        - 5.161.26.66/32
```

Tighten permissions (netplan complains otherwise):

```bash
chmod 600 /etc/netplan/60-floating-ip.yaml
```

Validate and apply:

```bash
netplan generate
netplan try
```

`netplan try` applies the config and rolls back automatically after 120s
unless you press Enter. Use this to avoid locking yourself out if something
is wrong. Once confirmed, reboot the node to verify the address survives a
full boot.

Verify:

```bash
ip -4 addr show eth0
ip route get 1.1.1.1
```

The default route source IP should still be the primary `.214` — the
Floating IP is an additional address, not a replacement.

## Step 3 — Pin kubelet to the primary node IP

**This step is critical and non-obvious** (see troubleshooting section).

Without an explicit hint, kubelet auto-detects the node IP by picking the
first IPv4 address on the interface used by the default route. Because
the static Floating IP entry is added at boot before DHCP replies from
Hetzner populate the primary address, the Floating IP ends up first in
`ip addr show eth0` output, and kubelet picks **the wrong address** as the
Node's `InternalIP`.

Force the correct choice by adding `--node-ip` to kubelet via k0s's
`--kubelet-extra-args` flag. This is a CLI flag for the `k0s` binary, so it
has to go into the systemd unit (or a drop-in) — there is no equivalent
field in `k0s.yaml` because `--node-ip` is not part of `KubeletConfiguration`.

Edit `/etc/systemd/system/k0scontroller.service` and append the flag to the
`ExecStart` line:

```
ExecStart=/usr/local/bin/k0s controller --config=/etc/k0s/k0s.yaml --enable-worker=true --kubelet-extra-args=--node-ip=178.156.239.214
```

Reload and restart:

```bash
systemctl daemon-reload
systemctl restart k0scontroller
```

Verify:

```bash
k0s kubectl get node -o wide
```

`INTERNAL-IP` must show the primary IP (`178.156.239.214`).

Alternatively, a systemd drop-in at
`/etc/systemd/system/k0scontroller.service.d/override.conf` works the same
way and survives a `k0s install` re-run without losing the override.

## Step 4 — Convert the existing (primary) controller off `hostNetwork`

If the primary ingress-nginx controller currently uses `hostNetwork: true`,
it **must** be converted to the same `ClusterIP` + `externalIPs` pattern
before adding a second controller. Running the two side-by-side with one on
`hostNetwork` causes two distinct problems:

1. **Port conflict** — both pods would claim host ports 80/443/8443 at the
   PodSpec level. The scheduler blocks the second one. See troubleshooting
   ("hostPort scheduler conflict") for why this cannot be worked around via
   the chart's `hostPort.enabled` toggle.
2. **Node IP collision** — a `hostNetwork` pod inherits the node's
   `InternalIP` as its pod IP. If kubelet picked the Floating IP as the
   node's `InternalIP` (see troubleshooting: "Wrong node IP"), the primary
   controller's pod IP ends up being the Floating IP, and kube-proxy installs
   `KUBE-SEP` rules that route traffic destined for the Floating IP to the
   primary controller — silently breaking the isolation.

Rewrite the primary HelmRelease `release.yaml` to mirror the secondary's
structure, keeping the default `nginx` IngressClass untouched but dropping
everything related to `hostNetwork`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nginx-ingress
  namespace: flux-system
spec:
  interval: 1h
  chart:
    spec:
      chart: ingress-nginx
      version: ">=4.0.0 <5.0.0"
      sourceRef:
        kind: HelmRepository
        name: ingress-nginx
        namespace: flux-system
  targetNamespace: ingress-nginx
  install:
    createNamespace: true
  values:
    controller:
      service:
        type: ClusterIP
        externalIPs:
          - "178.156.239.214"
```

Specifically, remove:

- `controller.hostNetwork: true`
- `controller.config.bind-address` (no longer needed — the pod binds inside
  its own netns, and kube-proxy delivers packets from the external IP)
- `controller.updateStrategy.type: Recreate` (was only needed to work
  around the `hostNetwork` rolling-update deadlock — default
  `RollingUpdate` is fine and gives zero-downtime upgrades)
- `spec.upgrade.force: true` (was only needed because of the `Recreate`
  transition — not needed on steady-state)

Commit this change **before** adding the second controller, so the cluster
passes through a clean single-controller-on-externalIP state first. Verify
the primary IP still serves traffic as expected:

```bash
k0s kubectl -n ingress-nginx get pods -o wide
k0s kubectl -n ingress-nginx get svc
curl -I -H "Host: leadsfilter.com" http://178.156.239.214/
```

Pod IP should be a normal cluster CIDR address (not the node IP), the
service should show `EXTERNAL-IP: 178.156.239.214`, and the curl should
return `308 → https` as before.

## Step 5 — Deploy the second ingress-nginx controller

Both controllers are managed via Flux HelmReleases under
`infrastructure/cluster/nginx-ingress/`. The second controller goes into its
own HelmRelease with a distinct `IngressClass`, `electionID`, and
`Service.externalIPs`.

`release-hfc.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nginx-ingress-hfc
  namespace: flux-system
spec:
  interval: 1h
  chart:
    spec:
      chart: ingress-nginx
      version: ">=4.0.0 <5.0.0"
      sourceRef:
        kind: HelmRepository
        name: ingress-nginx
        namespace: flux-system
  targetNamespace: ingress-nginx
  install:
    createNamespace: true
  values:
    controller:
      ingressClassResource:
        name: nginx-hfc
        enabled: true
        default: false
        controllerValue: "k8s.io/ingress-nginx-hfc"
      ingressClass: nginx-hfc
      electionID: ingress-nginx-hfc-leader
      admissionWebhooks:
        enabled: false
      service:
        type: ClusterIP
        externalIPs:
          - "5.161.26.66"
```

Key points:

- `ingressClassResource.name` and `ingressClass` must differ from the default
  `nginx` class of the primary controller.
- `electionID` must be unique — otherwise the two controllers fight for the
  same leader lease and one of them never becomes ready.
- `admissionWebhooks.enabled: false` avoids a port conflict on `:8443`, since
  both controllers run on the same node and the webhook listener needs a
  unique port per pod. Disabling it only skips admission-time ingress
  validation; the controller still enforces the same rules at runtime.
- `service.type: ClusterIP` + `externalIPs` binds this controller's service
  (and therefore its DNAT entry in kube-proxy) specifically to the
  Floating IP.
- No `hostNetwork`, same as the primary controller was converted to in
  Step 4.

Add the new file to `kustomization.yaml`:

```yaml
resources:
  - source.yaml
  - release.yaml
  - release-hfc.yaml
```

## Step 6 — Teach cert-manager which controller to use per domain

By default, a cert-manager `ClusterIssuer` has a single `solvers` entry
with a hardcoded ingress class. When the ACME HTTP-01 solver creates its
temporary ingress for a domain challenge, that ingress goes to whatever
class is in the ClusterIssuer — regardless of which class the *real*
Ingress for the domain uses.

With two controllers on different IPs, this breaks: if the ClusterIssuer
always puts solver ingresses on `nginx`, the solver is served from the
primary IP, but the DNS A record for the new domain points at the
secondary IP. Let's Encrypt fetches the challenge via DNS → it lands on
the secondary controller → no matching solver ingress there → 404.
Challenge hangs forever in `pending`.

Fix: give the ClusterIssuer multiple solvers, selected by `dnsNames`,
each using the correct class:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - selector:
          dnsNames:
            - homefinanceclub.com
            - www.homefinanceclub.com
        http01:
          ingress:
            ingressClassName: nginx-hfc
      - http01:
          ingress:
            ingressClassName: nginx
```

The first solver is the specific one — its `selector.dnsNames` makes it
match only challenges for the listed hosts, and it points the solver at
`nginx-hfc`. The second solver has no selector — it is the default
fallback for every other domain and keeps using `nginx`. cert-manager
picks the most specific matching solver, so the ordering of the two
blocks does not matter, but putting the specific one first reads better.

**Important: list every host that appears in the matching Ingress's
`tls.hosts`.** If the Ingress TLS section covers `example.com` and
`www.example.com`, the ClusterIssuer selector must include both — cert-manager
issues one challenge per host, and any host missing from the selector
falls back to the default solver (wrong class). List the selector hosts
in sync with what the Ingress requests.

## Step 7 — Move ingress resources to the new class

For each domain that must only be served via the new IP, change its
`Ingress` to reference the new class:

```yaml
spec:
  ingressClassName: nginx-hfc
```

From this moment on:

- The primary controller (`nginx`) stops matching this ingress, so the host
  returns `404 default backend` when queried via the primary IP.
- The secondary controller (`nginx-hfc`) starts matching it and serves
  normally via the Floating IP.

Point the domain's DNS A records at the Floating IP. cert-manager will
re-issue the TLS certificate through HTTP-01 on the secondary controller
automatically (the solver ingress inherits the class of the original
ingress), provided DNS already resolves to the new IP at the time of
challenge.

## Verification

All four combinations should match the isolation matrix:

```bash
curl -I -H "Host: leadsfilter.com"     http://178.156.239.214/   # 308 → https
curl -I -H "Host: leadsfilter.com"     http://5.161.26.66/       # 404
curl -I -H "Host: homefinanceclub.com" http://178.156.239.214/   # 404
curl -I -H "Host: homefinanceclub.com" http://5.161.26.66/       # 308 → https
```

---

## Troubleshooting

Real problems encountered while setting this up, in the order they bit us.

### Rolling update deadlock on `hostNetwork` controller

**Symptom**: after changing the primary controller's config, the new pod
stayed in `Pending` and the old one kept running. `kubectl describe pod`
showed port conflicts.

**Cause**: with `hostNetwork: true`, both old and new pod try to bind the
same `0.0.0.0:80/443` on the host during a rolling update, and the new one
cannot start until the old one releases the ports — which only happens after
the new one is Ready. Classic deadlock.

**Initial workaround**: set `updateStrategy.type: Recreate` so the old pod is
terminated before the new one starts. This introduced a few seconds of
downtime per upgrade but broke the deadlock.

**Real fix (later)**: eliminating `hostNetwork` entirely (see next problem)
made `Recreate` unnecessary — normal pods have independent network
namespaces, so parallel old/new instances during `RollingUpdate` no longer
collide. The final configuration uses default `RollingUpdate` with no
`hostNetwork`.

### Helm three-way merge error on strategy change

**Symptom**: after switching to `Recreate`, Helm upgrade failed with:

```
Deployment.apps ... is invalid: spec.strategy.rollingUpdate: Forbidden:
may not be specified when strategy type is 'Recreate'
```

**Cause**: Helm's three-way merge left the old `rollingUpdate` sub-object in
place while also setting `type: Recreate`, which is an invalid combination.

**Fix**: `spec.upgrade.force: true` on the HelmRelease — this makes Flux
replace the Deployment instead of patching it. Removed together with
`Recreate` once the controller moved off `hostNetwork`.

### hostPort scheduler conflict between two `hostNetwork` controllers

**Symptom**: the second controller's pod stayed Pending with:

```
0/1 nodes are available: 1 node(s) didn't have free ports for the
requested pod ports.
```

Even though the chart's values had `hostPort.enabled: false`.

**Cause**: when a pod uses `hostNetwork: true`, the Kubernetes PodSpec
defaulter automatically populates `hostPort = containerPort` for every
container port
([kubernetes/kubernetes#117689](https://github.com/kubernetes/kubernetes/issues/117689)).
This happens at the API server admission level and cannot be overridden via
the chart's `hostPort.enabled` toggle — that toggle only controls what the
chart explicitly renders, not the defaulter's behavior. With both
controllers running `hostNetwork`, they both claim host ports 80, 443, and
8443, and the scheduler blocks the second one.

**Fix**: do not run ingress-nginx with `hostNetwork` at all when you need
multiple controllers on the same node. Use `service.type: ClusterIP` +
`service.externalIPs` instead. Each controller then gets a normal pod IP and
kube-proxy handles the external-IP-to-pod DNAT. This is the approach the
final config uses for both controllers.

### Wrong node IP after adding Floating IP — `kube-proxy` routes to the wrong pod

**Symptom**: after switching the secondary controller to `externalIPs`, the
new IP was unreachable (404 from default backend or connection reset), and
`iptables-save -t nat | grep 5.161.26.66` showed `KUBE-SEP` rules for the
**primary** controller pointing at `5.161.26.66:80/443`. In other words, the
Floating IP was being routed to the wrong pod.

**Cause**: the primary controller was still `hostNetwork: true`, so its pod
IP equalled the node's `InternalIP`. And `InternalIP` was `5.161.26.66`,
because kubelet auto-detects node IP by picking the first IPv4 on the
default-route interface — and the Floating IP (static, configured via
netplan at early boot) appeared in `ip addr show eth0` before the primary
IP (DHCP, delivered later by Hetzner's DHCP server). So kubelet registered
the node with the Floating IP as its internal address, the `hostNetwork` pod
inherited that address, and kube-proxy cheerfully installed DNAT rules
sending `.66` traffic to a pod whose "IP" was also `.66`, colliding with
the second controller's externalIP rules.

**Fix**: two changes, both required.

1. Move the primary controller off `hostNetwork`, same as the secondary.
   Now its pod has a normal cluster CIDR IP, and kube-proxy routes `.214`
   traffic to a unique endpoint — no collision with `.66`.
2. Pin kubelet to the primary IP with
   `--kubelet-extra-args=--node-ip=178.156.239.214`. This ensures
   `Node.status.addresses.InternalIP` is correct regardless of the kernel's
   interface address order, which affects anything that uses the downward
   API `status.hostIP`, outgoing metrics labels, and future pods that
   might need to know the node's "real" address.

After these, each controller's endpoints live on a distinct pod IP, and
iptables rules for the two external IPs are cleanly separated.

### Broken Helm release state after manually deleting deployments

**Symptom**: deleted a stuck Deployment by hand; Flux/Helm refused to
reconcile with errors like `cannot use force conflicts and force replace
together` or `Failed to load release ...`.

**Cause**: Helm stores release state in a Secret. In Flux v2, that Secret
lives in the HelmRelease's own namespace (`flux-system`), **not** in the
`targetNamespace` of the deployed workload. Deleting the Deployment without
clearing the release Secret leaves Helm convinced the release is still
installed, so subsequent reconciles try to patch a non-existent object.

**Fix**: delete the Helm release Secret in `flux-system` (look for
`sh.helm.release.v1.<name>.v<revision>` entries) and let Flux reinstall from
scratch on the next reconcile.

### cert-manager challenges stuck in `pending` after splitting controllers

**Symptom**: after moving a domain's Ingress to the new `nginx-hfc` class
and pointing DNS at the secondary IP, the `Certificate` stayed `READY:
False`. `k0s kubectl -n <ns> get order,challenge` showed Orders and
Challenges in `pending` state for days. The `cm-acme-http-solver-*`
Ingresses were still there — but with `CLASS: nginx` and `ADDRESS` equal
to the primary controller's ClusterIP.

**Cause**: two compounding issues.

1. **ClusterIssuer hardcoded the solver class.** The `letsencrypt`
   ClusterIssuer had a single solver with `http01.ingress.ingressClassName:
   nginx`, so cert-manager created every solver ingress on the primary
   controller regardless of which real ingress was asking for the cert.
   Even though DNS now pointed to the secondary IP, Let's Encrypt's HTTP-01
   probe landed on the secondary controller, which had no solver ingress,
   and returned 404.
2. **Updating the ClusterIssuer did not retroactively rewrite the
   existing Order.** cert-manager only reads Issuer config when it
   *creates* a new Order. The stuck Order was created six days earlier,
   under the old single-solver config, so its Challenges' solver
   ingresses were frozen in the wrong class. No amount of waiting would
   fix them.

**Fix**: two steps, in order.

1. Update the ClusterIssuer to have a per-domain solver — see Step 6.
2. **Delete the stuck Order** to force cert-manager to create a fresh
   one that reads the new Issuer config:

   ```bash
   k0s kubectl -n <ns> delete order <order-name>
   ```

   The deletion cascades to the Challenges, solver Ingresses, Services,
   and Pods (via owner references). cert-manager then sees the
   `CertificateRequest` with no live Order and immediately creates a new
   one. The new solver ingresses come up with the correct class, Let's
   Encrypt validates within a minute or two, and the Certificate flips
   to `READY: True`.

You do not need to restart the solver pods, touch cert-manager, or
reissue the Certificate resource. Deleting the Order is the single lever.

### Missing DNS record for `www.` stalls HTTP-01 challenge silently

**Symptom**: after fixing the ClusterIssuer and recreating the Order,
one Challenge still stayed `pending`. `dig +short www.example.com`
returned nothing.

**Cause**: the Ingress's `tls.hosts` listed both `example.com` and
`www.example.com`, so cert-manager issued two Challenges — one per host.
DNS only existed for the apex. Let's Encrypt could not even resolve the
`www` host to make the HTTP request, so that Challenge hung indefinitely
and the parent Order never progressed.

**Fix**: add DNS for every host in `tls.hosts` before asking cert-manager
to issue the cert. The cleanest option is a CNAME from `www` to the
apex — single source of truth, survives future IP changes:

```
www.example.com.   CNAME   example.com.
```

After DNS propagates (`dig +short www.example.com` should return the
chain), delete the stuck Order again to force a fresh cycle. The new
Challenges will validate both hosts, and the Certificate becomes Ready.

### Unrelated but same session — `mcedit` replaces spaces with tabs in YAML

**Symptom**: netplan refused to parse a YAML file edited in `mcedit`, with
indentation errors.

**Fix**: disable auto-tab in `mcedit` (`Options` → `Editor options`, uncheck
"Fake half tabs" and make sure tab size matches expected indentation). YAML
is whitespace-sensitive and does not accept tabs for indentation.
