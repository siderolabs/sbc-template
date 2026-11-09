# Management node

A small Linux box beside the cluster (not a Talos node) that runs everything the
cluster shouldn't depend on for itself:

| service | what for | files |
|---|---|---|
| holzkube-manager | GUI; provisions maintenance-mode nodes (assigns configs) | its own release, systemd unit on the host |
| pull-through caches | `ghcr.io` (:5003) and `docker.io` (:5000); nodes use them via `talos/patches/registry-mirror.yaml` | `mgmt/compose.yaml` |
| install-image-guard (every 5 min) | pins each Quartz/SOQuartz node's install image to its GHCR board installer | `mgmt/install-image-guard.*` |
| etcd-snapshot (every 6 h) | etcd backups off the control plane | `mgmt/etcd-snapshot.*` |
| `sbc-flash` | download a release image, check it, write it to eMMC/SD | `mgmt/sbc-flash` |
| PXE/TFTP (optional) | dnsmasq serving the netboot tree | [netboot.md](netboot.md) |

The cluster keeps running without it: nodes fall back to ghcr.io/docker.io, and nothing
else changes until you provision, upgrade or need a backup.

Everything board-specific is in one file, `/etc/sbc-quartz/mgmt.env`
(from `mgmt/mgmt.env.example`): where the data and the backups live.

## Which board

| | Pi Zero 2 W | Quartz64 A (4/8 GB) |
|---|---|---|
| OS | Raspberry Pi OS Lite 64-bit | DietPi Quartz64A (Debian 13 "trixie"), on **eMMC** |
| network | USB-Ethernet + PoE splitter | onboard GbE |
| `DATA_DIR` | USB disk, `/mnt/usb` | eMMC, `/var/lib/sbc-quartz` |
| `BACKUP_DIR` | `/mnt/usb/etcd` | microSD if fitted (`/mnt/sd/etcd`), else eMMC |
| RAM headroom | tight (512 MB): caches + guard + holzkube only | plenty: can also join the cluster as a worker (below) |
| local imaging | `sbc-flash` works, slow over USB 2 | `sbc-flash` on USB 3; can also run `hack/build-image.sh` (arm64 Docker) |

Give it the static address the patches expect, **10.20.0.5** on the cluster VLAN
(`registry-mirror.yaml`, `netboot/dnsmasq.conf.example`).

## Bring-up

### 1. OS

**Pi Zero 2 W:** Raspberry Pi Imager → Raspberry Pi OS Lite (64-bit), enable SSH, flash the
microSD. Mount a USB disk at `/mnt/usb` (`/etc/fstab` by UUID, `nofail`).

**Quartz64 A:** the eMMC holds the OS, the microSD is optional data storage only.
1. Download `DietPi_Quartz64A-ARMv8-Trixie.img.xz` from dietpi.com.
2. Write it to the **eMMC module** in a USB eMMC adapter:
   `xz -dc DietPi_Quartz64A-ARMv8-Trixie.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync`
   No adapter: boot DietPi from an SD card and `dd` the same image onto `/dev/mmcblk0`.
3. Fit the eMMC, no SD card, power on. Log in as `root` / `dietpi` (SSH or UART2 at
   1500000 8N1) and finish DietPi's first-run setup. Set a static IP of 10.20.0.5.
4. Optional microSD for backups: `mkfs.ext4 -L sbc-backup /dev/mmcblk1` and mount it at
   `/mnt/sd` (`LABEL=sbc-backup /mnt/sd ext4 defaults,nofail 0 2`).

The boot ROM tries SPI → eMMC → SD, so with the eMMC fitted this board always boots
DietPi. A card in the slot is never booted, only mounted. Use other boards (or pull the
eMMC) to test Talos SD images.

### 2. Services (both boards)

```sh
git clone https://github.com/s-collison/sbc-quartz && cd sbc-quartz
sudo mgmt/install.sh                         # first run writes /etc/sbc-quartz/mgmt.env
sudoedit /etc/sbc-quartz/mgmt.env            # DATA_DIR / BACKUP_DIR per the table above
sudoedit /etc/sbc-quartz/nodes.yaml          # Quartz/SOQuartz IPs and boards
sudo mgmt/install.sh                         # caches up, guard + snapshot timers installed
```

`install.sh` is idempotent. Re-run it after pulling this repo to update the scripts.

