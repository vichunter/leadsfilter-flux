#!/usr/bin/env bash
# Offline replica of the leadsfilter ingress topology, for verifying Path B
# without touching production. Builds a one-node kind cluster, puts two
# "public" IPs on the node's eth0, runs both HAProxy IC instances in
# hostNetwork, and asserts everything 09-runtime-verification.md claims.
#
# Requires: docker, curl. Downloads helm/kubectl/kind into ./bin.
# Runtime: ~5 minutes. Destroy with: kind delete cluster --name ipfix
#
# Replica IP mapping:
#   5.161.26.66     (hfc,  homefinanceclub) -> 192.168.160.91
#   178.156.239.214 (main, leadsfilter)     -> 192.168.160.90
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PWD/bin:$PATH"
HFC_IP=192.168.160.91
MAIN_IP=192.168.160.90
CHART_VERSION=1.52.1

step() { printf '\n\033[1m=== %s\033[0m\n' "$1"; }

step "tools"
mkdir -p bin
[ -x bin/helm ] || { curl -sSL https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz | tar xz -O linux-amd64/helm > bin/helm && chmod +x bin/helm; }
[ -x bin/kubectl ] || { curl -sSLo bin/kubectl "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x bin/kubectl; }
[ -x bin/kind ] || { curl -sSLo bin/kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 && chmod +x bin/kind; }

step "cluster (k8s 1.35.1; prod is k0s 1.35.2 — hostNetwork/#117689 mechanics are stock upstream)"
kind get clusters 2>/dev/null | grep -qx ipfix || kind create cluster --config kind-cfg.yaml --image kindest/node:v1.35.1 --wait 180s
kind get kubeconfig --name ipfix --internal > kubeconfig.internal
export KUBECONFIG="$PWD/kubeconfig.internal"
# If this script runs inside a container, join the kind network so the API and
# the replica IPs are reachable. Harmless when run from the docker host.
docker network connect kind "$(hostname)" 2>/dev/null || true

step "two 'public' IPs on the node's eth0 (mirrors prod: two /32 on eth0)"
docker exec ipfix-control-plane ip addr add $MAIN_IP/32 dev eth0 2>/dev/null || true
docker exec ipfix-control-plane ip addr add $HFC_IP/32 dev eth0 2>/dev/null || true
docker exec ipfix-control-plane ip -4 addr show eth0 | grep inet

step "render gate (offline; the dossier's one mandatory pre-commit check)"
helm repo add haproxytech https://haproxytech.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
for i in hfc main; do
  sed -e "s/5\.161\.26\.66/$HFC_IP/g" -e "s/178\.156\.239\.214/$MAIN_IP/g" \
      -e "s/leadsfilter-n1/ipfix-control-plane/" "values-$i.yaml" > "/tmp/lab-$i.yaml"
  helm template "haproxy-ingress-$i" haproxytech/kubernetes-ingress --version $CHART_VERSION \
    -f "/tmp/lab-$i.yaml" --kube-version 1.35.1 --namespace haproxy-ingress > "/tmp/render-$i.yaml"
  echo "--- $i:"; grep -E '^\s+- --' "/tmp/render-$i.yaml" | sed 's/^/   /'
done

step "install both instances"
for i in hfc main; do
  helm upgrade --install "haproxy-ingress-$i" haproxytech/kubernetes-ingress --version $CHART_VERSION \
    -f "/tmp/lab-$i.yaml" -n haproxy-ingress --create-namespace --timeout 150s >/dev/null &
done; wait
until [ "$(kubectl -n haproxy-ingress get pods -l app.kubernetes.io/name=kubernetes-ingress --no-headers 2>/dev/null | grep -c '1/1')" = "2" ]; do sleep 4; done
kubectl -n haproxy-ingress get pod -o wide | grep -v job-check

step "demo backends + ingresses"
kubectl apply -f ingress-demo.yaml >/dev/null
kubectl -n demo rollout status deploy/hfc-app --timeout=90s >/dev/null
kubectl -n demo rollout status deploy/lf-app --timeout=90s >/dev/null
sleep 12

step "THE listener dump — read every line, never grep (this is how :10000 was missed)"
docker exec ipfix-control-plane ss -ltnp
docker exec ipfix-control-plane ss -lunp

step "ASSERT: no two listeners share an addr:port"
if docker exec ipfix-control-plane ss -ltnp | grep haproxy | awk '{print $4}' | sort | uniq -d | grep -q .; then
  echo "FAIL: collision (SO_REUSEPORT hides it — both bind, kernel picks at random)"; exit 1
fi
echo "OK: every addr:port unique"

step "ASSERT: 4-way isolation matrix (docs/adding-hfc-ip.md)"
# Retry: an instance can be Ready a beat before its default-backend server is
# registered, which briefly yields a connect failure instead of the 404.
check() {
  for _ in $(seq 1 10); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $1" "http://$2/") || true
    [ "$c" = "$3" ] && break
    sleep 3
  done
  printf '   %-24s on %-15s -> %s (want %s)\n' "$1" "$2" "$c" "$3"; [ "$c" = "$3" ]
}
check homefinanceclub.com $HFC_IP  301
check homefinanceclub.com $MAIN_IP 404
check leadsfilter.com     $MAIN_IP 301
check leadsfilter.com     $HFC_IP  404

step "ASSERT: the ACME path survives both redirects (H5/O-1)"
for h in homefinanceclub.com www.homefinanceclub.com; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $h" "http://$HFC_IP/.well-known/acme-challenge/probe")
  printf '   %-24s -> %s (want 200; 301 = the SAN stalls at renewal)\n' "$h" "$c"; [ "$c" = 200 ]
done

step "ASSERT: the backend sees the REAL client IP (the point of the project)"
curl -sk --max-time 8 --resolve "homefinanceclub.com:443:$HFC_IP" https://homefinanceclub.com/api/ | grep -i "X-Forwarded-For" | sed 's/^/   /'

step "the ports that become PUBLIC after migration (see 09 §5 — firewall required)"
for p in 1024 1026 1042 1043 6061 6063; do
  printf '   %s:%-5s -> %s\n' "$HFC_IP" "$p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HFC_IP:$p/" || echo refused)"
done
echo "   /metrics leaks backend names:"
curl -s --max-time 5 "http://$HFC_IP:1024/metrics" | grep -oE 'proxy="[^"]+"' | sort -u | head -4 | sed 's/^/      /'

printf '\n\033[1mDONE.\033[0m Destroy with: kind delete cluster --name ipfix\n'
