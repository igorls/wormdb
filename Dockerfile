# Dockerfile for WormDB
# Uses pre-built binary from host (meshguard embedded as library)

FROM debian:trixie-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsodium23 \
    libssl3 \
    ca-certificates \
    netcat-openbsd \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /data

# Copy pre-built binary (meshguard is embedded, no separate binary needed)
COPY zig-out/bin/wormdb /usr/bin/wormdb
RUN chmod +x /usr/bin/wormdb

# Create data directory
RUN mkdir -p /data

EXPOSE 6389
# QUIC/WebTransport port
EXPOSE 6394/udp
# Gossip port for SWIM protocol
EXPOSE 51821/udp
# WireGuard port
EXPOSE 51830/udp

HEALTHCHECK --interval=5s --timeout=3s --start-period=2s --retries=3 \
    CMD echo "PING" | nc -w1 localhost 6389 || exit 1

ENTRYPOINT ["/usr/bin/wormdb"]
CMD ["--port", "6389", "--data", "/data"]