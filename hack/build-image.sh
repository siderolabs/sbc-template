#!/usr/bin/env bash
# Build bootable Talos images, upgrade installers and netboot (PXE) assets for
# Pine64 RK3566 boards, and verify them.
#
#   hack/build-image.sh [board ...]          # default: quartz64-a soquartz-blade soquartz-model-a
#
# Env:
#   TALOS_VERSION         Talos version (default v1.14.5)
#   FLAVOR                stock | media (default stock). "media" = custom kernel with Hantro/RGA;
#                         needs the images from .github/workflows/media-kernel.yaml
#   OVERLAY_IMAGE         overlay from this repo (default ghcr.io/s-collison/sbc-quartz:$(git describe))
#   IMAGER_IMAGE          default: ghcr.io/siderolabs/imager:$TALOS_VERSION (stock),
#                         ghcr.io/s-collison/talos-media/imager:$TALOS_VERSION (media)
#   BASE_INSTALLER_IMAGE  default: unset (stock), ghcr.io/s-collison/talos-media/installer-base:$TALOS_VERSION (media)
#   EXTENSIONS            official extension names, pinned for TALOS_VERSION, e.g. "drbd" (stock only:
#                         official modules are signed with Sidero's key, not the media kernel's)
#   EXTENSION_IMAGES      explicit extension image refs (media: ghcr.io/s-collison/talos-media/drbd:$TALOS_VERSION)
#   INSTALLER_REPO        also push ${INSTALLER_REPO}-<board>[-media]:${TALOS_VERSION}
#   NETBOOT=1             also build the TFTP tree _out/netboot-<flavor>/ (+ .tar.gz) for U-Boot PXE
#   DOCKER_CONFIG         registry credentials dir passed to imager/crane (default ~/.docker)
#
# Disk images use the board's overlay profile (GRUB). Plain "metal" would pick
# systemd-boot on arm64, and so would an EFI netboot. The netboot tree therefore
# serves the *raw* kernel Image for U-Boot booti (no EFI), so a PXE install
# also writes GRUB.
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:-v1.14.5}"
FLAVOR="${FLAVOR:-stock}"
TAG="$(git describe --tag --always --dirty --match 'v[0-9]*')"
OVERLAY_IMAGE="${OVERLAY_IMAGE:-ghcr.io/s-collison/sbc-quartz:${TAG}}"
EXTENSIONS="${EXTENSIONS:-}"
EXTENSION_IMAGES="${EXTENSION_IMAGES:-}"
INSTALLER_REPO="${INSTALLER_REPO:-}"
NETBOOT="${NETBOOT:-0}"
OUT="${PWD}/_out"
CRANE="gcr.io/go-containerregistry/crane:latest"

case "${FLAVOR}" in
  stock)
    IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/siderolabs/imager:${TALOS_VERSION}}"
    BASE_INSTALLER_IMAGE="${BASE_INSTALLER_IMAGE:-}"
    SUFFIX="" ;;
  media)
    IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/s-collison/talos-media/imager:${TALOS_VERSION}}"
    BASE_INSTALLER_IMAGE="${BASE_INSTALLER_IMAGE:-ghcr.io/s-collison/talos-media/installer-base:${TALOS_VERSION}}"
    [ -z "${EXTENSIONS}" ] || { echo "FLAVOR=media: use EXTENSION_IMAGES (rebuilt for the media kernel), not EXTENSIONS" >&2; exit 1; }
    SUFFIX="-media" ;;
  *) echo "FLAVOR must be stock or media" >&2; exit 1 ;;
esac

# Registry creds into containers only when stored in the file (CI). Docker
# Desktop's osxkeychain store can't be read from a container.
DOCKER_ARGS=()
CFG="${DOCKER_CONFIG:-${HOME}/.docker}"
if [ -f "${CFG}/config.json" ] && ! grep -q '"credsStore"' "${CFG}/config.json"; then
  DOCKER_ARGS+=(-v "${CFG}:/docker-config:ro" -e DOCKER_CONFIG=/docker-config)
fi

