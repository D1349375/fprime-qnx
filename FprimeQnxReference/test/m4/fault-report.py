#!/usr/bin/env python3
"""Summarize the existing M3 and M4 verdicts and raw timing for the paired ADCS run."""

import argparse
import csv
import json
import runpy
from pathlib import Path


m3 = runpy.run_path(str(Path(__file__).resolve().parents[1] / "int/check-m3.py"))
fields = m3["fields"]
read_flight = m3["read_flight"]
percentiles = m3["percentiles"]
NA = "—"


def tsv(path):
    with path.open(encoding="utf-8", newline="") as source:
        return list(csv.DictReader(source, delimiter="\t"))


def read_text(path):
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def millis(ns):
    return NA if ns is None else f"{ns / 1_000_000:.3f}"


def release_counts(rows, expected, deadline):
    delays = [row["finish_ns"] - row["release_ns"] for row in rows if row["submitted"]]
    missing = expected - len(rows)
    unsubmitted = len(rows) - len(delays)
    late = sum(delay > deadline for delay in delays)
    return {
        "missing": missing, "unsubmitted": unsubmitted, "late": late, "submitted": len(delays),
        "valid": sum(row["submitted"] and row["valid"] for row in rows),
        "misses": missing + unsubmitted + late, "latency": percentiles(delays),
    }


def timing_facts(directory):
    events, bounds = {}, {}
    for line in read_text(directory / "timing.txt").splitlines():
        if line.startswith(("fallback_ns ", "rejoin_ns ")):
            stamps = fields(line)
            bounds[line.split()[0]] = int(stamps["min"]), int(stamps["max"])
        else:
            events.update(fields(line))
    return events, bounds


def interval(bounds):
    return f"{millis(bounds[0])}–{millis(bounds[1])}" if bounds else NA


def read_case(directory, verdict):
    config = fields(read_text(directory / "config.txt"))
    events, bounds = timing_facts(directory)
    expected = int(config["cycles"])
    period, deadline = (int(config[key]) for key in ("period_ns", "deadline_ns"))
    crash = int(events["injection_ns"]) if "injection_ns" in events else None
    result = {"events": events, "bounds": bounds, "expected": expected,
              "phase": NA, "counts": None, "incomplete": False, "relative_crash": None,
              "restart": NA, "session": NA, "adoption": NA}
    try:
        ready, _, rows, _ = read_flight(directory, expected, period)
        first_release = int(ready["first_release_ns"])
        result["counts"] = release_counts(rows, expected, deadline)
        if crash is not None:
            before = len(range(first_release, min(crash, first_release + expected * period), period))
            pre = release_counts([row for row in rows if row["cycle_id"] <= before], before, deadline)
            post = release_counts([row for row in rows if row["cycle_id"] > before], expected - before, deadline)
            result["phase"] = f"{pre['misses']}/{before} / {post['misses']}/{expected - before}"
            result["relative_crash"] = crash - first_release
    except (OSError, ValueError, KeyError, IndexError):
        result["incomplete"] = True

    new_pid = events.get("advisor_pid_after")
    if crash is not None and new_pid:
        starts = [fields(line) for line in read_text(directory / "advisor.log").splitlines() if line.startswith("READY ")]
        entry = int(next((row.get("main_entry_ns", "0") for row in starts if row["pid"] == new_pid), "0"))
        ready_ns = int(events["advisor_start_ns"])
        entry_ms = millis(entry - crash) if crash <= entry <= ready_ns else NA
        result["restart"] = f"{new_pid} at {entry_ms} entry / {millis(ready_ns - crash)} ready"
        result["session"] = f"{events['new_session']} at {millis(int(events['session_ns']) - crash)}"
        try:
            replay = json.loads(read_text(directory / "adcs.json"))
        except json.JSONDecodeError:
            replay = {}
        gate = int(events["first_valid_result_ns"])
        adoption = next((record for record in replay.get("verified_rejoins", []) if
                         record["gate_ns"] == gate and str(record["session"]) == events["new_session"]), None)
        measured = interval(bounds.get("rejoin_ns"))
        if adoption:
            result["adoption"] = (
                f"{measured} · flight {adoption['flight_cycle']}, snapshot {adoption['snapshot_cycle']}, "
                f"score {adoption['live_score']:.9g} (replay matched, alert {adoption['alert']})"
            )
        else:
            result["adoption"] = f"{measured} · replay match unavailable"
    elif crash is not None and verdict["timing_exit"] == "0" and events.get("rejoin") == "not-observed":
        observed = millis(int(events["observation_end_ns"]) - crash)
        result["adoption"] = f"Not observed in {observed} ms"
    return result


def table(headers, rows):
    def line(row):
        return "| " + " | ".join(map(str, row)) + " |"

    print(line(headers))
    print(line(["---"] * len(headers)))
    for row in rows:
        print(line(row))
    print()


def raw_links(directory, run_id):
    names = ("config.txt", "target.log", "flight.csv", "link.csv", "advisor.log", "death.csv", "slm.log",
             "m3-slm.xml", "timing.txt", "adcs.json", "adcs.err", "trace.kev", "trace-anchor.txt",
             "trace-status.txt", "tracelogger.log", "trace-control.log")
    return " · ".join(f"[{name}]({run_id}/{name})" for name in names if (directory / name).is_file())


