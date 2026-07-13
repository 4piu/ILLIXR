#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "pandas",
#   "matplotlib",
# ]
# ///
"""
ILLIXR ada (scene reconstruction offload) benchmark analysis script.

Usage — single run:
    uv run scripts/analyze_ada_metrics.py \\
        --server run1/server --client run1/client --label baseline

Usage — SEV on vs off comparison:
    uv run scripts/analyze_ada_metrics.py \\
        --server sev_off/run1/server --client sev_off/run1/client --label sev_off_run1 \\
        --server sev_on/run1/server  --client sev_on/run1/client  --label sev_on_run1  \\
        --out report/

Notes:
  - --server/--client each point at a directory containing that side's
    ILLIXR_METRICS_DIR sqlite output (tcp_socket_stats.sqlite, tcp_frame.sqlite,
    plugin_name.sqlite, ...) *and* a `recorded_data/` subdirectory holding that
    side's ada.* plugins' hand-rolled CSV files (device_tx/server_rx/etc. do not
    use ILLIXR_METRICS_DIR -- they always write to `<cwd>/recorded_data` at
    process start; the orchestration script is expected to have copied that
    directory alongside the sqlite output before invoking this script).
  - ada.scene_management runs *client-side* (see profiles/bench_ada_device.yaml),
    same machine as ada.device_tx. That means the headline "offload round-trip"
    metric (send -> mesh ready) is a single-machine, monotonic-clock delta, NOT
    subject to cross-machine clock skew. Only two legs actually cross machines
    and need clock-skew care (see MAX_PLAUSIBLE_LATENCY_MS below):
      - uplink:   device_tx (client) -> server_rx (server)
      - downlink: server_tx (server) -> device_rx (client)
  - Warm-up trimming: ada's dataset (TUM fr1_desk, 596 frames) finishes in
    well under a minute of actual data, ~10x shorter than offload_vio's ~85s
    EuRoC clip analyze_metrics.py was built for -- --warmup-s defaults to 2s
    here (not 10s) so a default run doesn't discard a big fraction of the
    already-small sample. Override with --warmup-s if your dataset differs.
  - Known data-quality caveat, not fixed here (out of scope for this analysis
    script -- see notes/ada_sev_benchmark_plan.md): ada.device_rx routes every
    mesh chunk to decompression worker 0 regardless of MESH_DECOMPRESS_PARALLELISM
    (chunk_id always arrives as 0), so only decoding_latency_0.csv has real data;
    the per-worker breakdown for the *client* decompression stage is not
    meaningful. Server-side mesh_compression's 8 workers are all exercised
    normally. device_unpackage_time_.csv's per-chunk duration_ms column reads
    0 for every row (likely sub-resolution or an instrumentation gap on
    device_rx's chunk-unpack timer) -- also excluded from the breakdown.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

import matplotlib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

matplotlib.rcParams["figure.dpi"] = 130
matplotlib.rcParams["axes.spines.top"] = False
matplotlib.rcParams["axes.spines.right"] = False

PERCENTILES = [50, 90, 95, 99]

# Cross-machine legs (uplink/downlink) use plain epoch-millisecond wall-clock
# timestamps taken independently on each machine (std::chrono::high_resolution_clock
# on Linux/libstdc++ is system_clock under the hood, so since_epoch() is a real
# wall-clock value -- see docs/docs/plugin_README/README_ada.md Q7). Unlike
# offload_vio's unsigned-nanosecond subtraction, there's no wraparound bit
# pattern here -- clock skew instead shows up as an implausible (very large,
# or negative) millisecond delta. Filter the same way analyze_metrics.py does
# for offload_vio_uplink/downlink, just on plain signed deltas.
MAX_PLAUSIBLE_LATENCY_MS = 5000
# Real near-zero latencies routinely read as small negative numbers (a few ms)
# purely from clock jitter between the two machines' independently-sampled
# epoch timestamps -- hard-dropping every negative value would discard genuine
# "latency ~= 0" samples and bias percentiles upward (the same class of bias
# Task 1's offload_vio wraparound filter causes, avoided here by only treating
# a *large* negative delta -- beyond plausible clock-sync residual -- as an
# artifact, not any negative value).
MIN_PLAUSIBLE_LATENCY_MS = -50


# ──────────────────────────────────────────────────────────────────────────────
# CSV loading helpers -- ada.* plugins hand-roll whitespace-delimited CSVs
# under <cwd>/recorded_data instead of using record_logger/sqlite.
# ──────────────────────────────────────────────────────────────────────────────

def _read_labeled_csv(path: Path, ncols: int) -> pd.DataFrame | None:
    """Read a whitespace-delimited file whose first column is a string label
    (e.g. "Decompose"/"Encode"/"FullFrame") and the rest are numeric. Rows with
    the wrong column count for their label are dropped (defensive -- these
    files mix row shapes by label, see plugin.cpp for each one)."""
    if not path.exists() or path.stat().st_size == 0:
        return None
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) != ncols:
            continue
        rows.append(parts)
    if not rows:
        return None
    return pd.DataFrame(rows)


def _read_id_value_csv(path: Path, id_col: str, value_col: str) -> pd.DataFrame | None:
    """Read a plain `<id> <value>` file (sending_timestamp_.csv, receiving_timestamp.csv,
    server_receiving_timestamp.csv, server_send_mesh_timestamp.csv, vb_timestamp_.csv)."""
    if not path.exists() or path.stat().st_size == 0:
        return None
    df = pd.read_csv(path, sep=r"\s+", header=None, names=[id_col, value_col])
    return df.astype({id_col: "int64", value_col: "int64"})


def _drop_implausible(df: pd.DataFrame, col: str, label: str) -> pd.DataFrame:
    bad = (df[col] > MAX_PLAUSIBLE_LATENCY_MS) | (df[col] < MIN_PLAUSIBLE_LATENCY_MS)
    n_bad = int(bad.sum())
    if n_bad:
        print(f"  [warn] {label}: dropping {n_bad}/{len(df)} rows with implausible "
              f"{col} (clock-skew artifact)", file=sys.stderr)
    return df[~bad].copy()


def load_sending_timestamp(client_dir: Path) -> pd.DataFrame | None:
    """device_tx.sending_timestamp_.csv: one row every FPS frames, frame_id is a
    multiple of FPS (15, 30, ...). scene_id = frame_id / FPS - 1."""
    df = _read_id_value_csv(client_dir / "recorded_data" / "sending_timestamp_.csv",
                             "frame_id", "send_epoch_ms")
    return df


def load_receiving_timestamp(client_dir: Path) -> pd.DataFrame | None:
    """device_rx.receiving_timestamp.csv: one row per new scene_id (0-indexed)."""
    return _read_id_value_csv(client_dir / "recorded_data" / "receiving_timestamp.csv",
                               "scene_id", "recv_epoch_ms")


def load_server_receiving_timestamp(server_dir: Path) -> pd.DataFrame | None:
    """server_rx.server_receiving_timestamp.csv: one row every FPS frames, same
    frame_id convention as sending_timestamp_.csv."""
    return _read_id_value_csv(server_dir / "recorded_data" / "server_receiving_timestamp.csv",
                               "frame_id", "server_recv_epoch_ms")


def load_server_send_mesh_timestamp(server_dir: Path) -> pd.DataFrame | None:
    """server_tx.server_send_mesh_timestamp.csv: one row per completed (fully-chunked)
    mesh, keyed by scene_id (0-indexed)."""
    return _read_id_value_csv(server_dir / "recorded_data" / "server_send_mesh_timestamp.csv",
                               "scene_id", "server_send_epoch_ms")


def load_ready_timestamp(client_dir: Path) -> pd.DataFrame | None:
    """scene_management.mesh_management_latency.csv's "Ready" rows: wall-clock epoch ms
    when a scene's mesh becomes available for display, keyed by scene_id."""
    path = client_dir / "recorded_data" / "mesh_management_latency.csv"
    df = _read_labeled_csv(path, ncols=3)
    if df is None:
        return None
    df = df[df[0] == "Ready"].copy()
    if df.empty:
        return None
    df.columns = ["label", "scene_id", "ready_epoch_ms"]
    return df[["scene_id", "ready_epoch_ms"]].astype({"scene_id": "int64", "ready_epoch_ms": "int64"})


