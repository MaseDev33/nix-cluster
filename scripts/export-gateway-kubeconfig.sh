#!/usr/bin/env bash
set -euo pipefail

readonly namespace=kube-system
readonly service_account=gateway-sync
readonly secret=gateway-sync-token
readonly output=/etc/rancher/k3s/gateway.yaml
readonly server=${1:-https://10.100.0.10:6443}
readonly source_kubeconfig=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root on a cluster server, or set KUBECONFIG to an administrator kubeconfig." >&2
  exit 1
fi
command -v kubectl >/dev/null || { echo "kubectl is required." >&2; exit 1; }
[[ -r "$source_kubeconfig" ]] || {
  echo "Cannot read administrator kubeconfig $source_kubeconfig." >&2
  exit 1
}

token=$(kubectl --kubeconfig "$source_kubeconfig" -n "$namespace" get secret "$secret" \
  -o 'jsonpath={.data.token}' | base64 --decode)
ca=$(kubectl --kubeconfig "$source_kubeconfig" -n "$namespace" get secret "$secret" \
  -o 'jsonpath={.data.ca\.crt}')
[[ -n "$token" && -n "$ca" ]] || {
  echo "The gateway ServiceAccount token Secret is not populated; apply k8s/gateway-rbac.yaml first." >&2
  exit 1
}

install -d -m 0700 "$(dirname "$output")"
temporary=$(mktemp "$(dirname "$output")/.gateway.XXXXXX")
trap 'rm -f "$temporary"; unset token' EXIT
cat > "$temporary" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
    certificate-authority-data: $ca
    server: $server
contexts:
- name: gateway
  context:
    cluster: cluster
    user: gateway-sync
current-context: gateway
users:
- name: gateway-sync
  user:
    token: $token
EOF
chmod 0600 "$temporary"
mv -f "$temporary" "$output"
unset token
echo "Created read-only gateway kubeconfig at $output."
