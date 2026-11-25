#!/usr/bin/env python3
"""Recompute slow-drift warnings, isolation and recovery from the M4 evidence."""

import argparse
from collections import Counter
import csv
import json
import math
from pathlib import Path
import runpy
import sys

from compare import Prediction, read_predictions, score_close
from train import DRIFT_SEEDS


m3 = runpy.run_path(str(Path(__file__).resolve().parents[1] / "int/check-m3.py"))
CHANNEL_MASK = 1  # The declared failure hypothesis is the X sensor (channel 0).
EXCLUSION = 1


def read_fixture(replay, seed, fault):
    return {
        int(row["cycle"]): row
        for row in m3["csv_rows"](replay / "adcs.csv", {"seed": int, "drift": int})
        if row["split"] == "test" and row["seed"] == seed and row["drift"] == fault
    }


def verify_advice(directory, frames, predictions, fixture, seed, fault, mode, freshness):
    log = (directory / "advisor.log").read_text(encoding="utf-8").splitlines()
    marker = "MODEL mlpack=4.7.0 schema=adcs-drift openblas_threads=1"
    if log.count(marker) != int(mode == "learned"):
        raise ValueError("Expected the drift model only in the learned arm")
    posts = {}
    for line in log:
        if not line.startswith("RESULT "):
            continue
        entry = m3["fields"](line)
        key = int(entry["session"]), int(entry["cycle"])
        prediction = predictions.get(f"{seed}-{fault}-{key[1]}")
        if (key in posts or not isinstance(prediction, Prediction) or
                not score_close(float(entry["score"]), prediction.score) or int(entry["alert"]) != prediction.label):
            raise ValueError(f"Live FFN post disagrees with the replay at {key}")
        posts[key] = prediction.label

    issued = set()
    queued = {}
    for row in m3["csv_rows"](directory / "link.csv", dict.fromkeys(("ns", "session", "cycle", "sample_ns"), int)):
        key = row["session"], row["cycle"], row["sample_ns"]
        if row["event"] == "ISSUED":
            issued.add(key)
        elif row["event"] == "QUEUED":
            queued[key] = row["ns"]
    if mode == "fdir" and (posts or issued or queued or any(not row["fdir"] for row in frames)):
        raise ValueError("The FDIR-only arm used advisor IPC")

    used = []
    for row in frames:
        key = row["checked_session"], row["checked_cycle"]
        if not row["gate_ns"] or key != (row["advisor_session"], row["advisor_cycle"]) or not key[0]:
            continue
        sample = row["checked_sample_ns"]
        stamp = (*key, sample)
        alert = posts.get(key)
        if (alert is None or alert != row["advisor_alert"] or stamp not in issued or stamp not in queued or
                not 0 <= row["start_ns"] - sample <= freshness or
                not sample <= queued[stamp] <= row["gate_ns"] <= row["finish_ns"]):
            raise ValueError(f"Flight used an unverified or stale FFN result at {key}")
        action = EXCLUSION if alert and int(fixture[key[1]]["confirmed"]) else 0
        if row["action"] != action or row["channel"] != 0:
            raise ValueError(f"FFN proposal differs from the replay and the confirmation rule at {key}")
        used.append((key[1], row["cycle_id"], alert))
    return used


def isolation_and_recovery(frames, angles, injection, angle_limit, stable_cycles):
    approved = []
    mask = 0
    for row in frames:
        sources = [source for field, source in (("gate", "learned"), ("fdir_gate", "fdir"))
                   if row[field] == "APPROVED"]
        new_mask = row["excluded"]
        if new_mask != mask or sources:
            # A gap can hide the approval. The mask change remains in the raw trace.
            if len(sources) != 1 or new_mask == mask:
                raise ValueError(f"Isolation transition has no unique approval at cycle {row['cycle_id']}")
            approved.append({"cycle": row["cycle_id"], "source": sources[0],
                             "before_mask": mask, "after_mask": new_mask, "submitted": bool(row["submitted"])})
        mask = new_mask

    correct = (len(approved) == 1 and approved[0]["before_mask"] == 0 and
               approved[0]["after_mask"] == CHANNEL_MASK and approved[0]["cycle"] >= injection and
               approved[0]["submitted"]) if injection else not approved
    stable_start = stable_confirmed = None
    if injection and correct:
        for row in reversed(frames):
            cycle = row["cycle_id"]
            if (cycle < approved[0]["cycle"] or angles[cycle] is None or angles[cycle] > angle_limit or
                    (stable_start is not None and cycle + 1 != stable_start)):
                break
            stable_start = cycle
        if stable_start is not None and frames[-1]["cycle_id"] - stable_start + 1 >= stable_cycles:
            stable_confirmed = stable_start + stable_cycles - 1
    return approved, correct, stable_start, stable_confirmed


