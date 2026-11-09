# Network install (optional, later): management node (PXE + DNS + holzkube) → Pi 5 control plane → Quartz workers

> Not needed to get running. Flashed images boot into maintenance mode and
> holzkube-manager provisions them directly; see [provision-and-upgrade.md](provision-and-upgrade.md).
> Netboot assets are built only when the `images` workflow is run with `netboot: true`.

```
 Express 7 (gateway, Wi-Fi) ── existing PoE switch (VLAN-aware)
                                 VLAN 20 "cluster" (no SSID, not on AP/mesh ports)
                                   ├─ management node (Pi Zero 2 W or Quartz64 A) 10.20.0.5
                                   │    dnsmasq: DHCP + TFTP (U-Boot PXE) + local DNS
                                   │    holzkube-manager, etcd backups on its USB disk
                                   ├─ Raspberry Pi 5 16GB     10.20.0.10  Talos control plane (API), NFS (Ganesha pod)
                                   ├─ Quartz64 A              10.20.0.21  worker
                                   ├─ SOQuartz + Blade        10.20.0.22  worker  (media flavor: Hantro decode)
                                   └─ SOQuartz + Model-A      10.20.0.23  worker  (media flavor)
```

## VLANs on the existing switch

- Create network **cluster** (VLAN 20, 10.20.0.0/24) on the Express 7 with
  **DHCP server off**, or DHCP relay to 10.20.0.5. The management node answers DHCP.
- Switch ports for the Pi 5, the Quartz boards and the management node: native VLAN 20, untagged.
- The uplink to the Express 7 carries VLAN 20 tagged. Don't attach VLAN 20 to any SSID,
  and on AP/mesh uplink ports set Tagged VLAN Management so VLAN 20 is excluded. That
  keeps cluster broadcasts off the mesh. Routed LAN ↔ cluster traffic goes through the
  Express 7 (firewall zones decide what's allowed).
- Optional install VLAN: put a blank node's port on a separate VLAN 30 where only the
  management node serves PXE, then move the port to VLAN 20 after install. With the local-first
  boot order below, one VLAN is enough.

## How a node netboots and installs (local disk first, PXE as fallback)

1. **Prime blank media with U-Boot only** (once per node). U-Boot comes from the release's
   `netboot-<talos>-<flavor>.tar.gz` (`u-boot/<board>/`):
   ```sh
   sudo dd if=u-boot/soquartz-blade/u-boot-rockchip.bin of=/dev/rdiskN bs=512 seek=64 conv=notrunc
   ```
   (Quartz64 A can instead carry `u-boot-rockchip-spi.bin` in SPI flash and boot with no SD at all.)
2. **Power on.** U-Boot's boot order is `mmc1 mmc0 nvme scsi usb pxe dhcp spi`. With no
   Talos on any local disk it reaches `pxe`, asks DHCP (the management node), and loads
   `pxelinux.cfg/default` over TFTP. That menu boots the raw kernel `Image` with `booti`,
   plus the initramfs and the board's DTB (`fdtdir` + U-Boot's `${fdtfile}`).
3. **Maintenance mode.** Talos runs from RAM and shows up in holzkube-manager or
   `talosctl get disks --insecure -n <ip>`.
4. **Apply config** (holzkube "provision" or `talosctl apply-config --insecure`) with:
   - `machine.install.disk`: the eMMC or SD
   - `machine.install.image`: **the board installer**,
     `ghcr.io/s-collison/talos-installer-<board>[-media]:<talos>` (`talos/patches/install-*.yaml`)

   The installer partitions the disk, installs **GRUB**, and its overlay hook writes U-Boot
   at sector 64 and the DTB to the ESP. Because the kernel was started by `booti`, not EFI,
   there's no `/sys/firmware/efi`, so Talos picks GRUB instead of systemd-boot. Don't
   serve an EFI binary (no `dhcp-boot`/bootfile option): the `dhcp` bootdev would EFI-boot
   it, and the install would get systemd-boot.
5. **Reboot.** U-Boot now finds Talos on the local disk first and never touches PXE
   again. Wipe the disk to re-provision; it falls back to PXE automatically.

The Pi 5 doesn't use this path (its firmware has its own network boot). Flash it from the
`rpi5` overlay image and boot from microSD.

## The management node

Set up per [management-node.md](management-node.md), then add dnsmasq:

```sh
sudo apt install dnsmasq
sudo cp netboot/dnsmasq.conf.example /etc/dnsmasq.d/cluster.conf   # edit MACs/IPs
sudo mkdir -p /srv/tftp && sudo tar -xzf netboot-v1.14.5-media.tar.gz -C /srv/tftp
sudo systemctl restart dnsmasq
```

Both flavors can sit side by side (`/srv/tftp/talos/stock`, `/srv/tftp/talos/media`).
`pxelinux.cfg/default` points at the flavor it came with. Use
`pxelinux.cfg/01-<mac-with-dashes>` files to give a node a different flavor.

### holzkube-manager and etcd backups

Both are part of the management node setup ([management-node.md](management-node.md)).
Provision with holzkube; upgrade the Quartz/SOQuartz boards with tuppr or
`talosctl upgrade --image ghcr.io/s-collison/talos-installer-<board>[-media]:<ver>`,
not holzkube's upgrade button.
