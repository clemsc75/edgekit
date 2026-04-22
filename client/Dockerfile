FROM opensuse/leap-micro:6.2

RUN zypper --non-interactive install --no-recommends nodejs20 npm20 && \
    zypper clean --all && \
    useradd --create-home --shell /bin/sh node

LABEL org.opencontainers.image.title="edgekit-client"
LABEL org.opencontainers.image.description="Edge agent for edgekit – collects metrics and streams to central MQTT broker"
LABEL org.opencontainers.image.source="https://github.com/perspikapps/edgekit"

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY src/ ./src/

ENV MQTT_BROKER_URL=ws://edgekit-server:9001
ENV MQTT_TOPIC_PREFIX=edgekit
ENV CLIENT_ID=edge-local-1
ENV PUBLISH_INTERVAL_MS=5000

USER node

CMD ["node", "src/index.js"]
