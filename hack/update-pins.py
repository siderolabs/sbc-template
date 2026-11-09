#!/usr/bin/env python3
"""Apply upstream pins to this repo (used by .github/workflows/track.yaml).

Inputs are upstream files the workflow downloads:
  --talos vX.Y.Z --pkgs <siderolabs/pkgs tag of that release>
  --rockchip-pkgfile   siderolabs/sbc-rockchip Pkgfile   (U-Boot, TF-A, rkbin pins + shas, bldr)
  --rockchip-makefile  siderolabs/sbc-rockchip Makefile  (TOOLS)
  --rockchip-gomod/--rockchip-gosum  one sbc-rockchip installer's go.mod/go.sum (machinery, go)

Following sbc-rockchip means only taking U-Boot/TF-A/rkbin/toolchain/Go versions
Sidero already builds RK3566/RK3568 boards with. Prints what changed; exit 0 either way.
"""
import argparse
import re
import sys

PKGFILE_VARS = [
    "arm_trusted_firmware_version", "arm_trusted_firmware_sha256", "arm_trusted_firmware_sha512",
    "uboot_version", "uboot_sha256", "uboot_sha512",
    "rkbin_ref", "rkbin_sha256", "rkbin_sha512",
]
changes = []


def rw(path, fn):
    old = open(path).read()
    new = fn(old)
    if new != old:
        open(path, "w").write(new)
        changes.append(path)


def sub1(pattern, repl, text, path, required=True):
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n == 0 and required:
        sys.exit(f"{path}: pattern not found: {pattern}")
    return new


def var(text, name):
    m = re.search(rf"^  {name}: *(\S+)[ \t]*$", text, re.M)
    return m.group(1) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--talos", required=True)
    ap.add_argument("--pkgs", required=True)
    ap.add_argument("--rockchip-pkgfile")
    ap.add_argument("--rockchip-makefile")
    ap.add_argument("--rockchip-gomod")
    ap.add_argument("--rockchip-gosum")
    a = ap.parse_args()

    # talos.env
    rw("talos.env", lambda t: sub1(r"^PKGS=.*$", f"PKGS={a.pkgs}",
                                   sub1(r"^TALOS_VERSION=.*$", f"TALOS_VERSION={a.talos}", t, "talos.env"), "talos.env"))
    # Makefile / .kres.yaml PKGS defaults
    rw("Makefile", lambda t: sub1(r"^PKGS \?= .*$", f"PKGS ?= {a.pkgs}", t, "Makefile"))
    rw(".kres.yaml", lambda t: sub1(r"(- name: PKGS\n\s+defaultValue: ).*$", rf"\g<1>{a.pkgs}", t, ".kres.yaml"))
    # example install patches + tuppr manifest
    for board in ("quartz64-a", "soquartz-blade", "soquartz-model-a"):
        p = f"talos/patches/install-{board}.yaml"
        rw(p, lambda t: sub1(r"(talos-installer-[a-z0-9-]+):v[0-9.]+(-\S+)?", rf"\g<1>:{a.talos}", t, p))
    rw("talos/tuppr/upgrades.yaml", lambda t: sub1(r"(talos:\n\s+version: )v\S+", rf"\g<1>{a.talos}", t, "upgrades.yaml"))

    if a.rockchip_pkgfile:
        up = open(a.rockchip_pkgfile).read()
        vals = {n: var(up, n) for n in PKGFILE_VARS}
        missing = [n for n, v in vals.items() if not v]
        if missing:
            sys.exit(f"sbc-rockchip Pkgfile lacks {missing}; refusing a partial update")
        bldr = re.search(r"^# syntax = (ghcr.io/siderolabs/bldr:\S+)", up, re.M)

        def pkgfile(t):
            for n, v in vals.items():
                t = sub1(rf"^(  {n}: *)\S+[ \t]*$", rf"\g<1>{v}", t, "Pkgfile")
            if bldr:
                t = sub1(r"^# syntax = ghcr.io/siderolabs/bldr:\S+", f"# syntax = {bldr.group(1)}", t, "Pkgfile")
            return t
        rw("Pkgfile", pkgfile)
        if bldr:
            ver = bldr.group(1).rsplit(":", 1)[1]
            rw("Makefile", lambda t: sub1(r"^BLDR_RELEASE := .*$", f"BLDR_RELEASE := {ver}", t, "Makefile"))

    if a.rockchip_makefile:
        m = re.search(r"^TOOLS \?= (\S+)", open(a.rockchip_makefile).read(), re.M)
        if not m:
            sys.exit("sbc-rockchip Makefile has no TOOLS ?=")
        rw("Makefile", lambda t: sub1(r"^TOOLS \?= .*$", f"TOOLS ?= {m.group(1)}", t, "Makefile"))
        rw(".kres.yaml", lambda t: sub1(r"(- name: TOOLS\n\s+defaultValue: ).*$", rf"\g<1>{m.group(1)}", t, ".kres.yaml"))

    if a.rockchip_gomod and a.rockchip_gosum:
        up = open(a.rockchip_gomod).read()
        if "github.com/siderolabs/talos/pkg/machinery" not in up:
            sys.exit("sbc-rockchip go.mod doesn't require machinery")
        # same dependency set; keep our module name
        new = re.sub(r"^module .*$", "module quartz64", up, count=1, flags=re.M)
        gomod = "installers/quartz64/src/go.mod"
        rw(gomod, lambda t: new)
        rw("installers/quartz64/src/go.sum", lambda t: open(a.rockchip_gosum).read())
        gover = re.search(r"^go (\S+)", new, re.M)
        if gover:
            rw("go.work", lambda t: sub1(r"^go \S+", f"go {gover.group(1)}", t, "go.work"))

    print("changed: " + (", ".join(sorted(set(changes))) if changes else "nothing"))


if __name__ == "__main__":
    main()
