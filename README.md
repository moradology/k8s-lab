# k8s-lab

GitOps-managed Kubernetes platform for a single-node homelab cluster
(`vulcan`). Everything the cluster runs — aside from the cluster itself
and its CNI — is installed and reconciled by Argo CD from this repo.

## What's in here

- `bootstrap/bootstrap.sh` — idempotent bring-up on a fresh Linux host:
  installs k3s (with opinionated defaults disabled), Cilium as CNI, and
  Argo CD. Then applies `bootstrap/root-app.yaml` which hands control
  to Argo CD.
- `bootstrap/root-app.yaml` — the "app of apps": a single Argo CD
  Application that watches `apps/` and installs every child Application
  found there.
- `apps/*.yaml` — one Argo CD Application per platform component
  (MetalLB, Envoy Gateway, cert-manager, external-dns, sealed-secrets,
  kube-prometheus-stack, Tailscale operator, and the post-install
  resources).
- `resources/*.yaml` — plain Kubernetes manifests that belong *on top
  of* installed components (MetalLB IPAddressPools, Gateway objects,
  Tailscale-exposed Services, etc.). Installed via the `resources`
  Argo CD Application.
- `docs/` — architecture notes, runbooks, the rundown document.

## Bootstrapping from scratch

On a fresh Linux host with sudo:

```
git clone git@github.com:moradology/k8s-lab.git
cd k8s-lab
./bootstrap/bootstrap.sh
```

Takes about 5 minutes. At the end you have a k3s cluster with Cilium
CNI and Argo CD running. Argo CD then reconciles everything else.

## Manual steps after bootstrap

Two things that can't live in plain git (yet):

1. **Tailscale OAuth credentials** — create an OAuth client at
   https://login.tailscale.com/admin/settings/oauth with tags
   `tag:k8s-operator`, Devices:Core:Write, Auth Keys:Write scopes.
   Then:
   ```
   kubectl create ns tailscale
   kubectl -n tailscale create secret generic operator-oauth \
       --from-literal=client_id=YOUR_ID \
       --from-literal=client_secret=YOUR_SECRET
   ```
   The `tailscale-operator` Application reads this secret at install
   time. Long-term, convert to a SealedSecret committed to this repo.

2. **DNS provider for external-dns** — currently configured with
   `provider=inmemory` (a no-op). When you pick a real provider,
   update `apps/external-dns.yaml` with the provider and credentials
   via a similar secret.

## Daily flow

- Change something under `apps/` or `resources/`, commit, push
- Argo CD detects the change within ~3 minutes and reconciles
- Force an immediate sync: `argocd app sync <name>` or click "Sync"
  in the UI (https://argocd.tail0df0ae.ts.net)

## Drift detection

```
argocd app list
argocd app diff <name>
```

If anyone has made a change in-cluster that isn't in git, `app diff`
shows it. Argo CD's self-heal (enabled on every Application) will
revert uncommitted drift automatically after ~3 minutes.

## What's NOT managed here

- The k3s installation itself (bootstrap concern, not GitOps)
- Cilium (bootstrap concern — it has to exist before other pods can
  schedule)
- Argo CD itself (boots itself up; we don't have Argo manage Argo
  on the first run)
- The Gemma 4 vLLM container on vulcan (runs as plain Docker, not in
  the cluster)
- The torpor2 worker + Firecracker microVMs (the worker is a k8s pod,
  but its internal microVMs are its own concern)

## Conventions

- **Namespace per component** where appropriate; put shared stuff in
  `kube-system` reluctantly
- **Pin chart versions** in each Application; bump them via PR, never
  let `HEAD` drift silently
- **No plain secrets in git.** Use SealedSecrets or reference external
  credential stores
- **Every change is a commit.** If you find yourself `kubectl
  apply`ing directly, capture it as a file here instead
