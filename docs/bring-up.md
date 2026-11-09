# Bring-up runbook

The order matters: images → network → management node → Pi 5 (control plane) → workers →
upgrades. Talos v1.14.5 is the example version throughout.

```
Express 7 (gateway, DHCP/DNS) ── PoE switch, VLAN 20 "cluster" 10.20.0.0/24
   ├─ mgmt node     10.20.0.5   Pi Zero 2 W or Quartz64 A: holzkube-manager, registry caches, install-image guard, etcd backups
   ├─ Pi 5 16GB     10.20.0.10  control plane / API + Plex, ripping, NFS (2 TB SSD)
   ├─ Quartz64 A    10.20.0.21  worker
   ├─ SOQuartz Blade 10.20.0.22 worker
   └─ SOQuartz Model-A 10.20.0.23 worker
```

## 0. Images (automatic)

1. One-time repo setting: Settings → Actions → General → Workflow permissions → **Read and
   write** and **Allow GitHub Actions to create and approve pull requests**.
2. Merge to `main`. **track** runs on the merge (and daily): it tags the build after the Talos
   version in `talos.env` (`v1.14.5`, later fixes `v1.14.5-r1`…) and starts **images**, which
   builds the **stock** and **media** (Hantro) images for each board and publishes the Release.
   The first media run builds the kernel and takes several hours; stock images don't wait.
   From then on you only hear from it through an `auto-update` PR or a `build-failure` issue.
3. When it's done, GitHub → Packages: set **sbc-quartz** and every **talos-installer-\*** package
   to **public**. Talos pulls installers without credentials.
4. Download `talos-v1.14.5-<board>.raw.xz` for each board from the new Release, or write it
   straight to a card/eMMC from the management node: `sudo sbc-flash <board> /dev/sdX`.

From then on it runs every Monday and publishes any new Talos release automatically.

## 1. Network (UniFi)

- Network **cluster**: VLAN 20, 10.20.0.0/24, gateway on the Express 7, DHCP on.
- **DHCP reservations** (by MAC) for the IPs above. The Talos API endpoint is the Pi 5's
  IP, so it must not change.
- Switch ports for these five devices: native VLAN 20. Uplink to the Express: VLAN 20 tagged.
  Don't attach VLAN 20 to an SSID, and exclude it on AP/mesh uplink ports.

## 2. Management node

A Pi Zero 2 W or a spare Quartz64 A (DietPi on eMMC) at 10.20.0.5. Full steps per board
are in [management-node.md](management-node.md). In short:

```sh
git clone https://github.com/s-collison/sbc-quartz && cd sbc-quartz
sudo mgmt/install.sh && sudoedit /etc/sbc-quartz/mgmt.env /etc/sbc-quartz/nodes.yaml && sudo mgmt/install.sh
```

Install **holzkube-manager** (`linux_arm64` release, systemd unit, data dir under
`DATA_DIR`) and open its UI. Create the cluster **homelab** with endpoint
`https://10.20.0.10:6443`.

Add these as stored patches in holzkube (from `talos/patches/`):

| patch | apply to |
|---|---|
| `registry-mirror.yaml` | all nodes |
| `tuppr.yaml` | all nodes |
| `rpi5-controlplane.yaml` | Pi 5 only, **first apply** |
| `drbd.yaml` | workers that will run LINSTOR on the M.2 SSD |
| `media.yaml` | only nodes installed from the `-media` images |

## 3. Pi 5: control plane

1. Update the Pi 5 bootloader EEPROM first (Raspberry Pi Imager → Misc utility images →
   Bootloader), or Talos may not boot.
