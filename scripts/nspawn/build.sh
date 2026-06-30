#!/usr/bin/env bash
# Configure + build ILLIXR inside the illixr-build nspawn container.
# Run setup_build_env.sh first.
#
# Usage:
#   build.sh                      build using the selection saved by setup_build_env.sh,
#                                  then install to CMAKE_INSTALL_PREFIX (run.sh depends on this)
#   build.sh --reconfigure        force a fresh cmake configure (e.g. after changing plugins)
#   build.sh --no-install         skip the install step (faster iteration on compile errors)
#   build.sh --jobs 4             override parallelism (default: nproc)
#   build.sh --prefix /some/path  override CMAKE_INSTALL_PREFIX for this run

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
cd "$(dirname "${SCRIPT_PATH}")"
# shellcheck source=common.sh
source ./common.sh

RECONFIGURE=0
DO_INSTALL=1
JOBS=""
PREFIX_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --reconfigure) RECONFIGURE=1; shift ;;
        --install) DO_INSTALL=1; shift ;;
        --no-install) DO_INSTALL=0; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --prefix) PREFIX_OVERRIDE="$2"; shift 2 ;;
        -h|--help) sed -n '2,9p' "$SCRIPT_PATH"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

[ -f "${STATE_FILE}" ] || { echo "No saved plugin selection found. Run setup_build_env.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "${STATE_FILE}"

[ -n "$PREFIX_OVERRIDE" ] && INSTALL_PREFIX="$PREFIX_OVERRIDE"
[ -z "$JOBS" ] && JOBS="$(nproc)"

ensure_machine_running

BUILD_DIR="${CONTAINER_SRC}/build"
container_exec_as_user "mkdir -p ${BUILD_DIR}"

if [ "$RECONFIGURE" = "1" ] || ! container_exec_as_user "test -f ${BUILD_DIR}/CMakeCache.txt"; then
    if [ -n "$PROFILE" ]; then
        CONFIGURE_ARGS="-DYAML_FILE=${CONTAINER_SRC}/profiles/${PROFILE}"
    else
        CONFIGURE_ARGS=""
        for plugin in $PLUGINS; do
            flag="USE_$(echo "$plugin" | tr '[:lower:]' '[:upper:]')"
            CONFIGURE_ARGS="${CONFIGURE_ARGS} -D${flag}=ON"
        done
    fi
    echo "Configuring: cmake .. -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}${CONFIGURE_ARGS}"
    container_exec_as_user "cd ${BUILD_DIR} && cmake .. -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}${CONFIGURE_ARGS}"
fi

TARGET=""
[ "$DO_INSTALL" = "1" ] && TARGET="--target install"

echo "Building with ${JOBS} jobs..."
container_exec_as_user "cd ${BUILD_DIR} && cmake --build . --parallel ${JOBS} ${TARGET} 2>&1 | tee build.log"