def load_scene_management_stages(client_dir: Path) -> pd.DataFrame | None:
    """scene_management.mesh_management_latency.csv's timing rows (Clean/Merge/Map/
    Display/PP), each `<label> <scene_id> <ms> [...]`. "Ready" (a timestamp, not a
    duration) is excluded -- use load_ready_timestamp for that."""
    path = client_dir / "recorded_data" / "mesh_management_latency.csv"
    if not path.exists() or path.stat().st_size == 0:
        return None
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) < 3 or parts[0] in ("Ready",):
            continue
        rows.append({"stage": parts[0], "scene_id": int(parts[1]), "duration_ms": float(parts[2])})
    return pd.DataFrame(rows) if rows else None


def load_compression_latency(server_dir: Path) -> pd.DataFrame | None:
    """mesh_compression.compression_latency_<idx>.csv: one value per line (ms), one
    file per worker thread. Concatenated with a `worker` column."""
    frames = []
    for f in sorted((server_dir / "recorded_data").glob("compression_latency_*.csv")):
        if f.stat().st_size == 0:
            continue
        idx = int(f.stem.rsplit("_", 1)[-1])
        vals = pd.read_csv(f, header=None, names=["duration_ms"])
        vals["worker"] = idx
        frames.append(vals)
    if not frames:
        return None
    return pd.concat(frames, ignore_index=True)


