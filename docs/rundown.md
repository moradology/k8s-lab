# Kubernetes Development on vulcan — Resource Rundown

**Audience:** you, working from the Mac thin client, driving a k3s cluster
on vulcan for infrastructure-parity testing and as the substrate for the
torpor2 worker + Firecracker microVM sandbox story.

**Physical host:** vulcan
- 48-core CPU, 184 GB RAM, 2× RTX 3090 Ti, 2× NVMe ZFS mirror at `/tank`
- GPUs reserved for vLLM (Gemma 4 tool-model); do not schedule GPU pods
  unless you have explicitly stopped the vLLM container
- `/dev/kvm` is available and required by torpor2's Firecracker backend

**Status:** k3s + full platform layer installed and running as of the
last update to this doc. Ready to develop against.

---

## 0. Quick access

| What | Where |
|---|---|
| kubectl context (Mac) | `vulcan` (default) |
| kubectl on vulcan | `~/.kube/config` (owned by `nathan`) |
| k3s systemd unit | `/etc/systemd/system/k3s.service` |
| k3s state | `/var/lib/rancher/k3s` |
| Envoy Gateway CRDs | `gateway.networking.k8s.io/v1` (Gateway, HTTPRoute, GRPCRoute...) |
| MetalLB LAN pool | `192.168.1.240–192.168.1.250` (L2 mode, vulcan LAN only) |
| Argo CD UI | `kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:443` → https://localhost:8080 |
| Argo CD admin pw | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana UI | `kubectl -n monitoring port-forward svc/kube-prom-grafana 3000:80` → http://localhost:3000 (admin/admin) |

---

## 1. Cluster

**Distribution:** k3s v1.34.6+k3s1 on bare metal
- Opinionated bits disabled at install: `traefik`, `servicelb`,
  `local-storage`, `flannel-backend`, `network-policy`
- Cluster CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`
- systemd-enabled; restarts on boot
- Commands: `sudo systemctl {status,restart} k3s`,
  `journalctl -u k3s -f`
- Uninstall: `/usr/local/bin/k3s-uninstall.sh`

---

## 2. Platform layer (installed)

| Component | Namespace | Notes |
|---|---|---|
| **Cilium** | `kube-system` | CNI + eBPF-backed kube-proxy replacement. NetworkPolicy enforcement enabled. Hubble bundled but not yet exposed. |
| **CoreDNS** | `kube-system` | cluster DNS |
| **metrics-server** | `kube-system` | enables `kubectl top` + HPA |
| **MetalLB** | `metallb-system` | L2 mode, pool `192.168.1.240-250`. See caveats under §6. |
| **Envoy Gateway** | `envoy-gateway-system` | Gateway API implementation (HTTPRoute, GRPCRoute, TCPRoute, TLSRoute, UDPRoute) |
| **cert-manager** | `cert-manager` | TLS automation; ClusterIssuers not yet configured |
| **kube-prometheus-stack** | `monitoring` | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics |
| **external-dns** | `external-dns` | installed with `provider=inmemory` as a placeholder; reconfigure when a real DNS zone is wired up |
| **sealed-secrets** | `kube-system` | bitnami-labs; encrypted secrets in git. Install `kubeseal` CLI locally to create them |
| **Argo CD** | `argocd` | GitOps control plane; points at nothing yet |

**Not installed, deliberately:**
- **Kata Containers / firecracker-containerd** — torpor2's worker
  manages its own Firecracker microVMs; a RuntimeClass would be
  redundant and conflicting
- **nvidia-device-plugin** — vLLM runs outside k8s as a plain Docker
  container. Install only when GPU pods are needed
- **Istio / Linkerd** — Cilium provides L4/L7 identity + policy without
  the full mesh ceremony
- **Traefik** — replaced by Envoy Gateway (Gateway API is the forward
  direction vs the legacy Ingress API)
- **libvirtd** — Firecracker talks to `/dev/kvm` directly; libvirt is
  not on the path. `virsh` binary is installed but daemon is not

---

## 3. torpor2 integration plan

The torpor2 worker binary is a host process that manages its own pool
of Firecracker microVMs. Kubernetes does NOT orchestrate microVMs here
— it only hosts the worker pod. Two isolation systems that do not
overlap:

- **k8s pod isolation:** worker runs as a `privileged: true` pod because
  it needs `/dev/kvm`, `CAP_NET_ADMIN` for tap/bridge setup, and
  `CAP_SYS_ADMIN` for cgroup v2 jailer work
- **Firecracker microVM isolation:** per-tool-call, managed entirely
  inside the worker process via the `agent-sandbox-firecracker` crate

**Pod skeleton (future deployment):**
```yaml
spec:
  hostNetwork: true
  containers:
  - name: worker
    image: torpor2/worker:dev
    securityContext:
      privileged: true
    volumeMounts:
    - { name: kvm, mountPath: /dev/kvm }
    - { name: run-root, mountPath: /var/lib/torpor2-run }
    - { name: base-images, mountPath: /var/lib/torpor2-images, readOnly: true }
  volumes:
  - { name: kvm, hostPath: { path: /dev/kvm } }
  - { name: run-root, hostPath: { path: /tank/torpor2-run, type: DirectoryOrCreate } }
  - { name: base-images, hostPath: { path: /tank/torpor2-images } }
