#!/usr/bin/env bash
# Offline replica of the leadsfilter ingress topology + the UPGRADE GATE for it.
#
# Builds a one-node kind cluster, puts both "public" IPs on the node's eth0,
# runs both HAProxy IC instances in hostNetwork, and asserts every behaviour
# this setup leans on — including the five that are UNDOCUMENTED and can be
# revoked by an upgrade without a word. See UPGRADING.md.
#
#   ./verify.sh                                   # verify the pinned versions
#   CHART_VERSION=1.53.0 IMAGE_PIN=3.3.0 ./verify.sh   # gate a candidate upgrade
#
# Requires: docker, curl. Downloads pinned helm/kubectl/kind into ./bin.
# Runtime: ~5 min. Destroy with: kind delete cluster --name ipfix
#
# Replica IP mapping:
#   5.161.26.66     (hfc,  homefinanceclub) -> 192.168.160.91
#   178.156.239.214 (main, leadsfilter)     -> 192.168.160.90
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PWD/bin:$PATH"

HFC_IP=192.168.160.91
MAIN_IP=192.168.160.90

# --- pins -------------------------------------------------------------------
# The chart+image under test. Override to gate an upgrade candidate.
CHART_VERSION="${CHART_VERSION:-1.52.1}"
# IMAGE_PIN: empty = use whatever values-*.yaml pins (the normal case).
# Set to a tag (e.g. 3.3.0) to test a different controller against these values.
IMAGE_PIN="${IMAGE_PIN:-}"
# The lab's own tooling is pinned too — otherwise the harness drifts under the
# thing it is supposed to be measuring, and a "regression" may just be a newer
# kubectl/kind. k8s node image tracks prod's minor (k0s v1.35.2).
HELM_VERSION=3.16.3
KUBECTL_VERSION=v1.35.1
KIND_VERSION=v0.30.0
NODE_IMAGE=kindest/node:v1.35.1
# ----------------------------------------------------------------------------

PASS=0; FAIL=0
step() { printf '\n\033[1m=== %s\033[0m\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '   \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '   \033[31mFAIL\033[0m %s\n' "$1"; }
assert() { # assert <desc> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — got '$2', want '$3'"; fi
}
retry_code() { # retry_code <host> <ip> <want> ; an instance can be Ready a beat
  local c=""                                # before its default backend registers
  for _ in $(seq 1 10); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $1" "http://$2/" || true)
    [ "$c" = "$3" ] && break
    sleep 3
  done
  echo "$c"
}

