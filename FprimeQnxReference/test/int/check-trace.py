#!/usr/bin/env python3
"""Check M2 evidence from the guest and report the measured scheduling window."""

import argparse
import csv
import math
import re
from pathlib import Path


def read_fields(log: str, prefix: str, count: int = 1) -> list[dict[str, str]]:
    lines = [line for line in log.splitlines() if line.startswith(f"{prefix} ")]
    require(len(lines) == count, f"expected {count} {prefix} lines, found {len(lines)}")
    return [dict(field.split("=", 1) for field in line.split()[1:]) for line in lines]


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def percentile(values: list[int], percentile_rank: float) -> int:
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * percentile_rank) - 1]


def check_restart(directory: Path, flight: dict[str, str], advisors: list[dict[str, str]],
                  replies: set[tuple[int, int, int]], samples: list[dict[str, str]]) -> None:
    run_log = (directory / "target-run.log").read_text(encoding="utf-8")
    crash, = read_fields(run_log, "CRASH")
    restart, = read_fields(run_log, "RESTART")
    require(crash["flight_pid"] == restart["flight_pid"] == flight["pid"], "flight PID changed")
    require(crash["advisor_pid"] == advisors[0]["pid"], "wrong advisor crash PID")
    require(restart["advisor_pid"] == advisors[1]["pid"], "wrong advisor restart PID")
    require(advisors[0]["client"] != advisors[1]["client"], "advisor client identity was reused")
    sessions = sorted({session for session, _, _ in replies})
    require(len(sessions) == 2, f"expected replies from two flight sessions, found {sessions}")

    active_sessions = [int(row["advisor_session"]) for row in samples]
    old, new = sessions
    last_old = max(index for index, session in enumerate(active_sessions) if session == old)
    first_new = active_sessions.index(new)
    require(first_new > last_old + 1 and active_sessions[last_old + 1:first_new] == [0] * (first_new - last_old - 1),
            "flight did not clear old advice before the replacement joined")
    print(f"slm old_session={old} new_session={new} cycles_without_advice={first_new - last_old - 1}")


def check(directory: Path, transport: str, fifo_priority: int = 30) -> None:
    flight_log = (directory / "flight.log").read_text(encoding="utf-8")
    advisor_log = (directory / "advisor.log").read_text(encoding="utf-8")
    flight, = read_fields(flight_log, "READY")
    advisors = read_fields(advisor_log, "READY", 2 if transport == "slm" else 1)
    totals, = read_fields(flight_log, "SUMMARY")
    pids = [flight["pid"], *(advisor["pid"] for advisor in advisors)]
    require(len(set(pids)) == len(pids), "processes used a repeated PID")
    expected_transport = "qnx" if transport == "slm" else transport
    require(all(entry["transport"] == expected_transport for entry in [flight, *advisors]), "unexpected transport")
    require(int(flight["fifo_priority"]) == fifo_priority, f"flight did not start at priority {fifo_priority}")
    require(int(totals["record_drops"]) == 0, "the timing logger lost records")

    period = int(flight["period_ns"])
    require(period == 20_000_000, "unexpected flight period")
    first_release = int(flight["first_release_ns"])
    expected = int(totals["last_cycle"])
    if transport == "slm":
        require(int(totals["expected"]) == 0 and expected >= 50, "wrong SLM time window")
    else:
        require(int(totals["expected"]) == expected == 200, "wrong time window")
    with (directory / "flight.csv").open(encoding="utf-8", newline="") as source:
        samples = list(csv.DictReader(source))
    require(
        [int(row["cycle_id"]) for row in samples] == list(range(1, expected + 1)),
        f"incomplete flight trace: {len(samples)} records for {expected} expected cycles",
    )

    latency = []
    observed_advice = set()
    drops = []
    for index, row in enumerate(samples):
        release, start, finish = (int(row[name]) for name in ("release_ns", "start_ns", "finish_ns"))
        require(release == first_release + index * period, f"phase mismatch at cycle {index + 1}")
        require(release <= start <= finish, f"timestamp order at cycle {index + 1}")
        require(row["valid"] == "1", f"no valid ADCS estimate at cycle {index + 1}")
        length = math.hypot(float(row["sun_x"]), float(row["sun_y"]), float(row["sun_z"]))
        require(abs(length - 1.0) < 1e-5, f"unnormalized estimate at cycle {index + 1}")
        latency.append(finish - release)
        drops.append(int(row["snapshot_drops"]))
        if int(row["advisor_session"]) != 0:
            observed_advice.add((int(row["advisor_session"]), int(row["advisor_cycle"]), int(row["advisor_alert"])))

    replies = {
        (int(session), int(cycle), int(alert))
        for session, cycle, alert in re.findall(
            r"^RESULT session=(\d+) cycle=(\d+) alert=([01])$", advisor_log, re.MULTILINE
        )
    }
    require(replies and replies <= observed_advice, "an advisor result did not match a flight trace entry")
    require(int(totals["accepted"]) >= len(replies), "advisor logged an unaccepted reply")
    require(drops == sorted(drops), "the cumulative drop counter decreased")
    if transport == "slm":
        check_restart(directory, flight, advisors, replies, samples)
    else:
        require(drops[25] > 0, "the startup backlog was not exercised")
        last_reply = max(cycle for _, cycle, _ in replies)
        require(expected > last_reply + 15, "flight did not keep running after the advisor stopped")
        require(samples[-1]["advisor_session"] == "0", "stale advice remained active")

    deadline_misses = sum(delay > period for delay in latency)
    advisor_pids = ",".join(pids[1:])
    print(f"{transport} flight_pid={flight['pid']} advisor_pids={advisor_pids} cycles={len(samples)}/{expected}")
    print(f"{transport} replies={len(replies)} correlated={len(observed_advice & replies)} snapshot_drops={drops[-1]}")
    print(
        f"{transport} release_to_commit_p50_ns={percentile(latency, 0.50)} "
        f"p99_ns={percentile(latency, 0.99)} max_ns={max(latency)} observed_deadline_misses={deadline_misses}"
    )
    require(deadline_misses == 0, "the M2 smoke run missed a deadline")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("transport", choices=("udp", "qnx", "slm"))
    parser.add_argument("--fifo-priority", type=int, default=30)
    args = parser.parse_args()
    try:
        check(args.directory, args.transport, args.fifo_priority)
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"M2 evidence check failed: {error}\n")


if __name__ == "__main__":
    main()
