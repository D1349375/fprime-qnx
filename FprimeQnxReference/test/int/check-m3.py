#!/usr/bin/env python3
"""Recompute one M3 verdict from guest traces and the pre-run contract."""
import argparse
import csv
import math
import re
from pathlib import Path


class Incomplete(ValueError):
    """The observations cannot establish a verdict."""


def fields(text):
    return dict(re.findall(r"(\w+)=([^\s]+)", text))


def only_line(text, prefix):
    matches = [line for line in text.splitlines() if line.startswith(prefix)]
    if len(matches) != 1:
        raise Incomplete(f"Expected one {prefix.strip()} line")
    return fields(matches[0])


def csv_rows(path, types):
    with path.open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            if None in row or None in row.values():
                raise Incomplete(f"Truncated record in {path.name}")
            for name, convert in types.items():
                row[name] = convert(row[name])
            yield row


def metrics(values):
    if not values:
        return "unavailable"
    values = sorted(values)
    return (
        f"p50={values[math.ceil(len(values)*0.50)-1]} "
        f"p99={values[math.ceil(len(values)*0.99)-1]} max={values[-1]}"
    )


def bounded(name, earliest, latest, outcome, limit, failures):
    if not 0 < earliest <= latest or outcome < earliest:
        raise Incomplete(f"{name} has missing or unordered timestamps")
    if outcome < latest:
        raise Incomplete(f"{name} precedes the latest possible fault onset")
    lower, upper = outcome - latest, outcome - earliest
    print(f"{name}_ns min={lower} max={upper} limit={limit}")
    if lower <= limit < upper:
        raise Incomplete(f"{name} interval straddles its limit")
    if lower > limit:
        failures.append(f"{name} exceeds {limit} ns")


def angle_error(row):
    estimate = [row[f"sun_{axis}"] for axis in "xyz"]
    truth = [row[f"truth_{axis}"] for axis in "xyz"]
    norms = math.hypot(*estimate) * math.hypot(*truth)
    if not math.isfinite(norms) or abs(norms - 1) > 1e-6:
        raise Incomplete("Invalid vector in a valid committed estimate")
    cosine = sum(a*b for a, b in zip(estimate, truth)) / norms
    return math.degrees(math.acos(max(-1.0, min(1.0, cosine))))