```

---

## 4. Storage

- **No PV/PVC story yet** — local-storage provisioner was disabled at
  install. Add it (or Longhorn for multi-node) when a workload needs
  PVCs. For torpor2's run-root and base images, use hostPath — the
  worker owns those paths directly
- `/tank` (1.4 TB ZFS mirror) is the canonical bulk-data location
- Root disk `/` is 200 GB — watch it (k3s images, Docker images, HF
  cache all land here by default). Default eviction threshold is ~85%

---

## 5. Networking

- **Cluster CIDR:** 10.42.0.0/16 (pods)
- **Service CIDR:** 10.43.0.0/16
- **MetalLB pool:** 192.168.1.240-250 (LAN L2 mode)
- **Tailscale:** vulcan reachable at `vulcan` via MagicDNS
- **k3s API:** :6443 on vulcan, accessed via Tailscale from Mac

---

## 6. Caveats and quirks

- **MetalLB IPs are reachable only on vulcan's LAN.** The Mac reaches
  vulcan via Tailscale, which is a different network. For Mac-to-pod
  traffic from outside the LAN, use `kubectl port-forward` — manifest
  semantics are identical regardless of IP reachability. Long-term fix
  if this matters: install the Tailscale Kubernetes Operator so
  services get Tailscale-backed addresses
- **external-dns** is installed with a placeholder (`inmemory`) provider.
  It will not create real DNS records until reconfigured. Reconfigure
  via `helm upgrade external-dns ... --set provider=...` when you pick
  a provider (AWS Route53, Cloudflare, PowerDNS, etc.)
- **cert-manager** has no ClusterIssuer yet. You'll need one for any
  Certificate resource to actually provision a cert. Staging
  Let's Encrypt is the usual first step
- **Argo CD** has no Application resources yet. Point it at a git repo
  when you're ready to rehearse GitOps flow
- **Gemma 4 vLLM** runs as a plain Docker container on vulcan (port
  :30000), NOT inside k3s. It survives k3s restarts since it's not
  managed by the cluster
- **Disk pressure** evicted pods earlier — old model cache and docker
  image sprawl. If you see `DiskPressure=True` in
  `kubectl describe node vulcan`, prune with
  `sudo docker system prune -a -f`

---

## 7. Host tools on vulcan (installed)

**Kubernetes core:** kubectl, helm, kustomize, k9s, stern, argocd,
kubectx, kubens, kubeconform, kube-linter, kube-score, sops, age

**GitOps & secrets:** sops, age (kubeseal not yet — install if you use
sealed-secrets: `go install github.com/bitnami-labs/sealed-secrets/cmd/kubeseal@latest`)

**Generic dev:** just, direnv, delta, lazygit, gh, hyperfine, grpcurl,
httpie, websocat, jq

**Firecracker / microVM:** firectl, crictl (via k3s), bpftrace, virsh
(binary only, no daemon), perf, flamegraph.pl

**Chaos / fault injection:** toxiproxy-cli, toxiproxy-server

**Rust / torpor2 dev:** bacon, cargo-nextest, cargo-audit, cargo-deny,
cargo-mutants, typos (all on Rust stable 1.95; default toolchain bumped
from the old 1.85 pin)

**Already present:** direnv, delta, lazygit, gh, hyperfine, bpftrace, perf

---

## 8. Mac thin-client toolkit (installed via brew)

kubectl, helm, kustomize, k9s, stern, kubectx, argocd, sops, age,
kubeconform, kube-linter, kube-score, just, direnv, git-delta, lazygit,
gh, hyperfine, grpcurl, httpie, websocat

**Kubeconfig:** `~/.kube/config` has the `vulcan` context (default).
Merged from k3s's kubeconfig with the server URL rewritten to
`https://vulcan:6443` so Tailscale MagicDNS resolves it.

