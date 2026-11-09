#!/usr/bin/env bash
# etcd snapshot from the Talos control plane into BACKUP_DIR, keeping BACKUP_KEEP copies.
# Config: /etc/sbc-quartz/mgmt.env. Run by etcd-snapshot.timer (every 6 h).
set -euo pipefail
. /etc/sbc-quartz/mgmt.env
mkdir -p "${BACKUP_DIR}"
out="${BACKUP_DIR}/etcd-$(date +%F-%H%M).db"
talosctl --talosconfig "${TALOSCONFIG}" -n "${CONTROL_PLANE}" etcd snapshot "${out}.part"
mv "${out}.part" "${out}"
ls -1t "${BACKUP_DIR}"/etcd-*.db | tail -n +"$(( ${BACKUP_KEEP:-28} + 1 ))" | xargs -r rm --
echo "saved ${out}"
