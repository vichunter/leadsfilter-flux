# OpenVPN

Two instances running on the cluster node with `hostNetwork: true`:
- **openvpn-tcp** — TCP on port 30094, tun0, PKI at `/data/openvpn-tcp/pki`
- **openvpn-udp** — UDP on port 30094, tun1, PKI at `/data/openvpn-udp/pki`

Both instances provide access to cluster services (Service CIDR) only.
Default gateway is NOT redirected through VPN — internet traffic goes directly.
Server-side iptables FORWARD rules explicitly block VPN clients from reaching the internet
regardless of client configuration — only RFC 1918 private networks (10/8, 172.16/12, 192.168/16) are allowed.

---

## Configuration

### ConfigMap parameters

| Parameter                          | Instances | Description                                                                                      |
|------------------------------------|-----------|--------------------------------------------------------------------------------------------------|
| `SERVER_URL`                       | TCP, UDP  | External IP and port, e.g. `tcp://1.2.3.4:30094` or `udp://1.2.3.4:30094`                      |
| `SERVICE_NETWORK` / `SERVICE_MASK` | TCP, UDP  | Kubernetes Service CIDR. Check with: `kubectl get svc -n kube-system kube-dns`                  |
| `DNS_IP`                           | TCP, UDP  | CoreDNS ClusterIP. Check with: `kubectl get svc -n kube-system kube-dns`                        |
| `VPN_SUBNET`                       | TCP, UDP  | Subnet assigned to VPN clients. Must match `server` directive in `openvpn.conf`. Do not change. |
| `NODE_IFACE`                       | TCP, UDP  | Node network interface facing the internet (usually `eth0`)                                      |
| `VPN_SERVER_SUBNET`                | UDP only  | VPN client subnet via `-s` in `ovpn_genconfig`. Must differ from TCP (`192.168.255.0/24`)       |

### Changing configuration

After editing a ConfigMap, the pod must be restarted to regenerate `openvpn.conf`:

```bash
kubectl rollout restart deploy/openvpn-tcp -n openvpn
kubectl rollout restart deploy/openvpn-udp -n openvpn
```

---

## Client certificates

### Issue a new certificate

```bash
kubectl exec -it deploy/openvpn-tcp -n openvpn -- bash
easyrsa build-client-full <client-name> nopass
ovpn_getclient <client-name> > /tmp/<client-name>.ovpn
exit
```

Download the `.ovpn` file:

```powershell
kubectl cp openvpn/<pod-name>:/tmp/<client-name>.ovpn ./<client-name>.ovpn
```

### Set certificate expiry (default: 825 days)

```bash
easyrsa --days=365 build-client-full <client-name> nopass
```

### Revoke a certificate

```bash
kubectl exec -it deploy/openvpn-tcp -n openvpn -- bash
easyrsa revoke <client-name>
easyrsa gen-crl
```

The server picks up the updated CRL on next restart.

---

## Verify no default route on client

After connecting, run on the client:

```powershell
route print | findstr "0.0.0.0"
```

Expected output — only one default route via the local gateway, no VPN gateway:

```
0.0.0.0    0.0.0.0    192.168.1.1    192.168.1.x    <metric>
```

If you see a line like:

```
0.0.0.0    128.0.0.0    192.168.255.5    ...
```

— the VPN is redirecting default traffic. Check `ovpn_env.sh` on the server:

```powershell
kubectl exec deploy/openvpn-tcp -n openvpn -- cat /etc/openvpn/ovpn_env.sh | findstr DEFROUTE
```

Must be `OVPN_DEFROUTE=0`. If it is `1`, the `-d` flag is missing in `ovpn_genconfig` call inside the initContainer.

---

## Node filesystem

PKI data persists on the node via `hostPath`:

```
/data/openvpn-tcp/pki/    — TCP instance PKI, config, client certs
/data/openvpn-udp/pki/    — UDP instance PKI, config, client certs
```

To fully reset an instance (loses all issued certificates):

```bash
rm -rf /data/openvpn-tcp/pki
kubectl rollout restart deploy/openvpn-tcp -n openvpn
```
