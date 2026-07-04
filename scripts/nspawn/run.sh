#!/usr/bin/env bash
# Run ILLIXR's main.*.exe inside the illixr-build nspawn container, using the
# plugin selection saved by setup_build_env.sh. Requires build.sh to have
# installed ILLIXR first (the default since build.sh installs unless you
# pass --no-install).
#
# Usage:
#   run.sh                            run with the saved plugin/profile selection
#   run.sh --duration=30               extra args are forwarded to main.*.exe
#   run.sh --plugins "a,b,c"          override the plugin list for this run
#   run.sh --yaml profiles/ci.yaml    run from a YAML profile instead (path relative
#                                      to the repo root, or absolute)
#   run.sh --headless                 set ILLIXR_DISPLAY_MODE=none (no window backend)
#   run.sh --headless-xvfb            run the real window backend under Xvfb
#                                      (default 1920x1080x24)
#   run.sh --headless-xvfb=1280x720   ...with a custom resolution
#
# --headless and --headless-xvfb are mutually exclusive: the former skips the
# window backend entirely, the latter runs it for real against a virtual X
# display (needs `xvfb` installed -- rerun setup_build_env.sh to pick it up
# if the container was provisioned before this option existed).
#
# Any other arguments (--duration=, --data=, --demo_data=, etc.) are passed
# straight through to main.*.exe -- see docs/getting_started.md.

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
cd "$(dirname "${SCRIPT_PATH}")"
# shellcheck source=common.sh
source ./common.sh

[ -f "${STATE_FILE}" ] || { echo "No saved plugin selection found. Run setup_build_env.sh first." >&2; exit 1; }
# shellcheck disable=SC1090
source "${STATE_FILE}"

PLUGIN_OVERRIDE=""
YAML_OVERRIDE=""
HEADLESS=0
HEADLESS_XVFB=0
XVFB_RESOLUTION="1920x1080"
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --plugins) PLUGIN_OVERRIDE="$2"; shift 2 ;;
        --yaml) YAML_OVERRIDE="$2"; shift 2 ;;
        --headless) HEADLESS=1; shift ;;
        --headless-xvfb) HEADLESS_XVFB=1; shift ;;
        --headless-xvfb=*) HEADLESS_XVFB=1; XVFB_RESOLUTION="${1#--headless-xvfb=}"; shift ;;
        -h|--help) sed -n '2,21p' "$SCRIPT_PATH"; exit 0 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

if [ "$HEADLESS" = "1" ] && [ "$HEADLESS_XVFB" = "1" ]; then
    echo "--headless and --headless-xvfb are mutually exclusive." >&2
    exit 1
fi
if [ "$HEADLESS_XVFB" = "1" ] && ! [[ "$XVFB_RESOLUTION" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "--headless-xvfb resolution must look like WIDTHxHEIGHT (got '${XVFB_RESOLUTION}')" >&2
    exit 1
fi

ensure_machine_running

# Find the installed binary regardless of build type (main.opt.exe, main.dbg.exe, ...).
BIN="$(container_exec_as_user "ls ${INSTALL_PREFIX}/bin/main.*.exe 2>/dev/null" | tr -d '\r' | head -1)"
if [ -z "$BIN" ]; then
    echo "No installed ILLIXR binary found under ${INSTALL_PREFIX}/bin." >&2
    echo "Run ./build.sh first (install is on by default)." >&2
    exit 1
fi

RUN_ARGS=""
if [ -n "$YAML_OVERRIDE" ]; then
    case "$YAML_OVERRIDE" in
        /*) YAML_PATH="$YAML_OVERRIDE" ;;
        *)  YAML_PATH="${CONTAINER_SRC}/${YAML_OVERRIDE}" ;;
    esac
    RUN_ARGS="--yaml=${YAML_PATH}"
elif [ -n "$PROFILE" ] && [ -z "$PLUGIN_OVERRIDE" ]; then
    RUN_ARGS="--yaml=${CONTAINER_SRC}/profiles/${PROFILE}"
else
    plugin_list="${PLUGIN_OVERRIDE:-$(echo "$PLUGINS" | tr ' ' ',')}"
    RUN_ARGS="-p ${plugin_list}"
fi

ENV_PREFIX=""
CMD_PREFIX=""
if [ "$HEADLESS" = "1" ]; then
    ENV_PREFIX="ILLIXR_DISPLAY_MODE=none "
elif [ "$HEADLESS_XVFB" = "1" ]; then
    if ! container_exec_as_user "command -v xvfb-run >/dev/null 2>&1"; then
        echo "xvfb-run not found in the container. Rerun setup_build_env.sh to install it (xvfb is in CORE_PACKAGES)." >&2
        exit 1
    fi
    # -a picks a free display number so concurrent runs don't collide.
    CMD_PREFIX="xvfb-run -a --server-args='-screen 0 ${XVFB_RESOLUTION}x24' "
fi

echo "Running: ${CMD_PREFIX}${BIN} ${RUN_ARGS} ${EXTRA_ARGS[*]}"
container_exec_as_user "export LD_LIBRARY_PATH=${INSTALL_PREFIX}/lib:${INSTALL_PREFIX}/lib64:\${LD_LIBRARY_PATH} && cd ${INSTALL_PREFIX}/bin && ${ENV_PREFIX}${CMD_PREFIX}${BIN} ${RUN_ARGS} ${EXTRA_ARGS[*]}"
