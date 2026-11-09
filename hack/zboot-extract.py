#!/usr/bin/env python3
"""Extract the raw arm64 Image from an EFI zboot kernel (CONFIG_EFI_ZBOOT).

Talos arm64 kernels are EFI zboot PE files. U-Boot's `booti` (used by
pxelinux/extlinux network boot) needs the raw Image instead. Booting the raw
Image without EFI also means /sys/firmware/efi is absent, so the Talos
installer picks GRUB, matching the flashed images.

Header layout (drivers/firmware/efi/libstub/zboot-header.S):
  0x00 "MZ\0\0"  0x04 "zimg"  0x08 u32 payload offset  0x0c u32 payload size
  0x18 compression type (asciz), e.g. "zstd" / "gzip"

usage: zboot-extract.py <vmlinuz> <Image>
"""
import struct
import subprocess
import sys

DECOMP = {"zstd": ["zstd", "-d", "-c", "-q"], "gzip": ["gzip", "-d", "-c"], "xzkern": ["xz", "-d", "-c"], "lzma": ["xz", "--format=lzma", "-d", "-c"]}


def main(src, dst):
    data = open(src, "rb").read()
    if data[0:2] != b"MZ" or data[4:8] != b"zimg":
        # Already a raw Image? (arm64 magic "ARM\x64" at 0x38)
        if data[0x38:0x3C] == b"ARM\x64":
            open(dst, "wb").write(data)
            print(f"{src}: already a raw arm64 Image, copied")
            return 0
        sys.exit(f"{src}: not an EFI zboot image (no MZ/zimg header)")
    off, size = struct.unpack_from("<II", data, 8)
    comp = data[0x18:0x38].split(b"\0", 1)[0].decode()
    if comp not in DECOMP:
        sys.exit(f"{src}: unsupported zboot compression {comp!r}")
    payload = data[off:off + size]
    if len(payload) != size:
        sys.exit(f"{src}: truncated payload ({len(payload)} of {size} bytes)")
    image = subprocess.run(DECOMP[comp], input=payload, stdout=subprocess.PIPE, check=True).stdout
    if image[0x38:0x3C] != b"ARM\x64":
        sys.exit(f"{src}: decompressed payload is not an arm64 Image")
    open(dst, "wb").write(image)
    print(f"{src}: {comp} zboot -> {dst} ({len(image)} bytes)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
