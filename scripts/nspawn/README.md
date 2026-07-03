# Building ILLIXR in a systemd-nspawn container

These scripts set up an isolated Ubuntu 22.04 build environment using
`systemd-nspawn` instead of Docker or a full VM. nspawn containers share the
host kernel (so they must match the host architecture -- this was built and
tested on an arm64 board) but get their own root filesystem, package set, and
init system, which keeps ILLIXR's large dependency footprint off the host.

## Scripts

- `setup_build_env.sh` -- bootstraps the container and installs dependencies.
  Prompts you to pick a plugin set (a `profiles/*.yaml` file, or a manual
  comma-separated plugin list) and installs only the apt packages that
  selection needs. Safe to re-run.
- `build.sh` -- runs `cmake` configure (first run, or after `--reconfigure`)
  and `cmake --build` inside the container, using the plugin selection saved
  by `setup_build_env.sh`. Installs to `CMAKE_INSTALL_PREFIX` by default
  (pass `--no-install` to skip, e.g. for a quick compile-error check).
- `run.sh` -- runs the installed `main.*.exe` inside the container with the
  saved plugin/profile selection. Depends on `build.sh` having installed
  (the default).
- `teardown_build_env.sh` -- stops and deletes the container. Only touches
  container-internal state; never deletes anything under the repo (including
  `build/`).
- `common.sh` -- shared config/helpers sourced by the scripts above, not
  meant to be run directly.

## Quick start

```sh
./scripts/nspawn/setup_build_env.sh      # pick plugins, provision the container
./scripts/nspawn/build.sh                # cmake configure + build + install
./scripts/nspawn/run.sh --headless --duration=30   # run it
```

To change plugins later, rerun `setup_build_env.sh --profile <name>` or
`--plugins "..."`, then `build.sh --reconfigure`.

To tear everything down: `./scripts/nspawn/teardown_build_env.sh`.

## Running

`run.sh` forwards unrecognized arguments straight to `main.*.exe` (e.g.
`--duration=`, `--data=`, `--demo_data=`). Useful flags:

- `--yaml <profile>` -- run from a YAML profile (e.g. `--yaml illixr.yaml`,
  the file `cmake` generates at the repo root, or `--yaml profiles/ci.yaml`)
  instead of the saved plugin list. This is also how `env_vars:` like `data:`
  get set, since `-p plugin,list` mode doesn't read a profile file at all.
- `--headless` -- sets `ILLIXR_DISPLAY_MODE=none` (no window backend).
- `--plugins "a,b,c"` -- override the plugin list for one run without
  touching the saved selection.

Without a profile (`-p` mode), most plugins still need environment variables
the profile would otherwise set for you (e.g. `offline_cam`/`offline_imu`
need `ILLIXR_DATA` / `--data=<path>` pointing at a EuRoC-format dataset) --
see `docs/getting_started.md` for the full list.

`main.*.exe`'s `dlopen()` calls use bare filenames
(`libplugin.<name>.opt.so`), so they're only found via `LD_LIBRARY_PATH` or
the binary's rpath -- `run.sh` sets `LD_LIBRARY_PATH` to
`$INSTALL_PREFIX/lib:$INSTALL_PREFIX/lib64` before launching. This is also
why `build.sh` installs by default: without an install, plugin `.so` files
are scattered across `build/plugins/*/` and `build/services/*/`, and even
`openvins.opt.so`'s own dependency (`libov_msckf_lib.so`) isn't found through
the executable's rpath alone -- only `LD_LIBRARY_PATH` covers it reliably,
since modern linkers emit `RUNPATH` (applies only to an object's direct
dependencies) rather than the older, process-wide `RPATH`.

## How it's wired up

- Rootfs: `/var/lib/machines/illixr-build` (an Ubuntu 22.04 `debootstrap`,
  architecture auto-detected from the host).
- Container config: `/etc/systemd/nspawn/illixr-build.nspawn` -- boots with
  systemd (`Boot=on`), shares the host's network namespace (so `apt` just
  works, no NAT setup needed), and bind-mounts the repo root into
  `/home/illixr/ILLIXR` inside the container.