TABLE="$(awk '/^  boards:/{f=1;next} f&&/^    [a-z0-9-]+:/{print $1;next} f{exit}' Pkgfile)"
[ -n "${TABLE}" ] || { echo "could not read boards from Pkgfile" >&2; exit 1; }
if [ "$#" -eq 0 ]; then set -- quartz64-a soquartz-blade soquartz-model-a; fi

EXT_ARGS=()
if [ -n "${EXTENSIONS}" ]; then
  DIGESTS="$(docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} "${CRANE}" export "ghcr.io/siderolabs/extensions:${TALOS_VERSION}" - | tar x -O image-digests)"
  for e in ${EXTENSIONS}; do
    ref="$(printf '%s\n' "${DIGESTS}" | grep -E "^ghcr.io/siderolabs/${e}:" | head -n1 || true)"
    [ -n "${ref}" ] || { echo "extension ${e} not found for Talos ${TALOS_VERSION}" >&2; exit 1; }
    EXT_ARGS+=(--system-extension-image "${ref}")
  done
fi
for ref in ${EXTENSION_IMAGES}; do EXT_ARGS+=(--system-extension-image "${ref}"); done
[ -z "${BASE_INSTALLER_IMAGE}" ] || EXT_ARGS+=(--base-installer-image "${BASE_INSTALLER_IMAGE}")
for a in ${EXT_ARGS[@]+"${EXT_ARGS[@]}"}; do case "$a" in --*) ;; *) echo ">> input ${a}";; esac; done

# imager <outdir> <args...>
imager() {
  local out="$1"; shift
  mkdir -p "${out}"
  docker run --rm -t ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
    -v "${out}:/out" -v /dev:/dev --privileged \
    "${IMAGER_IMAGE}" "$@"
}

entry_for() { printf '%s\n' "${TABLE}" | grep "^$1:" || true; }

build_one() {
BOARD="$1"
ENTRY="$(entry_for "${BOARD}")"
[ -n "${ENTRY}" ] || { echo "unknown board ${BOARD}; known: $(printf '%s\n' "${TABLE}" | cut -d: -f1 | tr '\n' ' ')" >&2; return 1; }
DTB="${ENTRY##*:}"
WORK="${OUT}/.work-${BOARD}"; rm -rf "${WORK}"

echo ">> [${FLAVOR}] imager ${IMAGER_IMAGE}  overlay ${OVERLAY_IMAGE}  board ${BOARD}"
imager "${WORK}" "${BOARD}" --arch arm64 \
  --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
  ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} || return 1

IMG="${OUT}/talos-${TALOS_VERSION}-${BOARD}${SUFFIX}.raw.xz"
NEW="$(ls "${WORK}"/*.raw.xz 2>/dev/null | head -n1)"
[ -n "${NEW}" ] || { echo "imager produced no .raw.xz" >&2; return 1; }
mv "${NEW}" "${IMG}" || return 1

echo ">> verifying ${IMG}"
TMP="$(mktemp)"
xz -dc "${IMG}" | head -c 300000000 > "${TMP}" || true   # first ~300MB covers u-boot + ESP
fail=0
if [ "$(dd if="${TMP}" bs=512 skip=64 count=1 2>/dev/null | head -c 4)" = "RKNS" ]; then
  echo "   ok  Rockchip idbloader at sector 64"
else
  echo "   BAD no idbloader at sector 64 (u-boot not written)"; fail=1
fi
if LC_ALL=C grep -aq 'BOOTAA64EFI' "${TMP}"; then
  echo "   ok  BOOTAA64.EFI present (arm64 EFI loader)"
else
  echo "   BAD no BOOTAA64.EFI — not an arm64 image"; fail=1
fi
if LC_ALL=C grep -aq 'LOADER     ' "${TMP}"; then
  echo "   BAD systemd-boot loader/ on ESP — built with the generic profile, expected GRUB"; fail=1
else
  echo "   ok  GRUB layout (no systemd-boot loader/ dir)"
fi
if LC_ALL=C grep -aq 'BOOTX64 EFI' "${TMP}"; then
  echo "   BAD BOOTX64.EFI present — this is an amd64 image"; fail=1
fi
if LC_ALL=C grep -aq "fdtfile=rockchip/${DTB}" "${TMP}"; then
  echo "   ok  U-Boot fdtfile matches ${BOARD}"