def load_decoding_latency(client_dir: Path) -> pd.DataFrame | None:
    """mesh_decompression_grey.decoding_latency_<idx>.csv: "Decode <id> <chunk_id> <ms>"
    and "PVBGen <id> <ms>" rows, one file per worker thread. See module docstring --
    in practice only worker 0 gets real data for this pipeline currently."""
    frames = []
    for f in sorted((client_dir / "recorded_data").glob("decoding_latency_*.csv")):
        if f.stat().st_size == 0:
            continue
        idx = int(f.stem.rsplit("_", 1)[-1])
        decode_rows, pvbgen_rows = [], []
        for line in f.read_text().splitlines():
            parts = line.split()
            if parts[0] == "Decode" and len(parts) == 4:
                decode_rows.append({"scene_id": int(parts[1]), "chunk_id": int(parts[2]),
                                    "duration_ms": float(parts[3]), "stage": "decode"})
            elif parts[0] == "PVBGen" and len(parts) == 3:
                pvbgen_rows.append({"scene_id": int(parts[1]), "duration_ms": float(parts[2]),
                                    "stage": "pvbgen"})
        rows = decode_rows + pvbgen_rows
        if not rows:
            continue
        df = pd.DataFrame(rows)
        df["worker"] = idx
        frames.append(df)
    if not frames:
        return None
    return pd.concat(frames, ignore_index=True)


def load_infinitam_latency(server_dir: Path) -> pd.DataFrame | None:
    """ada.infinitam's sr_latency.csv (external plugin, fetched at build time --
    see cmake/GetInfiniTAM.cmake). Row shapes empirically confirmed against a real
    captured sample this session:
      fuse <frame_id> <ms>            -- per-frame TSDF fusion, every processed frame
      start <frame_id> <epoch_ms>     -- mesh-extraction start, every FPS frames
      extract <scene_id> <ms> <faces> -- incremental mesh extraction (the GetMesh() call)
      vb <scene_id> <ms> <bytes>      -- voxel-block-list encode
      gen <scene_id> <ms>             -- mesh generation/post-processing
    """
    path = server_dir / "recorded_data" / "sr_latency.csv"
    if not path.exists() or path.stat().st_size == 0:
        return None
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        label = parts[0]
        if label in ("fuse", "gen") and len(parts) == 3:
            rows.append({"stage": label, "id": int(parts[1]), "duration_ms": float(parts[2])})
        elif label == "extract" and len(parts) == 4:
            rows.append({"stage": label, "id": int(parts[1]), "duration_ms": float(parts[2]),
                        "faces": int(parts[3])})
        elif label == "vb" and len(parts) == 4:
            rows.append({"stage": label, "id": int(parts[1]), "duration_ms": float(parts[2]),
                        "bytes": int(parts[3])})
        # "start" rows are a timestamp, not a duration -- not loaded here.
    return pd.DataFrame(rows) if rows else None


def _load_sqlite_table(db_path: Path, table: str) -> pd.DataFrame | None:
    if not db_path.exists():
        return None
    try:
        con = sqlite3.connect(db_path)
        df = pd.read_sql(f"SELECT * FROM {table}", con)
        con.close()
        return df
    except Exception as e:
        print(f"  [warn] {db_path}: {e}", file=sys.stderr)
        return None


