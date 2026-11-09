# Running the cluster: install, storage, upgrades

## Topology

The existing PoE switch carries a dedicated cluster VLAN. A management node
(Pi Zero 2 W or Quartz64 A, [management-node.md](management-node.md)) provides
DHCP/TFTP/DNS and holzkube-manager, the Pi 5 is the control plane (API) and NFS,
and the Quartz boards are workers. Full layout, VLAN settings and the PXE install
flow are in [netboot.md](netboot.md).

- Load balancing, DNS and TLS run in-cluster: MetalLB/Cilium L2 VIPs in VLAN 20,
  Gateway API, external-dns, cert-manager, and an OIDC provider (Pocket ID /
  Authelia / Authentik). Outside access: forward 443 on the Express 7 to the
  ingress VIP, or use Cloudflare Tunnel.
- Onsite LAN hardware reaches the API and VIPs through the Express 7 (inter-VLAN
  routing + firewall zones). mDNS/SSDP need UniFi's mDNS reflector.
- If you later want routing off the gateway, a Layer 3 switch (e.g. UniFi
  Enterprise 8 PoE) can host the VLAN 20 gateway instead. Nothing else changes.
- Talos has no in-kernel NFS server (`nfsd`). NFS on the Pi 5 runs as NFS-Ganesha in a pod.

## Flavors

| flavor | kernel | extensions | use |
|---|---|---|---|
| `stock` | Talos kernel as released | official `drbd` | default |
| `media` | same kernel + `kernel/media.config` (Hantro G1/VEPU, RGA) | `drbd` rebuilt for that kernel | SOQuartz/Quartz64 nodes doing video decode (Scrypted) |

Talos enforces module signatures, so the media flavor rebuilds the kernel, its DRBD
module, `installer-base` and `imager` together (`.github/workflows/media-kernel.yaml`,
images under `ghcr.io/s-collison/talos-media/*`). Media nodes also get
`talos/patches/media.yaml` (loads `hantro_vpu`, `rockchip_rga`, labels the node).

## What CI publishes

### Tracking upstream (`track.yaml`, daily)

| reads | writes |
|---|---|
| latest siderolabs/talos release, its Makefile `PKGS` | `talos.env`, `Makefile`, `.kres.yaml`, `talos/patches/install-*.yaml`, `talos/tuppr/upgrades.yaml` |
| latest siderolabs/sbc-rockchip release: Pkgfile, Makefile, installer go.mod/go.sum | `Pkgfile` (U-Boot, TF-A, rkbin + checksums, bldr), `TOOLS`, `installers/quartz64/src/go.{mod,sum}`, `go.work` |

It also moves `FFMPEG_REF` in `containers/ffmpeg-v4l2request/Dockerfile` to the head of
`FFMPEG_BRANCH`. The edits are made by `hack/update-pins.py` (run it locally with the same
arguments to reproduce). If build inputs changed, `make target-sbc-quartz PLATFORM=linux/arm64`
must pass:

- pass → commit to `main`, close any open `auto-update` PR;
- fail → force-push `auto/update-pins`, open/comment the `auto-update` PR with the run link,
  and stop. Fix on that branch and merge. PR checks don't run on bot-pushed branches; push
  any commit yourself (or close/reopen) to start them.

Then, in the same run (and on every merge to `main` that touches build inputs):

- **tag**: tags are named after the Talos version in `talos.env`. No tag for it yet →
  `vX.Y.Z`. Build inputs changed since the newest `vX.Y.Z[-rN]` → `vX.Y.Z-r(N+1)`.
  Otherwise nothing. The new tag is pushed and `images.yaml` is dispatched on it.
- **containers**: `media-containers.yaml` is dispatched if `containers/` changed since the
  commit recorded in the published image's labels, or the Scrypted/Debian base digest moved.

Installers are pushed as `talos-installer-<board>[-media]:<talos>` (what tuppr upgrades
to; a `-rN` rebuild replaces it) and the release assets stay on each tag.

To hold an older Talos, edit `talos.env` by hand and disable the track workflow
(Actions → track → ⋯ → Disable), otherwise the next run moves it forward again.

### Building (`images.yaml`)

Runs on a `v*` tag (created by track, or pushed by you) or by hand. Failures on tag runs
open/comment an issue labelled `build-failure`. Run by hand on a branch, it builds and
uploads 7-day workflow artifacts without a release. It:

1. reads the Talos version and kernel build (`PKGS`) from `talos.env` (a manual run
   may override the version);
2. builds the media kernel stack if it's missing (`media-kernel.yaml`), and the overlay
   `ghcr.io/s-collison/sbc-quartz:<tag>` (e.g. `v1.14.5-r1`);
