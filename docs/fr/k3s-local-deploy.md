# EdgeKit – Guide de déploiement local K3s

> **Branch:** `feature/k3s-local-test` | **Topology:** `k3s-local`

Ce guide documente le **déploiement local de EdgeKit basé sur K3s**, simulant un environnement edge réel avec un nœud master dédié et un ou plusieurs nœuds worker.

---

## 1. Vue d'ensemble de l'architecture

Le déploiement `k3s-local` suit un modèle à deux nœuds (Master + Worker). Il isole le Control Plane (Server) des équipements edge (Clients), reproduisant ainsi une véritable infrastructure IoT.

```text
 ┌──────────────────────────────────┐      ┌─────────────────────────────────┐
 │          MASTER NODE             │      │         WORKER NODE(S)          │
 │  ┌────────────────────────────┐  │      │  ┌───────────────────────────┐  │
 │  │   K3s Server (API + etcd)  │  │      │  │     K3s Agent             │  │
 │  └────────────────────────────┘  │      │  └───────────────────────────┘  │
 │  ┌────────────────────────────┐  │ MQTT │  ┌───────────────────────────┐  │
 │  │  EdgeKit Server Pod        │◄─┼──────┼──│  EdgeKit Client Pod(s)    │  │
 │  │  (Mosquitto + processor)   │  │      │  │  (émetteurs de télémesure)│  │
 │  └────────────────────────────┘  │      │  └───────────────────────────┘  │
 │  ┌────────────────────────────┐  │      │                                 │
 │  │  Helm (chart management)   │  │      │  Labels:                        │
 │  └────────────────────────────┘  │      │  edgekit.io/role=worker         │
 └──────────────────────────────────┘      └─────────────────────────────────┘
```

### Mécanismes techniques clés
- **Déploiement Zero-Touch :** Le Master planifie les pods EdgeKit Client, mais ceux-ci restent à l'état `Pending` jusqu'à ce qu'un nœud Worker rejoigne le cluster avec le label `edgekit.io/role=worker`.
- **Isolation des namespaces Containerd :** Les images Docker sont exportées puis importées directement dans le namespace interne `k8s.io` de K3s, permettant des déploiements totalement isolés d'Internet (air-gapped).
- **Pare-feu automatisé :** `ufw` et `iptables` sont configurés automatiquement par les scripts pour autoriser les communications K3s (Ports : `6443/TCP`, `8472/UDP`, `1883/TCP`).

---

## 2. Prérequis

| Rôle | Specs Min. | OS | Outils requis |
|------|-----------|----|----------------|
| **Master** | 2 vCPU, 2 Go RAM | Ubuntu/Debian (x86_64 ou ARM64) | `bash`, `curl`, `docker` |
| **Worker** | 1 vCPU, 1 Go RAM | Ubuntu/Debian/RasPiOS | `bash`, `curl` |

> **⚠️ Critique :** Assurez-vous que l'heure est synchronisée sur les deux nœuds (NTP). Une horloge désynchronisée sur le Worker provoquera des erreurs de vérification SSL (`curl: (60)`) lors de la connexion au cluster.

---

## 3. Provisionnement étape par étape

### Étape 1 : Provisionner le nœud Master
Sur votre machine principale, exécutez le script master. Cela installera K3s, configurera le pare-feu, construira l'image Server et déploiera le Helm chart.

```bash
# Optionnel : Surcharger les valeurs par défaut du chart via des variables d'environnement en ligne
CLIENT_REPLICAS=2 PUBLISH_INTERVAL_MS=5000 bash scripts/k3s-master.sh
```

À la fin du script, le `MASTER_IP` et le `K3S_TOKEN` seront affichés. Gardez-les de côté.

### Étape 2 : Provisionner le nœud Worker
Sur votre équipement edge (ou VM secondaire), exportez les identifiants fournis par le Master et exécutez le script worker.

```bash
bash scripts/k3s-worker.sh --master-ip "<IP_FROM_MASTER>" --token "<TOKEN_FROM_MASTER>"
```
Ce script installe l'agent K3s, se connecte au Master, construit l'image Client localement et applique le label `edgekit.io/role=worker` afin que les pods en attente (pending) puissent démarrer.

---

## 4. Vérification & Observabilité

Toutes les commandes de vérification doivent être exécutées sur le **nœud Master** (qui détient la configuration `kubectl`).

### 4.1 Vérifier la distribution des pods
Vérifiez que le server s'exécute sur le master et le client sur le worker.
```bash
kubectl get pods -n edgekit -o wide
```

### 4.2 Suivre la télémesure JSON en temps réel
Le Client génère en continu des métriques IoT. Pour voir les données JSON brutes transiter dans le Broker MQTT en temps réel, abonnez-vous directement à l'intérieur du pod Server :
```bash
kubectl exec -n edgekit deploy/edgekit-server -- mosquitto_sub -h localhost -p 1883 -t '#' -v
```

### 4.3 Logs de l'application
Pour afficher la sortie standard des applications :
```bash
# Logs du Server
kubectl logs -n edgekit -l app.kubernetes.io/component=server

# Logs du Client
kubectl logs -n edgekit -l app.kubernetes.io/component=client
```

---

## 5. Dépannage & Commandes d'aide

En cas de problème, utilisez ces commandes pour diagnostiquer l'anomalie.

### Débogage du nœud Master
```bash
# Vérifier si le service server K3s est sain
sudo systemctl status k3s
sudo journalctl -u k3s -f

# Vérifier le statut de la release Helm
helm list -n edgekit
```

### Débogage du nœud Worker
```bash
# Vérifier si le service agent K3s est sain
sudo systemctl status k3s-agent
sudo journalctl -u k3s-agent -f

# Si le worker ne parvient pas à rejoindre le cluster en raison d'un certificat SSL (Code 60), vérifiez la synchronisation de l'heure :
date
sudo date -s "YYYY-MM-DD HH:MM:SS"
```

---

## 6. Nettoyage & Réinitialisation

Pour supprimer complètement l'environnement, désinstaller K3s et réinitialiser les règles réseau, exécutez le script de désinstallation sur les **deux** nœuds :

```bash
bash scripts/uninstall-edgekit.sh
```
