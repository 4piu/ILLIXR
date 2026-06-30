#!/usr/bin/env bash
# Provision a systemd-nspawn container for building ILLIXR.
#
# Usage:
#   setup_build_env.sh                         interactive plugin picker
#   setup_build_env.sh --profile ci.yaml        use a profiles/*.yaml plugin list
#   setup_build_env.sh --plugins "native_renderer,timewarp_vk,vkdemo,pose_lookup"
#   setup_build_env.sh ... --prefix /home/illixr/.local
#
# Re-running is safe: it skips debootstrap if the rootfs already exists and
# only (re)installs packages / rewrites config.

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
cd "$(dirname "${SCRIPT_PATH}")"
# shellcheck source=common.sh
source ./common.sh

PROFILE=""
PLUGIN_ARG=""
INSTALL_PREFIX="${CONTAINER_HOME}/.local"
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --plugins) PLUGIN_ARG="$2"; shift 2 ;;
        --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,12p' "$SCRIPT_PATH"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

require_root_tools

# ---------------------------------------------------------------------------
# 1. Pick plugins, if not already given on the command line.
# ---------------------------------------------------------------------------
if [ -z "$PROFILE" ] && [ -z "$PLUGIN_ARG" ]; then
    echo "Select a plugin profile to build:"
    mapfile -t PROFILES < <(ls "${REPO_ROOT}/profiles"/*.yaml | xargs -n1 basename)
    i=1
    for p in "${PROFILES[@]}"; do
        printf "  %2d) %s\n" "$i" "$p"
        i=$((i + 1))
    done
    printf "  %2d) manual plugin list\n" "$i"
    read -rp "Choice [1-$i]: " choice
    if [ "$choice" -eq "$i" ] 2>/dev/null; then
        read -rp "Comma-separated plugin names (e.g. native_renderer,timewarp_vk,vkdemo): " PLUGIN_ARG
    else
        PROFILE="${PROFILES[$((choice - 1))]}"
    fi
fi

PLUGINS=()
if [ -n "$PROFILE" ]; then
    PROFILE_PATH="$PROFILE"
    [ -f "$PROFILE_PATH" ] || PROFILE_PATH="${REPO_ROOT}/profiles/${PROFILE}"
    [ -f "$PROFILE_PATH" ] || { echo "Profile not found: $PROFILE" >&2; exit 1; }
    line="$(grep -m1 '^plugins:' "$PROFILE_PATH")"
    IFS=',' read -ra PLUGINS <<< "${line#plugins:}"
    # trim whitespace
    for idx in "${!PLUGINS[@]}"; do PLUGINS[$idx]="$(echo "${PLUGINS[$idx]}" | xargs)"; done
    echo "Using profile ${PROFILE_PATH} (-DYAML_FILE) with plugins: ${PLUGINS[*]}"
else
    IFS=',' read -ra PLUGINS <<< "$PLUGIN_ARG"
    for idx in "${!PLUGINS[@]}"; do PLUGINS[$idx]="$(echo "${PLUGINS[$idx]}" | xargs)"; done
    PROFILE=""
    echo "Using manual plugin list: ${PLUGINS[*]}"
fi

# ---------------------------------------------------------------------------
# 2. Resolve the apt package set for the chosen plugins.
# ---------------------------------------------------------------------------
PKG_SET=()
for pkg in "${CORE_PACKAGES[@]}"; do PKG_SET+=("$pkg"); done
NEED_REALSENSE_REPO=0
NEED_USB_PASSTHROUGH=0
for plugin in "${PLUGINS[@]}"; do
    base="${plugin%%.*}"
    for u in "${UNSUPPORTED_PLUGINS[@]}"; do
        if [ "$base" = "$u" ]; then
            echo "WARNING: '$plugin' needs a vendor SDK / CUDA toolchain this script does not provision (see docs/external_dependencies.rst). Continuing without it." >&2
        fi
    done
    if [ "$base" = "realsense" ]; then NEED_REALSENSE_REPO=1; fi
    for u in "${USB_PASSTHROUGH_PLUGINS[@]}"; do
        if [ "$base" = "$u" ]; then NEED_USB_PASSTHROUGH=1; fi
    done
    extra="${PLUGIN_PACKAGES[$base]:-}"
    if [ -n "$extra" ]; then
        # shellcheck disable=SC2206
        PKG_SET+=($extra)
    fi
done
# de-duplicate
mapfile -t PKG_SET < <(printf '%s\n' "${PKG_SET[@]}" | sort -u)

# ---------------------------------------------------------------------------
# 3. Host packages: systemd-container + debootstrap.
# ---------------------------------------------------------------------------
if ! command -v systemd-nspawn >/dev/null 2>&1 || ! command -v debootstrap >/dev/null 2>&1; then
    echo "Installing systemd-container and debootstrap on the host..."
    sudo apt-get update -qq
    sudo apt-get install -y systemd-container debootstrap
fi

# ---------------------------------------------------------------------------
# 4. Bootstrap the rootfs (skip if it already exists).
# ---------------------------------------------------------------------------
ARCH="$(host_arch)"
# /var/lib/machines is root-only (0700), so an unprivileged -d test always
# reports "missing" here even when the rootfs exists -- check via sudo.
if ! sudo test -d "${ROOTFS}/usr"; then
    echo "Bootstrapping Ubuntu ${RELEASE} (${ARCH}) into ${ROOTFS}..."
    sudo mkdir -p /var/lib/machines
    sudo debootstrap --arch="${ARCH}" "${RELEASE}" "${ROOTFS}" "$(apt_mirror)"
else
    echo "Rootfs already exists at ${ROOTFS}, skipping debootstrap."
fi

# apt sources + hostname + resolv.conf
MIRROR="$(apt_mirror)"
sudo tee "${ROOTFS}/etc/apt/sources.list" >/dev/null <<EOF
deb ${MIRROR} ${RELEASE} main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-updates main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-security main restricted universe multiverse
deb ${MIRROR} ${RELEASE}-backports main restricted universe multiverse
EOF
echo "${MACHINE_NAME}" | sudo tee "${ROOTFS}/etc/hostname" >/dev/null
sudo ln -sf /usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime"
sudo rm -f "${ROOTFS}/etc/resolv.conf"
sudo cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

# ---------------------------------------------------------------------------
# 5. .nspawn unit: boot with systemd, share host networking, bind-mount the
#    repo (and /dev/bus/usb plus any matching /dev/videoN nodes, if a
#    USB-dependent plugin like realsense was selected -- see the USB
#    passthrough step below for the cgroup half of this).
#
#    RealSense (and most UVC cameras) stream image data over V4L2
#    (/dev/videoN) and IMU (gyro/accel) data over a separate USB HID
#    interface (/dev/hidrawN) -- raw /dev/bus/usb access alone is only
#    enough for librealsense's control channel (firmware/hardware-monitor
#    commands). Without /dev/videoN, rs-enumerate-devices reports "No
#    device detected"; without /dev/hidrawN, the camera enumerates fine but
#    ILLIXR's realsense plugin still aborts with "Supported Realsense
#    device NOT found!" because plugins/realsense/plugin.cpp requires BOTH
#    a gyro and an accel stream to recognize a D4xx camera, and those only
#    show up via the HID interface. Unlike /dev/bus/usb, there's no stable
#    parent directory to bind once for either of these, so matching nodes
#    are discovered by USB vendor ID here and bound individually. NOTE:
#    device numbers can change across replugs -- rerun this script after
#    reconnecting the camera to refresh the bound set.
# ---------------------------------------------------------------------------
sudo mkdir -p "$(dirname "${NSPAWN_UNIT}")"
USB_BIND_LINES=""
MATCHED_NODES=()
if [ "$NEED_USB_PASSTHROUGH" = "1" ]; then
    USB_BIND_LINES="Bind=/dev/bus/usb:/dev/bus/usb"
    for dev in /dev/video*; do
        [ -c "$dev" ] || continue
        vendor="$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')"
        if [ "$vendor" = "8086" ]; then
            MATCHED_NODES+=("$dev")
            USB_BIND_LINES="${USB_BIND_LINES}
Bind=${dev}:${dev}"
        fi
    done
    # hidraw nodes don't get an ID_VENDOR_ID property from udev's default
    # rules (unlike video4linux), but DEVPATH embeds the USB
    # "<bus_type>:<vendor>:<product>.<n>" id, e.g. ".../6-1:1.5/0003:8086:0B5C.0037/...".
    for dev in /dev/hidraw*; do
        [ -c "$dev" ] || continue
        devpath="$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^DEVPATH=//p')"
        if echo "$devpath" | grep -qi ':8086:'; then
            MATCHED_NODES+=("$dev")
            USB_BIND_LINES="${USB_BIND_LINES}
Bind=${dev}:${dev}"
        fi
    done
    if [ "${#MATCHED_NODES[@]}" -eq 0 ]; then
        echo "WARNING: realsense selected but no /dev/video* or /dev/hidraw* node with USB vendor 8086 (Intel) found -- is the camera plugged in? Rerun this script once it is." >&2
    fi
fi

NSPAWN_UNIT_TMP="$(mktemp)"
cat > "${NSPAWN_UNIT_TMP}" <<EOF
[Exec]
Boot=on
PrivateUsers=no

[Network]
VirtualEthernet=no

[Files]
Bind=${REPO_ROOT}:${CONTAINER_SRC}
${USB_BIND_LINES}
EOF

NSPAWN_UNIT_CHANGED=0
if ! sudo cmp -s "${NSPAWN_UNIT_TMP}" "${NSPAWN_UNIT}" 2>/dev/null; then
    NSPAWN_UNIT_CHANGED=1
fi
sudo cp "${NSPAWN_UNIT_TMP}" "${NSPAWN_UNIT}"
rm -f "${NSPAWN_UNIT_TMP}"

# ---------------------------------------------------------------------------
# 5b. USB passthrough, cgroup half: Bind= above only makes /dev/bus/usb
#     visible inside the container's mount namespace -- opening a device node
#     under it still needs the container's cgroup device-controller policy to
#     allow it (DevicePolicy=closed denies everything not explicitly listed).
#     "char-usb_device" is systemd's symbolic name for major 189 (`grep usb
#     /proc/devices`), i.e. every node under /dev/bus/usb.
# ---------------------------------------------------------------------------
SERVICE_DROPIN_CHANGED=0
if [ "$NEED_USB_PASSTHROUGH" = "1" ]; then
    sudo mkdir -p "${NSPAWN_SERVICE_DROPIN_DIR}"
    DROPIN_TMP="$(mktemp)"
    cat > "${DROPIN_TMP}" <<EOF
[Service]
DeviceAllow=char-usb_device rwm
DeviceAllow=char-video4linux rwm
DeviceAllow=char-hidraw rwm
EOF
    if ! sudo cmp -s "${DROPIN_TMP}" "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf" 2>/dev/null; then
        SERVICE_DROPIN_CHANGED=1
    fi
    sudo cp "${DROPIN_TMP}" "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf"
    rm -f "${DROPIN_TMP}"
    sudo systemctl daemon-reload
elif [ -f "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf" ]; then
    # Plugin selection changed and no longer needs USB -- drop the grant.
    sudo rm -f "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf"
    sudo rmdir --ignore-fail-on-non-empty "${NSPAWN_SERVICE_DROPIN_DIR}" 2>/dev/null || true
    SERVICE_DROPIN_CHANGED=1
    sudo systemctl daemon-reload
fi

# ---------------------------------------------------------------------------
# 5c. USB passthrough, permissions half: for individual device-file Bind=
#     entries (as opposed to the /dev/bus/usb *directory* bind, which is a
#     real bind mount and keeps the host's permissions), systemd-nspawn
#     recreates the node inside the container via mknod(same major:minor)
#     rather than propagating the source's mode/owner -- every /dev/videoN
#     and /dev/hidrawN bound above comes up 0600 root:root on boot
#     regardless of the host's (usually 0666 plugdev) permissions. The
#     cgroup DeviceAllow= grant above is necessary but not sufficient: it
#     only lifts the cgroup device-controller check, the normal Unix
#     permission bits are checked too and default-deny non-root. Fix it with
#     a oneshot unit that chmods the exact paths we bound, since the
#     container has no real udev to redo this for us.
# ---------------------------------------------------------------------------
PERMS_UNIT_TMP="$(mktemp)"
PERMS_SCRIPT_TMP="$(mktemp)"
if [ "$NEED_USB_PASSTHROUGH" = "1" ] && [ "${#MATCHED_NODES[@]}" -gt 0 ]; then
    {
        echo "#!/bin/sh"
        for node in "${MATCHED_NODES[@]}"; do
            echo "[ -e '${node}' ] && chmod 0666 '${node}'"
        done
    } > "${PERMS_SCRIPT_TMP}"
    cat > "${PERMS_UNIT_TMP}" <<'EOF'
[Unit]
Description=Fix permissions on bind-mounted RealSense device nodes
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/illixr-fix-usb-perms.sh

[Install]
WantedBy=sysinit.target
EOF
fi

PERMS_CHANGED=0
if ! sudo cmp -s "${PERMS_SCRIPT_TMP}" "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh" 2>/dev/null; then
    PERMS_CHANGED=1
fi
if [ -s "${PERMS_SCRIPT_TMP}" ]; then
    sudo install -m 755 "${PERMS_SCRIPT_TMP}" "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh"
    sudo install -m 644 "${PERMS_UNIT_TMP}" "${ROOTFS}/etc/systemd/system/illixr-usb-perms.service"
    sudo mkdir -p "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
    sudo ln -sf /etc/systemd/system/illixr-usb-perms.service \
        "${ROOTFS}/etc/systemd/system/sysinit.target.wants/illixr-usb-perms.service"
elif [ -f "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh" ]; then
    # No USB-dependent plugin selected (or no matching devices) anymore -- clean up.
    sudo rm -f "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh" \
        "${ROOTFS}/etc/systemd/system/illixr-usb-perms.service" \
        "${ROOTFS}/etc/systemd/system/sysinit.target.wants/illixr-usb-perms.service"
    PERMS_CHANGED=1
fi
rm -f "${PERMS_UNIT_TMP}" "${PERMS_SCRIPT_TMP}"

# Bind=, DeviceAllow=, and the perms-fixup unit are only applied when the
# container (re)starts.
if { [ "$NSPAWN_UNIT_CHANGED" = "1" ] || [ "$SERVICE_DROPIN_CHANGED" = "1" ] || [ "$PERMS_CHANGED" = "1" ]; } && machine_running; then
    echo "USB passthrough config changed; restarting ${MACHINE_NAME} to apply it..."
    sudo machinectl stop "${MACHINE_NAME}"
    for _ in $(seq 1 30); do machine_running || break; sleep 1; done
fi

# ---------------------------------------------------------------------------
# 6. Start the machine. Using `machinectl start` (rather than a one-off
#    `systemd-nspawn -D`) matters even on a first run: spawning a second,
#    independent systemd-nspawn instance against a rootfs already managed by
#    machinectl fails with "Directory tree ... is currently busy".
# ---------------------------------------------------------------------------
ensure_machine_running

# ---------------------------------------------------------------------------
# 7. Container build user, uid/gid-matched to the host so the bind-mounted
#    repo stays writable from both sides. A no-op if it already matches --
#    note this would fail if processes are currently running as that uid
#    inside the container (e.g. a build in progress).
# ---------------------------------------------------------------------------
UID_H="$(host_uid)"
GID_H="$(host_gid)"
container_exec "
if ! id ${CONTAINER_USER} >/dev/null 2>&1; then
    useradd -m -s /bin/bash ${CONTAINER_USER}
    echo '${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${CONTAINER_USER}-user
    chmod 440 /etc/sudoers.d/${CONTAINER_USER}-user
fi
current_uid=\$(id -u ${CONTAINER_USER})
if [ \"\$current_uid\" != \"${UID_H}\" ]; then
    groupmod -g ${GID_H} ${CONTAINER_USER}
    usermod -u ${UID_H} ${CONTAINER_USER}
    find / -xdev -group \$current_uid -exec chgrp -h ${GID_H} {} + 2>/dev/null || true
    find / -xdev -user \$current_uid -exec chown -h ${UID_H} {} + 2>/dev/null || true
fi
"

# ---------------------------------------------------------------------------
# 8. Install packages.
# ---------------------------------------------------------------------------

if [ "$NEED_REALSENSE_REPO" = "1" ]; then
    echo "Adding Intel librealsense apt repo..."
    # Fetch the key on the host and copy it in, rather than piping curl into gpg
    # *inside* the container: that pipeline reliably hung waiting on gpg-agent
    # (no pinentry/tty in a `machinectl shell` session) during testing.
    KEY_TMP="$(mktemp)"
    curl -sSf "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${REALSENSE_REPO_KEYID}" | gpg --dearmor > "${KEY_TMP}"
    sudo mkdir -p "${ROOTFS}/etc/apt/keyrings"
    sudo cp "${KEY_TMP}" "${ROOTFS}/etc/apt/keyrings/librealsense.gpg"
    rm -f "${KEY_TMP}"
    container_exec "echo 'deb [signed-by=/etc/apt/keyrings/librealsense.gpg] ${REALSENSE_REPO_URL} ${RELEASE} main' > /etc/apt/sources.list.d/librealsense.list"
fi

echo "apt-get update..."
container_exec "apt-get update -qq"

echo "Installing packages: ${PKG_SET[*]}"
container_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y ${PKG_SET[*]}"

if [ "$NEED_USB_PASSTHROUGH" = "1" ]; then
    echo "Checking USB passthrough..."
    if container_exec "rs-enumerate-devices -s 2>&1 | grep -qv 'No device detected'"; then
        echo "RealSense device visible inside the container:"
        container_exec "rs-enumerate-devices -s" || true
    elif container_exec "lsusb 2>/dev/null | grep -qi '8086:0b5c\|realsense'"; then
        echo "WARNING: USB device visible via lsusb but rs-enumerate-devices still reports none -- /dev/videoN binding may be stale (camera replugged after the container last started?)." >&2
        echo "  Rerun this script to refresh the bound video nodes, then restart: machinectl stop ${MACHINE_NAME}" >&2
    else
        echo "WARNING: no RealSense device detected inside the container yet." >&2
        echo "  - Confirm it's plugged in on the host: lsusb | grep -i realsense" >&2
        echo "  - If it was plugged in after the container started, rerun this script to pick up the /dev/videoN nodes, then restart: machinectl stop ${MACHINE_NAME}" >&2
    fi
fi

# ---------------------------------------------------------------------------
# 9. Persist the plugin selection for build.sh.
# ---------------------------------------------------------------------------
mkdir -p "${STATE_DIR}"
{
    echo "PROFILE=\"${PROFILE}\""
    echo "PLUGINS=\"${PLUGINS[*]}\""
    echo "INSTALL_PREFIX=\"${INSTALL_PREFIX}\""
} > "${STATE_FILE}"

echo
echo "Build environment ready. Source is bind-mounted at ${CONTAINER_SRC} inside ${MACHINE_NAME}."
echo "Next: ./scripts/nspawn/build.sh"