2. Make the image: Image Factory (holzkube's schematic screen, or factory.talos.dev) →
   Talos v1.14.5, arm64, SBC overlay **rpi5** (`siderolabs/sbc-raspberrypi`). Flash it to the microSD.
3. Attach the 2 TB SSD and boot. The Pi shows up in holzkube as a maintenance-mode machine.
4. Provision it as **control plane**: install disk = the microSD, patches `registry-mirror`,
   `tuppr`, `rpi5-controlplane`. If the SSD is on USB rather than NVMe, change `nvme` to
   `usb` in that patch first (`talosctl get disks --insecure -n 10.20.0.10`).
5. Bootstrap etcd (holzkube does this for the first control plane, or run
   `talosctl bootstrap -n 10.20.0.10`).
6. Export credentials on the management node and enable its timers:
   ```sh
   holzkubectl talosconfig homelab | sudo tee /etc/sbc-quartz/talosconfig >/dev/null
   holzkubectl kubeconfig homelab | sudo tee /etc/sbc-quartz/kubeconfig >/dev/null
   sudo mgmt/install.sh                       # enables install-image-guard + etcd-snapshot timers
   talosctl --talosconfig /etc/sbc-quartz/talosconfig -n 10.20.0.10 health
   ```

## 4. Quartz64 A / SOQuartz: workers

For each board:

1. Flash its image onto the disk it will boot from (eMMC through a USB adapter, or SD):
   `xz -dc talos-v1.14.5-soquartz-blade.raw.xz | sudo dd of=/dev/rdiskN bs=4m`
   Remove any other card or eMMC that has an old bootloader (boot order: SPI → eMMC → SD).
2. Boot. On first boot, watch UART2 at **1500000 8N1**: U-Boot, then GRUB, then Talos.
   The node appears in holzkube in maintenance mode.
3. Provision it as **worker**: install disk = the disk you flashed, patches
   `registry-mirror`, `tuppr` (+ `drbd`).
4. Add it to `/etc/sbc-quartz/nodes.yaml` on the management node. The guard timer picks it
   up within 5 minutes (or run `sudo install-image-guard.py`).
   It changes the node's install image from holzkube's stock installer to
   `ghcr.io/s-collison/talos-installer-<board>:v1.14.5` (no reboot). Check:
   `talosctl -n <ip> get machineconfig -o yaml | grep image:`
5. Verify: `kubectl get nodes`, `talosctl -n <ip> get extensions` (drbd listed).

## 5. Upgrades (tuppr)

Once, on any machine with the kubeconfig:

```sh
helm install tuppr oci://ghcr.io/home-operations/charts/tuppr -n system-upgrade --create-namespace
kubectl apply -f talos/tuppr/upgrades.yaml     # TalosUpgrade + KubernetesUpgrade at the current versions
```

For each new Talos release:

1. Nothing to start: **track** sees the release within a day, tags `v<new>` and **images**
   publishes `talos-installer-<board>:<new>` (watch for a `build-failure` issue instead).
2. Bump `spec.talos.version` in `talos/tuppr/upgrades.yaml` and apply it. tuppr upgrades one
   node at a time:
   - **Quartz/SOQuartz:** `ghcr.io/s-collison/talos-installer-<board>:<new>`. The overlay
     refreshes U-Boot and the device tree, and GRUB is kept.
   - **Pi 5:** the same Image Factory schematic at the new version.
3. Kubernetes upgrades: bump `spec.kubernetes.version` the same way.

holzkube's upgrade button is fine for the Pi 5. **Don't use it for the Quartz/SOQuartz
nodes**: it sends an Image Factory installer without this overlay.

By hand instead of tuppr:
`talosctl -n <ip> upgrade --image ghcr.io/s-collison/talos-installer-<board>:<new>`

## 6. Backups

The management node's `etcd-snapshot.timer` saves a snapshot from the Pi 5 every 6 hours
into `BACKUP_DIR` (`/etc/sbc-quartz/mgmt.env`), keeping 28. Check with
`systemctl list-timers etcd-snapshot.timer` and `ls $BACKUP_DIR`. Restore:
`talosctl -n 10.20.0.10 bootstrap --recover-from=<snapshot.db>` on a wiped control plane.
