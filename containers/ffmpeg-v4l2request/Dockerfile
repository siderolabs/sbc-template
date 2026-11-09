# FFmpeg 8.1 + V4L2 Request API hwaccels (Kwiboo, pending upstream as FFmpeg PR20847),
# for mainline stateless decoders: Hantro G1 on RK356x (H.264/VP8/MPEG-2).
#
# Built by .github/workflows/media-containers.yaml (started by track.yaml) on top of two bases:
#   BASE_IMAGE=ghcr.io/koush/scrypted:latest -> ghcr.io/<owner>/scrypted-rk3566
#   BASE_IMAGE=debian:trixie-slim            -> ghcr.io/<owner>/ffmpeg-v4l2request
#
# The build runs in a clean, pinned Ubuntu image, never in the base: base images
# carry their own apt sources (Scrypted's coral-edgetpu repo has been removed
# upstream, which breaks apt-get update there). Everything FFmpeg needs beyond
# glibc is bundled into /opt/ffmpeg-v4l2request/lib and found via DT_RPATH, so
# the final stage runs no package manager at all. Ubuntu 24.04's glibc (2.39)
# is <= the glibc of both bases, so the binaries run on either.
ARG BUILDER_IMAGE=ubuntu:24.04
ARG BASE_IMAGE=ghcr.io/koush/scrypted:latest
ARG FFMPEG_REPO=https://github.com/Kwiboo/FFmpeg.git
# track.yaml moves FFMPEG_REF to the head of FFMPEG_BRANCH daily
ARG FFMPEG_BRANCH=v4l2-request-n8.1
ARG FFMPEG_REF=b57fbbe50c9b2656fad86a1a7eeabfd2b2a50935

FROM ${BUILDER_IMAGE} AS build
ARG FFMPEG_REPO
ARG FFMPEG_REF
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git build-essential pkg-config nasm \
      libdrm-dev libudev-dev libx264-dev linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git init /src && cd /src \
    && git remote add origin "${FFMPEG_REPO}" \
    && git fetch --depth 1 origin "${FFMPEG_REF}" \
    && git checkout --detach FETCH_HEAD
WORKDIR /src
# --disable-new-dtags: DT_RPATH also applies to the bundled libs' own deps (RUNPATH would not)
RUN ./configure \
      --prefix=/opt/ffmpeg-v4l2request \
      --enable-gpl --enable-libx264 \
      --enable-v4l2-request --enable-libdrm --enable-libudev \
      --enable-shared --disable-static --disable-doc --disable-debug \
      --extra-ldflags="-Wl,--disable-new-dtags,-rpath,/opt/ffmpeg-v4l2request/lib" \
    && make -j"$(nproc)" && make install
# Bundle every non-glibc shared library the binaries and FFmpeg's own libs pull in.
RUN set -eu; lib=/opt/ffmpeg-v4l2request/lib; \
    for f in /opt/ffmpeg-v4l2request/bin/* ${lib}/*.so.*; do ldd "$f"; done \
      | awk '$2 == "=>" && $3 ~ /^\// {print $3}' | sort -u \
      | grep -vE '/(libc|libm|libdl|libpthread|librt|libresolv|ld-linux[^/]*)\.so' \
      | grep -v "^${lib}/" \
      | while read -r so; do cp -Lv "$so" "${lib}/"; done; \
    /opt/ffmpeg-v4l2request/bin/ffmpeg -hide_banner -hwaccels | tee /tmp/hwaccels; \
    grep -q v4l2request /tmp/hwaccels

FROM ${BASE_IMAGE}
COPY --from=build /opt/ffmpeg-v4l2request /opt/ffmpeg-v4l2request
ENV PATH=/opt/ffmpeg-v4l2request/bin:${PATH}
# Smoke test in the real base: libraries resolve and the hwaccel is compiled in.
RUN ! ldd /opt/ffmpeg-v4l2request/bin/ffmpeg | grep -q 'not found' \
    && ffmpeg -hide_banner -hwaccels | grep -q v4l2request
LABEL org.opencontainers.image.source=https://github.com/s-collison/sbc-quartz \
      org.opencontainers.image.description="FFmpeg 8.1 with V4L2 Request hwaccel (Hantro/rkvdec) for Rockchip mainline kernels"