def report(run):
    outcomes, pairs = tsv(run / "results.tsv"), tsv(run / "pairs.tsv")
    cases = {row["run_id"]: read_case(run / row["run_id"], row) for row in outcomes}
    verdicts = {row["run_id"]: row["verdict"] for row in outcomes}
    revisions = read_text(run / "source.txt").splitlines()
    weights = (run / "replay" / "input.sha256").read_text().splitlines()[0].split()[0]
    target = read_text(run / "target-uname.txt").strip()

    print("# ADCS fault benchmark\n")
    print(f"- Source commit `{revisions[0]}`")
    print(f"- Target `{target}`")
    print(f"- FFN weights SHA-256 `{weights}`")
    print(f"- {len(pairs)} pairs on one QNX guest with one frozen model and a 20 ms period and deadline")
    print("- [SDK packages, compiler and submodules](source.txt) · [VM arguments](qemu-argv.txt) · "
          "[Image](image.sha256) · [Executables](binaries.sha256) · [Training configuration](replay/training.json) · "
          "[Replay comparison](replay/summary.txt) · [Model and replay manifest](replay/input.sha256)")
    print("- [Original checker verdicts and exit codes](results.tsv) · [Pair configurations](pairs.tsv)\n")

    timing, recovery = [], []
    for verdict in outcomes:
        run_id = verdict["run_id"]
        case = cases[run_id]
        counts = case["counts"]
        latency = " / ".join(millis(counts["latency"].get(name)) for name in ("p50", "p99", "max")) if counts else NA
        commits = f"{counts['submitted']} ({counts['valid']} valid)" if counts else NA
        timing.append((run_id, verdict["verdict"], case["expected"], commits,
                       *(counts[name] if counts else NA for name in ("missing", "unsubmitted", "late")),
                       latency, case["phase"]))
        events = case["events"]
        fallback = case["bounds"].get("fallback_ns")
        fdir = f"{events['fdir_cycle']} · {events['fallback_reason']} · {interval(fallback)}" if fallback else NA
        expiry_to_commit = NA
        if events.get("fallback_reason") == "RESULT_TIMEOUT" and int(events.get("last_advisor_sample_ns", "0")) > 0:
            expiry_to_commit = millis(int(events["fdir_commit_ns"]) - int(events["last_sample_expiry_ns"]))
        recovery.append((run_id, events.get("flight_pid", NA), events.get("advisor_pid", NA),
                         events.get("old_session", NA), events.get("injection_cycle", NA),
                         millis(case["relative_crash"]),
                         fdir, expiry_to_commit, case["restart"], case["session"], case["adoption"]))

    print("## 20 ms deadline\n")
    print("The denominator includes every scheduled release. Missing releases, failed submissions and "
          "late commits each count once. Latencies are nearest-rank release-to-commit values for submitted rows. "
          "Releases before the recorded injection belong to the first window.\n")
    table(("Round", "Verdict", "Expected", "Submitted", "Missing", "Unsubmitted", "Late",
           "p50 / p99 / max (ms)", "Misses before / from injection"), timing)

    print("## Repair-policy pairs\n")
    print("Both arms use cycle 55 as the fixed injection threshold. The advisor injects SIGKILL "
          "when its polling loop first receives an eligible snapshot. Measured offsets are relative "
          "to each arm's first scheduled release.\n")
    comparisons = []
    for pair in pairs:
        q1, q2 = cases[pair["q1"]], cases[pair["q2"]]
        snapshot = f"{q1['events'].get('injection_cycle', NA)} / {q2['events'].get('injection_cycle', NA)}"
        c1, c2 = q1["relative_crash"], q2["relative_crash"]
        delta = millis(c1 - c2) if c1 is not None and c2 is not None else NA
        comparisons.append((pair["pair"], pair["seed"], pair["first"], pair["slm_config"], snapshot, delta,
                            verdicts[pair["q1"]], verdicts[pair["q2"]]))
    table(("Pair", "Seed", "First arm", "SLM XML comparison", "Crash snapshot Q1 / Q2",
           "Crash offset Q1 − Q2 (ms)", "Q1 verdict", "Q2 verdict"), comparisons)

    print("## FDIR and advisor recovery\n")
    print("FDIR and rejoin ranges use the recorded injection and the earliest observed exit as "
          "bounds on fault onset. Advisor main entry, readiness and session offsets are from injection. "
          "Main entry is the first application timestamp in the new PID. The rejoin matches the "
          "new session's first inference adopted by FlightSW to the offline replay.\n")
    table(("Round", "Flight PID", "Old advisor PID", "Old session", "Crash snapshot",
           "Crash from first release (ms)",
           "FDIR cycle · reason · bounds (ms)", "Expiry to FDIR commit (ms)", "New advisor PID / ms",
           "New session / ms", "First accepted inference · bounds (ms)"), recovery)

    print("## Raw guest timeline and trace\n")
    for verdict in outcomes:
        run_id = verdict["run_id"]
        directory = run / run_id
        trace = read_text(directory / "trace-status.txt").strip()
        print(f"- **{run_id}** {raw_links(directory, run_id)}")
        if trace:
            print(f"  - Ring export `{trace}`")
        if cases[run_id]["incomplete"]:
            print(f"  - Flight timing evidence incomplete. See [{run_id}/timing.txt]({run_id}/timing.txt).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    report(parser.parse_args().directory)


if __name__ == "__main__":
    main()
