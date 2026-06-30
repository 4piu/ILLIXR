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
for plugin in "${PLUGINS[@]}"; do
    base="${plugin%%.*}"
    for u in "${UNSUPPORTED_PLUGINS[@]}"; do
        if [ "$base" = "$u" ]; then
            echo "WARNING: '$plugin' needs a vendor SDK / CUDA toolchain this script does not provision (see docs/external_dependencies.rst). Continuing without it." >&2
        fi
    done
    if [ "$base" = "realsense" ]; then NEED_REALSENSE_REPO=1; fi
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
# 5. .nspawn unit: boot with systemd, share host networking, bind-mount the repo.
# ---------------------------------------------------------------------------
sudo mkdir -p "$(dirname "${NSPAWN_UNIT}")"
sudo tee "${NSPAWN_UNIT}" >/dev/null <<EOF
[Exec]
Boot=on
PrivateUsers=no

[Network]
VirtualEthernet=no

[Files]
Bind=${REPO_ROOT}:${CONTAINER_SRC}
EOF

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
