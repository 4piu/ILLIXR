#!/usr/bin/env bash
# Shared configuration for the ILLIXR systemd-nspawn build scripts.
# Sourced by setup_build_env.sh, build.sh, teardown_build_env.sh.

set -euo pipefail

MACHINE_NAME="illixr-build"
ROOTFS="/var/lib/machines/${MACHINE_NAME}"
NSPAWN_UNIT="/etc/systemd/nspawn/${MACHINE_NAME}.nspawn"
# Per-instance drop-in for the templated systemd-nspawn@.service unit. Used to
# grant the container's cgroup access to host USB devices (e.g. a RealSense
# camera) -- Bind= in the .nspawn file alone only makes the device node
# visible in the container's mount namespace, it doesn't grant the cgroup
# device-controller permission needed to actually open() it.
NSPAWN_SERVICE_DROPIN_DIR="/etc/systemd/system/systemd-nspawn@${MACHINE_NAME}.service.d"
CONTAINER_USER="illixr"
CONTAINER_HOME="/home/${CONTAINER_USER}"
RELEASE="jammy"   # Ubuntu 22.04, matches the most common ILLIXR target

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINER_SRC="${CONTAINER_HOME}/ILLIXR"
STATE_DIR="${REPO_ROOT}/build"
STATE_FILE="${STATE_DIR}/.nspawn-config"

# Host arch as Debian/Ubuntu port architecture name.
host_arch() {
    case "$(uname -m)" in
        aarch64) echo "arm64" ;;
        x86_64)  echo "amd64" ;;
        *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
    esac
}

# Mirror to debootstrap/apt from, keyed by arch (ports.ubuntu.com hosts arm64/armhf/ppc64el/s390x,
# archive.ubuntu.com only hosts amd64/i386).
apt_mirror() {
    if [ "$(host_arch)" = "amd64" ]; then
        echo "http://archive.ubuntu.com/ubuntu"
    else
        echo "http://ports.ubuntu.com/ubuntu-ports"
    fi
}

# Packages required for ANY ILLIXR build, regardless of which plugins are selected.
# Derived from CMakeLists.txt's global find_package() calls plus utils/CMakeLists.txt,
# which is built unconditionally (glfw3/OpenGL/gstreamer/glib) and from a clean
# configure+build done against this list on 2026-06-30.
CORE_PACKAGES=(
    build-essential clang cmake git pkg-config
    libboost-all-dev libeigen3-dev
    libglew-dev libgl-dev libglu1-mesa-dev
    libsqlite3-dev libx11-dev libspdlog-dev libopencv-dev
    python3-dev
    libglfw3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
    libvulkan-dev vulkan-tools vulkan-validationlayers glslang-tools spirv-tools
    libglm-dev libusb-1.0-0-dev libudev-dev libssl-dev libtool
    ca-certificates curl wget less sudo vim-tiny
    # libdw1 (pulled in transitively) is NEEDED by some plugin .so files at
    # runtime (e.g. offline_cam) but doesn't declare libdebuginfod1 as a hard
    # apt dependency -- without it, dlopen() fails at runtime with
    # "libdebuginfod.so.1: cannot open shared object file", not at build time.
    libdebuginfod1
)

# Extra apt packages per plugin, keyed by the plugin's base name (the part before
# any '.', e.g. "offload_vio.device_rx" -> "offload_vio"). Only plugins that need
# something beyond CORE_PACKAGES are listed; anything absent here is assumed to
# build against CORE_PACKAGES alone (true for gtsam_integrator, openvins, orb_slam3,
# native_renderer, vkdemo, timewarp_vk, pose_prediction, tcp_network_backend,
# ground_truth_slam, offline_cam, offline_imu, debugview, gldemo, etc. -- their
# remaining dependencies are fetched and built from source by the cmake Get*.cmake
# modules).
declare -A PLUGIN_PACKAGES=(
    [realsense]="librealsense2-dev librealsense2-gl-dev librealsense2-utils usbutils"
    [openni]="libopenni2-dev"
    [audio_pipeline]="libprotobuf-dev protobuf-compiler libprotoc-dev portaudio19-dev libspatialaudio-dev"
    [offload_vio]="libprotobuf-dev protobuf-compiler libprotoc-dev"
    [ada]="libprotobuf-dev protobuf-compiler libprotoc-dev portaudio19-dev libspatialaudio-dev"
    [timewarp_gl]="libjpeg-dev libpng-dev libtiff-dev libgflags-dev libwayland-dev wayland-protocols libx11-xcb-dev libxcb-glx0-dev libxcb-randr0-dev libxkbcommon-dev libxrandr-dev"
)

# Plugins that need hardware/SDKs this script does not provision (proprietary SDK
# install, CUDA toolchain). Selecting these only installs what's listed (if any)
# and prints a warning -- see docs/external_dependencies.rst for the rest.
UNSUPPORTED_PLUGINS=(zed offload_rendering_server offload_rendering_client hand_tracking_gpu)

