# sbc-quartz

Talos Linux overlay for the Pine64 RK3566 family.

| overlay name       | board                                   | DTB                          |
|--------------------|-----------------------------------------|------------------------------|
| `quartz64-a`       | Quartz64 Model A                        | `rk3566-quartz64-a.dtb`      |
| `quartz64-b`       | Quartz64 Model B                        | `rk3566-quartz64-b.dtb`      |
| `soquartz-blade`   | SOQuartz on the Pine64 Blade baseboard  | `rk3566-soquartz-blade.dtb`  |
| `soquartz-model-a` | SOQuartz on the Pine64 Model-A baseboard| `rk3566-soquartz-model-a.dtb`|
| `soquartz-cm4`     | SOQuartz on a CM4-IO style carrier      | `rk3566-soquartz-cm4.dtb`    |

SOQuartz is one module with many possible baseboards. Each overlay name pairs a
U-Boot defconfig with a kernel DTB. The pairs are listed once, in `Pkgfile`
(`vars.boards`). Third-party CM4 carriers can reuse the `soquartz-cm4` pair
under their own name; see [docs/adding-a-baseboard.md](docs/adding-a-baseboard.md).

One overlay image (`ghcr.io/s-collison/sbc-quartz`) covers every board. The
separate `sbc-soquartz` folder isn't needed.

## Build

```sh
docker buildx create --name local --use            # once
echo "$GITHUB_TOKEN" | docker login ghcr.io -u s-collison --password-stdin

# 1. overlay image (linux/amd64 + linux/arm64) -> ghcr.io/s-collison/sbc-quartz:<git tag>
make sbc-quartz PUSH=true
#    The ghcr package must be public (or the imager can't pull it).

# 2. bootable image for one board (always --arch arm64, verified before it's returned)
hack/build-image.sh                       # quartz64-a, soquartz-blade, soquartz-model-a (uses each board's GRUB profile)
hack/build-image.sh soquartz-cm4          # or name any boards
TALOS_VERSION=v1.14.5 hack/build-image.sh quartz64-a
```

Output: `_out/talos-<version>-<board>.raw.xz`.

## Getting a cluster up

**Start here: [docs/bring-up.md](docs/bring-up.md)** (images → network → management node → Pi 5 → workers → upgrades).

Flash a release image, boot into maintenance mode, assign configs with
holzkube-manager (or talosctl), and upgrade with tuppr:
[docs/provision-and-upgrade.md](docs/provision-and-upgrade.md). The management
node (Pi Zero 2 W or Quartz64 A: holzkube, registry caches, install-image guard,
etcd backups, `sbc-flash`) is in [docs/management-node.md](docs/management-node.md).

## Flavors and netboot (optional)

- `stock`: Talos kernel as released. `media`: the same kernel plus Hantro/RGA for
  hardware video decode ([docs/hardware-video.md](docs/hardware-video.md)).
- Optional, later: U-Boot tries local disks first, then PXE. The management node running dnsmasq serves the
  `netboot-<talos>-<flavor>.tar.gz` tree, and nodes are provisioned from maintenance
  mode with holzkube-manager or talosctl ([docs/netboot.md](docs/netboot.md)).

## CI releases

Hands-off: one daily workflow, `track.yaml`, and you only act on failures.

- It follows upstream: the latest Talos release and its kernel `PKGS`, the latest
  siderolabs/sbc-rockchip U-Boot/TF-A/rkbin/toolchain/Go deps, and the Kwiboo FFmpeg
  branch. They are written to `talos.env` (the source of truth) and the build files,
  the overlay is test-built, and the change is committed to `main`.
- Releases are tagged after upstream Talos: **`v1.14.5`** is the first build for Talos
  v1.14.5; **`v1.14.5-r1`, `-r2`…** are rebuilds with fixes from this repo. A tag is created
  only when build inputs changed since the last one, and `images.yaml` then publishes the
  release: stock and media images and upgrade installers for quartz64-a, soquartz-blade
  and soquartz-model-a.
- The media containers are rebuilt when their Dockerfile or base image changes.
- **Failures:** if the pin update doesn't build, you get a PR labelled `auto-update`. If a
  release or container build fails, you get an issue labelled `build-failure`. Fix it, merge
  to `main`, and the next tag and build happen by themselves.

Details are in [docs/cluster-ops.md](docs/cluster-ops.md).

## Flash and first boot

```sh
diskutil list                               # find the SD card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
xz -dc _out/talos-v1.14.5-quartz64-a.raw.xz | sudo dd of=/dev/rdisk4 bs=4m
```

* The RK3566 boot ROM tries SPI -> eMMC -> SD. **Remove the eMMC module (or wipe
  its first 16 MiB) when booting from SD**, or an old bootloader on eMMC wins.
* Watch the UART2 debug header at **1500000 8N1** (3.3 V). U-Boot does not drive
  HDMI on RK3566, so a black HDMI screen during boot is expected; the node will
  show up on DHCP and answer `talosctl -n <ip> get links --insecure` in
  maintenance mode.

## Install to disk / upgrade

Flash the image straight onto the disk the board boots from (eMMC or SD); see
[docs/cluster-ops.md](docs/cluster-ops.md#first-install-simplest-bare-metal-path)
for why. For upgrades, use the board's installer image:

```sh
INSTALLER_REPO=ghcr.io/s-collison/talos-installer hack/build-image.sh quartz64-a
# -> ghcr.io/s-collison/talos-installer-quartz64-a:<talos-version>
talosctl -n <ip> upgrade --image ghcr.io/s-collison/talos-installer-quartz64-a:v1.14.5
```

CI publishes these installers on every release.

## Versions

| component | version |
|---|---|
| Talos (imager, machinery Go library) | v1.14.5 |
| DTBs | Talos 1.14.5 kernel (`PKGS` = siderolabs/pkgs v1.14.0-48-gf4bda77, Linux 6.18.58) |
| U-Boot | 2026.10 |
| TF-A (BL31) | lts-v2.14.11 |
| rkbin (DDR blob) | 74213af, rk3566_ddr_1056MHz |
| toolchain | siderolabs/tools v1.15.0-alpha.0-16-g54f72f9, bldr v0.6.5 |

These pins match siderolabs/sbc-rockchip v0.3.0, which builds RK3566/RK3568
boards with them. `track.yaml` moves them (and `PKGS`) forward automatically.
