# shellcheck shell=bash disable=SC2034

# Szenario k: MicroK8s (Snap) vor dem Kopieren installieren, einmal starten lassen und stoppen,
# damit /var/snap/microk8s/common echte Daten (dqlite, containerd) enthaelt.
snap install microk8s --classic --channel=1.35/stable
microk8s status --wait-ready --timeout 400
microk8s kubectl get nodes
snap stop microk8s
