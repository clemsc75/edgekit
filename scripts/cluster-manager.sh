#!/usr/bin/env bash
# =============================================================================
# scripts/cluster-manager.sh
# 
# Description: Script exécuté périodiquement sur le Master pour :
#   1. Purger les anciens nœuds (NotReady) pour gérer les conflits d'IP.
#   2. Ajuster dynamiquement (auto-scale) le nombre de réplicas du client
#      pour correspondre au nombre de workers "Ready".
# =============================================================================

NAMESPACE="edgekit"
DEPLOYMENT="edgekit-client"

# Prévention des exécutions simultanées (Race condition)
# Utilise le descripteur de fichier 200 pour poser un verrou
exec 200>/tmp/edgekit-cluster-manager.lock
flock -n 200 || exit 1

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if command -v kubectl >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif command -v k3s >/dev/null 2>&1; then
  KUBECTL="k3s kubectl"
else
  echo "Erreur: kubectl n'est pas disponible."
  exit 1
fi

# On supprime l'écho de date systématique pour rendre le cron silencieux par défaut.

# ---------------------------------------------------------
# 1. Nettoyage des nœuds NotReady
# ---------------------------------------------------------
# On ne procède que si kubectl arrive à communiquer avec le cluster
if ! nodes_out=$($KUBECTL get nodes --no-headers 2>/dev/null); then
  echo "Erreur: K3s API injoignable, abandon du cycle." >&2
  exit 1
fi

echo "$nodes_out" | awk '$2 ~ /NotReady/ {print $1}' | while read -r node; do
  if [ -n "$node" ]; then
    echo "$(date) - Suppression du noeud inactif: $node"
    $KUBECTL delete node "$node" >/dev/null 2>&1 || true
  fi
done

# ---------------------------------------------------------
# 2. Auto-scaling du déploiement
# ---------------------------------------------------------
# On compte les nœuds portant le tag edgekit.io/role=worker qui sont à l'état Ready
WORKER_COUNT=$(echo "$nodes_out" | awk '$2 ~ /Ready/ && $2 !~ /NotReady/' | wc -l)
# Kubernetes adds multiple conditions, but a simpler count of Ready nodes matching the label is safer:
WORKER_COUNT=$($KUBECTL get nodes -l edgekit.io/role=worker -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)

if [ -z "$WORKER_COUNT" ]; then
  WORKER_COUNT=0
fi

# Récupère le nombre actuel de réplicas pour ne pas scale inutilement
# Note: kubectl get deployment ignore les erreurs si le déploiement n'est pas encore créé
CURRENT_REPLICAS=$($KUBECTL get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "N/A")

if [ "$CURRENT_REPLICAS" != "N/A" ]; then
  if [ "$WORKER_COUNT" -ne "$CURRENT_REPLICAS" ]; then
    echo "$(date) - Ajustement du déploiement $DEPLOYMENT: $CURRENT_REPLICAS -> $WORKER_COUNT replicas"
    $KUBECTL scale deployment -n "$NAMESPACE" "$DEPLOYMENT" --replicas="$WORKER_COUNT" >/dev/null 2>&1 || true
  fi
fi