- Build user: a uid/gid-matched `illixr` user inside the container (matched
  to the invoking host user's uid/gid). This matters: nspawn doesn't
  translate ownership across the bind mount, so a uid mismatch between the
  host user and the container's default first-user (usually 1000) silently
  breaks writes into the bind-mounted `build/` directory with permission
  errors that look unrelated to the mismatch.
- Managed via `machinectl start/stop illixr-build` (persists across host
  reboots, shows up in standard tooling like `machinectl list`/`status`)
  rather than raw `systemd-nspawn` invocations. Commands run *inside* the
  container go through `systemd-run --pipe --wait --machine=illixr-build`
  (the `container_exec`/`container_exec_as_user` helpers in `common.sh`),
  not `machinectl shell`: `man machinectl` documents that `shell` does not
  propagate the invoked process's exit code (it always returns 0 to the
  caller regardless of what happened inside) -- every `if container_exec
  ...` check in these scripts depends on a real exit code, and silently got
  the wrong answer until this was caught and fixed.
- **Self-healing container config**: `sync_container_config()` in
  `common.sh` is called both by `setup_build_env.sh` and by
  `ensure_machine_running()` itself, every time the container needs to be
  started from stopped. This matters because `systemd-nspawn`'s `Bind=` has
  no "skip if the source is missing" syntax -- a `.nspawn` file with a
  stale `Bind=/dev/hidraw3` entry (e.g. left over from before a host
  reboot, when a since-replugged camera re-enumerates under a different
  node) makes the *entire container* fail to start
  (`Failed to stat /dev/hidraw3: No such file or directory`), not just lose
  USB passthrough. Re-deriving the USB bind list from currently-connected
  hardware on every start, rather than only when `setup_build_env.sh` is
  run explicitly, avoids that.

## Dependency notes

- The "core" package set (always installed) covers everything
  `utils/CMakeLists.txt` and the top-level `CMakeLists.txt` need
  unconditionally: Boost, Eigen3, OpenCV, GLEW, X11, spdlog, glfw3, GStreamer,
  the Vulkan/glslang/SPIR-V toolchain, etc.
- Most plugins (`gtsam_integrator`, `openvins`, `orb_slam3`,
  `native_renderer`, `timewarp_vk`, `vkdemo`, `pose_prediction`,
  `tcp_network_backend`, `ground_truth_slam`, ...) fetch and build their
  remaining dependencies from source via the `cmake/Get*.cmake` modules and
  need nothing beyond the core set -- expect the first build to take a while
  (GTSAM, Vulkan-ValidationLayers, and yaml-cpp are all compiled from source).
- A few plugins need extra apt packages; see `PLUGIN_PACKAGES` in
  `common.sh` (currently: `realsense`, `openni`, `audio_pipeline`,
  `offload_vio`, `ada`, `timewarp_gl`).
- `librealsense2-dev` isn't in Ubuntu's repos; the script adds Intel's apt
  repo. As of this writing, the GPG key published at
  `https://librealsense.intel.com/Debian/librealsense.pgp` does **not**
  match the key the repo's `InRelease` is actually signed with
  (`FB0B24895113F120`) -- the script pulls the correct key from
  `keyserver.ubuntu.com` instead. If `apt-get update` ever complains about
  `NO_PUBKEY` again, that's almost certainly what's happened: Intel rotated
  keys without updating the static `.pgp` URL.
- `zed`, `offload_rendering_server/client`, and `hand_tracking_gpu` need a
  vendor SDK or CUDA toolchain this script doesn't provision. Selecting them
  prints a warning and installs nothing extra for them -- see
  `docs/external_dependencies.rst`.

## USB device passthrough (RealSense)

If the selected plugin list includes `realsense` (see `USB_PASSTHROUGH_PLUGINS`
in `common.sh`), `setup_build_env.sh` automatically wires through a connected
Intel RealSense camera. This needs three independent pieces, all handled by
the script:

1. **`/dev/bus/usb` bind mount** (`.nspawn` `[Files] Bind=`) -- gives the
   container libusb/control-channel access. By itself this is only enough
   for `rs-enumerate-devices` to see the device, not for ILLIXR's plugin.
