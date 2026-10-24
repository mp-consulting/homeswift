# syntax=docker/dockerfile:1
# The homeswift binary for the Synology package (Synology/build.sh). Amazon Linux 2 has glibc 2.26, the release
# DSM 7.0 ships, so the binary runs on every DSM 7. The Swift runtime is linked in; Avahi's dns_sd and its
# D-Bus library go in lib/ next to bin/, which the binary finds through its rpath. The rest it links (libcurl,
# libstdc++, zlib, libsystemd) is part of DSM.

ARG SWIFT_VERSION=6.2
# ffmpeg-for-homeswift (FFmpeg/), as in the container image: DSM's own FFmpeg (4.1) has no libx264, which every
# HomeKit Secure Video recording needs. Static, so it runs on DSM as it is.
ARG FFMPEG_IMAGE=ghcr.io/mp-consulting/ffmpeg-for-homeswift:8.1.3-1

FROM ${FFMPEG_IMAGE} AS ffmpeg

FROM swift:${SWIFT_VERSION}-amazonlinux2 AS build
# With their documentation (the image installs without), for D-Bus's licence file, which bundle-libraries.sh copies.
RUN yum install -y -q --setopt=tsflags= avahi-compat-libdns_sd-devel \
    && yum reinstall -y -q --setopt=tsflags= dbus-libs \
    && yum clean all
WORKDIR /src
# The manifest first, so the dependencies are fetched again only when Package.resolved changes.
COPY Package.swift Package.resolved ./
RUN swift package resolve
# What the build reads, so editing the package's own files does not build it again.
COPY Sources Sources
COPY Plugins Plugins
COPY Tests Tests
# DT_RPATH (--disable-new-dtags), not RUNPATH: it also finds lib/ for the libraries' own dependencies (dns_sd
# needs avahi-client). The cache keeps .build between local builds; the build plan is made again each time, as
# a stale one in the cache names targets that are no longer there.
RUN --mount=type=cache,target=/src/.build \
    rm -f .build/*.yaml .build/*/release/description.json \
    && swift build -c release --static-swift-stdlib --product homeswift \
        -Xlinker --disable-new-dtags -Xlinker -rpath -Xlinker '$ORIGIN/../lib' \
    && install -D "$(swift build -c release --show-bin-path)/homeswift" /out/bin/homeswift \
    && strip --strip-debug /out/bin/homeswift
COPY Synology/bundle-libraries.sh /usr/local/bin/
RUN sh /usr/local/bin/bundle-libraries.sh /out
# The licences the package goes out with, in share/doc/homeswift: Homeswift's, the ported projects' notices, the
# packages compiled in (from the checkouts `swift package resolve` left in the image), and bundle-libraries'
# libraries/ for what lib/ holds.
COPY LICENSE THIRD-PARTY-NOTICES.md ./
COPY LICENSES LICENSES
COPY Scripts/collect-licenses.sh /usr/local/bin/
RUN sh /usr/local/bin/collect-licenses.sh .build/checkouts /out/share/doc/homeswift

FROM scratch
COPY --from=build /out /
# FFmpeg is GPLv3: its licences, and where its sources are, go with it.
COPY --from=ffmpeg /ffmpeg /bin/ffmpeg
COPY --from=ffmpeg /licenses /share/doc/ffmpeg-for-homeswift