def load_tcp_socket_stats(metrics_dir: Path) -> pd.DataFrame | None:
    """tcp_socket_stats.sqlite -- reused as-is from tcp_network_backend's record_logger
    output (the one part of the ada pipeline that already uses the sqlite system)."""
    df = _load_sqlite_table(metrics_dir / "tcp_socket_stats.sqlite", "tcp_socket_stats")
    if df is None or df.empty:
        return None
    df = df.sort_values("wall_time").reset_index(drop=True)
    t0 = df["wall_time"].iloc[0]
    df["elapsed_s"] = (df["wall_time"] - t0) / 1e9
    df["rtt_ms"] = df["rtt_us"] / 1000.0
    return df


def load_tcp_frames(metrics_dir: Path) -> pd.DataFrame | None:
    df = _load_sqlite_table(metrics_dir / "tcp_frame.sqlite", "tcp_frame")
    if df is None or df.empty:
        return None
    df = df.sort_values("wall_time").reset_index(drop=True)
    t0 = df["wall_time"].iloc[0]
    df["elapsed_s"] = (df["wall_time"] - t0) / 1e9
    return df


def load_mem_probe(result_dir: Path) -> pd.DataFrame | None:
    """mem_probe.csv -- guest-side resource probe written by
    run_ada_sev_benchmark.sh's probe_loop, sampled every ~2s for the trial's
    duration (+60s grace, to catch any post-duration stall). Columns:
    epoch_ms,rss_kb,minflt,majflt[,swiotlb_used_slabs,swiotlb_hiwater_slabs]
    (the swiotlb columns are server-only -- the client is bare metal, no
    SEV/DMA-bounce-buffer concept applies there). Rows where the process
    wasn't found (trial not yet started, or already exited) have empty
    numeric fields -- kept as NaN via pandas rather than dropped, so gaps in
    the process's lifetime are visible in the time series instead of
    silently compressed away.
    """
    path = result_dir / "mem_probe.csv"
    if not path.exists() or path.stat().st_size == 0:
        return None
    df = pd.read_csv(path)
    if df.empty:
        return None
    df = df.sort_values("epoch_ms").reset_index(drop=True)
    t0 = df["epoch_ms"].iloc[0]
    df["elapsed_s"] = (df["epoch_ms"] - t0) / 1000.0
    return df


# ──────────────────────────────────────────────────────────────────────────────
# Joins -- see module docstring for which legs are cross-machine
# ──────────────────────────────────────────────────────────────────────────────

def build_latency_legs(server_dir: Path | None, client_dir: Path | None,
                        warmup_s: float) -> dict[str, pd.DataFrame]:
    legs: dict[str, pd.DataFrame] = {}
    if client_dir is None or server_dir is None:
        return legs

    send = load_sending_timestamp(client_dir)
    recv_srv = load_server_receiving_timestamp(server_dir)
    send_mesh = load_server_send_mesh_timestamp(server_dir)
    recv_cli = load_receiving_timestamp(client_dir)
    ready = load_ready_timestamp(client_dir)

    if send is None or recv_srv is None or send_mesh is None or recv_cli is None or ready is None:
        print("  [warn] missing one or more timestamp CSVs -- skipping latency-leg joins",
              file=sys.stderr)
        return legs

    # frame_id -> scene_id, per device_tx/server_rx's `frame_id_ % fps_ == 0` sampling
    # convention: scene_id = frame_id / FPS - 1. Recover FPS from the frame_id spacing
    # itself rather than hardcoding it.
    fps = int(send["frame_id"].diff().dropna().mode().iloc[0]) if len(send) > 1 else 15
    send = send.copy()
    send["scene_id"] = send["frame_id"] // fps - 1
    recv_srv = recv_srv.copy()
    recv_srv["scene_id"] = recv_srv["frame_id"] // fps - 1

    t0 = send["send_epoch_ms"].iloc[0]

    def _trim(df: pd.DataFrame, ts_col: str) -> pd.DataFrame:
        return df[df[ts_col] - t0 >= warmup_s * 1000].copy()

    # Uplink (cross-machine): client send -> server arrival.
    up = send.merge(recv_srv, on="scene_id", how="inner")
    up["uplink_latency_ms"] = up["server_recv_epoch_ms"] - up["send_epoch_ms"]
    up = _trim(up, "send_epoch_ms")
    legs["uplink"] = _drop_implausible(up, "uplink_latency_ms", "uplink")

    # Server-local: server arrival -> mesh fully sent.
    compute = recv_srv.merge(send_mesh, on="scene_id", how="inner")
    compute["server_compute_ms"] = compute["server_send_epoch_ms"] - compute["server_recv_epoch_ms"]
    legs["server_compute"] = _trim(compute, "server_recv_epoch_ms")

    # Downlink (cross-machine): server send -> client arrival.
    down = send_mesh.merge(recv_cli, on="scene_id", how="inner")
    down["downlink_latency_ms"] = down["recv_epoch_ms"] - down["server_send_epoch_ms"]
    down = _trim(down, "server_send_epoch_ms")
    legs["downlink"] = _drop_implausible(down, "downlink_latency_ms", "downlink")

    # Client-local: mesh arrival -> ready to display.
    display = recv_cli.merge(ready, on="scene_id", how="inner")
    display["client_display_ms"] = display["ready_epoch_ms"] - display["recv_epoch_ms"]
    legs["client_display"] = _trim(display, "recv_epoch_ms")

    # Headline end-to-end (client-local only -- both endpoints are client-side clocks,
    # no cross-machine skew involved despite spanning the whole network round trip).
    e2e = send.merge(ready, on="scene_id", how="inner")
    e2e["end_to_end_ms"] = e2e["ready_epoch_ms"] - e2e["send_epoch_ms"]
    legs["end_to_end"] = _trim(e2e, "send_epoch_ms")

    return legs