def assess(directory):
    config = dict(line.split("=", 1) for line in (directory / "config.txt").read_text().splitlines())
    group = config["group"]
    advisor_expected = group not in {"fdir_normal", "fdir_recovery"}
    cycles, period, deadline, freshness = (
        int(config[name]) for name in ("cycles", "period_ns", "deadline_ns", "freshness_ns")
    )
    print(f"run_id={config['run_id']} group={group} cycles={cycles} period_ns={period} deadline_ns={deadline}")
    flight = (directory / "flight.log").read_text()
    ready = only_line(flight, "READY ")
    stats = only_line(flight, "SUMMARY ")
    if (int((directory / "target-status.txt").read_text()) != 0 or
            int(stats["record_drops"]) != 0 or int(stats["result_drops"]) != 0 or
            int(stats.get("link_drops", "0")) != 0 or
            int(stats["expected"]) != cycles or int(ready["period_ns"]) != period or int(stats["exit_ok"]) != 1):
        raise Incomplete("Guest command, record integrity, or run configuration failed")
    t0 = int(ready["first_release_ns"])
    end = t0 + (cycles - 1) * period + deadline
    records = list(csv_rows(directory / "flight.csv", {
        **dict.fromkeys(("cycle_id", "release_ns", "start_ns", "finish_ns", "valid", "submitted", "fdir",
                         "rejoin", "isolated", "excluded", "sensor_fault", "advisor_session", "checked_session",
                         "checked_cycle", "checked_sample_ns", "advisor_sample_ns", "gate_ns", "fallback_ns",
                         "snapshot_drops", "action", "channel"), int),
        **dict.fromkeys(("sun_x", "sun_y", "sun_z", "truth_x", "truth_y", "truth_z"), float),
    }))
    if not records or records[-1]["cycle_id"] != int(stats["last_cycle"]):
        raise Incomplete("CSV transmission is incomplete")
    releases = set(range(1, cycles + 1))
    started, finished = [], []
    late = 0
    for row in records:
        cycle, release, start, finish = (row[key] for key in ("cycle_id", "release_ns", "start_ns", "finish_ns"))
        if cycle not in releases or release != t0 + (cycle - 1) * period or not release <= start <= finish:
            raise Incomplete(f"Cycle {cycle} is duplicated or inconsistent with the timing contract")
        releases.remove(cycle)
        started.append(start - release)
        if row["submitted"]:
            finished.append(finish - release)
        if not row["submitted"] or finish - release > deadline:
            late += 1
    misses = late + len(releases)
    print(f"start_minus_release_ns {metrics(started)}")
    print(f"finish_minus_release_ns {metrics(finished)}")
    slack = deadline - max(finished) if finished else "unavailable"
    print(f"misses={misses}/{cycles} missing={len(releases)} failed_or_late={late} "
          f"min_committed_slack_ns={slack} snapshot_drops={records[-1]['snapshot_drops']} "
          f"timer_overruns={stats['timer_overruns']}")
    failures = [f"{misses} deadline misses"] if misses else []
    inconclusive = []

    def check_interval(name, earliest, latest, outcome, limit):
        try:
            bounded(name, earliest, latest, outcome, limit, failures)
        except Incomplete as error:
            inconclusive.append(str(error))

    def require(condition, message):
        if not condition:
            failures.append(message)

    link = list(csv_rows(directory / "link.csv", dict.fromkeys(("ns", "pid", "session", "cycle", "sample_ns"), int)))
    if (advisor_expected and not link) or any(a["ns"] > b["ns"] for a, b in zip(link, link[1:])):
        raise Incomplete("Missing or unordered IPC trace")
    if sum(row["event"] == "QUEUED" for row in link) != int(stats["accepted"]):
        raise Incomplete("IPC trace does not agree with the final result count")
    sessions = {row["session"]: row for row in link if row["event"] == "SESSION"}
    issued = {(row["session"], row["cycle"], row["sample_ns"]) for row in link if row["event"] == "ISSUED"}
    queued = {(row["session"], row["cycle"], row["sample_ns"]): row["ns"] for row in link if row["event"] == "QUEUED"}
    log = (directory / "advisor.log").read_text()
    starts = {int(entry["pid"]): int(entry["client"]) for entry in
              (fields(line) for line in log.splitlines() if line.startswith("READY "))}
    advisor_events = [
        {"event": line.split()[1], **{key: int(value) for key, value in fields(line).items()}}
        for line in log.splitlines() if line.startswith("EVENT ")
    ]
    rejoined = [row for row in records if row["rejoin"]]
    warmup = int(config["min_warmup_cycles"])
    if advisor_expected:
        require(any(row["cycle_id"] <= warmup and row["rejoin"] for row in records),
                "Advisor did not warm up by the scheduled cycle")
    else:
        require(not starts and not rejoined and not sessions and all(r["fdir"] for r in records),
                "FDIR control unexpectedly used an advisor session")
    for row in rejoined:
        key = (row["checked_session"], row["checked_cycle"], row["checked_sample_ns"])
        require(key in issued and key in queued and
                key[0] == row["advisor_session"] and key[0] in sessions and
                0 <= row["start_ns"] - key[2] <= freshness and
                key[2] <= queued.get(key, 0) <= row["gate_ns"] <= row["finish_ns"],
                "Rejoin does not match an issued and fresh result")

    for row in records:
        if row["submitted"] and row["valid"]:
            require(angle_error(row) <= float(config["angle_limit_deg"]), "A committed estimate exceeded the angle limit")
        if row["submitted"] and not row["valid"]:
            require(not any(row[f"sun_{axis}"] for axis in "xyz"),
                    "Degraded output carries an active estimate")

    if group in {"q1", "q2", "stall", "transport"}:
        kind = {"q1": "CRASH_BEGIN", "q2": "CRASH_BEGIN", "stall": "STALL_BEGIN", "transport": "REPLY_HELD"}[group]
        events = link if group == "transport" else advisor_events
        injected = [event for event in events if event["event"] == kind]
        if len(injected) != 1:
            raise Incomplete(f"Expected one target-side {kind} event")
        injection = injected[0]
        early = late_effect = injection["ns"]
        original_session = injection["session"]
        ci = injection["cycle"]
        expected_ci = int(config["injection_cycle"])
        print(f"injection_ns={early} injection_cycle={ci} advisor_pid={injection['pid']} "
              f"old_session={original_session} flight_pid={ready['pid']} observation_end_ns={end}")
        require(expected_ci <= ci <= expected_ci + 4, "Injection missed its fixed snapshot window")
        if group in {"q1", "q2"}:
            require(not any(row["fallback"] and 0 < row["fallback_ns"] < early for row in records),
                    "Advisor entered FDIR before the scheduled crash")
            exits = [event["ns"] for event in link if event["event"] == "EXIT_OBSERVED" and
                     event["pid"] == injection["pid"] and event["ns"] >= early]
            if exits:
                print(f"exit_observed_ns={min(exits)}")
            if config.get("exit_observer") == "procmgr":
                events = csv_rows(directory / "death.csv", {"ns": int, "pid": int})
                watched = [event["ns"] for event in events if event["pid"] == injection["pid"]
                           and early <= event["ns"] <= end]
                if not watched:
                    raise Incomplete("QNX process manager did not report the original advisor's death")
                print(f"exit_pulse_received_ns={min(watched)}")
                exits.extend(watched)
            if not exits:
                raise Incomplete("Original advisor exit has no observation upper bound")
            late_effect = min(exits)
            print(f"fault_onset_latest_ns={late_effect}")

        fallback = next((row for row in records if row["fallback"] and row["fallback_ns"] >= early), None)
        if fallback is None:
            failures.append("No FDIR transition after the injection")
        else:
            commit = next((row for row in records if row["submitted"] and row["fdir"] and
                           row["start_ns"] >= fallback["start_ns"]), None)
            if commit is not None:
                check_interval("fallback", early, late_effect, commit["finish_ns"],
                               int(config["fallback_limit_ns"]))
                previous = next((row for row in reversed(records) if row["cycle_id"] < fallback["cycle_id"]), None)
                last_sample = previous["advisor_sample_ns"] if previous else 0
                if group in {"stall", "transport"}:
                    require(fallback["fallback"] == "RESULT_TIMEOUT" and last_sample > 0 and
                            fallback["start_ns"] - last_sample > freshness, "FDIR did not follow the result deadline")
                print(f"fallback_reason={fallback['fallback']} fdir_cycle={commit['cycle_id']} "
                      f"last_advisor_sample_ns={last_sample} last_sample_expiry_ns={last_sample + freshness}")
            else:
                failures.append("FDIR transition has no committed output")

        new_sessions = [entry for sess, entry in sessions.items() if sess != original_session and entry["ns"] >= early]
        after = [row for row in rejoined if row["gate_ns"] >= early]
        if group == "q2":
            require(len(starts) == 1 and not after and not new_sessions, "Q2 started or accepted a replacement")
            print("rejoin=not-observed")
        elif not after:
            failures.append("Expected a new session and a fresh result")
        else:
            joined = after[0]
            new_session = joined["advisor_session"]
            replacement = sessions.get(new_session)
            require(new_session != original_session and replacement in new_sessions,
                    "Rejoin reused the revoked session")
            if replacement:
                pid = replacement["pid"]
                restart_ns = starts.get(pid, 0)
                require((pid != injection["pid"]) == (group == "q1"),
                        "Unexpected advisor PID change or reuse")
                require(0 < restart_ns <= replacement["ns"] <= joined["gate_ns"],
                        "Advisor start, session, and first valid result are out of order")
                print(f"advisor_pid_after={pid} advisor_start_ns={restart_ns} "
                      f"new_session={new_session} session_ns={replacement['ns']} "
                      f"first_valid_result_ns={joined['gate_ns']}")
            check_interval("rejoin", early, late_effect, joined["gate_ns"],
                           int(config[f"{group}_rejoin_limit_ns"]))
            if group == "q1":
                require(any(row["gate"] == "R2_SESSION" and row["checked_session"] != new_session and
                            row["gate_ns"] >= early for row in records), "Old-session result was not rejected")

        if group == "stall":
            require(any(e["event"] == "HEARTBEAT" and e["ns"] > early for e in advisor_events),
                    "No heartbeat proven during application stall")
        if group == "transport":
            release = next((event for event in link if event["event"] == "REPLY_RELEASED"), None)
            if release is None:
                raise Incomplete("Transport hold has no release-control timestamp")
            resume = release["sample_ns"]
            returned = next((event["ns"] for event in advisor_events if event["event"] == "REQUEST_RETURN_ERROR" and
                             event["ns"] >= early), None)
            unblocks = [event for event in link if event["event"] == "REPLY_UNBLOCK" and
                        all(event[key] == injection[key] for key in ("pid", "session", "cycle", "sample_ns"))]
            if len(unblocks) != 1:
                raise Incomplete("Held request has no unique QNX unblock pulse")
            unblocked = unblocks[0]["ns"]
            require(early <= unblocked <= resume and
                    early + int(config["transport_pause_ns"]) <= resume <= release["ns"] and
                    returned is not None and resume <= returned and
                    bool(after) and returned <= after[0]["gate_ns"],
                    "Client return, injected release, or successful reconnection was not ordered")
            print(f"transport_unblock_ns={unblocked} transport_release_control_ns={resume} "
                  f"transport_release_ns={release['ns']} "
                  f"transport_client_return_ns={returned}")

    if group in {"q1", "q2", "stall", "recovery", "fdir_recovery"}:
        expected = "gate" if group == "recovery" else "fdir_gate"
        require(any(r[expected] == "APPROVED" and r["excluded"] == 1 for r in records),
                f"No {expected} approval of the independently faulty channel")
        tail = records[-int(config["stable_cycles"]):]
        require(len(tail) == int(config["stable_cycles"]) and all(r["valid"] and r["excluded"] == 1 for r in tail),
                "Recovered estimate did not hold through the stable window")
    elif group == "gate":
        reasons = {row["gate"] for row in records}
        required = {"R1_WHITELIST", "R2_DUPLICATE", "R2_SESSION", "R2_UNISSUED", "R2_STALE", "R6_CONSISTENCY"}
        require(required <= reasons, f"Missing Gate reasons {sorted(required - reasons)}")
        require(any(event["event"] == "R2_FORMAT" for event in link), "Malformed envelope was not rejected")
        require(any(r["fallback"] == "GATE_ISOLATION" and r["fdir"] and r["submitted"] for r in records),
                "Repeated rejects did not isolate the advisor and commit an FDIR output")
        require(all(r["excluded"] == 0 for r in records), "A rejected proposal changed the sensor mask")
    elif group == "geometry":
        require(any(r["gate"] == "R5_GEOMETRY" for r in records), "No geometry rejection")
        require(all(not r["valid"] and r["submitted"] and r["excluded"] == 0
                    for r in records if r["cycle_id"] >= int(config["injection_cycle"])),
                "Insufficient geometry did not hold a committed degraded output")
    elif group in {"normal", "fdir_normal"}:
        require(all(r["valid"] and r["excluded"] == 0 and not r["fallback"] for r in records),
                "No-fault baseline unexpectedly excluded, degraded, or fell back")

    print(f"gate_reasons={','.join(sorted({r['gate'] for r in records if r['gate']}))}")
    for failure in dict.fromkeys(failures):
        print(f"FAIL {failure}")
    if inconclusive:
        raise Incomplete("; ".join(inconclusive))
    if not failures:
        print("PASS")
    return bool(failures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    try:
        return int(assess(parser.parse_args().directory))
    except (OSError, KeyError, ValueError, IndexError) as error:
        print(f"INDETERMINATE {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
