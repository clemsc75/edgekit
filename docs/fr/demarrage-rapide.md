# Guide de démarrage rapide

Ce guide vous explique comment exécuter EdgeKit localement puis le déployer sur un cluster K3s.

---

## Exécution locale avec Docker Compose

### Prérequis

- [Docker](https://docs.docker.com/get-docker/) ≥ 24 (avec Compose v2)
- Git

### Étapes

#### 1. Cloner le dépôt

```bash
git clone https://github.com/perspikapps/edgekit.git
cd edgekit
```

#### 2. (Optionnel) Construire les images manuellement

```bash
./scripts/build.sh
```

#### 3. Démarrer l'ensemble de la stack

```bash
./scripts/start-local.sh
```

Sortie attendue :

```
==> Starting edgekit stack (builds images if needed)…
[+] Building …
[+] Running 2/2
 ✔ Container edgekit-server  Started
 ✔ Container edgekit-client  Started

✅ edgekit is running!

   MQTT broker:       mqtt://localhost:1883
   MQTT over WS:      ws://localhost:9001

   View logs:         docker compose logs -f
   Stop:              ./scripts/stop-local.sh
```

#### 4. Vérifier que les métriques transitent

Ouvrez un second terminal et abonnez-vous à tous les topics :

```bash
docker run --rm --network host eclipse-mosquitto:2.0 \
  mosquitto_sub -h localhost -t "edgekit/#" -v
```

Vous devriez voir des payloads JSON arriver toutes les 5 secondes :

```
edgekit/edge-local-1/metrics {"clientId":"edge-local-1","timestamp":"2024-01-15T10:30:00.000Z","cpu":{"loadPercent":5.12},...}
```

#### 5. Arrêter la stack

```bash
./scripts/stop-local.sh
```

---

## Déploiement sur K3s

### Prérequis

- Un cluster K3s (un seul nœud suffit pour les tests)
- [Helm](https://helm.sh/docs/intro/install/) ≥ 3.14
- `kubectl` configuré pour le cluster

### Option A – Installer depuis GHCR (recommandé)

```bash
helm install edgekit oci://ghcr.io/perspikapps/charts/edgekit \
  --namespace edgekit \
  --create-namespace \
  --wait
```

### Option B – Installer depuis le chart local

```bash
helm install edgekit ./helm/edgekit \
  --namespace edgekit \
  --create-namespace \
  --wait
```

### Vérifier le déploiement

```bash
kubectl -n edgekit get pods
# NAME                               READY   STATUS    RESTARTS
# edgekit-server-xxxxxxxxxx-xxxxx   1/1     Running   0
# edgekit-client-xxxxxxxxxx-xxxxx   1/1     Running   0

kubectl -n edgekit logs -f -l app.kubernetes.io/component=client
# [edgekit-client] Starting — id=edgekit-client-xxxxx broker=ws://edgekit-server:9001
# [edgekit-client] Connected to ws://edgekit-server:9001
# [edgekit-client] Published to edgekit/edgekit-client-xxxxx/metrics
```

### Augmenter le nombre de clients (Scaling)

```bash
helm upgrade edgekit ./helm/edgekit \
  --namespace edgekit \
  --set client.replicaCount=3
```

### Modifier l'intervalle de publication

```bash
helm upgrade edgekit ./helm/edgekit \
  --namespace edgekit \
  --set client.publishIntervalMs=10000
```

### Désinstallation

```bash
helm uninstall edgekit --namespace edgekit
kubectl delete namespace edgekit
```

---

## S'abonner aux métriques depuis l'extérieur du cluster

Transférez le port WebSocket vers votre machine locale :

```bash
kubectl -n edgekit port-forward svc/edgekit-server 9001:9001
```

Connectez ensuite n'importe quel client MQTT-over-WebSocket à `ws://localhost:9001`.

Exemple utilisant `mosquitto_sub` avec support WebSocket :

```bash
docker run --rm --network host eclipse-mosquitto:2.0 \
  mosquitto_sub -h localhost -p 9001 -t "edgekit/#" -v
```

---

## Référence des variables d'environnement

| Variable | Valeur par défaut | Description |
|---|---|---|
| `MQTT_BROKER_URL` | `ws://edgekit-server:9001` | URL WebSocket complète du broker |
| `MQTT_TOPIC_PREFIX` | `edgekit` | Préfixe pour tous les topics publiés |
| `CLIENT_ID` | nom du pod (k8s) / `edge-local-1` (compose) | Identifiant unique de l'agent |
| `PUBLISH_INTERVAL_MS` | `5000` | Intervalle de publication des métriques (ms) |
