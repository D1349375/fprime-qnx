#!/usr/bin/env python3
"""Verify the ordered GDS downlink from the FlightSW SLM restart scenario."""

import argparse
import itertools
import math
from pathlib import Path
import sys


def rows(path, separator_limit):
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split(",", separator_limit)
        if len(fields) == separator_limit + 1:
            yield fields[2], fields[-1]


def last_session(channel_rows):
    sessions = [int(value) for name, value in channel_rows if name.endswith(".ground.AdvisorSession")]
    return sessions[-1] if sessions else 0


def check(directory, crash_event, crash_channel, advisor_pid, sessions=None):
    events = list(rows(directory / "event.log", 5))
    channels = list(rows(directory / "channel.log", 4))
    before_crash = events[:crash_event]
    names = [name.rsplit(".", 1)[-1] for name, _ in before_crash]
    if "NoOpReceived" not in names or "OpCodeCompleted" not in names[names.index("NoOpReceived") + 1:]:
        raise ValueError("GDS did not confirm CMD_NO_OP")
    print("PASS CMD_NO_OP round trip")

    death = ("M2Flight.processMonitor.ProcessDied", f"Process {advisor_pid} (MlAdvisor) died")
    deaths = [row for row in events if row[0].endswith(".processMonitor.ProcessDied")]
    if deaths != [death] or death not in events[crash_event:]:
        raise ValueError(f"expected one ProcessDied for the stopped advisor {advisor_pid}, got {deaths}")
    print("PASS kernel death event for the watched advisor only")

    old_session = last_session(channels[:crash_channel])
    if old_session == 0:
        raise ValueError("no pre-crash advisor session in GDS")

    pids = {}
    if sessions is not None:
        for line in sessions.read_text(encoding="utf-8").splitlines():
            pid, session = map(int, line.split(","))
            if session in pids and pids[session] != pid:
                raise ValueError(f"conflicting PIDs for session {session}")
            pids[session] = pid
        if pids.get(old_session) != advisor_pid:
            raise ValueError("pre-crash GDS session does not match the stopped advisor PID")
    fdir_seen = False
    for name, message in events[crash_event:]:
        if name.endswith(".ground.FdirEngaged"):
            fdir_seen = message.endswith(("RESULT_TIMEOUT", "SESSION_CHANGED"))
        if fdir_seen and name.endswith(".ground.AdvisorAccepted"):
            new_session = int(message.rsplit(" ", 1)[-1])
            if new_session == old_session or new_session == 0:
                continue
            if sessions is not None:
                # A result from the old PID can reach GDS after the process-death notification.
                replacement = pids.get(new_session, 0)
                if replacement <= 1 or replacement == advisor_pid:
                    continue
            break
    else:
        if sessions is not None:
            raise ValueError("FDIR was not followed by acceptance of a replacement advisor's session")
        raise ValueError("GDS did not show FDIR followed by acceptance of a new advisor session")
    print("PASS FDIR and new advisor session")

    prior_control = [value.strip() for name, value in channels[:crash_channel]
                     if name.endswith(".ground.ControlSource")]
    if not prior_control or prior_control[-1] != "ML":
        raise ValueError("GDS did not show ML control immediately before the advisor crash")
    states = (value.strip() for name, value in channels[crash_channel:] if name.endswith(".ground.ControlSource"))
    transitions = [state for state, _ in itertools.groupby(itertools.chain(["ML"], states))]
    if not any(transitions[i:i + 3] == ["ML", "FDIR", "ML"] for i in range(len(transitions) - 2)):
        raise ValueError(f"GDS control source did not show ML, FDIR, ML (saw {transitions})")
    if not any(math.isfinite(float(value)) for name, value in channels if name.endswith(".ground.AttitudeErrorDeg")):
        raise ValueError("no finite attitude error in GDS")
    print("PASS control source and attitude telemetry")

    if sessions is not None:
        print("PASS SLM replaced the advisor and FlightSW accepted its session")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("crash_event", type=int)
    parser.add_argument("crash_channel", type=int)
    parser.add_argument("advisor_pid", type=int)
    parser.add_argument("--sessions", type=Path)
    args = parser.parse_args()
    try:
        check(args.directory, args.crash_event, args.crash_channel, args.advisor_pid, args.sessions)
    except (OSError, ValueError) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
