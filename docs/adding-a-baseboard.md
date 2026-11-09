# Adding a baseboard

## How an image is put together

The SOQuartz is a CM4-form-factor module: the RK3566, RAM, PMIC, eMMC and the
gigabit PHY are on the module, and the baseboard decides everything else
(which SD slot, PCIe, USB hub, fans, extra NICs). For Talos that comes down to
**two choices per baseboard**:

| piece | where it comes from | what it decides |
|---|---|---|
| U-Boot defconfig | `artifacts/quartz64/u-boot` builds `<defconfig>` from mainline U-Boot (+ TF-A BL31, rkbin DDR blob) | power-up, which storage it boots from, and `fdtfile`, the DTB name it hands the kernel |
| kernel DTB | `rk3566-*.dtb` from the Talos kernel image (`installers/pkg.yaml` copies all of `dtb/rockchip`) | which peripherals Linux brings up |

The imager then combines Talos (arm64) with this overlay:

```
imager <board> --arch arm64 --overlay-image ghcr.io/s-collison/sbc-quartz:<tag> --overlay-name <board>
   └─ runs installers/<board>  ->  writes u-boot-rockchip.bin at sector 64
                                   copies dtb to the ESP at /dtb/rockchip/<dtb>
                                   adds console=ttyS2,1500000n8 to the kernel args
```

**Rule:** the DTB file name must equal U-Boot's `CONFIG_DEFAULT_FDT_FILE` for
that defconfig, because that's the file U-Boot loads from the ESP.
`hack/build-image.sh` checks this for you.

Everything is in this repo. Boards are listed **once**, in `Pkgfile`:

```yaml
  boards: >-
    quartz64-a:quartz64-a-rk3566_defconfig:rk3566-quartz64-a.dtb
    soquartz-blade:soquartz-blade-rk3566_defconfig:rk3566-soquartz-blade.dtb
    ...
#   <overlay-name>:<u-boot defconfig>:<kernel dtb>
```

## Case A: mainline already knows the baseboard

Check both exist:

```sh
tar tjf u-boot-<ver>.tar.bz2 | grep 'configs/.*rk3566_defconfig'      # U-Boot
# kernel: arch/arm64/boot/dts/rockchip/rk3566-*.dts in the Linux version Talos ships
```

1. Add a line to `boards:` in `Pkgfile`.
2. `cp profiles/boards/soquartz-blade.yaml profiles/boards/<name>.yaml`. The file name must equal the
   overlay name: `hack/build-image.sh` runs `imager <name>`, which picks this profile and its
   `bootloader: grub`.
3. `make sbc-quartz PUSH=true && hack/build-image.sh <name>`

## Case B: third-party CM4 carrier (most common)

The SOQuartz is pin-compatible with CM4, so most CM4 carriers (Waveshare
CM4-IO-BASE / CM4-PoE, Turing Pi 2, DeskPi Super6C, ...) boot with the
`soquartz-cm4` U-Boot and DTB. Add an **alias** with its own overlay name, so
nodes are labelled by board, and reuse the cm4 pieces:

```yaml
    turingpi2:soquartz-cm4-rk3566_defconfig:rk3566-soquartz-cm4.dtb
```

plus `profiles/boards/turingpi2.yaml`. U-Boot is built once per defconfig, so
an alias costs nothing.

What to expect:
- **Works:** anything on the module: CPU/RAM, module eMMC, the module's GbE
  port, the PMIC, and UART2 on the carrier's debug pins at 1.5 Mbaud.
- **Check:** the carrier's SD slot, USB, and PCIe/M.2. These work if the carrier
  wires them like the Raspberry Pi CM4-IO board, which `soquartz-cm4.dts` targets.
- **Won't work without a DTB change:** carrier-specific I²C devices (fan
  controller, RTC), USB hubs or PCIe switches that need a reset/enable GPIO,
  and any extra NIC on the carrier.

## Case C: the carrier needs its own device tree

Not wired up yet. The approach:

1. Add `artifacts/quartz64/dts/rk3566-soquartz-<carrier>.dts` that
   `#include "rk3566-soquartz.dtsi"` and enables or adds the carrier's nodes
   (start by copying `rk3566-soquartz-cm4.dts`).
2. Add a bldr stage that unpacks the Linux source for the Talos kernel version
   and builds it with
   `make ARCH=arm64 dtbs` after dropping the file into `arch/arm64/boot/dts/rockchip/`
   (and adding it to that Makefile). Install the result into
   `/rootfs/artifacts/arm64/dtb/rockchip/`.
3. Make U-Boot point at it: build the cm4 defconfig with a fragment that sets
   `CONFIG_DEFAULT_FDT_FILE="rockchip/rk3566-soquartz-<carrier>.dtb"`.
   This needs a 4th field in the board table, or a dedicated defconfig in a patch.
4. Use that DTB name in the `boards:` entry.

Try upstreaming the DTS too; once it's in mainline, the board becomes Case A.

## Verifying a new board

1. `hack/build-image.sh <name>` must print four `ok` lines.
2. Serial at 1500000 8N1: you should see U-Boot, then `EFI stub`, then Talos
   logs. If it stops right after U-Boot, the DTB or `fdtfile` is wrong.
3. The node gets a DHCP address; `talosctl -n <ip> --insecure get links` answers.
4. Boot ROM order is SPI -> eMMC -> SD. An old bootloader on eMMC takes priority
   over the SD card.
