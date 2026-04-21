'use strict';

const mqtt = require('mqtt');
const si = require('systeminformation');

const BROKER_URL = process.env.MQTT_BROKER_URL || 'ws://edgekit-server:9001';
const TOPIC_PREFIX = process.env.MQTT_TOPIC_PREFIX || 'edgekit';
const CLIENT_ID = process.env.CLIENT_ID || `edge-${Math.random().toString(16).slice(2, 8)}`;
const INTERVAL_MS = parseInt(process.env.PUBLISH_INTERVAL_MS || '5000', 10);

console.log(`[edgekit-client] Starting — id=${CLIENT_ID} broker=${BROKER_URL}`);

const client = mqtt.connect(BROKER_URL, {
  clientId: CLIENT_ID,
  reconnectPeriod: 5000,
  connectTimeout: 30000,
});

client.on('connect', () => {
  console.log(`[edgekit-client] Connected to ${BROKER_URL}`);
  startPublishing();
});

client.on('error', (err) => {
  console.error('[edgekit-client] MQTT error:', err.message);
});

client.on('reconnect', () => {
  console.log('[edgekit-client] Reconnecting…');
});

client.on('close', () => {
  console.log('[edgekit-client] Connection closed');
});

async function collectMetrics() {
  const [cpu, mem, fsSize, networkStats, time] = await Promise.all([
    si.currentLoad(),
    si.mem(),
    si.fsSize(),
    si.networkStats(),
    si.time(),
  ]);

  return {
    clientId: CLIENT_ID,
    timestamp: new Date().toISOString(),
    uptime: time.uptime,
    cpu: {
      loadPercent: parseFloat(cpu.currentLoad.toFixed(2)),
      cores: cpu.cpus ? cpu.cpus.length : undefined,
    },
    memory: {
      totalBytes: mem.total,
      usedBytes: mem.used,
      freeBytes: mem.free,
      usedPercent: parseFloat(((mem.used / mem.total) * 100).toFixed(2)),
    },
    filesystems: (fsSize || []).map((fs) => ({
      mount: fs.mount,
      type: fs.type,
      totalBytes: fs.size,
      usedBytes: fs.used,
      usedPercent: parseFloat(fs.use.toFixed(2)),
    })),
    network: (networkStats || []).slice(0, 4).map((iface) => ({
      iface: iface.iface,
      rxBytesTotal: iface.rx_bytes,
      txBytesTotal: iface.tx_bytes,
    })),
  };
}

let publishTimer = null;

async function startPublishing() {
  const publish = async () => {
    try {
      const metrics = await collectMetrics();
      const topic = `${TOPIC_PREFIX}/${CLIENT_ID}/metrics`;
      client.publish(topic, JSON.stringify(metrics), { qos: 1 }, (err) => {
        if (err) {
          console.error('[edgekit-client] Publish error:', err.message);
        } else {
          console.log(`[edgekit-client] Published to ${topic}`);
        }
      });
    } catch (err) {
      console.error('[edgekit-client] Collect error:', err.message);
    }
  };

  // Publish immediately, then on interval
  await publish();
  publishTimer = setInterval(publish, INTERVAL_MS);
}

process.on('SIGTERM', () => {
  console.log('[edgekit-client] SIGTERM received, shutting down…');
  if (publishTimer) clearInterval(publishTimer);
  client.end(false, {}, () => process.exit(0));
});

process.on('SIGINT', () => {
  console.log('[edgekit-client] SIGINT received, shutting down…');
  if (publishTimer) clearInterval(publishTimer);
  client.end(false, {}, () => process.exit(0));
});
