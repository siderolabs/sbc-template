#!/usr/bin/env bash
# EXPERIMENTAL: join this Debian-based management node (Quartz64 A, 4/8 GB) to the
# Talos cluster as a tainted, non-Talos worker, so imaging/PXE/helper jobs can be
# scheduled on it with kubectl like everything else. Not for the 512 MB Pi Zero.
#
#   sudo KUBECONFIG=/etc/sbc-quartz/kubeconfig mgmt/join-cluster.sh [--node-ip 10.20.0.5]
#   sudo KUBECONFIG=/etc/sbc-quartz/kubeconfig mgmt/join-cluster.sh --leave
#
# How: a short-lived bootstrap token + standard kubelet TLS bootstrapping (no kubeadm,
# nothing changed on the Talos nodes). kubelet matches the cluster's Kubernetes version
# (pkgs.k8s.io), containerd from Debian. The node is tainted
#   sbc-quartz.io/management=true:NoSchedule
# so only pods that tolerate it land here (DaemonSets such as kube-proxy/flannel do).
# Talos points kube-proxy/flannel at KubePrism (127.0.0.1:7445); a socat unit provides
# the same endpoint here. holzkube-manager and the caches stay on the host, untouched.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
: "${KUBECONFIG:=/etc/sbc-quartz/kubeconfig}"; export KUBECONFIG
node="$(hostname -s)"
node_ip=""; leave=false; domain=cluster.local
while [ $# -gt 0 ]; do
  case "$1" in
    --node-ip) node_ip="$2"; shift ;;
    --cluster-domain) domain="$2"; shift ;;
    --leave) leave=true ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done
[ -f "${KUBECONFIG}" ] || { echo "need an admin kubeconfig at ${KUBECONFIG} (holzkubectl kubeconfig <cluster>)" >&2; exit 1; }

kc() { kubectl --kubeconfig "${KUBECONFIG}" "$@"; }

if ${leave}; then
  kc drain "${node}" --ignore-daemonsets --delete-emptydir-data --force || true
  kc delete node "${node}" || true
  systemctl disable --now kubelet kubeprism-shim 2>/dev/null || true
  rm -f /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf
  rm -rf /var/lib/kubelet/pki
  echo "left the cluster; packages kept"; exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl gpg jq socat conntrack iptables containerd

# --- cluster facts from the admin kubeconfig -----------------------------------
if ! command -v kubectl >/dev/null; then
  arch=arm64; v="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${v}/bin/linux/${arch}/kubectl"; chmod +x /usr/local/bin/kubectl
fi
server="$(kc config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
kc config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt
kver="$(kc version -o json | jq -r .serverVersion.gitVersion)"     # e.g. v1.35.2
minor="$(echo "${kver}" | cut -d. -f1-2)"
dns="$(kc -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')"
cp_hostport="${server#https://}"
[ -n "${node_ip}" ] || node_ip="$(ip -4 route get "${cp_hostport%:*}" | sed -nE 's/.* src ([0-9.]+).*/\1/p')"
echo "cluster ${server}, Kubernetes ${kver}, DNS ${dns}, this node ${node} @ ${node_ip}"

# --- kubelet matching the cluster ----------------------------------------------
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${minor}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-mark unhold kubelet >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends --allow-downgrades "kubelet=${kver#v}-*"
apt-mark hold kubelet

# --- kernel + containerd -------------------------------------------------------
printf 'overlay\nbr_netfilter\nvxlan\n' > /etc/modules-load.d/k8s.conf
modprobe overlay; modprobe br_netfilter; modprobe vxlan || true
printf 'net.ipv4.ip_forward=1\nnet.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\n' > /etc/sysctl.d/90-k8s.conf
sysctl --system >/dev/null
mkdir -p /etc/containerd /opt/cni/bin
[ -s /etc/containerd/config.toml ] && grep -q SystemdCgroup /etc/containerd/config.toml || containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# base CNI plugins: pkgs.k8s.io's kubernetes-cni (pulled in by kubelet) puts them in /opt/cni/bin
if [ ! -x /opt/cni/bin/bridge ]; then
  apt-get install -y --no-install-recommends containernetworking-plugins
  for p in /usr/lib/cni/*; do [ -e "/opt/cni/bin/${p##*/}" ] || ln -s "$p" /opt/cni/bin/; done