def assess(replay, directory):
    config = dict(line.split("=", 1) for line in (directory / "config.txt").read_text().splitlines())
    seed, mode, scenario = int(config["seed"]), config["advisor"], config["scenario"]
    if seed not in DRIFT_SEEDS["test"] or mode not in {"fdir", "learned"} or scenario not in {"normal", "drift"}:
        raise ValueError("Expected an independent held-out drift arm")
    fault = int(scenario == "drift")
    cycles, period, freshness = (int(config[key]) for key in ("cycles", "period_ns", "freshness_ns"))
    expected_onset = int(config["injection_cycle"]) if fault else None
    _, _, frames, missing = m3["read_flight"](directory, cycles, period)
    extra_types = dict.fromkeys(("advisor_alert", "advisor_cycle", "fdir_alert", *(f"s{i}" for i in range(6))), int)
    with (directory / "flight.csv").open(newline="", encoding="utf-8") as file:
        for record, extra in zip(frames, csv.DictReader(file), strict=True):
            record.update({name: convert(extra[name]) for name, convert in extra_types.items()})

    fixture = read_fixture(replay, seed, fault)
    calibration = json.loads((replay / "calibration.json").read_text())
    cutoff = calibration["fdir"]["cutoff"]
    if float(config["drift_cutoff"]) != cutoff or sorted(fixture) != list(range(1, cycles + 1)):
        raise ValueError("Run cutoff or fixture differs from the frozen experiment")
    if sorted(row["cycle_id"] for row in frames) != [row["cycle_id"] for row in frames]:
        raise ValueError("Unordered flight records")
    for row in frames:
        reference = fixture[row["cycle_id"]]
        if (any(row[f"s{i}"] != int(reference[f"s{i}"]) for i in range(6)) or
                any(not math.isclose(row[f"truth_{axis}"], float(reference[f"truth_{axis}"]), abs_tol=1e-9)
                    for axis in "xyz")):
            raise ValueError(f"Sensor or truth fixture differs at cycle {row['cycle_id']}")
        if row["fdir_alert"] != int(float(reference["fdir_residual"]) >= cutoff):
            raise ValueError(f"FDIR warning differs from the calibrated residual at cycle {row['cycle_id']}")

    observed_onsets = [row["cycle_id"] for row in frames if row["sensor_fault"]]
    expected_observed = next((row["cycle_id"] for row in frames if fault and row["cycle_id"] >= expected_onset), None)
    if observed_onsets != ([expected_observed] if expected_observed else []):
        raise ValueError("Fault onset marker differs from the fixture")

    predictions = read_predictions(replay / "qnx.csv")
    used = verify_advice(directory, frames, predictions, fixture, seed, fault, mode, freshness)
    scores = used if mode == "learned" else [
        (row["cycle_id"], row["cycle_id"], row["fdir_alert"]) for row in frames
    ]
    offline_flags = {}
    for cycle, row in fixture.items():
        if mode == "fdir":
            offline_flags[cycle] = float(row["fdir_residual"]) >= cutoff
        else:
            prediction = predictions.get(f"{seed}-{fault}-{cycle}")
            if not isinstance(prediction, Prediction):
                raise ValueError(f"Missing valid FFN replay at snapshot {cycle}")
            offline_flags[cycle] = bool(prediction.label)
    is_fault = {cycle: bool(int(row["label"])) for cycle, row in fixture.items()}
    first_warning = next(((snapshot, flight) for snapshot, flight, alert in scores if alert and is_fault[snapshot]),
                         (None, None))
    false_alerts = [snapshot for snapshot, _, alert in scores if alert and not is_fault[snapshot]]
    angles = {row["cycle_id"]: m3["angle_error"](row) if row["valid"] and row["submitted"] else None
              for row in frames}
    approved, correct, stable_start, stable_confirmed = isolation_and_recovery(
        frames, angles, expected_onset, float(config["angle_limit_deg"]), int(config["stable_cycles"]),
    )
    evidence_complete = not missing and bool(scores) and all(row["submitted"] for row in frames)
    stable_to_end = stable_confirmed is not None and frames[-1]["cycle_id"] == cycles
    passed = evidence_complete and not false_alerts and correct
    if fault:
        passed = passed and first_warning[0] is not None and stable_to_end and approved[0]["source"] == mode
    return {
        "seed": seed, "scenario": scenario, "arm": mode, "case_pass": passed,
        "expected_cycles": cycles, "missing_cycles": sorted(missing), "evidence_complete": evidence_complete,
        "expected_onset_cycle": expected_onset, "observed_onset_cycles": observed_onsets,
        "first_alert_snapshot_cycle": first_warning[0], "first_alert_flight_cycle": first_warning[1],
        "offline_first_alert_cycle": next((cycle for cycle in sorted(fixture)
                                           if offline_flags[cycle] and is_fault[cycle]), None),
        "offline_false_alert_cycles": [cycle for cycle in sorted(fixture)
                                       if offline_flags[cycle] and not is_fault[cycle]],
        "false_alert_snapshot_cycles": false_alerts,
        "healthy_samples_observed": sum(not is_fault[snapshot] for snapshot, _, _ in scores),
        "verified_flight_uses": len(used), "approval_and_exclusion": approved, "isolation_correct": correct,
        "first_exclusion_cycle": approved[0]["cycle"] if approved else None,
        "valid_submitted_cycles": sum(angle is not None for angle in angles.values()),
        "degraded_submitted_cycles": sum(row["submitted"] and not row["valid"] for row in frames),
        "peak_valid_angle_deg": max((angle for angle in angles.values() if angle is not None), default=None),
        "stable_start_cycle": stable_start, "stable_confirmed_cycle": stable_confirmed,
        "stable_to_end": stable_to_end,
        "fallbacks": dict(Counter(row["fallback"] for row in frames if row["fallback"])),
    }