# Plugins that talk to a physical USB device and need /dev/bus/usb passed
# through into the container (see the USB passthrough section of
# setup_build_env.sh). Only "realsense" has actually been exercised against
# real hardware; add others here once verified.
USB_PASSTHROUGH_PLUGINS=(realsense)

# librealsense isn't in Ubuntu's repos; Intel publishes their own apt repo.
# NOTE: as of 2026-06-30 the key published at https://librealsense.intel.com/Debian/librealsense.pgp
# does NOT match the key actually used to sign the repo (InRelease asks for key
# FB0B24895113F120); pull the real key from the Ubuntu keyserver instead.
REALSENSE_REPO_KEYID="FB0B24895113F120"
REALSENSE_REPO_URL="https://librealsense.intel.com/Debian/apt-repo"

require_root_tools() {
    if ! command -v sudo >/dev/null 2>&1; then
        echo "This script requires sudo." >&2
        exit 1
    fi
}

# uid/gid of the real (non-root) invoking user, so files bind-mounted from the
# host repo stay writable from both sides of the container boundary.
host_uid() { echo "${SUDO_UID:-$(id -u)}"; }
host_gid() { echo "${SUDO_GID:-$(id -g)}"; }

machine_running() {
    sudo machinectl status "${MACHINE_NAME}" >/dev/null 2>&1
}

# (Re)writes the .nspawn unit, the systemd-nspawn@.service cgroup drop-in,
# and the in-container boot-time permissions-fixup unit, based on which USB
# device nodes currently match USB_PASSTHROUGH_PLUGINS' vendor. Takes the
# space-separated plugin list as $1.
#
# This is NOT just a one-time setup step: systemd-nspawn's Bind= has no
# "skip if source is missing" syntax, so a .nspawn file with a stale
# Bind=/dev/hidraw3 entry (e.g. left over from before a host reboot, when
# the camera re-enumerates under a different node) makes the container fail
# to start at all ("Failed to stat /dev/hidraw3: No such file or
# directory"), not just lose USB passthrough. To stay self-healing, this is
# called from ensure_machine_running() itself, every time the container is
# about to be (re)started from stopped -- not only from setup_build_env.sh.
#
# Sets the global NEED_USB_PASSTHROUGH and CONTAINER_CONFIG_CHANGED (0/1) as
# side effects.
sync_container_config() {
    local plugins="$1"
    NEED_USB_PASSTHROUGH=0
    local plugin base u
    for plugin in $plugins; do
        base="${plugin%%.*}"
        for u in "${USB_PASSTHROUGH_PLUGINS[@]}"; do
            [ "$base" = "$u" ] && NEED_USB_PASSTHROUGH=1
        done
    done

    sudo mkdir -p "$(dirname "${NSPAWN_UNIT}")"
    local usb_bind_lines="" dev vendor devpath
    MATCHED_NODES=()
    if [ "$NEED_USB_PASSTHROUGH" = "1" ]; then
        usb_bind_lines="Bind=/dev/bus/usb:/dev/bus/usb"
        for dev in /dev/video*; do
            [ -c "$dev" ] || continue
            vendor="$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')"
            if [ "$vendor" = "8086" ]; then
                MATCHED_NODES+=("$dev")
                usb_bind_lines="${usb_bind_lines}
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
                usb_bind_lines="${usb_bind_lines}
Bind=${dev}:${dev}"
            fi
        done
        if [ "${#MATCHED_NODES[@]}" -eq 0 ]; then
            echo "WARNING: realsense selected but no /dev/video* or /dev/hidraw* node with USB vendor 8086 (Intel) found -- is the camera plugged in?" >&2
        fi
    fi

    local nspawn_unit_tmp nspawn_unit_changed=0
    nspawn_unit_tmp="$(mktemp)"
    cat > "${nspawn_unit_tmp}" <<EOF
[Exec]
Boot=on
PrivateUsers=no

[Network]
VirtualEthernet=no

[Files]
Bind=${REPO_ROOT}:${CONTAINER_SRC}
${usb_bind_lines}
EOF
    sudo cmp -s "${nspawn_unit_tmp}" "${NSPAWN_UNIT}" 2>/dev/null || nspawn_unit_changed=1
    sudo cp "${nspawn_unit_tmp}" "${NSPAWN_UNIT}"
    rm -f "${nspawn_unit_tmp}"

    # cgroup half: Bind= only makes the node visible in the container's mount
    # namespace, DevicePolicy=closed still denies open() on it without this.
    # "char-usb_device"/"char-video4linux"/"char-hidraw" are systemd's
    # symbolic names for majors 189/81/236 (see /proc/devices).
    local dropin_changed=0
    if [ "$NEED_USB_PASSTHROUGH" = "1" ]; then
        sudo mkdir -p "${NSPAWN_SERVICE_DROPIN_DIR}"
        local dropin_tmp
        dropin_tmp="$(mktemp)"
        cat > "${dropin_tmp}" <<EOF
[Service]
DeviceAllow=char-usb_device rwm
DeviceAllow=char-video4linux rwm
DeviceAllow=char-hidraw rwm
EOF
        sudo cmp -s "${dropin_tmp}" "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf" 2>/dev/null || dropin_changed=1
        sudo cp "${dropin_tmp}" "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf"
        rm -f "${dropin_tmp}"
        sudo systemctl daemon-reload
    elif [ -f "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf" ]; then
        sudo rm -f "${NSPAWN_SERVICE_DROPIN_DIR}/usb.conf"
        sudo rmdir --ignore-fail-on-non-empty "${NSPAWN_SERVICE_DROPIN_DIR}" 2>/dev/null || true
        dropin_changed=1
        sudo systemctl daemon-reload
    fi

    # permissions half: unlike the /dev/bus/usb *directory* bind (a real bind
    # mount that keeps the host's permissions), systemd-nspawn recreates
    # individual device-file binds via mknod(same major:minor) without the
    # source's mode/owner -- they come up 0600 root:root every boot
    # regardless of the host's (usually 0666 plugdev) permissions. Fix it
    # with a oneshot unit, since the container has no real udev to redo this.
    local perms_unit_tmp perms_script_tmp perms_changed=0
    perms_unit_tmp="$(mktemp)"
    perms_script_tmp="$(mktemp)"
    if [ "$NEED_USB_PASSTHROUGH" = "1" ] && [ "${#MATCHED_NODES[@]}" -gt 0 ]; then
        {
            echo "#!/bin/sh"
            for dev in "${MATCHED_NODES[@]}"; do
                echo "[ -e '${dev}' ] && chmod 0666 '${dev}'"
            done
        } > "${perms_script_tmp}"
        cat > "${perms_unit_tmp}" <<'EOF'
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
    sudo cmp -s "${perms_script_tmp}" "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh" 2>/dev/null || perms_changed=1
    if [ -s "${perms_script_tmp}" ]; then
        sudo install -m 755 "${perms_script_tmp}" "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh"
        sudo install -m 644 "${perms_unit_tmp}" "${ROOTFS}/etc/systemd/system/illixr-usb-perms.service"
        sudo mkdir -p "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
        sudo ln -sf /etc/systemd/system/illixr-usb-perms.service \
            "${ROOTFS}/etc/systemd/system/sysinit.target.wants/illixr-usb-perms.service"
    elif [ -f "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh" ]; then
        sudo rm -f "${ROOTFS}/usr/local/sbin/illixr-fix-usb-perms.sh" \
            "${ROOTFS}/etc/systemd/system/illixr-usb-perms.service" \
            "${ROOTFS}/etc/systemd/system/sysinit.target.wants/illixr-usb-perms.service"
        perms_changed=1
    fi
    rm -f "${perms_unit_tmp}" "${perms_script_tmp}"

    CONTAINER_CONFIG_CHANGED=0
    if [ "$nspawn_unit_changed" = "1" ] || [ "$dropin_changed" = "1" ] || [ "$perms_changed" = "1" ]; then
        CONTAINER_CONFIG_CHANGED=1
    fi
}