2. **`/dev/videoN` + `/dev/hidrawN` bind mounts** -- discovered dynamically by
   USB vendor ID (`8086`, Intel) at setup time and bound individually, since
   unlike `/dev/bus/usb` there's no stable parent directory for V4L2/hidraw
   devices. The D4xx series streams color/depth/IR over V4L2 but exposes its
   IMU (gyro/accel) over a separate USB HID interface -- without the
   `/dev/hidrawN` bind, `rs-enumerate-devices` succeeds but ILLIXR's
   `plugins/realsense/plugin.cpp` still aborts with `Supported Realsense
   device NOT found!`, because `find_supported_devices()` requires *both* a
   gyro and an accel stream to recognize a D4xx camera.
3. **cgroup `DeviceAllow=`** (`systemd-nspawn@illixr-build.service.d/usb.conf`)
   -- `Bind=` only makes the node visible in the container's mount namespace;
   the container's `DevicePolicy=closed` cgroup policy separately denies
   `open()` on it unless explicitly allowed. Granted via systemd's symbolic
   device-tag names: `char-usb_device` (major 189), `char-video4linux`
   (major 81), `char-hidraw` (major 236) -- matched against `/proc/devices`
   on the host.
4. **Boot-time permission fixup** (`illixr-usb-perms.service`, installed into
   the container's rootfs) -- for the *directory* bind (`/dev/bus/usb`) the
   kernel preserves the host's permissions (it's a real bind mount of an
   existing populated directory). For *individual device-file* binds
   (`/dev/videoN`, `/dev/hidrawN`), systemd-nspawn instead recreates the node
   via `mknod` with the same major:minor but **not** the host's mode/owner --
   it comes up `0600 root:root` regardless of the host's actual (usually
   `0666 plugdev`) permissions. A oneshot unit chmods the exact bound paths
   on every container boot to fix this, since there's no real udev inside the
   container to redo it for us.

**Known limitation:** device numbers can change across host replugs (or a
host reboot). If the container is currently *stopped*, this self-heals: the
next `run.sh`/`build.sh`/`setup_build_env.sh` re-derives the bind list from
whatever's connected *right now* before starting it (dropping stale entries
if the camera isn't plugged in, or picking up new ones if it is). If the
container is already *running* when you replug, that doesn't apply --
rerun `setup_build_env.sh` to refresh it (it stops/starts the container
automatically if the passthrough config changed).

**Known issue on at least one tested board (OrangePi/Rockchip, single USB3
port):** the D455 can flap -- the kernel repeatedly detaches and reprobes its
interfaces (visible in `dmesg` as repeating `uvcvideo: Found UVC 1.50
device` / incrementing `hid-generic ... hiddev96,hidraw3` lines) even at
idle, which recreates the device nodes out from under the static bind mounts
and makes `rs-enumerate-devices`/the realsense plugin intermittently fail
with `No device detected` even though the setup itself is correct (verified
working multiple times when the connection briefly held steady, including
gyro/accel detection). This looks like a power/signal-integrity issue with
the D455's draw on this board's USB3 controller, not a container
configuration problem -- a powered USB hub is the standard fix for D455
power issues on SBCs. If `rs-enumerate-devices -s` run as root
(`sudo machinectl shell illixr-build /bin/bash -c 'rs-enumerate-devices -s'`)
works but `run.sh` still reports "Supported Realsense device NOT found!",
check `dmesg` for repeating UVC/HID probe lines before assuming the script is
broken -- two unbind/rebind attempts during development reproduced this
exact symptom and one even caused a full USB disconnect requiring a physical
replug to recover (don't run raw `/sys/bus/usb/drivers/usb/{unbind,bind}` on
a device you can't physically reach).

## Why nspawn over Docker here

The repo ships Docker images (`docker/`), but they're x86_64 + CUDA-oriented
(`docker/ubuntu`) or otherwise don't match an arm64, non-Nvidia board. nspawn
reuses the host kernel and `apt`, so there's no need to maintain a separate
Dockerfile per architecture, and `machinectl shell`/`bind-mount` make it easy
to iterate on the repo from the host editor while building inside the
container.
