#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "pandas",
#   "matplotlib",
#   "scipy",
# ]
# ///
"""
ILLIXR offload_vio benchmark analysis script.

Usage — single run:
    uv run scripts/analyze_metrics.py \\
        --server metrics_server --client metrics_client --label baseline

Usage — SEV on vs off comparison:
    uv run scripts/analyze_metrics.py \\
        --server runs/sev_on/server   --client runs/sev_on/client   --label sev_on \\
        --server runs/sev_off/server  --client runs/sev_off/client  --label sev_off \\
        --out plots/

Notes:
  - server dir  = ILLIXR_METRICS_DIR for the offload_vio.server_rx / openvins process
  - client dir  = ILLIXR_METRICS_DIR for the offload_vio.device_rx / device_tx process
  - Either dir may be omitted (e.g. for runs where only one side produced data)
  - Warm-up trimming: the first --warmup-s seconds of each run are dropped before
    computing statistics. Defaults to 10s.
  - Wall-time columns in threadloop_iteration / switchboard_callback use
    std::chrono::high_resolution_clock, which is process-relative on Linux
    (CLOCK_MONOTONIC). They are useful for within-run durations but NOT for
    cross-machine subtraction. Only uplink_latency_ms / downlink_latency_ms
    (computed with system_clock on both ends) are valid cross-machine.
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


# ──────────────────────────────────────────────────────────────────────────────
# Data loading helpers
# ──────────────────────────────────────────────────────────────────────────────

def _load_table(db_path: Path, table: str, extra_cols: str = "*") -> pd.DataFrame | None:
    if not db_path.exists():
        return None
    try:
        con = sqlite3.connect(db_path)
        df = pd.read_sql(f"SELECT {extra_cols} FROM {table}", con)
        con.close()
        return df
    except Exception as e:
        print(f"  [warn] {db_path}: {e}", file=sys.stderr)
        return None


def load_plugin_names(metrics_dir: Path) -> dict[int, str]:
    df = _load_table(metrics_dir / "plugin_name.sqlite", "plugin_name")
    if df is None or df.empty:
        return {}
    return dict(zip(df["plugin_id"], df["plugin_name"]))


def load_uplink(metrics_dir: Path, warmup_s: float) -> pd.DataFrame | None:
    """offload_vio_uplink from the server-side metrics dir."""
    df = _load_table(metrics_dir / "offload_vio_uplink.sqlite", "offload_vio_uplink")
    if df is None or df.empty:
        return None
    # real_timestamp is wall-clock nanoseconds (system_clock); sort and trim warmup
    df = df.sort_values("real_timestamp").reset_index(drop=True)
    t0 = df["real_timestamp"].iloc[0]
    df = df[df["real_timestamp"] - t0 >= warmup_s * 1e9].copy()
    df["elapsed_s"] = (df["real_timestamp"] - t0) / 1e9
    return df


def load_downlink(metrics_dir: Path, warmup_s: float) -> pd.DataFrame | None:
    """offload_vio_downlink from the client-side metrics dir."""
    df = _load_table(metrics_dir / "offload_vio_downlink.sqlite", "offload_vio_downlink")
    if df is None or df.empty:
        return None
    df = df.sort_values("end_server_timestamp").reset_index(drop=True)
    t0 = df["end_server_timestamp"].iloc[0]
    df = df[df["end_server_timestamp"] - t0 >= warmup_s * 1e9].copy()
    df["elapsed_s"] = (df["end_server_timestamp"] - t0) / 1e9
    return df


def load_switchboard_callbacks(metrics_dir: Path, warmup_s: float,
                                plugin_names: dict[int, str]) -> pd.DataFrame | None:
    """switchboard_callback — all scheduled callbacks, including OpenVINS feed_imu_cam."""
    df = _load_table(metrics_dir / "switchboard_callback.sqlite", "switchboard_callback")
    if df is None or df.empty:
        return None
    df["plugin_name"] = df["plugin_id"].map(plugin_names).fillna(df["plugin_id"].astype(str))
    # wall_time_start is high_resolution_clock nanoseconds (process-relative epoch)
    df = df.sort_values("wall_time_start").reset_index(drop=True)
    t0 = df["wall_time_start"].iloc[0]
    df = df[df["wall_time_start"] - t0 >= warmup_s * 1e9].copy()
    df["wall_duration_ms"] = (df["wall_time_stop"] - df["wall_time_start"]) / 1e6
    df["cpu_duration_ms"] = (df["cpu_time_stop"] - df["cpu_time_start"]) / 1e6
    return df


def load_threadloop(metrics_dir: Path, warmup_s: float,
                    plugin_names: dict[int, str]) -> pd.DataFrame | None:
    """threadloop_iteration — per-plugin iteration timing."""
    df = _load_table(metrics_dir / "threadloop_iteration.sqlite", "threadloop_iteration")
    if df is None or df.empty:
        return None
    df["plugin_name"] = df["plugin_id"].map(plugin_names).fillna(df["plugin_id"].astype(str))
    df = df.sort_values("wall_time_start").reset_index(drop=True)
    t0 = df["wall_time_start"].iloc[0]
    df = df[df["wall_time_start"] - t0 >= warmup_s * 1e9].copy()
    df["wall_duration_ms"] = (df["wall_time_stop"] - df["wall_time_start"]) / 1e6
    df["cpu_duration_ms"] = (df["cpu_time_stop"] - df["cpu_time_start"]) / 1e6
    return df


def load_run(server_dir: Path | None, client_dir: Path | None,
             warmup_s: float) -> dict:
    """Load all relevant tables for one (server_dir, client_dir) pair."""
    run: dict = {}

    if server_dir:
        names_s = load_plugin_names(server_dir)
        run["server_plugin_names"] = names_s
        run["uplink"] = load_uplink(server_dir, warmup_s)
        run["server_callbacks"] = load_switchboard_callbacks(server_dir, warmup_s, names_s)
        run["server_threadloop"] = load_threadloop(server_dir, warmup_s, names_s)

    if client_dir:
        names_c = load_plugin_names(client_dir)
        run["client_plugin_names"] = names_c
        run["downlink"] = load_downlink(client_dir, warmup_s)
        run["client_callbacks"] = load_switchboard_callbacks(client_dir, warmup_s, names_c)
        run["client_threadloop"] = load_threadloop(client_dir, warmup_s, names_c)

    return run


# ──────────────────────────────────────────────────────────────────────────────
# Statistic helpers
# ──────────────────────────────────────────────────────────────────────────────

def percentile_table(series: pd.Series, label: str) -> pd.DataFrame:
    pcts = {f"p{p}": np.nanpercentile(series.dropna(), p) for p in PERCENTILES}
    return pd.DataFrame([{
        "metric": label,
        "n": int(series.notna().sum()),
        "mean": series.mean(),
        **pcts,
    }])


def summarise_latency(run: dict, label: str) -> pd.DataFrame:
    rows = []
    if run.get("uplink") is not None:
        rows.append(percentile_table(run["uplink"]["uplink_latency_ms"], "uplink_ms"))

    if run.get("downlink") is not None:
        rows.append(percentile_table(run["downlink"]["downlink_latency_ms"], "downlink_ms"))

    # OpenVINS compute from switchboard callbacks on "imu" topic (slam2::feed_imu_cam)
    cb = run.get("server_callbacks")
    if cb is not None:
        imu_cb = cb[cb["topic_name"] == "imu"]
        if not imu_cb.empty:
            rows.append(percentile_table(imu_cb["wall_duration_ms"], "openvins_wall_ms"))
            rows.append(percentile_table(imu_cb["cpu_duration_ms"],  "openvins_cpu_ms"))

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


def plot_cdf(runs_data: list[tuple[str, dict]], col: str, source: str,
             title: str, xlabel: str, out_path: Path | None = None) -> None:
    fig, ax = plt.subplots(figsize=(7, 4))
    any_data = False
    for label, run in runs_data:
        df = run.get(source)
        if df is None or col not in df.columns:
            continue
        x, y = _cdf(df[col])
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


def plot_switchboard_cdf(runs_data: list[tuple[str, dict]], topic: str,
                          col: str, title: str, xlabel: str,
                          out_path: Path | None = None) -> None:
    """CDF for a specific switchboard topic (e.g. OpenVINS on 'imu')."""
    fig, ax = plt.subplots(figsize=(7, 4))
    any_data = False
    for label, run in runs_data:
        cb = run.get("server_callbacks")
        if cb is None:
            continue
        series = cb[cb["topic_name"] == topic][col]
        if series.empty:
            continue
        x, y = _cdf(series)
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
    """Stacked mean-latency bar chart: uplink + openvins + downlink per run."""
    if summary_df.empty:
        return
    pivot = summary_df.pivot(index="run", columns="metric", values="mean")
    # Keep only these three if present; others go into per-plugin table
    cols = [c for c in ["uplink_ms", "openvins_wall_ms", "downlink_ms"] if c in pivot.columns]
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


def plot_time_series(runs_data: list[tuple[str, dict]], out_path: Path | None = None) -> None:
    """Rolling-median latency over time, to spot warm-up, drift, or burst patterns."""
    fig, axes = plt.subplots(2, 1, figsize=(9, 6), sharex=False)
    ax_up, ax_dn = axes

    window = 20  # frames

    any_up, any_dn = False, False
    for label, run in runs_data:
        if run.get("uplink") is not None:
            up = run["uplink"].sort_values("elapsed_s")
            rolled = up["uplink_latency_ms"].rolling(window, min_periods=1).median()
            ax_up.plot(up["elapsed_s"], rolled, label=label, linewidth=1.2)
            any_up = True
        if run.get("downlink") is not None:
            dn = run["downlink"].sort_values("elapsed_s")
            rolled = dn["downlink_latency_ms"].rolling(window, min_periods=1).median()
            ax_dn.plot(dn["elapsed_s"], rolled, label=label, linewidth=1.2)
            any_dn = True

    if any_up:
        ax_up.set_ylabel("Uplink latency (ms)")
        ax_up.set_title(f"Rolling median ({window}-frame window) over time")
        ax_up.legend()
    if any_dn:
        ax_dn.set_ylabel("Downlink latency (ms)")
        ax_dn.set_xlabel("Elapsed time (s)")
        ax_dn.legend()

    if not (any_up or any_dn):
        plt.close(fig)
        return

    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_per_plugin_threadloop(runs_data: list[tuple[str, dict]], side: str,
                                out_path: Path | None = None) -> None:
    """Box plots of per-plugin threadloop wall duration, for one side (server/client)."""
    key = f"{side}_threadloop"
    fig, ax = plt.subplots(figsize=(10, 5))
    all_data, all_labels = [], []
    for label, run in runs_data:
        tl = run.get(key)
        if tl is None:
            continue
        for pname, grp in tl.groupby("plugin_name"):
            all_data.append(grp["wall_duration_ms"].dropna().values)
            all_labels.append(f"{label}\n{pname}")
    if not all_data:
        plt.close(fig)
        return
    ax.boxplot(all_data, labels=all_labels, showfliers=False, patch_artist=True)
    ax.set_ylabel("Wall duration per iteration (ms)")
    ax.set_title(f"Per-plugin iteration latency — {side}")
    plt.xticks(rotation=30, ha="right")
    fig.tight_layout()
    if out_path:
        fig.savefig(out_path)
        print(f"  saved {out_path}")
    else:
        plt.show()
    plt.close(fig)


def plot_payload_throughput(runs_data: list[tuple[str, dict]], out_path: Path | None = None) -> None:
    """Effective throughput (MB/s) from payload size / latency."""
    fig, axes = plt.subplots(1, 2, figsize=(10, 4))
    for ax, (source, lat_col, label_prefix) in zip(axes, [
        ("uplink",   "uplink_latency_ms",   "Uplink"),
        ("downlink", "downlink_latency_ms",  "Downlink"),
    ]):
        any_data = False
        for run_label, run in runs_data:
            df = run.get(source)
            if df is None or "payload_bytes" not in df.columns:
                continue
            mb = df["payload_bytes"] / (1024 * 1024)
            lat_s = df[lat_col] / 1000.0
            throughput = mb / lat_s.replace(0, np.nan)
            x, y = _cdf(throughput)
            ax.plot(x, y, label=run_label, linewidth=1.8)
            any_data = True
        if any_data:
            ax.set_xlabel("Throughput (MB/s)")
            ax.set_ylabel("CDF")
            ax.set_title(f"{label_prefix} effective throughput")
            ax.legend()
            ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
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


def print_topic_breakdown(runs_data: list[tuple[str, dict]]) -> None:
    """Per-topic switchboard callback stats from the server side."""
    for label, run in runs_data:
        cb = run.get("server_callbacks")
        if cb is None:
            continue
        print(f"\n  Server switchboard callbacks [{label}]:")
        rows = []
        for topic, grp in cb.groupby("topic_name"):
            rows.append({
                "topic": topic,
                "n": len(grp),
                "wall_p50": np.percentile(grp["wall_duration_ms"], 50),
                "wall_p95": np.percentile(grp["wall_duration_ms"], 95),
                "wall_p99": np.percentile(grp["wall_duration_ms"], 99),
                "cpu_p50":  np.percentile(grp["cpu_duration_ms"],  50),
                "cpu_p95":  np.percentile(grp["cpu_duration_ms"],  95),
            })
        print(pd.DataFrame(rows).to_string(index=False))


def print_run_info(label: str, run: dict) -> None:
    print(f"\n── Run: {label} ──────────────────────────────────────────────────")
    for k, df in run.items():
        if isinstance(df, pd.DataFrame) and not df.empty:
            print(f"  {k}: {len(df)} rows")
        elif isinstance(df, dict):
            pass  # plugin_names dict, skip


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Analyze ILLIXR offload_vio benchmark metrics",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Notes:")[1] if "Notes:" in __doc__ else "",
    )
    p.add_argument("--server", metavar="DIR", action="append", default=[],
                   help="Server-side ILLIXR_METRICS_DIR (repeatable, one per run)")
    p.add_argument("--client", metavar="DIR", action="append", default=[],
                   help="Client-side ILLIXR_METRICS_DIR (repeatable, one per run)")
    p.add_argument("--label", metavar="NAME", action="append", default=[],
                   help="Label for each run (must match count of --server/--client pairs)")
    p.add_argument("--warmup-s", type=float, default=10.0,
                   help="Seconds to trim from start of each run (default: 10)")
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

    # Pad shorter list with None
    servers = servers + [None] * (n - len(servers))
    clients = clients + [None] * (n - len(clients))
    labels  = args.label + [f"run{i}" for i in range(len(args.label), n)]

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

    # ── Summary percentile table ──────────────────────────────────────────────
    print("\n\n═══ Latency summary (ms) ═══════════════════════════════════════════")
    all_summaries = [summarise_latency(run, label) for label, run in runs_data]
    summary = pd.concat([s for s in all_summaries if not s.empty], ignore_index=True)
    print_summary_table(summary)

    # ── Per-topic switchboard breakdown ───────────────────────────────────────
    print_topic_breakdown(runs_data)

    if args.no_plots:
        return

    # ── Plots ─────────────────────────────────────────────────────────────────
    def out(name: str) -> Path | None:
        return out_dir / name if out_dir else None

    print("\nGenerating plots ...")

    plot_cdf(runs_data, "uplink_latency_ms", "uplink",
             "Uplink latency CDF (capture → server arrival)", "ms",
             out("cdf_uplink.png"))

    plot_cdf(runs_data, "downlink_latency_ms", "downlink",
             "Downlink latency CDF (server send → client arrival)", "ms",
             out("cdf_downlink.png"))

    plot_switchboard_cdf(runs_data, "imu", "wall_duration_ms",
                         "OpenVINS per-frame wall time CDF", "ms",
                         out("cdf_openvins_wall.png"))

    plot_switchboard_cdf(runs_data, "imu", "cpu_duration_ms",
                         "OpenVINS per-frame CPU time CDF", "ms",
                         out("cdf_openvins_cpu.png"))

    if not summary.empty:
        plot_latency_breakdown_bar(summary, out("breakdown_bar.png"))

    plot_time_series(runs_data, out("timeseries.png"))

    plot_payload_throughput(runs_data, out("throughput_cdf.png"))

    plot_per_plugin_threadloop(runs_data, "server", out("threadloop_server.png"))
    plot_per_plugin_threadloop(runs_data, "client", out("threadloop_client.png"))

    if out_dir:
        print(f"\nAll plots saved to {out_dir}/")
    else:
        print("\nDisplayed all plots interactively.")


if __name__ == "__main__":
    main()
