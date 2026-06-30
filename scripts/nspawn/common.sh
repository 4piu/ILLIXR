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

ensure_machine_running() {
    if ! machine_running; then
        echo "Starting ${MACHINE_NAME}..."
        sudo machinectl start "${MACHINE_NAME}"
        for _ in $(seq 1 30); do
            machine_running && break
            sleep 1
        done
    fi
    # machine_running (machinectl status) goes true before the container's
    # own systemd has finished booting far enough for `machinectl shell` to
    # work -- without this, the very next container_exec can fail with
    # "Failed to get shell PTY: Protocol error".
    for _ in $(seq 1 30); do
        sudo machinectl shell "${MACHINE_NAME}" /bin/true >/dev/null 2>&1 && return
        sleep 1
    done
    echo "WARNING: ${MACHINE_NAME} did not become shell-ready in time." >&2
}

container_exec() {
    sudo machinectl shell "${MACHINE_NAME}" /bin/bash -c "$1"
}

container_exec_as_user() {
    sudo machinectl shell "${MACHINE_NAME}" /bin/su - "${CONTAINER_USER}" -c "$1"
}
