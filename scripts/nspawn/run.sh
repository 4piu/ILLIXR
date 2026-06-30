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
#   run.sh --headless                 set ILLIXR_DISPLAY_MODE=none (no window)
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
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --plugins) PLUGIN_OVERRIDE="$2"; shift 2 ;;
        --yaml) YAML_OVERRIDE="$2"; shift 2 ;;
        --headless) HEADLESS=1; shift ;;
        -h|--help) sed -n '2,16p' "$SCRIPT_PATH"; exit 0 ;;
        *) EXTRA_ARGS+=("$1"); shift ;;
    esac
done

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
[ "$HEADLESS" = "1" ] && ENV_PREFIX="ILLIXR_DISPLAY_MODE=none "

echo "Running: ${BIN} ${RUN_ARGS} ${EXTRA_ARGS[*]}"
container_exec_as_user "export LD_LIBRARY_PATH=${INSTALL_PREFIX}/lib:${INSTALL_PREFIX}/lib64:\${LD_LIBRARY_PATH} && cd ${INSTALL_PREFIX}/bin && ${ENV_PREFIX}${BIN} ${RUN_ARGS} ${EXTRA_ARGS[*]}"
