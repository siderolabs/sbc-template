# Bring-up runbook

The order matters: images → network → Pi Zero → Pi 5 (control plane) → workers →
upgrades. Talos v1.14.5 is the example version throughout.

```
Express 7 (gateway, DHCP/DNS) ── PoE switch, VLAN 20 "cluster" 10.20.0.0/24
   ├─ Pi Zero 2 W   10.20.0.5   holzkube-manager, registry caches, install-image guard, etcd backups  (not in the cluster)
   ├─ Pi 5 16GB     10.20.0.10  control plane / API + Plex, ripping, NFS (2 TB SSD)
   ├─ Quartz64 A    10.20.0.21  worker
   ├─ SOQuartz Blade 10.20.0.22 worker
   └─ SOQuartz Model-A 10.20.0.23 worker
```

## 0. Images (once per Talos release, automatic afterwards)

1. Push the branch, open the PR and merge it:
   `git push -u origin fix/quartz64-arm64-boot && gh pr create --fill --body-file _out/PR_BODY.md`
2. GitHub → Actions → **images** → *Run workflow* (defaults: latest Talos, stock flavor).
3. When it's done, GitHub → Packages: set **sbc-quartz** and every **talos-installer-\*** package
   to **public**. Talos pulls installers without credentials.
4. Download `talos-v1.14.5-<board>.raw.xz` for each board from the new Release.

From then on it runs every Monday and publishes any new Talos release automatically.

## 1. Network (UniFi)

- Network **cluster**: VLAN 20, 10.20.0.0/24, gateway on the Express 7, DHCP on.
- **DHCP reservations** (by MAC) for the IPs above. The Talos API endpoint is the Pi 5's
  IP, so it must not change.
- Switch ports for these five devices: native VLAN 20. Uplink to the Express: VLAN 20 tagged.
  Don't attach VLAN 20 to an SSID, and exclude it on AP/mesh uplink ports.

## 2. Pi Zero 2 W (management box)

Raspberry Pi OS Lite 64-bit, USB-Ethernet + PoE splitter, USB disk mounted at `/mnt/usb`.
Details are in [zero.md](zero.md). In short:

```sh
sudo apt install docker.io docker-compose python3-yaml
curl -sL https://talos.dev/install | sh                       # talosctl
sudo docker compose -f zero/compose.yaml up -d                # ghcr.io :5003, docker.io :5000 caches
```

Install **holzkube-manager** (`linux_arm64` release, systemd unit, data dir on
`/mnt/usb`) and open its UI. Create the cluster **homelab** with endpoint
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
6. Export credentials on the Zero:
   ```sh
   holzkubectl talosconfig homelab | sudo tee /etc/sbc-quartz/talosconfig >/dev/null
   holzkubectl kubeconfig homelab > ~/.kube/config
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
4. Add it to the guard's inventory on the Zero (`/etc/sbc-quartz/nodes.yaml`, from
   `zero/nodes.yaml.example`), then install and start the guard once:
   ```sh
   sudo install -m 0755 zero/install-image-guard.py /usr/local/bin/
   sudo install -m 0644 zero/install-image-guard.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now install-image-guard.timer
   sudo /usr/local/bin/install-image-guard.py
   ```
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

1. Wait for the **images** workflow (Monday, or run it by hand) to publish
   `talos-installer-<board>:<new>`.
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

On the Zero (`/etc/cron.d/etcd-snapshot`), keeping copies off the Pi 5, which holds etcd:

```sh
0 */6 * * * root talosctl --talosconfig /etc/sbc-quartz/talosconfig -n 10.20.0.10 etcd snapshot /mnt/usb/etcd/etcd-$(date +\%F-\%H).db && ls -1t /mnt/usb/etcd/etcd-*.db | tail -n +29 | xargs -r rm
```

holzkube can schedule snapshots too. Keep its data dir on `/mnt/usb` as well.

## Optional, later

- **Hantro decode** on SOQuartz: run **images** with flavors `["stock","media"]`. The first
  run builds the media kernel, which takes hours. Install the node from
  `talos-v1.14.5-<board>-media.raw.xz`, add the `media` patch, and set `flavor: media` in the
  guard inventory. Scrypted: `talos/examples/scrypted-media.yaml`.
- **M.2 storage with LINSTOR:** see [cluster-ops.md](cluster-ops.md#m2-ssd-with-drbd--linstor-piraeus).
- **PXE:** see [netboot.md](netboot.md). It needs a self-hosted Image Factory before holzkube
  can provision PXE nodes with the right installer. Groundwork:
  [provision-and-upgrade.md](provision-and-upgrade.md#later-holzkube-for-everything-self-hosted-image-factory).