### 3. holzkube-manager

Install its `linux_arm64` release with its systemd unit (per its README), with the data
directory under `DATA_DIR`. Open the UI, create the cluster (endpoint
`https://10.20.0.10:6443`) and add the stored patches; see [bring-up.md](bring-up.md) §2.
It stays on the host even if this node joins the cluster.

### 4. After the control plane is up

```sh
holzkubectl talosconfig homelab | sudo tee /etc/sbc-quartz/talosconfig >/dev/null
holzkubectl kubeconfig homelab  | sudo tee /etc/sbc-quartz/kubeconfig  >/dev/null
sudo mgmt/install.sh                         # now enables the guard and etcd-snapshot timers
sudo systemctl start etcd-snapshot.service && ls -l "$(. /etc/sbc-quartz/mgmt.env; echo $BACKUP_DIR)"
```

## Imaging boards

```sh
sudo sbc-flash soquartz-blade /dev/sdb              # latest release, stock flavor
sudo sbc-flash quartz64-a /dev/sdb --media          # media (Hantro) flavor
sudo sbc-flash soquartz-model-a /dev/sdb --tag v1.14.5-r1
```

It downloads `talos-<talos>-<board>[-media].raw.xz` from the GitHub release into
`/var/cache/sbc-quartz/<tag>/`, checks the `.sha256`, refuses mounted disks and the
running system disk, and asks before writing. For network installs instead of flashing,
see [netboot.md](netboot.md).

To build images locally rather than from a release (Quartz64 A only; needs Docker and
~10 GB free): `TALOS_VERSION=... bash hack/build-image.sh quartz64-a`.

## Optional: join the cluster as a non-Talos worker (Quartz64 A)

`mgmt/join-cluster.sh` makes this node a Kubernetes worker of the Talos cluster without
changing any Talos node, so helper jobs (imaging, PXE tooling, backup uploads) can be
scheduled here with kubectl:

```sh
sudo KUBECONFIG=/etc/sbc-quartz/kubeconfig mgmt/join-cluster.sh
kubectl get node "$(hostname -s)" -o wide
```

- kubelet from pkgs.k8s.io at exactly the cluster's Kubernetes version, containerd
  (shared with Docker), TLS bootstrap with a one-hour bootstrap token that is deleted
  once the node is Ready.
- Tainted `sbc-quartz.io/management=true:NoSchedule` and labelled
  `sbc-quartz.io/role=management`: nothing lands here unless it asks to. DaemonSets
  (kube-proxy, flannel) do run here.
- `kubeprism-shim.service` provides `127.0.0.1:7445` (Talos's KubePrism endpoint), which
  Talos configures kube-proxy and flannel to use.
- After a Kubernetes upgrade (tuppr's `KubernetesUpgrade`), re-run the script to move
  kubelet to the new version; tuppr doesn't manage this node.
- Leave with `join-cluster.sh --leave`.

A pod for this node needs:

```yaml
nodeSelector: {sbc-quartz.io/role: management}
tolerations: [{key: sbc-quartz.io/management, operator: Exists, effect: NoSchedule}]
```

and, if privileged (writing disks, PXE on host network), a namespace labelled
`pod-security.kubernetes.io/enforce: privileged`.

This is **experimental**: it has not been run against this cluster yet. If it fails,
`--leave` undoes it and nothing else depends on it. The Pi Zero doesn't have the RAM for
it, and holzkube-manager and the caches work the same either way.

## Why the guard exists

holzkube-manager 0.8 writes `.machine.install.image` during provisioning: the stock
`ghcr.io/siderolabs/installer:<v>` for nodes without an Image Factory schematic, or
the Factory installer. It's appended after your patches, so a patch can't override it.
Neither image carries this overlay. tuppr upgrades a node to `<its install image
repository>:<new version>`, so the guard sets that repository to
`ghcr.io/s-collison/talos-installer-<board>` right after provisioning, before any upgrade.
It handles both the legacy `.machine.install` and the 1.14 `UnattendedInstallConfig`.

**Don't use holzkube-manager's upgrade button for the Quartz/SOQuartz nodes.** Its
upgrade RPC sends the installer it resolves from the Image Factory, regardless of the
node's config. Use tuppr. The button is fine for the Pi 5 (Factory `rpi5` image).
