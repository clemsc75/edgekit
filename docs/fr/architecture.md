# Architecture

## Vue d'ensemble

EdgeKit est une plateforme IoT edge légère composée de deux types de conteneurs :

| Composant | Image | Rôle |
|---|---|---|
| **server** | `edgekit-server` | Broker MQTT central Eclipse Mosquitto |
| **client** | `edgekit-client` | Agent edge – collecte les métriques, les envoie au server |

---

## Server

Le server est une instance unique de [Eclipse Mosquitto](https://mosquitto.org/) configurée avec deux listeners :

| Port | Protocole | Utilisation |
|------|----------|-------|
| 1883 | MQTT (TCP) | Communication interne du cluster |
| 9001 | MQTT over WebSocket | Clients navigateur, outils externes |

**Fichier de configuration** : `server/mosquitto.conf`

Mosquitto est le broker MQTT léger de référence pour les workloads IoT. Il gère l'ensemble du routage pub/sub ; aucun code server personnalisé n'est requis.

### Persistance des données

Lors d'un déploiement via Helm, l'état du broker (messages conservés, etc.) est stocké dans un `PersistentVolumeClaim`. En mode local Docker Compose, un volume Docker nommé est utilisé.

---

## Client

Le client est une application Node.js qui :

1. Se connecte au broker MQTT via WebSocket (`MQTT_BROKER_URL`)
2. Collecte périodiquement les métriques système en utilisant la bibliothèque [`systeminformation`](https://systeminformation.io/)
3. Sérialise les métriques au format JSON et les publie sur `<MQTT_TOPIC_PREFIX>/<CLIENT_ID>/metrics`

### Format du payload publié

```json
{
  "clientId": "edge-local-1",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "uptime": 123456,
  "cpu": {
    "loadPercent": 12.34,
    "cores": 4
  },
  "memory": {
    "totalBytes": 8589934592,
    "usedBytes": 3221225472,
    "freeBytes": 5368709120,
    "usedPercent": 37.50
  },
  "filesystems": [
    {
      "mount": "/",
      "type": "ext4",
      "totalBytes": 107374182400,
      "usedBytes": 21474836480,
      "usedPercent": 20.00
    }
  ],
  "network": [
    {
      "iface": "eth0",
      "rxBytesTotal": 104857600,
      "txBytesTotal": 52428800
    }
  ]
}
```

### Comportement de reconnexion

Le client MQTT utilise une stratégie de reconnexion avec exponential-back-off (intégrée au package npm `mqtt`) avec une période de base de 5 secondes. Le conteneur s'arrête proprement sur SIGTERM/SIGINT, en terminant d'abord les publications en cours.

### Image de base

L'image Docker `edgekit-client` utilise l'image de base officielle `node:20-alpine`. Ce choix permet de disposer d'un runtime Node.js compact et officiellement maintenu tout en gardant le conteneur léger et sécurisé. Voir [ISSUE_03](../issue/ISSUE_03_migrate-to-alpine-base-image.md) pour les détails de migration et les résultats de validation.

---

## Structure des topics

```
edgekit/
└── <client-id>/
    └── metrics      ← Télémesure JSON (QoS 1)
```

Les consommateurs peuvent s'abonner à `edgekit/#` pour recevoir toutes les métriques de tous les clients, ou à `edgekit/<client-id>/metrics` pour un agent spécifique.

---

## Déploiement Kubernetes / k3s

```
Namespace: edgekit
│
├── Deployment: edgekit-server     (replicas: 1)
│   └── Container: mosquitto
├── Service: edgekit-server
│   ├── ClusterIP :1883 (mqtt)
│   └── ClusterIP :9001 (websockets)
├── PersistentVolumeClaim: edgekit-server-data
│
└── Deployment: edgekit-client     (replicas: N)
    └── Container: edge-agent
```

Le Helm chart situé dans `helm/edgekit/` déploie l'ensemble de ces ressources. Les pods client utilisent la downward API de Kubernetes pour configurer `CLIENT_ID` à partir de `metadata.name`, garantissant ainsi que chaque réplica possède un identifiant unique.

---

## Extension de EdgeKit

L'architecture est volontairement minimale. Extensions courantes :

- **Ajout de l'authentification** : Configurer des fichiers de mots de passe Mosquitto ou des certificats TLS via un Secret Kubernetes monté dans le conteneur server.
- **Ajout d'un dashboard** : Déployer [MQTT Explorer](https://mqtt-explorer.com/) ou [Grafana + EMQX](https://docs.emqx.com/en/emqx/latest/dashboard/introduction.html) en tant que pods supplémentaires.
- **Métriques personnalisées** : Étendre `client/src/index.js` pour publier des données supplémentaires (lectures GPIO, capteurs personnalisés, logs d'application, etc.). Par exemple, à l'intérieur de `collectMetrics()` :
  ```javascript
  // 1. Récupérer vos données personnalisées
  const temperature = await getSensorData(); 
  
  return {
    // ... propriétés existantes
    custom: {
      temperature: temperature,
      status: "ok"
    }
  };
  ```
- **Namespaces multiples** : Déployer le chart plusieurs fois avec des valeurs `MQTT_TOPIC_PREFIX` différentes.
