#!/usr/bin/env python3
"""List the kernel modules (and their module dependencies) that the media
flavor needs, as paths relative to /usr/lib/modules/<version>/, the format of
Talos's hack/modules-arm64.txt.

Talos only puts the modules named in that list into the image (its depmod
stage). The Hantro/RGA/rkvdec drivers and the V4L2/videobuf2 stack they need
aren't on it, so the media build appends this output before building the imager.

Dependencies are read from each .ko's ELF .modinfo section ("depends="), so no
host modinfo is needed and it works for any architecture.

usage: media-modules.py <modules-dir> [module-name ...]
  modules-dir: .../usr/lib/modules/<version>
  default names: hantro-vpu rockchip-rga rockchip-vdec  (missing ones are skipped,
  but at least one must exist)
"""
import os
import struct
import sys

DEFAULT = ["hantro-vpu", "rockchip-rga", "rockchip-vdec"]


def norm(name):
    return name.replace("-", "_")


def modinfo(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not an ELF file (compressed module?)")
    is64 = data[4] == 2
    endian = "<" if data[5] == 1 else ">"
    if is64:
        shoff, = struct.unpack_from(endian + "Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(endian + "HHH", data, 0x3A)
    else:
        shoff, = struct.unpack_from(endian + "I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(endian + "HHH", data, 0x2E)

    def section(i):
        base = shoff + i * shentsize
        if is64:
            name, _type, _flags, _addr, off, size = struct.unpack_from(endian + "IIQQQQ", data, base)
        else:
            name, _type, _flags, _addr, off, size = struct.unpack_from(endian + "IIIIII", data, base)
        return name, off, size

    _, stroff, _ = section(shstrndx)
    for i in range(shnum):
        name, off, size = section(i)
        end = data.index(b"\0", stroff + name)
        if data[stroff + name:end] == b".modinfo":
            info = {}
            for kv in data[off:off + size].split(b"\0"):
                if b"=" in kv:
                    k, v = kv.split(b"=", 1)
                    info.setdefault(k.decode(), v.decode())
            return info
    return {}


def main(root, names):
    index = {}
    for dirpath, _, files in os.walk(os.path.join(root, "kernel")):
        for f in files:
            if f.endswith(".ko"):
                index[norm(f[:-3])] = os.path.relpath(os.path.join(dirpath, f), root)

    wanted, todo, found_any = set(), [norm(n) for n in names], False
    while todo:
        n = todo.pop()
        if n in wanted:
            continue
        if n not in index:
            if norm(n) in map(norm, names):
                print(f"note: {n} not built in this kernel, skipping", file=sys.stderr)
                continue
            sys.exit(f"dependency {n} has no .ko under {root} (built-in modules never appear in depends=)")
        wanted.add(n)
        if norm(n) in map(norm, names):
            found_any = True
        deps = modinfo(os.path.join(root, index[n])).get("depends", "")
        todo += [norm(d) for d in deps.split(",") if d]
    if not found_any:
        sys.exit(f"none of {names} found under {root}: is kernel/media.config applied?")
    for path in sorted(index[n] for n in wanted):
        print(path)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2:] or DEFAULT))
