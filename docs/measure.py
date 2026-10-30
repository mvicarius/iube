#!/usr/bin/env python3
"""Measure iube window open time and peak RSS on Hyprland.

Usage:
    python3 docs/measure.py [path-to-iube]

The default binary is zig-out/bin/iube. The script uses Hyprland's IPC socket
directly, so it does not pay for a hyprctl process on every poll.
"""

import json
import os
import socket
import statistics
import subprocess
import sys
import time

DEFAULT_BIN = os.path.join(os.path.dirname(os.path.dirname(__file__)), "zig-out/bin/iube")
RUNS = 5
WARMUP_RUNS = 1
MAP_TIMEOUT = 2.0
SETTLE_SECONDS = 0.5


def hypr_socket() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if not runtime or not signature:
        raise SystemExit("XDG_RUNTIME_DIR and HYPRLAND_INSTANCE_SIGNATURE are required")
    return f"{runtime}/hypr/{signature}/.socket.sock"


def get_layers() -> dict:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(1.0)
    try:
        sock.connect(hypr_socket())
        sock.sendall(b"j/layers")
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        return json.loads(b"".join(chunks))
    finally:
        sock.close()


def layer_mapped(pid: int) -> bool:
    layers = get_layers()
    for monitor in layers.values():
        for entries in monitor.get("levels", {}).values():
            for entry in entries:
                if entry.get("namespace") == "iube" and entry.get("pid") == pid:
                    return True
    return False


def measure(binary: str, args: list[str]) -> tuple[float, float]:
    started = time.perf_counter()
    proc = subprocess.Popen(
        [binary, *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    mapped_at = None
    try:
        while time.perf_counter() - started < MAP_TIMEOUT:
            if layer_mapped(proc.pid):
                mapped_at = time.perf_counter()
                break
            if proc.poll() is not None:
                raise RuntimeError(f"iube {' '.join(args) or '(panel)'} exited before mapping")
            time.sleep(0.002)
        if mapped_at is None:
            raise RuntimeError(f"iube {' '.join(args) or '(panel)'} did not map within {MAP_TIMEOUT}s")

        # Let the first frame, icon decoding and initial layout settle. Peak RSS
        # comes from wait4, so this delay mostly makes the reported peak stable.
        time.sleep(SETTLE_SECONDS)
        proc.terminate()
        _, _, usage = os.wait4(proc.pid, 0)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    open_ms = (mapped_at - started) * 1000.0
    rss_mb = usage.ru_maxrss / 1024.0
    return open_ms, rss_mb


def main() -> None:
    binary = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BIN
    if not os.path.isfile(binary):
        raise SystemExit(f"binary not found: {binary}")

    commands = [
        ("iube", []),
        ("iube launch", ["launch"]),
        ("iube audio", ["audio"]),
        ("iube bluetooth", ["bluetooth"]),
        ("iube wifi", ["wifi"]),
        ("iube power", ["power"]),
        ("iube brightness", ["brightness"]),
    ]

    print("| Command | Open (median) | Peak RSS |")
    print("| --- | ---: | ---: |")
    for label, args in commands:
        for _ in range(WARMUP_RUNS):
            measure(binary, args)

        open_times = []
        peak_rss = 0.0
        for _ in range(RUNS):
            open_ms, rss_mb = measure(binary, args)
            open_times.append(open_ms)
            peak_rss = max(peak_rss, rss_mb)

        print(f"| `{label}` | {statistics.median(open_times):.1f} ms | {peak_rss:.1f} MB |")


if __name__ == "__main__":
    main()
