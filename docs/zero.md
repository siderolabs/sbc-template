# Pi Zero 2 W: management box (outside the cluster)

Raspberry Pi OS Lite 64-bit, USB-Ethernet + PoE splitter, USB disk at `/mnt/usb`.
It runs:

| service | what for |
|---|---|
| holzkube-manager | GUI; provisions maintenance-mode nodes (assigns configs) |
| `zero/compose.yaml` pull-through caches | `ghcr.io` (:5003) and `docker.io` (:5000) cached on the USB disk; nodes use them via `talos/patches/registry-mirror.yaml` |
| `install-image-guard` (timer, every 5 min) | pins each Quartz/SOQuartz node's `machine.install.image` to its GHCR board installer |
| etcd snapshot cron | backups off the control plane (see netboot.md → etcd backups) |

The cluster doesn't depend on the Zero. If it's down, nodes pull straight from
ghcr.io/docker.io (Talos falls back to upstream), and nothing else changes.

## Install

```sh
sudo apt install docker.io docker-compose python3-yaml
# talosctl (arm64)
curl -sL https://talos.dev/install | sh
sudo mkdir -p /etc/sbc-quartz /mnt/usb/registry
sudo cp talosconfig /etc/sbc-quartz/talosconfig          # from talosctl gen config / holzkube
sudo cp zero/nodes.yaml.example /etc/sbc-quartz/nodes.yaml  # edit IPs/boards

# caches
sudo docker compose -f zero/compose.yaml up -d

# guard
sudo install -m 0755 zero/install-image-guard.py /usr/local/bin/
sudo install -m 0644 zero/install-image-guard.service zero/install-image-guard.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now install-image-guard.timer
sudo /usr/local/bin/install-image-guard.py     # run once by hand
```

holzkube-manager: install per its guide (`linux_arm64` release, systemd unit), with
its data directory on `/mnt/usb`. 512 MB is tight, so watch memory with all of this
running. The caches are small Go processes; Docker itself is the biggest user.

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
