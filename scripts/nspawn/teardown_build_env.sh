#!/usr/bin/env bash
# Remove the illixr-build nspawn container created by setup_build_env.sh.
#
# This only touches container-internal state (the rootfs under /var/lib/machines
# and the .nspawn unit). It never deletes anything inside the bind-mounted repo
# (ILLIXR/build, ILLIXR/profiles/*.nspawn-config, etc.) -- that's host content.
#
# Usage:
#   teardown_build_env.sh            prompts for confirmation
#   teardown_build_env.sh -y         skip confirmation
#   teardown_build_env.sh -y --purge-host-tools   also apt-get remove systemd-container/debootstrap from the host

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
cd "$(dirname "${SCRIPT_PATH}")"
# shellcheck source=common.sh
source ./common.sh

ASSUME_YES=0
PURGE_HOST_TOOLS=0
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        --purge-host-tools) PURGE_HOST_TOOLS=1; shift ;;
        -h|--help) sed -n '2,9p' "$SCRIPT_PATH"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

require_root_tools

if [ "$ASSUME_YES" != "1" ]; then
    echo "This will delete:"
    echo "  - ${NSPAWN_UNIT}"
    echo "  - ${ROOTFS} (the entire container rootfs, root-owned)"
    [ "$PURGE_HOST_TOOLS" = "1" ] && echo "  - the systemd-container and debootstrap host packages"
    read -rp "Continue? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

if machine_running; then
    echo "Stopping ${MACHINE_NAME}..."
    sudo machinectl stop "${MACHINE_NAME}"
    for _ in $(seq 1 30); do
        machine_running || break
        sleep 1
    done
fi

[ -f "${NSPAWN_UNIT}" ] && sudo rm -f "${NSPAWN_UNIT}"
[ -d "${ROOTFS}" ] && sudo rm -rf "${ROOTFS}"
[ -f "${STATE_FILE}" ] && rm -f "${STATE_FILE}"

if [ "$PURGE_HOST_TOOLS" = "1" ]; then
    sudo apt-get remove -y systemd-container debootstrap
fi

echo "Removed ${MACHINE_NAME}. The repo and ILLIXR/build/ on the host were left untouched."
