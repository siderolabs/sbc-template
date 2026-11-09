# Provisioning (holzkube-manager) and upgrades (tuppr)

## 1. Get a node into maintenance mode: flash the image

```sh
xz -dc talos-v1.14.5-soquartz-blade.raw.xz | sudo dd of=/dev/rdiskN bs=4m   # SD, or eMMC via USB adapter
```

Boot it. With no config, Talos sits in **maintenance mode**: Talos API on :50000,
insecure, waiting for a config. That's the state holzkube-manager's provisioning
wizard looks for. It's the same as an ISO or PXE boot, so no PXE is needed.

The disk you flashed **is** the install. `machine.install.disk` must point at that
same disk so Talos doesn't reinstall. A fresh install from inside Talos (install mode)
would pick systemd-boot under U-Boot's UEFI, while these images use GRUB.

| node | image | role |
|---|---|---|
| Raspberry Pi 5 | Image Factory, official `rpi5` overlay (`sbc-raspberrypi`) | control plane / API |
| Quartz64 A | `talos-<ver>-quartz64-a.raw.xz` (this repo) | worker |
| SOQuartz + Blade | `talos-<ver>-soquartz-blade.raw.xz` | worker |
| SOQuartz + Model-A | `talos-<ver>-soquartz-model-a.raw.xz` | worker |

## 2. Assign configs with holzkube-manager

holzkube-manager provisions any maintenance-mode node: it checks the certificate
fingerprint, then writes the config. Add these patches from `talos/patches/` (stored
patches / machine class in holzkube):

- `drbd.yaml`: DRBD for Piraeus/LINSTOR.
- `tuppr.yaml`: Talos API access for tuppr.
- `registry-mirror.yaml`: pull through the management node's caches.
- `rpi5-controlplane.yaml` (Pi 5 only, first apply): etcd/EPHEMERAL on the SSD, media volume.
- Install disk: choose the disk you flashed (`talosctl get disks --insecure -n <ip>`).

**The installer image gets fixed up afterwards.** holzkube-manager 0.8 sets
`.machine.install.image` itself (stock or Image Factory installer) and adds it after your
patches. The management node's **install-image-guard** ([management-node.md](management-node.md)) then pins each
Quartz/SOQuartz node to `ghcr.io/s-collison/talos-installer-<board>:<talos>` within a few
minutes. For a flashed node nothing is reinstalled, so the stock value is never used.
Without a management node, run once per node:

```sh
talosctl -n <ip> patch mc --mode=no-reboot \
  -p '{"machine":{"install":{"image":"ghcr.io/s-collison/talos-installer-<board>:v1.14.5"}}}'
```

Control plane: the **Pi 5** (16 GB) is the API server and also runs Plex (direct
play), Blu-ray ripping and NFS. Apply the controlplane config with
`rpi5-controlplane.yaml` **on first apply**, then bootstrap etcd there
(`talosctl bootstrap -n 10.20.0.10`). Every other node gets worker configs.

## 3. Upgrades: tuppr (not holzkube)

- **holzkube-manager's upgrades** always resolve the installer through an Image
  Factory (`IMAGE_FACTORY_URL`, from the node's schematic), and the upgrade call sends
  that image, not the one in the node's config. The Factory only offers
  Sidero's signed overlays, so for these boards it would install an image without our
  U-Boot/DTB. **Don't upgrade Quartz/SOQuartz nodes from holzkube.** It's fine for the Pi 5,
  which is a Factory `rpi5` image.
- **tuppr** reads each node's own `machine.install.image` (or the 1.14
  `UnattendedInstallConfig`). For a non-Factory repository it upgrades to
  `<that repository>:<target version>`, which is exactly how CI tags the board installers.
  For the Pi 5's Factory image it keeps the schematic and swaps the version. So one
  `TalosUpgrade` handles the whole cluster:

  ```yaml
  apiVersion: tuppr.home-operations.com/v1alpha1
  kind: TalosUpgrade
  metadata: { name: talos }
  spec:
    talos: { version: v1.14.6 }    # bump only after the images workflow has published v1.14.6 installers
  ```

  Install: `helm install tuppr oci://ghcr.io/home-operations/charts/tuppr -n system-upgrade --create-namespace`.
  It drains, upgrades and health-checks one node at a time.
- **By hand:** `talosctl -n <ip> upgrade --image ghcr.io/s-collison/talos-installer-<board>:<ver>`.

Upgrade mode keeps the boot loader that's on disk (GRUB), and the overlay's installer
hook rewrites U-Boot and the DTB, so **U-Boot updates ride along with Talos upgrades**.

## Order of operations for a new Talos release

1. CI (`track.yaml` → `images.yaml`, automatic) publishes `talos-installer-<board>:<new>` and the release images.
2. Bump `TalosUpgrade.spec.talos.version`. tuppr rolls the cluster.

## Later: holzkube for everything (self-hosted Image Factory)

CI already publishes what a self-hosted factory needs on GHCR:
- **Overlay:** `ghcr.io/s-collison/sbc-quartz:<tag>`, signed with cosign keyless (GitHub OIDC).
- **Overlay catalog:** `ghcr.io/s-collison/overlays:<talos>`, the official catalog plus these
  boards, also signed. It's what `artifacts.core.components.overlayManifest` points at.

Running `ghcr.io/siderolabs/image-factory` on the Pi 5 (see Sidero's "Running Image
Factory On-Prem"), with that catalog and `containerSignature` set to trust Sidero's
signers plus this repo's workflow identity, and pointing holzkube's
`IMAGE_FACTORY_URL` at it, would let holzkube provision (including PXE) and upgrade
these boards with factory schematics. Then the guard isn't needed. Not tested yet.
