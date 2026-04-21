#!/bin/sh
set -e

# Ensure data and log directories exist and are writable
mkdir -p /mosquitto/data /mosquitto/log
chown -R mosquitto:mosquitto /mosquitto/data /mosquitto/log 2>/dev/null || true

exec "$@"
