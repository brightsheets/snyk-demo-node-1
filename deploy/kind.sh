#!/usr/bin/env bash
# Deploy the hardened goof app to a local kind cluster.
#
#   bash deploy/kind.sh            # create cluster (with Calico for NetworkPolicy), build, deploy
#   bash deploy/kind.sh --scan     # also run Snyk Container + IaC scans before deploying
#   bash deploy/kind.sh --delete   # delete the cluster
#
# Needs: docker, kind, kubectl. Optional: snyk (for --scan).
# kind's default CNI doesn't enforce NetworkPolicy, so the cluster is created without it and
# Calico is installed instead.
set -euo pipefail

CLUSTER=goof
IMAGE=goof-secure:local
CALICO_VERSION=v3.29.1
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--delete" ]]; then
  kind delete cluster --name "$CLUSTER"
  exit 0
fi

if ! kind get clusters | grep -qx "$CLUSTER"; then
  cat <<'EOF' | kind create cluster --name "$CLUSTER" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s
fi

docker build -f Dockerfile.secure -t "$IMAGE" .

if [[ "${1:-}" == "--scan" ]]; then
  snyk container test "$IMAGE" --file=Dockerfile.secure --severity-threshold=high || true
  snyk iac test k8s/ --severity-threshold=medium || true
fi

kind load docker-image "$IMAGE" --name "$CLUSTER"

kubectl apply -f k8s/goof.yaml
# Credentials are generated here and live only in the cluster.
if ! kubectl -n goof get secret goof-mongo-auth >/dev/null 2>&1; then
  kubectl -n goof create secret generic goof-mongo-auth \
    --from-literal=username=goof \
    --from-literal=password="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
fi
kubectl -n goof rollout status deploy/goof-mongo --timeout=180s
kubectl -n goof rollout status deploy/goof --timeout=180s

echo
echo "Open the app:  kubectl -n goof port-forward svc/goof 3001:80   then http://localhost:3001"
