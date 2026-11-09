# Hardware video (MPP / RKMPP) on Talos: what's possible

**Short version: Rockchip MPP (BSP) cannot run on Talos, but the mainline Hantro
decoder can, and this repo builds it as the `media` flavor (below).**

## Why

- MPP is a split stack. The kernel driver behind `/dev/mpp_service` exists only
  in Rockchip's vendor (BSP) kernels (4.19 / 5.10 / 6.1). `libmpp.so` and the
  `ffmpeg-rockchip` fork both need that device.
- Talos boots a mainline kernel (Linux 6.18 in Talos 1.14), built by
  siderolabs/pkgs. It has no `CONFIG_ROCKCHIP_MPP`, and you can't swap in a BSP kernel.
- The mainline alternatives (V4L2 stateless) are **disabled** in the Talos
  arm64 config: `CONFIG_VIDEO_HANTRO`, `CONFIG_VIDEO_ROCKCHIP_VDEC` and
  `CONFIG_VIDEO_ROCKCHIP_RGA` are all "not set". Even enabled, mainline on RK3566
  gives decode only (Hantro G1 / rkvdec). H.264/HEVC **encode** is not upstream.
- `hostPath` with `/opt/ffmpeg-rockchip` doesn't fit Talos either. The root
  filesystem is immutable, there's no compiler on the host, and there's no `/opt`.

What *is* enabled: `DRM_ROCKCHIP` (display), `DRM_PANFROST` (Mali GPU),
`DMABUF_HEAPS_SYSTEM`, and all the storage, network and PMIC drivers these boards need.

## What this repo provides: the `media` flavor (mainline)

- **Kernel:** Talos's own kernel config plus `kernel/media.config`. That enables
  `hantro_vpu` (rk3568-vpu: H.264 / VP8 / MPEG-2 decode; rk3568-vepu: JPEG encode) and
  `rockchip_rga` (scaling / colour conversion). The device-tree nodes are enabled by
  default on all five boards. Built by `.github/workflows/media-kernel.yaml` together
  with `installer-base`, `imager` and a re-signed `drbd`.
- **Images:** `talos-<ver>-<board>-media.raw.xz`, `talos-installer-<board>-media:<ver>`
  and `netboot-<ver>-media.tar.gz`.
- **Node config:** `talos/patches/media.yaml` loads the modules and labels the node
  `quartz64.dev/video-decode=hantro`.
- **Userspace:** `ghcr.io/s-collison/scrypted-rk3566` (Scrypted +
  `/opt/ffmpeg-v4l2request/bin/ffmpeg`) and `ghcr.io/s-collison/ffmpeg-v4l2request`.
  FFmpeg is Kwiboo's `v4l2-request-n8.1` (FFmpeg 8.1 with the V4L2 Request hwaccels that
  are pending upstream). Example Deployment: `talos/examples/scrypted-media.yaml`.
  Decoder args in Scrypted: `-hwaccel v4l2request -hwaccel_output_format drm_prime`.
- **Modules in the image:** Talos only ships modules named in its `hack/modules-arm64.txt`.
  `media-kernel.yaml` appends the Hantro/RGA/rkvdec modules and their V4L2/videobuf2
  dependencies (resolved by `hack/media-modules.py` from the built kernel) before
  building the imager.
- **Check on a node:** `talosctl -n <ip> ls /dev | grep -E 'video|media'`, then in the
  pod `ffmpeg -hide_banner -hwaccels` lists `v4l2request`.

Limits: decode only. No HEVC/VP9 (no rkvdec on RK356x upstream) and no H.264 encode. For
re-encode/transcode, Scrypted falls back to software (libx264 is included).

## Other options


| option | effort | result |
|---|---|---|
| **Software ffmpeg in Scrypted** on a Quartz64 / Pi 5 node | none | Fine for rebroadcast (no transcode). Motion/object detection on a few low-res substreams works; many cameras won't |
| **One RK3566 board off Talos** running a vendor-kernel distro (Armbian vendor / Ubuntu Rockchip) with libmpp + ffmpeg-rockchip, running Scrypted directly | medium | Full MPP encode/decode. That board isn't Talos-managed |
| **Intel N100/N150 mini-PC as a Talos worker** + official `i915` extension | low (hardware cost) | Quick Sync decode/encode for Scrypted *and* Plex, inside the cluster |

If you do build a custom Scrypted image (the K8s-native path from the MPP
guides), it only works on a node whose kernel exposes the device, so it
pairs with the "off Talos" option, not with these Talos nodes.
