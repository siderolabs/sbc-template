#!/usr/bin/env python3
"""install-image-guard: keep each Quartz/SOQuartz node's machine.install.image on
its board installer  <installerRepo>-<board>[-media]:<running Talos version>.

Why: holzkube-manager's provisioning writes machine.install.image itself (the
stock ghcr.io/siderolabs/installer or an Image Factory installer), after any
patches. Neither has this overlay. tuppr upgrades each node to
"<install image repo>:<new version>", so the repo must be ours before the first upgrade.

Idempotent: patches only when the repository differs, in no-reboot mode.
Needs: talosctl, python3-yaml, a talosconfig.
  INV=/etc/sbc-quartz/nodes.yaml  TALOSCONFIG=/etc/sbc-quartz/talosconfig
"""
import json
import os
import subprocess
import sys

import yaml

INV = os.environ.get("INV", "/etc/sbc-quartz/nodes.yaml")
os.environ.setdefault("TALOSCONFIG", "/etc/sbc-quartz/talosconfig")
TALOSCTL = os.environ.get("TALOSCTL", "talosctl")


def talosctl(*args):
    return subprocess.run([TALOSCTL, *args], capture_output=True, text=True)


def server_version(ip):
    r = talosctl("-n", ip, "version")
    if r.returncode != 0:
        return None
    server = False
    for line in r.stdout.splitlines():
        if line.startswith("Server:"):
            server = True
        elif server and line.strip().startswith("Tag:"):
            return line.split()[-1]
    return None  # only the client section printed: node unreachable


def install_image(ip):
    r = talosctl("-n", ip, "get", "machineconfig", "-o", "yaml")
    if r.returncode != 0:
        return None, None
    for res in yaml.safe_load_all(r.stdout):
        spec = (res or {}).get("spec")
        if not isinstance(spec, str):
            continue
        for doc in yaml.safe_load_all(spec):
            doc = doc or {}
            if doc.get("kind") == "UnattendedInstallConfig":          # Talos 1.14+
                return "unattended", (doc.get("installer") or {}).get("image")
            if doc.get("version") == "v1alpha1":
                legacy = ((doc.get("machine") or {}).get("install") or {}).get("image")
    return ("legacy", legacy) if "legacy" in locals() else (None, None)


def repo_of(ref):
    return ref.rsplit(":", 1)[0] if ref and ":" in ref.rsplit("/", 1)[-1] else ref


def main():
    inv = yaml.safe_load(open(INV))
    repo = inv["installerRepo"]
    rc = 0
    for n in inv.get("nodes", []):
        ip, board = n["ip"], n["board"]
        suffix = "-media" if n.get("flavor") == "media" else ""
        ver = server_version(ip)
        if not ver:
            print(f"{ip}: unreachable or not configured yet, skipping")
            continue
        want = f"{repo}-{board}{suffix}:{ver}"
        kind, have = install_image(ip)
        if repo_of(have) == repo_of(want):
            print(f"{ip}: ok ({have})")
            continue
        print(f"{ip}: install image {have or '<unset>'!r} -> {want!r}")
        if kind == "unattended":
            # 1.14 document owns the installer; .machine.install would be rejected
            patch = json.dumps({"apiVersion": "v1alpha1", "kind": "UnattendedInstallConfig",
                                "installer": {"image": want}})
        else:
            patch = json.dumps({"machine": {"install": {"image": want}}})
        r = talosctl("-n", ip, "patch", "machineconfig", "--mode=no-reboot", "-p", patch)
        if r.returncode != 0:
            print(f"{ip}: patch failed: {r.stderr.strip()}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