# Plugin list saved by setup_build_env.sh, or empty if none yet.
saved_plugins() {
    [ -f "${STATE_FILE}" ] || return 0
    sed -n 's/^PLUGINS="\(.*\)"$/\1/p' "${STATE_FILE}"
}

ensure_machine_running() {
    if ! machine_running; then
        # Regenerate USB passthrough config from currently-connected hardware
        # before every start -- see sync_container_config's comment for why
        # this can't just be done once in setup_build_env.sh.
        if [ -f "${NSPAWN_UNIT}" ]; then
            sync_container_config "$(saved_plugins)"
        fi
        echo "Starting ${MACHINE_NAME}..."
        sudo machinectl start "${MACHINE_NAME}"
        for _ in $(seq 1 30); do
            machine_running && break
            sleep 1
        done
    fi
    # machine_running (machinectl status) goes true before the container's
    # own systemd has finished booting far enough for commands to work --
    # without this, the very next container_exec can fail with "Failed to
    # get shell PTY: Protocol error" (machinectl) / "Connection reset by
    # peer" (systemd-run).
    for _ in $(seq 1 30); do
        sudo systemd-run --quiet --pipe --wait --machine="${MACHINE_NAME}" /bin/true >/dev/null 2>&1 && return
        sleep 1
    done
    echo "WARNING: ${MACHINE_NAME} did not become shell-ready in time." >&2
}

# `machinectl shell` -- despite the name suggesting otherwise -- does NOT
# propagate the invoked process's exit code (this is explicitly documented in
# `man machinectl`: "machinectl shell does not propagate the exit
# code/status of the invoked shell process"). Every `if container_exec ...`
# / `! container_exec ...` check in these scripts depends on a real exit
# code, so these use `systemd-run --pipe --wait` instead, which does
# propagate it (verified: `exit 1`, `test -f <missing>`, etc. all come back
# correctly, unlike machinectl shell which always returns 0 regardless of
# what happened inside).
container_exec() {
    sudo systemd-run --quiet --pipe --wait --machine="${MACHINE_NAME}" /bin/bash -c "$1"
}

container_exec_as_user() {
    sudo systemd-run --quiet --pipe --wait --machine="${MACHINE_NAME}" /bin/su - "${CONTAINER_USER}" -c "$1"
}
