#!/usr/bin/env bash
# Set up a management node (Debian 13 / Raspberry Pi OS / DietPi, arm64). Idempotent.
#
#   sudo mgmt/install.sh            # from a checkout of this repo
#
# Installs: Docker + compose, talosctl, registry caches, install-image-guard timer,
# etcd-snapshot timer, sbc-flash. holzkube-manager is installed separately (its own
# release + systemd unit). Joining the cluster as a worker is separate too: join-cluster.sh.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
etc=/etc/sbc-quartz
mkdir -p "${etc}"

if [ ! -f "${etc}/mgmt.env" ]; then
  install -m 0644 "${here}/mgmt.env.example" "${etc}/mgmt.env"
  echo ">> wrote ${etc}/mgmt.env with defaults; edit DATA_DIR/BACKUP_DIR for this board and re-run"
fi
[ -f "${etc}/nodes.yaml" ] || install -m 0644 "${here}/nodes.yaml.example" "${etc}/nodes.yaml"
. "${etc}/mgmt.env"
mkdir -p "${DATA_DIR}/registry/ghcr" "${DATA_DIR}/registry/docker" "${BACKUP_DIR}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends docker.io docker-compose python3-yaml curl xz-utils ca-certificates
systemctl enable --now docker

if ! command -v talosctl >/dev/null; then
  curl -fsSL https://talos.dev/install | sh
fi

docker compose --env-file "${etc}/mgmt.env" -f "${here}/compose.yaml" up -d

install -m 0755 "${here}/install-image-guard.py" /usr/local/bin/install-image-guard.py
install -m 0755 "${here}/etcd-snapshot.sh" /usr/local/bin/etcd-snapshot.sh
install -m 0755 "${here}/sbc-flash" /usr/local/bin/sbc-flash
install -m 0644 "${here}"/install-image-guard.{service,timer} "${here}"/etcd-snapshot.{service,timer} /etc/systemd/system/
systemctl daemon-reload

if [ -f "${TALOSCONFIG}" ]; then
  systemctl enable --now install-image-guard.timer etcd-snapshot.timer
  echo ">> timers enabled"
else
  echo ">> ${TALOSCONFIG} missing: timers installed but not enabled."
  echo "   After the control plane is up:  holzkubectl talosconfig <cluster> > ${TALOSCONFIG}"
  echo "   then re-run this script."
fi
docker compose --env-file "${etc}/mgmt.env" -f "${here}/compose.yaml" ps