3. for each flavor × board (`quartz64-a`, `soquartz-blade`, `soquartz-model-a`):
   - `talos-<talos>-<board>[-media].raw.xz`, verified (idbloader, arm64 GRUB, fdtfile, PXE);
   - upgrade installer `ghcr.io/s-collison/talos-installer-<board>[-media]:<talos>`;
4. builds `netboot-<talos>-<flavor>.tar.gz` (raw kernel Image, initramfs, DTBs,
   pxelinux.cfg, U-Boot binaries);
5. creates the GitHub Release for the tag with all of it and checksums.

`media-containers.yaml` builds `ghcr.io/s-collison/scrypted-rk3566` and
`ghcr.io/s-collison/ffmpeg-v4l2request` (FFmpeg 8.1 + V4L2 Request hwaccel).

## First install (simplest bare-metal path)

**Write the release image straight onto the disk the board will boot from**,
then apply config. Don't boot the SD card and let Talos "install" to eMMC:
in install mode, Talos 1.14 auto-selects systemd-boot whenever U-Boot's UEFI
is present. These images deliberately use GRUB, which is what Sidero ships
for Rockchip boards. Upgrades keep whatever boot loader is already on the disk.

| board | boot disk | how to write it |
|---|---|---|
| Quartz64 A | eMMC module (recommended) or SD | eMMC: Pine64 USB eMMC adapter, then `dd` from the Mac |
| SOQuartz (Blade / Model-A) | eMMC on the module, or the baseboard SD | eMMC: rpiboot-style USB mass storage isn't available, so flash SD, or use a Pine64 eMMC module + adapter |

1. `xz -dc talos-<ver>-<board>.raw.xz | sudo dd of=/dev/rdiskN bs=4m` onto that disk, insert, power on.
   The node comes up in maintenance mode and gets a DHCP address.
2. Generate and apply the config. `install.disk` is the disk you just wrote, so
   Talos sees it's already installed and doesn't reinstall:

   ```sh
   talosctl gen config homelab https://<cp-ip>:6443 \
     --config-patch @talos/patches/drbd.yaml \
     --config-patch @talos/patches/tuppr.yaml
   talosctl apply-config --insecure -n <ip> -f worker.yaml \
     --config-patch @talos/patches/install-soquartz-blade.yaml
   ```

   `machine.install.image` must be **the board's own installer**. The stock
   `ghcr.io/siderolabs/installer` and Image Factory installers don't contain
   this overlay.
3. The RK3566 boot ROM can't boot NVMe directly. Keep Talos on eMMC/SD and give the M.2 SSD to storage.

## Network boot

U-Boot on every board has PXE. Local disks are tried first, then the network.
CI publishes a TFTP tree per flavor (`netboot-<talos>-<flavor>.tar.gz`). See
[netboot.md](netboot.md) for the management node setup and the PXE → holzkube → install flow.

## M.2 SSD with DRBD / LINSTOR (Piraeus)

The images already contain the `drbd` extension and `drbd.yaml` loads it.

1. Leave the NVMe disk out of Talos volumes (no `UserVolumeConfig` on it), so LINSTOR can take it.
2. Install the operator:

   ```sh
   helm upgrade --install piraeus-op oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus \
     -n piraeus-datastore --create-namespace
   ```

3. Apply the Talos module-loader override from the Piraeus "Talos" guide
   (`LinstorSatelliteConfiguration` that removes the `drbd-module-loader` init
   container). Then create a `LinstorCluster` and a storage pool on `/dev/nvme0n1`.
4. Check: `talosctl -n <ip> read /proc/modules | grep drbd`.

## Upgrades

See [provision-and-upgrade.md](provision-and-upgrade.md). In short: tuppr upgrades
every node to `<its install image repository>:<version>`, which suits the board
installers CI publishes. holzkube-manager provisions nodes, but don't use it to upgrade
the Quartz/SOQuartz nodes, because its upgrades come from the Image Factory.

## Fleet managers / GUIs (free options)

| tool | cost / license | GUI | works with these boards? |
|---|---|---|---|
| **tuppr** | free, AGPL-3.0 | no (kubectl/GitOps) | yes; upgrades are driven by version, which our installer tags support |
| **holzkube-manager** | free, AGPL-3.0, alpha (0.8) | yes, web + mobile | runs outside the cluster (management node). Use it for provisioning/config; its upgrades go through the Image Factory, so not for these boards |
| **Omni (self-hosted)** | free for home lab / non-production under BSL; hosted Hobby is paid | yes | builds images and installers through Image Factory, which doesn't have this overlay, so its upgrades would fight these boards |
| Kamaji | free | no | runs hosted control planes; not an OS fleet or upgrade manager |
| Headlamp | free | yes | Kubernetes GUI only (workloads), no Talos upgrades |

Suggested setup for a small, zero-cost cluster: tuppr for upgrades, CI for
images, and optionally holzkube-manager on a spare board for a dashboard.
