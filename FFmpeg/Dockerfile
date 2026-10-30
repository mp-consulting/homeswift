# syntax=docker/dockerfile:1
# ffmpeg-for-homeswift: a static FFmpeg for the camera plugins (FFmpeg/README.md). One binary that runs on any
# Linux of its architecture: musl, every library linked in. Published to ghcr.io/mp-consulting/ffmpeg-for-homeswift
# by .github/workflows/ffmpeg.yml; the bridge's image copies /ffmpeg from it.
#
# GPLv3 and redistributable: x264 (GPL), Opus (BSD), OpenSSL (Apache 2.0, which needs --enable-version3), and no
# fdk-aac, whose licence FFmpeg cannot combine with the GPL. Live streams send Opus; recordings use FFmpeg's AAC.

# Bump REVISION when the build changes without a new FFmpeg; the image's tag is <FFMPEG_VERSION>-<REVISION>.
ARG REVISION=2
ARG FFMPEG_VERSION=8.1.3
ARG FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
# The head of x264's stable branch.
ARG X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
ARG OPUS_VERSION=1.5.2
ARG OPUS_SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
# The 3.5 long-term support release: TLS for the cameras' rtsps:// streams.
ARG OPENSSL_VERSION=3.5.9
ARG OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a

FROM alpine:3.24 AS build
# bash: x264's configure.
RUN apk add --no-cache bash build-base curl git linux-headers nasm perl pkgconf xz
ARG FFMPEG_VERSION FFMPEG_SHA256 X264_COMMIT OPUS_VERSION OPUS_SHA256 OPENSSL_VERSION OPENSSL_SHA256
WORKDIR /build
# The sources as built, kept for the image: the GPL asks for them next to the binary.
RUN curl -fsSLo ffmpeg-${FFMPEG_VERSION}.tar.xz https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz \
    && curl -fsSLo opus-${OPUS_VERSION}.tar.gz https://github.com/xiph/opus/releases/download/v${OPUS_VERSION}/opus-${OPUS_VERSION}.tar.gz \
    && curl -fsSLo openssl-${OPENSSL_VERSION}.tar.gz https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz \
    && printf '%s  %s\n' \
        "$FFMPEG_SHA256" ffmpeg-${FFMPEG_VERSION}.tar.xz \
        "$OPUS_SHA256" opus-${OPUS_VERSION}.tar.gz \
        "$OPENSSL_SHA256" openssl-${OPENSSL_VERSION}.tar.gz \
        | sha256sum -c - \
    # GitLab's archives are generated on request and their checksums drift: the commit is the check instead.
    && git clone -q https://code.videolan.org/videolan/x264.git x264 \
    && git -C x264 checkout -q ${X264_COMMIT} \
    && git -C x264 archive --prefix=x264-${X264_COMMIT}/ -o ../x264-${X264_COMMIT}.tar.gz ${X264_COMMIT} \
    && mkdir sources && mv ./*.tar.* sources/

# The libraries, static, under /deps.
RUN tar xf sources/openssl-${OPENSSL_VERSION}.tar.gz && cd openssl-${OPENSSL_VERSION} \
    && ./config --prefix=/deps --libdir=lib no-shared no-module no-apps no-docs no-tests \
    && make -j"$(nproc)" build_libs && make install_dev
RUN tar xf sources/opus-${OPUS_VERSION}.tar.gz && cd opus-${OPUS_VERSION} \
    && ./configure --prefix=/deps --disable-shared --enable-static --disable-doc --disable-extra-programs \
    && make -j"$(nproc)" && make install
RUN tar xf sources/x264-${X264_COMMIT}.tar.gz && cd x264-${X264_COMMIT} \
    && ./configure --prefix=/deps --enable-static --enable-pic --disable-cli --disable-opencl \
    && make -j"$(nproc)" && make install-lib-static

# --disable-autodetect: nothing that happens to be installed ends up linked in. v4l2-m2m is the Raspberry Pi's
# hardware encoder (h264_v4l2m2m). VAAPI and Quick Sync load their drivers at run time, which a static binary
# cannot, so Intel machines encode with libx264.
RUN tar xf sources/ffmpeg-${FFMPEG_VERSION}.tar.xz && cd ffmpeg-${FFMPEG_VERSION} \
    && PKG_CONFIG_PATH=/deps/lib/pkgconfig ./configure \
        --prefix=/ffmpeg --pkg-config-flags=--static \
        --extra-cflags=-I/deps/include --extra-ldflags="-L/deps/lib -static" --extra-libs="-lpthread -lm" \
        --enable-gpl --enable-version3 --disable-shared --enable-static \
        --disable-autodetect --disable-debug --disable-doc --disable-ffplay --disable-ffprobe \
        --enable-libx264 --enable-libopus --enable-openssl --enable-v4l2-m2m \
    && make -j"$(nproc)" && make install \
    && strip /ffmpeg/bin/ffmpeg \
    && /ffmpeg/bin/ffmpeg -hide_banner -version
ARG REVISION
RUN mkdir -p /out/licenses \
    && printf '%s\n' \
        "ffmpeg-for-homeswift ${FFMPEG_VERSION}-${REVISION}: FFmpeg ${FFMPEG_VERSION} with x264 ${X264_COMMIT}, Opus ${OPUS_VERSION}" \
        "and OpenSSL ${OPENSSL_VERSION}, linked statically; GPLv3 as a whole. The sources it was built from are under" \
        "/sources in ghcr.io/mp-consulting/ffmpeg-for-homeswift:${FFMPEG_VERSION}-${REVISION}, and FFmpeg/Dockerfile in" \
        "https://github.com/mp-consulting/homeswift builds it." > /out/licenses/README.txt \
    && cp ffmpeg-${FFMPEG_VERSION}/COPYING.GPLv3 /out/licenses/FFmpeg.txt \
    && cp x264-${X264_COMMIT}/COPYING /out/licenses/x264.txt \
    && cp opus-${OPUS_VERSION}/COPYING /out/licenses/Opus.txt \
    && cp openssl-${OPENSSL_VERSION}/LICENSE.txt /out/licenses/OpenSSL.txt \
    && cp /ffmpeg/bin/ffmpeg /out/ffmpeg \
    && mv sources /out/sources

FROM scratch
COPY --from=build /out /
ARG FFMPEG_VERSION REVISION
LABEL org.opencontainers.image.title="ffmpeg-for-homeswift" \
      org.opencontainers.image.description="A static FFmpeg with x264, Opus and OpenSSL for Homeswift's camera plugins" \
      org.opencontainers.image.version="${FFMPEG_VERSION}-${REVISION}" \
      org.opencontainers.image.source="https://github.com/mp-consulting/homeswift" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"