---

## 9. Development loop

1. `s vulcan` — fish auto-attaches to tmux session `main`
2. `cd /tank/projects/torpor2`, run `bacon` for background check/clippy
3. Edit locally or over SSH; Rust compilation stays on vulcan
4. From Mac: `kubectl` / `k9s` / `stern` against the remote cluster
5. Commit + push from the Mac; Argo CD pulls and reconciles
6. Results visible both in `bacon` and in Grafana

---

## 10. What to do next (playbook)

**Gateway wiring (when ready):**
1. Create a `GatewayClass` (Envoy Gateway ships one — check
   `kubectl get gatewayclass`)
2. Create a `Gateway` listening on :80 and :443
3. Point the Gateway at a MetalLB-provided LoadBalancer service
4. Create `HTTPRoute` resources per backend app

**First cert-manager use:**
1. Create a `ClusterIssuer` for Let's Encrypt staging
2. Add TLS to the Gateway's HTTPS listener referencing a
   `Certificate` the issuer will provision

**ArgoCD bootstrap:**
1. Create a public or private git repo (`moradology/k8s-dev-cluster`
   for example)
2. `argocd app create platform --repo <repo> --path apps --dest-namespace argocd --dest-server https://kubernetes.default.svc`
3. Put your cluster configs under `apps/` in that repo; every push
   gets reconciled

**When torpor2 is ready to containerize:**
1. Build the worker image
2. Write the privileged DaemonSet/Deployment manifest per §3
3. Apply as a normal k8s resource; Firecracker children spawn inside
   the pod via `/dev/kvm`

---

## 11. Where things live

- **This doc:** `~/Sync/k8s-dev-rundown.md` on vulcan, replicated to
  Mac via Syncthing
- **Quantization project:** `/tank/projects/qwen36-awq`
  (abandoned — quant tooling not ready for Qwen3.6 arch)
- **HF model cache:** `~/.cache/huggingface` (owned partially by root
  due to docker vLLM mount — use `sudo` to clean up)
- **torpor2 source:** `/tank/projects/torpor2`

---

## 12. Undo / nuke

- Kill k3s (keeps host otherwise untouched):
  `/usr/local/bin/k3s-killall.sh` (graceful),
  `/usr/local/bin/k3s-uninstall.sh` (full wipe)
- Kill a single Helm release: `helm uninstall <name> -n <ns>`
- Nuke all platform installs except k3s itself:
  ```
  for r in metallb cert-manager kube-prom external-dns sealed-secrets argo-cd eg cilium; do
    helm uninstall $r -n <ns> 2>/dev/null
  done
  ```