def read_case(replay, directory):
    try:
        return assess(replay, directory)
    except (OSError, ValueError, KeyError, IndexError) as error:
        return {"case_pass": False, "evidence_complete": False, "error": str(error)}


def paired_report(root):
    with (root / "results.tsv").open(newline="", encoding="utf-8") as file:
        statuses = {row["run_id"]: row for row in csv.DictReader(file, delimiter="\t")}
    pairs = []
    for seed in DRIFT_SEEDS["test"]:
        for scenario, label in (("normal", "nominal"), ("drift", "drift")):
            arms = {}
            for mode in ("fdir", "learned"):
                run_id = f"{seed}-{mode}-{label}"
                arm = read_case(root / "replay", root / run_id)
                if "error" not in arm and (arm["seed"], arm["scenario"], arm["arm"]) != (seed, scenario, mode):
                    arm.update(case_pass=False, evidence_complete=False, error="Case configuration differs from pair")
                arms[mode] = {**arm, "original_verdict": statuses.get(run_id), "case_dir": run_id}
            comparable = all(arm["evidence_complete"] for arm in arms.values())
            observed = {}
            for name in ("offline_first_alert_cycle", "first_alert_snapshot_cycle", "first_alert_flight_cycle",
                         "first_exclusion_cycle", "peak_valid_angle_deg", "degraded_submitted_cycles",
                         "stable_start_cycle", "stable_confirmed_cycle"):
                learned, fdir = (None if "error" in arm else arm.get(name) for arm in (arms["learned"], arms["fdir"]))
                observed[name] = learned - fdir if learned is not None and fdir is not None else None
            deltas = {name: difference if comparable or name == "offline_first_alert_cycle" else None
                      for name, difference in observed.items()}
            pairs.append({"seed": seed, "scenario": scenario, "complete_pair": comparable,
                          "learned_minus_fdir": deltas, "observed_learned_minus_fdir": observed, **arms})
    return pairs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("replay_or_run", type=Path)
    parser.add_argument("case", type=Path, nargs="?")
    parser.add_argument("--pairs", action="store_true")
    args = parser.parse_args()
    if args.pairs:
        if args.case is not None:
            parser.error("--pairs takes the run directory only")
        pairs = paired_report(args.replay_or_run)
        print(json.dumps(pairs, indent=2))
        return int(any(not arm["case_pass"] or (arm["original_verdict"] or {}).get("verdict") != "PASS"
                       for pair in pairs for arm in (pair["learned"], pair["fdir"])))
    if args.case is None:
        parser.error("provide the replay and case directories")
    report = read_case(args.replay_or_run, args.case)
    print(json.dumps(report, indent=2))
    if "error" in report:
        print(report["error"], file=sys.stderr)
        return 2
    return int(not report["case_pass"])


if __name__ == "__main__":
    raise SystemExit(main())