def load_run(server_dir: Path | None, client_dir: Path | None, warmup_s: float) -> dict:
    run: dict = {}
    run["legs"] = build_latency_legs(server_dir, client_dir, warmup_s)
    if server_dir:
        run["server_compression"] = load_compression_latency(server_dir)
        run["server_infinitam"] = load_infinitam_latency(server_dir)
        run["server_tcp_stats"] = load_tcp_socket_stats(server_dir)
        run["server_tcp_frames"] = load_tcp_frames(server_dir)
        run["server_mem_probe"] = load_mem_probe(server_dir)
    if client_dir:
        run["client_decoding"] = load_decoding_latency(client_dir)
        run["client_scene_mgmt"] = load_scene_management_stages(client_dir)
        run["client_tcp_stats"] = load_tcp_socket_stats(client_dir)
        run["client_tcp_frames"] = load_tcp_frames(client_dir)
        run["client_mem_probe"] = load_mem_probe(client_dir)
    return run


# ──────────────────────────────────────────────────────────────────────────────
# Statistic helpers (same shape as analyze_metrics.py)
# ──────────────────────────────────────────────────────────────────────────────

def percentile_table(series: pd.Series, label: str) -> pd.DataFrame:
    clean = series.dropna()
    pcts = {f"p{p}": np.nanpercentile(clean, p) for p in PERCENTILES} if len(clean) else \
        {f"p{p}": np.nan for p in PERCENTILES}
    return pd.DataFrame([{
        "metric": label,
        "n": int(clean.shape[0]),
        "mean": clean.mean() if len(clean) else np.nan,
        **pcts,
    }])


def scalar_row(value: float, n: int, label: str) -> pd.DataFrame:
    return pd.DataFrame([{"metric": label, "n": n, "mean": value,
                          "p50": value, "p90": value, "p95": value, "p99": value}])


def summarise_latency(run: dict, label: str) -> pd.DataFrame:
    rows = []
    legs = run.get("legs", {})
    for leg, col in [("end_to_end", "end_to_end_ms"), ("uplink", "uplink_latency_ms"),
                      ("server_compute", "server_compute_ms"), ("downlink", "downlink_latency_ms"),
                      ("client_display", "client_display_ms")]:
        df = legs.get(leg)
        if df is not None and not df.empty:
            rows.append(percentile_table(df[col], f"{leg}_ms"))

    for side in ("client", "server"):
        stats = run.get(f"{side}_tcp_stats")
        if stats is not None and not stats.empty:
            rows.append(percentile_table(stats["rtt_ms"], f"{side}_tcp_rtt_ms"))
            rows.append(scalar_row(float(stats["total_retrans"].max()), len(stats),
                                   f"{side}_tcp_total_retrans"))

    if not rows:
        return pd.DataFrame()
    df = pd.concat(rows, ignore_index=True)
    df.insert(0, "run", label)
    return df


# ──────────────────────────────────────────────────────────────────────────────
# Plot helpers
# ──────────────────────────────────────────────────────────────────────────────

def _cdf(series: pd.Series):
    s = series.dropna().sort_values()
    return s.values, np.linspace(0, 1, len(s))


