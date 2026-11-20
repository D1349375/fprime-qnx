#!/usr/bin/env python3
"""Tie each learned advisor packet and closed-loop decision to the held-out replay."""

import argparse
import csv
import json
from pathlib import Path
import runpy
import sys

from compare import Prediction, read_predictions, score_close


m3 = runpy.run_path(str(Path(__file__).resolve().parents[1] / "int/check-m3.py"))
fields = m3["fields"]
angle_error = m3["angle_error"]
csv_rows = m3["csv_rows"]


def assess(replay, directory):
    config = dict(line.split("=", 1) for line in (directory / "config.txt").read_text().splitlines())
    group, seed, mode = config["group"], config["seed"], config["advisor"]
    bias = int(config["scenario"] != "normal")
    count = int(config["cycles"])
    inject = int(config["injection_cycle"])
    angle_limit = float(config["angle_limit_deg"])
    stable_cycles = int(config["stable_cycles"])
    sensors = [f"s{i}" for i in range(6)]
    frame_ints = ("cycle_id", "start_ns", "finish_ns", "submitted", "valid", "sensor_fault", "excluded",
                  "fdir", "fdir_candidate", "advisor_session", "advisor_cycle", "checked_session",
                  "checked_cycle", "gate_ns", "fdir_gate_ns", "fdir_candidate_ns", "rejoin", "action", "channel",
                  *sensors)
    frames = list(csv_rows(directory / "flight.csv", {
        **dict.fromkeys(frame_ints, int),
        **dict.fromkeys(("sun_x", "sun_y", "sun_z", "truth_x", "truth_y", "truth_z"), float),
    }))
    with (replay / "adcs.csv").open(newline="", encoding="utf-8") as file:
        expected = {int(row["cycle"]): row for row in csv.DictReader(file)
                    if row["seed"] == seed and int(row["bias"]) == bias}
    if len(expected) != count or [row["cycle_id"] for row in frames] != list(range(1, count + 1)):
        raise ValueError("Incomplete or unordered scenario")
    for row in frames:
        reference = expected[row["cycle_id"]]
        if any(row[key] != int(reference[key]) for key in sensors):
            raise ValueError(f"Guest sensor fixture differs at cycle {row['cycle_id']}")
        candidate_ns = row["fdir_candidate_ns"]
        if (candidate_ns != 0) != (row["fdir_candidate"] >= 0) or (
                candidate_ns and not row["start_ns"] <= candidate_ns <= row["finish_ns"]):
            raise ValueError(f"Invalid FDIR detection timestamp at cycle {row['cycle_id']}")

    faults = [row for row in frames if row["sensor_fault"]]
    if [row["cycle_id"] for row in faults] != ([inject] if bias else []):
        raise ValueError("Sensor injection differs from the frozen scenario")

    predictions = read_predictions(replay / "qnx.csv")
    log = (directory / "advisor.log").read_text(encoding="utf-8").splitlines()
    exact_model_marker = "MODEL mlpack=4.7.0 schema=adcs-bias openblas_threads=1"
    expected_starts = 0 if mode == "fdir" else 2 if group == "q1" else 1
    if log.count(exact_model_marker) != expected_starts:
        raise ValueError("Unexpected number of initialized FFN instances")
    observed = {}
    for line in log:
        if line.startswith("RESULT "):
            entry = fields(line)
            session, cycle = int(entry["session"]), int(entry["cycle"])
            prediction = predictions.get(f"{seed}-{bias}-{cycle}")
            key = session, cycle
            if (not isinstance(prediction, Prediction) or key in observed or
                    not score_close(float(entry["score"]), prediction.score) or int(entry["alert"]) != prediction.label):
                raise ValueError(f"Live advisor inference differs from held-out replay at {key}")
            observed[key] = prediction
    if bool(observed) != (mode == "learned"):
        raise ValueError("The advisor result log does not match the requested mode")

    received = []
    expected_uses = 0
    for row in frames:
        checked = row["checked_session"], row["checked_cycle"]
        active = row["advisor_session"], row["advisor_cycle"]
        if row["gate_ns"] and checked == active and active[0] != 0:
            expected_uses += 1
            if checked not in observed:
                raise ValueError(f"Flight accepted a result without a matching model score: {checked}")
            prediction = observed[checked]
            if row["action"] != prediction.label or row["channel"] != 0:
                raise ValueError(f"Proposal does not match the learned decision: {checked}")
            received.append((row, prediction))
    if mode == "learned" and (not received or (group == "q1" and
            any((row["checked_session"], row["checked_cycle"]) not in observed for row in frames if row["rejoin"]))):
        raise ValueError("No verified live result, or a rejoin lacks model evidence")

    learned_false = sum(prediction.label and int(expected[row["checked_cycle"]]["label"]) == 0
                        for row, prediction in received)
    residual_false = sum(row["fdir_candidate"] >= 0 and int(expected[row["cycle_id"]]["label"]) == 0
                         for row in frames)
    approvals = [(row, source, row[timestamp]) for row in frames
                 for key, source, timestamp in (("gate", "learned", "gate_ns"), ("fdir_gate", "fdir", "fdir_gate_ns"))
                 if row[key] == "APPROVED"]
    changed = [row for index, row in enumerate(frames)
               if row["excluded"] != (frames[index-1]["excluded"] if index else 0)]
    if learned_false or residual_false:
        raise ValueError("An alert occurred during nominal sensor input")
    angles = [angle_error(row) if row["submitted"] and row["valid"] else None for row in frames]
    report = {
        "seed": int(seed), "group": group, "fault_cycle": None, "fault_ns": None,
        "learned_alert_cycle": None, "learned_alert_ns": None,
        "fdir_alert_cycle": None, "fdir_alert_ns": None,
        "approved_by": None, "approval_cycle": None, "approval_ns": None, "action_effective_ns": None,
        "stable_start_cycle": None, "stable_start_ns": None, "stable_confirm_ns": None,
        "max_valid_angle_deg": max((angle for angle in angles if angle is not None), default=None),
        "degraded_cycles": angles.count(None), "learned_false_alert_samples": learned_false,
        "fdir_false_alert_samples": residual_false, "verified_live_posts": len(observed),
        "verified_flight_uses": expected_uses, "approved_actions": len(approvals),
    }

    if bias:
        learned_alarm = next((row for row, prediction in received if prediction.label), None)
        fdir_alarm = next((row for row in frames if row["fdir_candidate"] == 0), None)
        required_source = "learned" if group == "recovery" else "fdir"
        if len(approvals) != 1 or len(changed) != 1:
            raise ValueError("Expected one action and one exclusion transition")
        action, source, approval_ns = approvals[0]
        if (action is not changed[0] or action["excluded"] != 1 or not action["submitted"] or
                action["cycle_id"] < inject or source != required_source or
                not action["start_ns"] <= approval_ns <= action["finish_ns"]):
            raise ValueError("Unexpected channel, source or timestamp for the isolation")
        if (required_source == "learned" and learned_alarm is None) or (required_source == "fdir" and fdir_alarm is None):
            raise ValueError("The acting detector has no observed alarm")
        if any(row["fdir_candidate"] not in (-1, 0) for row in frames):
            raise ValueError("FDIR identified an incorrect channel")

        action_index = action["cycle_id"] - 1
        stable_from = action_index
        for i in range(action_index, len(frames)):
            if angles[i] is None or angles[i] > angle_limit:
                stable_from = i + 1
        if len(frames) - stable_from < stable_cycles:
            raise ValueError("No stable recovered output through the observation tail")

        report.update(
            fault_cycle=inject, fault_ns=faults[0]["start_ns"],
            learned_alert_cycle=learned_alarm["cycle_id"] if learned_alarm else None,
            learned_alert_ns=learned_alarm["gate_ns"] if learned_alarm else None,
            fdir_alert_cycle=fdir_alarm["cycle_id"] if fdir_alarm else None,
            fdir_alert_ns=fdir_alarm["fdir_candidate_ns"] if fdir_alarm else None,
            approved_by=source, approval_cycle=action["cycle_id"], approval_ns=approval_ns,
            action_effective_ns=action["finish_ns"], stable_start_cycle=frames[stable_from]["cycle_id"],
            stable_start_ns=frames[stable_from]["finish_ns"],
            stable_confirm_ns=frames[stable_from + stable_cycles - 1]["finish_ns"],
        )
    elif approvals or changed or any(angle is None or angle > angle_limit for angle in angles):
        raise ValueError("Nominal run had an action or lost a valid estimate")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("replay", type=Path)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(assess(args.replay, args.directory), indent=2))
    except (OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
