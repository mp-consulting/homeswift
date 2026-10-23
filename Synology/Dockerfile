# syntax=docker/dockerfile:1
# The homeswift binary for the Synology package (Synology/build.sh). Amazon Linux 2 has glibc 2.26, the release
# DSM 7.0 ships, so the binary runs on every DSM 7. The Swift runtime is linked in; Avahi's dns_sd and its
# D-Bus library go in lib/ next to bin/, which the binary finds through its rpath. The rest it links (libcurl,
# libstdc++, zlib, libsystemd) is part of DSM.

ARG SWIFT_VERSION=6.2

FROM swift:${SWIFT_VERSION}-amazonlinux2 AS build
RUN yum install -y -q avahi-compat-libdns_sd-devel && yum clean all
WORKDIR /src
# The manifest first, so the dependencies are fetched again only when Package.resolved changes.
COPY Package.swift Package.resolved ./
RUN swift package resolve
# What the build reads, so editing the package's own files does not build it again.
COPY Sources Sources
COPY Plugins Plugins
COPY Tests Tests
# DT_RPATH (--disable-new-dtags), not RUNPATH: it also finds lib/ for the libraries' own dependencies (dns_sd
# needs avahi-client). The cache keeps .build between local builds.
RUN --mount=type=cache,target=/src/.build \
    swift build -c release --static-swift-stdlib --product homeswift \
        -Xlinker --disable-new-dtags -Xlinker -rpath -Xlinker '$ORIGIN/../lib' \
    && install -D "$(swift build -c release --show-bin-path)/homeswift" /out/bin/homeswift \
    && strip --strip-debug /out/bin/homeswift
COPY Synology/bundle-libraries.sh /usr/local/bin/
RUN sh /usr/local/bin/bundle-libraries.sh /out

FROM scratch
COPY --from=build /out /
