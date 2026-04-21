FROM eclipse-mosquitto:2.0

LABEL org.opencontainers.image.title="edgekit-server"
LABEL org.opencontainers.image.description="Central MQTT broker for edgekit (WebSocket + plain MQTT)"
LABEL org.opencontainers.image.source="https://github.com/perspikapps/edgekit"

COPY mosquitto.conf /mosquitto/config/mosquitto.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 1883 9001

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