else
  echo "   BAD U-Boot fdtfile does not match ${BOARD}"; fail=1
fi
if LC_ALL=C grep -aq 'pxelinux.cfg' "${TMP}"; then
  echo "   info U-Boot can PXE boot (upstream default; local disks are tried first)"
fi
rm -f "${TMP}"
[ "${fail}" = 0 ] || { echo "image failed verification" >&2; return 1; }
echo ">> done: ${IMG}"

if [ -n "${INSTALLER_REPO}" ]; then
  REF="${INSTALLER_REPO}-${BOARD}${SUFFIX}:${TALOS_VERSION}"
  echo ">> installer ${REF}"
  imager "${WORK}" installer --arch arm64 \
    --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
    ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} || return 1
  docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} -v "${WORK}:/out" "${CRANE}" \
    push /out/installer-arm64.tar "${REF}" || return 1
fi
rm -rf "${WORK}"
}

# TFTP tree for U-Boot PXE (one tree serves every board: U-Boot's per-board
# ${fdtfile} picks the DTB from fdtdir):
#   talos/<flavor>/Image               raw arm64 kernel (extracted from EFI zboot) for booti
#   talos/<flavor>/initramfs-arm64.xz  initramfs incl. extensions
#   talos/<flavor>/dtb/rockchip/*.dtb  from the overlay
#   pxelinux.cfg/default               generated from netboot/pxelinux.cfg.default.tmpl
#   u-boot/<board>/u-boot-rockchip.bin  to prime blank media (not needed by TFTP)
build_netboot() {
local board="$1" W="${OUT}/.work-netboot" T="${OUT}/netboot-${FLAVOR}"
rm -rf "${W}" "${T}"; mkdir -p "${W}/k" "${W}/i" "${W}/c" "${T}/talos/${FLAVOR}/dtb" "${T}/pxelinux.cfg"
local common=(--arch arm64 --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${board}" ${EXT_ARGS[@]+"${EXT_ARGS[@]}"})
echo ">> [${FLAVOR}] netboot assets"
imager "${W}/k" "${board}" --output-kind kernel    "${common[@]}" || return 1
imager "${W}/i" "${board}" --output-kind initramfs "${common[@]}" || return 1
imager "${W}/c" "${board}" --output-kind cmdline   "${common[@]}" || return 1
local kern init cmd
kern="$(ls "${W}"/k/* | head -n1)"; init="$(ls "${W}"/i/* | head -n1)"; cmd="$(ls "${W}"/c/* | head -n1)"
python3 hack/zboot-extract.py "${kern}" "${T}/talos/${FLAVOR}/Image" || return 1
cp "${init}" "${T}/talos/${FLAVOR}/initramfs-arm64.xz"
docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} "${CRANE}" export --platform linux/arm64 "${OVERLAY_IMAGE}" - \
  | tar x -C "${W}" artifacts/arm64/dtb artifacts/arm64/u-boot || return 1
cp -r "${W}/artifacts/arm64/dtb/rockchip" "${T}/talos/${FLAVOR}/dtb/"
# U-Boot per board, for priming a blank SD/eMMC (dd at sector 64) or SPI (quartz64-a)
cp -r "${W}/artifacts/arm64/u-boot" "${T}/u-boot"
local cmdline; cmdline="$(tr -d '\n' < "${cmd}")"
echo "   cmdline: ${cmdline}"
sed -e "s#@FLAVOR@#${FLAVOR}#g" -e "s#@CMDLINE@#${cmdline}#" netboot/pxelinux.cfg.default.tmpl > "${T}/pxelinux.cfg/default"
grep -q 'console=ttyS2,1500000n8' "${T}/pxelinux.cfg/default" || { echo "   BAD overlay console arg missing from cmdline" >&2; return 1; }
tar -C "${T}" -czf "${OUT}/netboot-${TALOS_VERSION}-${FLAVOR}.tar.gz" .
rm -rf "${W}"
echo ">> done: ${OUT}/netboot-${TALOS_VERSION}-${FLAVOR}.tar.gz"
}

rc=0
for b in "$@"; do build_one "$b" || rc=1; done
if [ "${NETBOOT}" = 1 ]; then build_netboot "$1" || rc=1; fi
exit "${rc}"