step "tools (pinned — see the block above)"
mkdir -p bin
[ -x bin/helm ]    || { curl -sSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar xz -O linux-amd64/helm > bin/helm && chmod +x bin/helm; }
[ -x bin/kubectl ] || { curl -sSLo bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && chmod +x bin/kubectl; }
[ -x bin/kind ]    || { curl -sSLo bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" && chmod +x bin/kind; }
echo "   chart=$CHART_VERSION image_override=${IMAGE_PIN:-<from values>} node=$NODE_IMAGE"

step "cluster (prod is k0s 1.35.2; hostNetwork + #117689 mechanics are stock upstream)"
kind get clusters 2>/dev/null | grep -qx ipfix || kind create cluster --config kind-cfg.yaml --image "$NODE_IMAGE" --wait 180s
kind get kubeconfig --name ipfix --internal > kubeconfig.internal
export KUBECONFIG="$PWD/kubeconfig.internal"
# If this runs inside a container, join the kind network. Harmless on the host.
docker network connect kind "$(hostname)" 2>/dev/null || true

step "two 'public' IPs on the node's eth0 (mirrors prod: two /32 on eth0)"
docker exec ipfix-control-plane ip addr add $MAIN_IP/32 dev eth0 2>/dev/null || true
docker exec ipfix-control-plane ip addr add $HFC_IP/32 dev eth0 2>/dev/null || true
docker exec ipfix-control-plane ip -4 addr show eth0 | grep inet

step "render + install both instances"
helm repo add haproxytech https://haproxytech.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
for i in hfc main; do
  sed -e "s/5\.161\.26\.66/$HFC_IP/g" -e "s/178\.156\.239\.214/$MAIN_IP/g" \
      -e "s/leadsfilter-n1/ipfix-control-plane/" "values-$i.yaml" > "/tmp/lab-$i.yaml"
  if [ -n "$IMAGE_PIN" ]; then   # override the digest pin with a plain tag
    sed -i -e "s|repository: docker.io/haproxytech/kubernetes-ingress@sha256|repository: docker.io/haproxytech/kubernetes-ingress|" \
           -e "s|^    tag: \".*\"|    tag: \"$IMAGE_PIN\"|" "/tmp/lab-$i.yaml"
  fi
  helm template "haproxy-ingress-$i" haproxytech/kubernetes-ingress --version "$CHART_VERSION" \
    -f "/tmp/lab-$i.yaml" --kube-version 1.35.1 --namespace haproxy-ingress > "/tmp/render-$i.yaml"
  echo "--- $i args:"; grep -E '^\s+- --' "/tmp/render-$i.yaml" | sed 's/^/   /'
done
for i in hfc main; do
  helm upgrade --install "haproxy-ingress-$i" haproxytech/kubernetes-ingress --version "$CHART_VERSION" \
    -f "/tmp/lab-$i.yaml" -n haproxy-ingress --create-namespace --timeout 150s >/dev/null &
done; wait
until [ "$(kubectl -n haproxy-ingress get pods -l app.kubernetes.io/name=kubernetes-ingress --no-headers 2>/dev/null | grep -c '1/1')" = "2" ]; do sleep 4; done
kubectl -n haproxy-ingress get pod -o wide | grep -v job-check

step "demo backends + ingresses"
kubectl apply -f ingress-demo.yaml >/dev/null
kubectl -n demo rollout status deploy/hfc-app --timeout=90s >/dev/null
kubectl -n demo rollout status deploy/lf-app  --timeout=90s >/dev/null
sleep 12

step "THE listener dump — printed WHOLE on purpose. Read every line."
echo "(grepping for expected ports is how the :10000 peers collision was missed — see ../03-refuted.md R-20)"
docker exec ipfix-control-plane ss -ltnp
docker exec ipfix-control-plane ss -lunp

#############################################################################
# ASSERTIONS. Each maps to a documented finding; a FAIL means an upgrade
# revoked something this setup depends on. Do not "fix" the test — read
# UPGRADING.md and re-derive.
#############################################################################

step "A1 — no two listeners share an addr:port (09 §2.1)"
# A clash does NOT raise EADDRINUSE: haproxy binds with SO_REUSEPORT, both
# instances bind, and the kernel answers from a random one. Silent. This is
# the single most important assertion here.
dupes=$(docker exec ipfix-control-plane ss -ltnp | grep haproxy | awk '{print $4}' | sort | uniq -d || true)
if [ -z "$dupes" ]; then ok "every haproxy addr:port unique"; else bad "collision (SO_REUSEPORT hides it): $dupes"; fi

step "A2 — --ipv4-bind-address still scopes the http/https frontends (09 §2)"
assert "hfc  binds $HFC_IP:80"  "$(docker exec ipfix-control-plane ss -ltnp | grep -c "$HFC_IP:80 ")"  1
assert "main binds $MAIN_IP:80" "$(docker exec ipfix-control-plane ss -ltnp | grep -c "$MAIN_IP:80 ")" 1
assert "nobody binds 0.0.0.0:80" "$(docker exec ipfix-control-plane ss -ltnp | grep -c '0.0.0.0:80 ')"  0

step "A3 — --controller-port=0 still removes the Go listener entirely (09 §5)"
# The only aux listener that CAN be closed. Gated on `!= 0` in builder.go:165.
assert ":6060 absent" "$(docker exec ipfix-control-plane ss -ltnp | grep -c ':6060 ')" 0

step "A4 — the aux listeners still honour their port flags (upstream PR #446)"
for p in 1024 1042 6061 1026 1043 6063; do
  assert "port $p bound exactly once" "$(docker exec ipfix-control-plane ss -ltnp | grep -c ":$p ")" 1
done
assert "hfc  peers on :10000" "$(docker exec ipfix-control-plane ss -ltnp | grep -c ':10000 ')" 1
assert "main peers on :10001" "$(docker exec ipfix-control-plane ss -ltnp | grep -c ':10001 ')" 1

step "A5 — the image still runs as root (unprivileged: false depends on it)"
# If a future image adds a USER, `unprivileged: false` renders no securityContext
# and the <1024 bind fails. NEVER "fix" that with allowPrivilegedPorts (R-02).
assert "uid" "$(kubectl -n haproxy-ingress exec -c kubernetes-ingress-controller \
  "$(kubectl -n haproxy-ingress get pod -l app.kubernetes.io/instance=haproxy-ingress-hfc -o name | head -1)" \
  -- id -u 2>/dev/null | tr -d '\r')" "0"

step "A6 — 4-way isolation matrix (../../adding-hfc-ip.md)"
assert "homefinanceclub.com on its own IP"  "$(retry_code homefinanceclub.com $HFC_IP  301)" 301
assert "homefinanceclub.com on the lf IP"   "$(retry_code homefinanceclub.com $MAIN_IP 404)" 404
assert "leadsfilter.com on its own IP"      "$(retry_code leadsfilter.com     $MAIN_IP 301)" 301
assert "leadsfilter.com on the hfc IP"      "$(retry_code leadsfilter.com     $HFC_IP  404)" 404

step "A7 — UNDOCUMENTED: request-redirect still honours an https:// prefix (09 §4.2)"
# Shipped in commit 9338c489 (2024-02-19); issue #613 is STILL OPEN and the docs
# still say "host or host:port" only. Zero contract. If this FAILs, every www
# visit downgrades to plaintext http:// — silently.
loc=$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 6 \
      --resolve "www.homefinanceclub.com:443:$HFC_IP" https://www.homefinanceclub.com/ || true)
assert "https://www -> apex over https" "$loc" "https://homefinanceclub.com/"

step "A8 — ssl-redirect-port still overrides the 8443 default (09 §4.1)"
# The annotation defaults to 8443 (annotations/common/main.go:69) and ignores
# --https-bind-port. Without the override every HTTP visitor hits a dead port.
loc=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 5 -H "Host: homefinanceclub.com" "http://$HFC_IP/" || true)
case "$loc" in
  https://homefinanceclub.com:443/*|https://homefinanceclub.com/) ok "ssl-redirect -> $loc" ;;
  *) bad "ssl-redirect -> '$loc' (8443 or a downgrade means the default changed)" ;;
