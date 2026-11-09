# FFmpeg 8.1 + V4L2 Request API hwaccels (Kwiboo, pending upstream as FFmpeg PR20847),
# for mainline stateless decoders: Hantro G1 on RK356x (H.264/VP8/MPEG-2).
#
# Built twice by .github/workflows/containers.yaml:
#   BASE_IMAGE=ghcr.io/koush/scrypted:latest -> ghcr.io/s-collison/scrypted-rk3566
#   BASE_IMAGE=debian:trixie-slim            -> ghcr.io/s-collison/ffmpeg-v4l2request
# Installs into /opt/ffmpeg-v4l2request (rpath'd, no LD_LIBRARY_PATH needed).
ARG BASE_IMAGE=ghcr.io/koush/scrypted:latest
ARG FFMPEG_REPO=https://github.com/Kwiboo/FFmpeg.git
# branch v4l2-request-n8.1
ARG FFMPEG_REF=b57fbbe50c9b2656fad86a1a7eeabfd2b2a50935

FROM ${BASE_IMAGE} AS build
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
RUN ./configure \
      --prefix=/opt/ffmpeg-v4l2request \
      --enable-gpl --enable-libx264 \
      --enable-v4l2-request --enable-libdrm --enable-libudev \
      --enable-shared --disable-static --disable-doc --disable-debug \
      --extra-ldflags=-Wl,-rpath,/opt/ffmpeg-v4l2request/lib \
    && make -j"$(nproc)" && make install \
    && /opt/ffmpeg-v4l2request/bin/ffmpeg -hide_banner -hwaccels | tee /tmp/hwaccels \
    && grep -q v4l2request /tmp/hwaccels

FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends libdrm2 libudev1 libx264-164 \
    || apt-get install -y --no-install-recommends libdrm2 libudev1 'libx264-*' ; rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/ffmpeg-v4l2request /opt/ffmpeg-v4l2request
ENV PATH=/opt/ffmpeg-v4l2request/bin:${PATH}
# Smoke test: the hwaccel must be compiled in and the binary must run here.
RUN ffmpeg -hide_banner -hwaccels | grep -q v4l2request
LABEL org.opencontainers.image.source=https://github.com/s-collison/sbc-quartz \
      org.opencontainers.image.description="FFmpeg 8.1 with V4L2 Request hwaccel (Hantro/rkvdec) for Rockchip mainline kernels"
