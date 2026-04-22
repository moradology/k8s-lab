#!/usr/bin/env bash
# Bring up a fresh Linux host to a k3s + Cilium + Argo CD baseline,
# then hand off to GitOps via the root Argo CD Application.
#
# Idempotent: safe to re-run. Each step checks whether it's already done.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/moradology/k8s-lab.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }
}

require curl
require sudo

echo "===== [1/4] k3s ====="
if ! systemctl is-active k3s >/dev/null 2>&1; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="\
        --disable=traefik \
        --disable=servicelb \
        --disable=local-storage \
        --flannel-backend=none \
        --disable-network-policy \
        --cluster-cidr=10.42.0.0/16 \
        --service-cidr=10.43.0.0/16" sh -
else
    echo "k3s already installed and running"
fi

# kubeconfig for the invoking user
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

echo
echo "===== [2/4] helm ====="
if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

echo
echo "===== [3/4] Cilium (CNI) ====="
if ! helm -n kube-system list | grep -q '^cilium'; then
    helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
    helm repo update cilium
    helm install cilium cilium/cilium \
        --namespace kube-system \
        --version 1.19.3 \
        --set operator.replicas=1 \
        --set ipam.mode=kubernetes \
        --set k8sServiceHost=$(hostname) \
        --set k8sServicePort=6443 \
        --set kubeProxyReplacement=true
else
    echo "cilium already installed"
fi

echo "waiting for node to become Ready..."
while [ "$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')" != "True" ]; do
    sleep 3
done
echo "node Ready."

echo
echo "===== [4/4] Argo CD + root app ====="
if ! helm -n argocd list 2>/dev/null | grep -q '^argo-cd'; then
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update argo
    kubectl create namespace argocd 2>/dev/null || true
    helm install argo-cd argo/argo-cd \
        -n argocd \
        --set configs.params."server\.insecure"=true
    kubectl -n argocd wait --for=condition=available deploy --all --timeout=180s
else
    echo "argo-cd already installed"
fi

# Hand off to GitOps.
kubectl apply -f "$(dirname "$0")/root-app.yaml"

echo
echo "===== done ====="
echo "Argo CD will reconcile the rest of the platform from ${REPO_URL}@${REPO_BRANCH}."
echo "Watch progress:  kubectl -n argocd get applications -w"
echo "Argo CD UI:      kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443"
echo "Admin password:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