esac

step "A9 — the ACME path still survives both redirects (H5/O-1, 09 §4.3)"
for h in homefinanceclub.com www.homefinanceclub.com; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $h" \
      "http://$HFC_IP/.well-known/acme-challenge/probe" || true)
  assert "solver reachable on $h (301 = the SAN stalls at renewal, +30d)" "$c" 200
done

step "A10 — the backend still receives the REAL client IP (the point of the project)"
xff=$(curl -sk --max-time 8 --resolve "homefinanceclub.com:443:$HFC_IP" \
      https://homefinanceclub.com/api/ 2>/dev/null | grep -i "X-Forwarded-For" | tr -d '\r' || true)
me=$(docker exec ipfix-control-plane ip -4 neigh 2>/dev/null | grep -oE '192\.168\.160\.[0-9]+' | head -1 || echo "")
if echo "$xff" | grep -qE '192\.168\.160\.[0-9]+'; then ok "$xff"; else bad "no client IP in XFF: '$xff'"; fi

step "INFO — ports that are PUBLIC after migration (09 §5; firewall required)"
# Not assertions: these cannot be closed. Printed so a version bump that
# ADDS a listener is visible here rather than in prod.
for p in 1024 1026 1042 1043 6061 6063; do
  printf '   %s:%-5s -> %s\n' "$HFC_IP" "$p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HFC_IP:$p/" || echo refused)"
done
echo "   /metrics leaks backend names (unauthenticated, on BOTH public IPs):"
curl -s --max-time 5 "http://$HFC_IP:1024/metrics" 2>/dev/null | grep -oE 'proxy="[^"]+"' | sort -u | head -4 | sed 's/^/      /' || true
echo "   QUIC udp/443 (present despite enablePorts.quic: false — 09 §4.7):"
docker exec ipfix-control-plane ss -lunp | grep haproxy | awk '{print "      "$4}' || true

step "RESULT"
printf '   passed: %s   failed: %s\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mAn assertion failed.\033[0m Do not deploy. Read UPGRADING.md — every check\nhere exists because a real, silent failure got past review.\n'
  exit 1
fi
printf '\n\033[32mAll assertions passed.\033[0m Destroy with: kind delete cluster --name ipfix\n'