def plot_leg_cdf(runs_data: list[tuple[str, dict]], leg: str, col: str,
                  title: str, xlabel: str, out_path: Path | None = None) -> None:
    fig, ax = plt.subplots(figsize=(7, 4))
    any_data = False
    for label, run in runs_data:
        df = run.get("legs", {}).get(leg)
        if df is None or col not in df.columns:
            continue
        x, y = _cdf(df[col])
        if len(x) == 0:
            continue
        ax.plot(x, y, label=label, linewidth=1.8)
        any_data = True
    if not any_data:
        plt.close(fig)
        return
    ax.set_xlabel(xlabel)
    ax.set_ylabel("CDF")
    ax.set_title(title)
    ax.legend()
    ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_latency_breakdown_bar(summary_df: pd.DataFrame, out_path: Path | None = None) -> None:
    """Stacked mean-latency bar: uplink + server_compute + downlink + client_display
    per run (the 4 legs that sum to end_to_end)."""
    if summary_df.empty:
        return
    pivot = summary_df.pivot(index="run", columns="metric", values="mean")
    cols = [c for c in ["uplink_ms", "server_compute_ms", "downlink_ms", "client_display_ms"]
            if c in pivot.columns]
    if not cols:
        return
    sub = pivot[cols].fillna(0)
    sub.columns = [c.replace("_ms", "").replace("_", " ") for c in sub.columns]

    fig, ax = plt.subplots(figsize=(max(5, len(sub) * 1.6 + 1), 4))
    sub.plot(kind="bar", stacked=True, ax=ax, colormap="tab10", edgecolor="white")
    ax.set_ylabel("Mean latency (ms)")
    ax.set_title("Per-stage mean latency breakdown")
    ax.set_xlabel("")
    ax.legend(loc="upper right")
    plt.xticks(rotation=15, ha="right")
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_end_to_end_time_series(runs_data: list[tuple[str, dict]], out_path: Path | None = None) -> None:
    """End-to-end latency per scene over elapsed time -- short runs (39 scenes) don't
    need rolling-median smoothing the way offload_vio's per-frame data did."""
    fig, ax = plt.subplots(figsize=(9, 4))
    any_data = False
    for label, run in runs_data:
        df = run.get("legs", {}).get("end_to_end")
        if df is None or df.empty:
            continue
        d = df.sort_values("scene_id")
        elapsed_s = (d["send_epoch_ms"] - d["send_epoch_ms"].iloc[0]) / 1000.0
        ax.plot(elapsed_s, d["end_to_end_ms"], marker="o", markersize=3, label=label, linewidth=1.2)
        any_data = True
    if not any_data:
        plt.close(fig)
        return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("End-to-end latency (ms)")
    ax.set_title("Offload round-trip latency per scene (send -> mesh ready)")
    ax.legend()
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_infinitam_breakdown(runs_data: list[tuple[str, dict]], out_path: Path | None = None) -> None:
    """Box plots of InfiniTAM's own per-stage timing (fuse/extract/vb/gen), server-side."""
    fig, ax = plt.subplots(figsize=(10, 5))
    all_data, all_labels = [], []
    for label, run in runs_data:
        df = run.get("server_infinitam")
        if df is None:
            continue
        for stage, grp in df.groupby("stage"):
            all_data.append(grp["duration_ms"].dropna().values)
            all_labels.append(f"{label}\n{stage}")
    if not all_data:
        plt.close(fig)
        return
    ax.boxplot(all_data, labels=all_labels, showfliers=False, patch_artist=True)
    ax.set_ylabel("Duration (ms)")
    ax.set_title("InfiniTAM per-stage timing (server)")
    plt.xticks(rotation=30, ha="right")
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_tcp_rtt_cdf(runs_data: list[tuple[str, dict]], side: str, out_path: Path | None = None) -> None:
    fig, ax = plt.subplots(figsize=(7, 4))
    any_data = False
    for label, run in runs_data:
        stats = run.get(f"{side}_tcp_stats")
        if stats is None or stats.empty:
            continue
        x, y = _cdf(stats["rtt_ms"])
        ax.plot(x, y, label=label, linewidth=1.8)
        any_data = True
    if not any_data:
        plt.close(fig)
        return
    ax.set_xlabel("ms")
    ax.set_ylabel("CDF")
    ax.set_title(f"{side.capitalize()}-side TCP RTT CDF (kernel TCP_INFO)")
    ax.legend()
    ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_rss_time_series(runs_data: list[tuple[str, dict]], side: str, out_path: Path | None = None) -> None:
    """RSS over elapsed time for the ada process, one side at a time. Primary
    tool for characterizing the sev_on memory-pressure anomaly (run2/run3
    hit near-OOM, ~7.2Gi/7.3Gi used) -- watch whether RSS keeps climbing
    instead of plateauing, and whether sev_on runs climb faster/higher than
    sev_off runs at the same elapsed time."""
    fig, ax = plt.subplots(figsize=(9, 4))
    any_data = False
    for label, run in runs_data:
        df = run.get(f"{side}_mem_probe")
        if df is None or df["rss_kb"].dropna().empty:
            continue
        ax.plot(df["elapsed_s"], df["rss_kb"] / 1024.0, label=label, linewidth=1.2, marker=".")
        any_data = True
    if not any_data:
        plt.close(fig)
        return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("RSS (MB)")
    ax.set_title(f"{side.capitalize()}-side ada process RSS over time")
    ax.legend()
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_majflt_time_series(runs_data: list[tuple[str, dict]], side: str, out_path: Path | None = None) -> None:
    """Cumulative major page faults over time -- major faults specifically
    (as opposed to minor faults) mean the kernel had to go to disk/swap,
    the clearest available signal that memory pressure turned into real
    thrashing rather than just elevated-but-comfortable RSS."""
    fig, ax = plt.subplots(figsize=(9, 4))
    any_data = False
    for label, run in runs_data:
        df = run.get(f"{side}_mem_probe")
        if df is None or df["majflt"].dropna().empty:
            continue
        ax.plot(df["elapsed_s"], df["majflt"], label=label, linewidth=1.2, marker=".")
        any_data = True
    if not any_data:
        plt.close(fig)
        return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("Cumulative major page faults")
    ax.set_title(f"{side.capitalize()}-side major page faults over time (swap/thrashing signal)")
    ax.legend()
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_swiotlb_time_series(runs_data: list[tuple[str, dict]], out_path: Path | None = None) -> None:
    """Server-side SEV SWIOTLB DMA bounce-buffer pool usage over time
    (io_tlb_used, with io_tlb_used_hiwater as the running peak). Direct
    signal for whether the fixed-size bounce-buffer pool -- which *all*
    device DMA, including every network packet, must pass through under
    active AMD SEV since virtio_net can't DMA directly into encrypted guest
    memory -- is becoming a ceiling under load. Only meaningful server-side;
    the client is bare metal, no SEV/bounce-buffer concept applies."""
    fig, ax = plt.subplots(figsize=(9, 4))
    any_data = False
    for label, run in runs_data:
        df = run.get("server_mem_probe")
        if df is None or "swiotlb_used_slabs" not in df.columns or df["swiotlb_used_slabs"].dropna().empty:
            continue
        ax.plot(df["elapsed_s"], df["swiotlb_used_slabs"], label=f"{label} (used)", linewidth=1.2)
        ax.plot(df["elapsed_s"], df["swiotlb_hiwater_slabs"], label=f"{label} (hi-water)",
                linewidth=1.0, linestyle="--", alpha=0.6)
        any_data = True
    if not any_data:
        plt.close(fig)
        return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("SWIOTLB slabs in use")
    ax.set_title("Server SWIOTLB (SEV DMA bounce-buffer) pool usage over time")
    ax.legend(fontsize=8)
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