fi
if [ ! -x /opt/cni/bin/flannel ]; then   # flannel's CNI plugin isn't in the Debian package
  fv="$(curl -fsSL https://api.github.com/repos/flannel-io/cni-plugin/releases/latest | jq -r .tag_name)"
  curl -fsSL "https://github.com/flannel-io/cni-plugin/releases/download/${fv}/cni-plugin-flannel-linux-arm64-${fv}.tgz" | tar xz -C /tmp
  install -m 0755 /tmp/flannel-arm64 /opt/cni/bin/flannel
fi
systemctl restart containerd

# --- KubePrism stand-in: 127.0.0.1:7445 -> API server --------------------------
cat > /etc/systemd/system/kubeprism-shim.service <<UNIT
[Unit]
Description=Local API endpoint like Talos KubePrism (127.0.0.1:7445 -> ${cp_hostport})
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:7445,bind=127.0.0.1,reuseaddr,fork TCP:${cp_hostport}
Restart=always
[Install]
WantedBy=multi-user.target
UNIT

# --- TLS bootstrap: RBAC (idempotent) + 1 h token ------------------------------
bind() { kc create clusterrolebinding "$1" --clusterrole="$2" --group="$3" --dry-run=client -o yaml | kc apply -f - >/dev/null; }
bind sbc-quartz:node-bootstrapper system:node-bootstrapper system:bootstrappers
bind sbc-quartz:node-autoapprove-bootstrap system:certificates.k8s.io:certificatesigningrequests:nodeclient system:bootstrappers
bind sbc-quartz:node-autoapprove-renewal system:certificates.k8s.io:certificatesigningrequests:selfnodeclient system:nodes
tid="$(tr -dc a-z0-9 </dev/urandom | head -c6)"; tsec="$(tr -dc a-z0-9 </dev/urandom | head -c16)"
kc -n kube-system create secret generic "bootstrap-token-${tid}" --type bootstrap.kubernetes.io/token \
  --from-literal=token-id="${tid}" --from-literal=token-secret="${tsec}" \
  --from-literal=usage-bootstrap-authentication=true \
  --from-literal=expiration="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=description="sbc-quartz management node join (${node})"

install -d -m 0755 /etc/kubernetes/pki /var/lib/kubelet
install -m 0644 /tmp/ca.crt /etc/kubernetes/pki/ca.crt
cat > /etc/kubernetes/bootstrap-kubelet.conf <<KC
apiVersion: v1
kind: Config
clusters: [{name: talos, cluster: {server: "${server}", certificate-authority: /etc/kubernetes/pki/ca.crt}}]
users: [{name: bootstrap, user: {token: "${tid}.${tsec}"}}]
contexts: [{name: bootstrap, context: {cluster: talos, user: bootstrap}}]
current-context: bootstrap
KC
chmod 0600 /etc/kubernetes/bootstrap-kubelet.conf
cat > /var/lib/kubelet/config.yaml <<CFG
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous: {enabled: false}
  webhook: {enabled: true}
  x509: {clientCAFile: /etc/kubernetes/pki/ca.crt}
authorization: {mode: Webhook}
cgroupDriver: systemd
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
clusterDNS: ["${dns}"]
clusterDomain: ${domain}
rotateCertificates: true
failSwapOn: false
registerWithTaints:
  - {key: sbc-quartz.io/management, value: "true", effect: NoSchedule}
systemReserved: {cpu: 500m, memory: 768Mi}
CFG
mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/10-sbc-quartz.conf <<DROP
[Service]
ExecStart=
ExecStart=/usr/bin/kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --config=/var/lib/kubelet/config.yaml --node-ip=${node_ip} --node-labels=sbc-quartz.io/role=management
DROP
systemctl daemon-reload
systemctl enable --now kubeprism-shim
systemctl enable kubelet && systemctl restart kubelet

echo "waiting for ${node} to register and be Ready..."
for _ in $(seq 60); do kc get node "${node}" >/dev/null 2>&1 && break; sleep 5; done
if kc wait --for=condition=Ready "node/${node}" --timeout=300s; then
  kc -n kube-system delete secret "bootstrap-token-${tid}" >/dev/null
  kc get node "${node}" -o wide
else
  echo "not Ready yet: journalctl -u kubelet -e ; kubectl get pods -A -o wide --field-selector spec.nodeName=${node}" >&2
  exit 1
fi
