# syntax=docker/dockerfile:1
# The homeswift bridge in a container, for a NAS or any Linux server (docs/synology.md). Published to GHCR for
# linux/amd64 and linux/arm64 by .github/workflows/docker.yml. Run it with host networking: HomeKit finds the
# bridge over mDNS multicast, which a bridged container network does not carry.

ARG SWIFT_VERSION=6.2

FROM swift:${SWIFT_VERSION}-noble AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends libavahi-compat-libdnssd-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# The manifest first, so the dependencies are fetched again only when Package.resolved changes.
COPY Package.swift Package.resolved ./
RUN swift package resolve
# What the manifest names, and nothing else: an edit to a script or a document does not rebuild the bridge.
COPY Sources Sources
COPY Plugins Plugins
COPY Tests Tests
# The Swift runtime and Foundation are linked in; the runtime image needs only the system libraries.
RUN swift build -c release --static-swift-stdlib --product homeswift \
    && install -D "$(swift build -c release --show-bin-path)/homeswift" /out/homeswift \
    && strip --strip-debug /out/homeswift

FROM ubuntu:24.04
# avahi-daemon and dbus: Bonjour, which Homeswift reaches through Avahi's dns_sd compatibility library.
# ffmpeg: the UniFi Protect plugin's cameras. avahi-utils: avahi-browse, for checking what is advertised.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        avahi-daemon avahi-utils dbus libavahi-compat-libdnssd1 \
        ca-certificates tzdata libcurl4t64 ffmpeg tini \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/homeswift /usr/local/bin/homeswift
COPY Scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Avahi's compatibility layer otherwise prints a warning on every start.
ENV AVAHI_COMPAT_NOWARN=1
# config.json, the pairings, the accessory cache, logs and metrics.
VOLUME /homeswift
# HAP (the bridge's port in config.json), the web UI, mDNS. Informational: host networking publishes nothing.
EXPOSE 51826/tcp 8581/tcp 5353/udp

LABEL org.opencontainers.image.title="Homeswift" \
      org.opencontainers.image.description="A Homebridge in Swift: a HomeKit bridge with plugins, a web UI and an MCP server" \
      org.opencontainers.image.source="https://github.com/mp-consulting/homeswift" \
      org.opencontainers.image.licenses="MIT"

# tini reaps the daemons the entrypoint starts and forwards SIGTERM to the bridge, which shuts down cleanly.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