# ──────────────────────────────────────────────────────────────────────────────
# Console reporting
# ──────────────────────────────────────────────────────────────────────────────

def print_summary_table(summary: pd.DataFrame) -> None:
    if summary.empty:
        print("  (no data)")
        return
    pd.set_option("display.float_format", "{:.2f}".format)
    pd.set_option("display.max_columns", None)
    pd.set_option("display.width", 120)
    print(summary.to_string(index=False))


def print_run_info(label: str, run: dict) -> None:
    print(f"\n── Run: {label} ──────────────────────────────────────────────────")
    legs = run.get("legs", {})
    for leg, df in legs.items():
        n = len(df) if df is not None else 0
        print(f"  legs.{leg}: {n} rows")
    for k, df in run.items():
        if k == "legs":
            continue
        if isinstance(df, pd.DataFrame) and not df.empty:
            print(f"  {k}: {len(df)} rows")


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Analyze ILLIXR ada offload benchmark metrics",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Notes:")[1] if "Notes:" in __doc__ else "",
    )
    p.add_argument("--server", metavar="DIR", action="append", default=[],
                   help="Server-side result dir (ILLIXR_METRICS_DIR + recorded_data/, repeatable)")
    p.add_argument("--client", metavar="DIR", action="append", default=[],
                   help="Client-side result dir (ILLIXR_METRICS_DIR + recorded_data/, repeatable)")
    p.add_argument("--label", metavar="NAME", action="append", default=[],
                   help="Label for each run (must match count of --server/--client pairs)")
    p.add_argument("--warmup-s", type=float, default=2.0,
                   help="Seconds to trim from start of each run (default: 2 -- see module docstring)")
    p.add_argument("--out", metavar="DIR", default=None,
                   help="Output directory for plots (default: display interactively)")
    p.add_argument("--no-plots", action="store_true",
                   help="Skip plotting, print tables only")
    return p.parse_args()


def resolve_runs(args: argparse.Namespace) -> list[tuple[str, Path | None, Path | None]]:
    servers = [Path(d) for d in args.server]
    clients = [Path(d) for d in args.client]
    n = max(len(servers), len(clients))

    if n == 0:
        print("Error: specify at least one --server or --client directory.", file=sys.stderr)
        sys.exit(1)

    servers = servers + [None] * (n - len(servers))
    clients = clients + [None] * (n - len(clients))
    labels = args.label + [f"run{i}" for i in range(len(args.label), n)]

    if len(labels) != n:
        print(f"Error: got {len(args.label)} --label(s) but {n} run(s).", file=sys.stderr)
        sys.exit(1)

    return list(zip(labels, servers, clients))


def main() -> None:
    args = parse_args()
    runs_spec = resolve_runs(args)

    out_dir: Path | None = None
    if args.out and not args.no_plots:
        out_dir = Path(args.out)
        out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {len(runs_spec)} run(s), warmup={args.warmup_s}s ...")
    runs_data: list[tuple[str, dict]] = []
    for label, server_dir, client_dir in runs_spec:
        print(f"  [{label}]  server={server_dir}  client={client_dir}")
        run = load_run(server_dir, client_dir, args.warmup_s)
        print_run_info(label, run)
        runs_data.append((label, run))

    print("\n\n═══ Latency summary (ms) ═══════════════════════════════════════════")
    all_summaries = [summarise_latency(run, label) for label, run in runs_data]
    summary = pd.concat([s for s in all_summaries if not s.empty], ignore_index=True) \
        if any(not s.empty for s in all_summaries) else pd.DataFrame()
    print_summary_table(summary)

    if args.no_plots:
        return

    def out(name: str) -> Path | None:
        return out_dir / name if out_dir else None

    print("\nGenerating plots ...")

    plot_leg_cdf(runs_data, "end_to_end", "end_to_end_ms",
                 "Offload round-trip latency CDF (send -> mesh ready)", "ms",
                 out("cdf_end_to_end.png"))
    plot_leg_cdf(runs_data, "uplink", "uplink_latency_ms",
                 "Uplink latency CDF (capture -> server arrival)", "ms",
                 out("cdf_uplink.png"))
    plot_leg_cdf(runs_data, "server_compute", "server_compute_ms",
                 "Server compute CDF (arrival -> mesh sent)", "ms",
                 out("cdf_server_compute.png"))
    plot_leg_cdf(runs_data, "downlink", "downlink_latency_ms",
                 "Downlink latency CDF (server send -> client arrival)", "ms",
                 out("cdf_downlink.png"))
    plot_leg_cdf(runs_data, "client_display", "client_display_ms",
                 "Client display-ready CDF (arrival -> mesh ready)", "ms",
                 out("cdf_client_display.png"))

    if not summary.empty:
        plot_latency_breakdown_bar(summary, out("breakdown_bar.png"))

    plot_end_to_end_time_series(runs_data, out("timeseries_end_to_end.png"))
    plot_infinitam_breakdown(runs_data, out("infinitam_breakdown.png"))
    plot_tcp_rtt_cdf(runs_data, "client", out("cdf_tcp_rtt_client.png"))
    plot_tcp_rtt_cdf(runs_data, "server", out("cdf_tcp_rtt_server.png"))

    plot_rss_time_series(runs_data, "server", out("rss_server.png"))
    plot_rss_time_series(runs_data, "client", out("rss_client.png"))
    plot_majflt_time_series(runs_data, "server", out("majflt_server.png"))
    plot_swiotlb_time_series(runs_data, out("swiotlb_server.png"))

    if out_dir:
        print(f"\nAll plots saved to {out_dir}/")
    else:
        print("\nDisplayed all plots interactively.")


if __name__ == "__main__":
    main()
