#!/usr/bin/env python3
"""Retain a host and guest timing window on the first suspect ADCS deadline."""

import argparse
import csv
import json
import os
import selectors
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


HEARTBEAT_SECONDS = 0.060
SAMPLE_SECONDS = 0.015
RECOVERY_SECONDS = 0.200


def fields(text):
    return dict(field.split("=", 1) for field in text.split())


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


class Flight:
    def __init__(self, cycles, period, deadline):
        self.cycles = cycles
        self.period = period
        self.deadline = deadline
        self.first = None
        self.last = 0
        self.done = False
        self.anomaly = None

    @property
    def active(self):
        return self.first is not None and self.last < self.cycles and not self.done

    def take_row(self, line):
        if line.startswith("cycle_id,"):
            return
        row = next(csv.reader([line]))
        cycle, release, start, finish = map(int, row[:4])
        if (self.first is None or not self.last < cycle <= self.cycles
                or release != self.first + (cycle - 1) * self.period or not release <= start <= finish):
            raise ValueError(f"Unexpected flight timing row for cycle {cycle}")
        if self.anomaly is None:
            if cycle > self.last + 1:
                self.anomaly = {"kind": "cycle_gap", "first_cycle": self.last + 1, "last_cycle": cycle - 1}
            elif row[12] == "0" or finish > release + self.deadline:
                kind = "failed_submission" if row[12] == "0" else "late_commit"
                self.anomaly = {"kind": kind, "cycle": cycle, "release_ns": release, "finish_ns": finish}
        self.last = cycle

    def update(self, lines):
        clock = None
        for line in lines:
            if line.startswith("CLOCK "):
                clock = fields(line[6:])
            elif line.startswith("LOG READY "):
                ready = fields(line[10:])
                if self.first is not None or int(ready["period_ns"]) != self.period:
                    raise ValueError("Flight READY does not match the scheduled period")
                self.first = int(ready["first_release_ns"])
            elif line.startswith("ROW "):
                self.take_row(line[4:])
            elif line.startswith("DONE "):
                self.done = True
                if self.first is not None and self.last < self.cycles and self.anomaly is None:
                    self.anomaly = {"kind": "incomplete_flight", "first_cycle": self.last + 1, "last_cycle": self.cycles}
        if clock is None:
            raise ValueError("Guest timing sample has no clock anchor")
        return clock

    def suspect(self, guest_now):
        if self.active:
            next_deadline = self.first + self.last * self.period + self.deadline
            # Allow two periods for the logger and telemetry sample to reach the observer.
            if guest_now > next_deadline + 2 * self.period:
                return {"kind": "flight_progress_stalled", "next_cycle": self.last + 1}
        return None


class GuestStream:
    def __init__(self, process):
        self.process = process
        self.buffer = b""

    def request(self, command):
        before = time.monotonic_ns()
        self.process.stdin.write((command + "\n").encode())
        self.process.stdin.flush()
        return before

    def receive(self, seconds):
        deadline = time.monotonic() + seconds
        with selectors.DefaultSelector() as poller:
            poller.register(self.process.stdout, selectors.EVENT_READ)
            while b"\nEND\n" not in self.buffer:
                if not poller.select(max(0, deadline - time.monotonic())):
                    return None
                block = os.read(self.process.stdout.fileno(), 65536)
                if not block:
                    raise EOFError("Guest timing channel closed before a complete reply")
                self.buffer += block
        message, self.buffer = self.buffer.split(b"\nEND\n", 1)
        return message.decode().splitlines()


class HostTrace:
    def __init__(self, tracefs, output, qemu_pid, image):
        self.root = tracefs
        self.output = output
        self.process = Path(f"/proc/{qemu_pid}")
        self.pid = qemu_pid
        if (self.process.stat().st_uid != os.getuid()
                or (self.process / "cwd").resolve() != image):
            raise ValueError("QEMU identity does not match the owned test image")
        if not (self.process / "comm").read_text().startswith("qemu-system-"):
            raise ValueError("The guest PID is not QEMU")

    def control(self, name, value):
        (self.root / name).write_text(value + "\n", encoding="ascii")

    def capture_tasks(self, filename):
        tasks = []
        for task in sorted((self.process / "task").iterdir()):
            try:
                status = (task / "status").read_text()
                entry = dict(line.split(":", 1) for line in status.splitlines())
                tasks.append({
                    "tid": int(task.name), "name": entry["Name"].strip(),
                    "namespace_tids": entry.get("NSpid", "").split(), "state": entry["State"].strip(),
                    "cpus": entry["Cpus_allowed_list"].strip(), "wchan": (task / "wchan").read_text().strip(),
                })
            except (FileNotFoundError, ProcessLookupError):
                # QEMU can retire an I/O worker while its vCPUs are still running.
                continue
        write_json(self.output / filename, {"qemu_pid": self.pid, "tasks": tasks})
        return tasks

    def start(self):
        tasks = self.capture_tasks("host-tasks-start.json")
        # WSL's procfs TIDs can differ from global ftrace TIDs. Preserve the task
        # identities and filter on the recorded QEMU thread names at capture time.
        names = sorted({task["name"] for task in tasks})
        if not names:
            raise ValueError("No QEMU task names available for the scheduler filter")
        quoted = [json.dumps(name) for name in names]
        self.control("tracing_on", "0")
        self.control("trace_clock", "mono")
        self.control("buffer_size_kb", "512")
        for event, identity in (("sched_switch", ("prev_comm", "next_comm")), ("sched_wakeup", ("comm",))):
            event_path = f"events/sched/{event}"
            self.control(f"{event_path}/filter", " || ".join(f"{field} == {name}" for field in identity for name in quoted))
            self.control(f"{event_path}/enable", "1")
        self.clear()
        self.control("tracing_on", "1")

    def clear(self):
        with (self.root / "trace").open("w", encoding="ascii"):
            pass

    def save(self, name):
        before = time.monotonic_ns()
        self.control("tracing_on", "0")
        after = time.monotonic_ns()
        with (self.root / "trace").open("rb") as trace, (self.output / name).open("wb") as result:
            shutil.copyfileobj(trace, result)
        return [before, after]


    def event_count(self, filename=None):
        path = self.output / filename if filename else self.root / "trace"
        with path.open(encoding="ascii") as trace:
            for _ in range(4):
                line = trace.readline()
                if line.startswith("# entries-in-buffer/entries-written:"):
                    return int(line.split()[2].split("/")[0])
        return 0


def watch(args, trace, evidence):
    flight = Flight(args.cycles, args.period_ns, args.deadline_ns)
    status = args.output / "watch.json"
    recovery_time = None

    def trigger(anomaly):
        if evidence["trigger"] is not None:
            return
        evidence["trigger"] = {"host_ns": time.monotonic_ns(), "last_seen_cycle": flight.last, **anomaly}
        # Write the trigger before waiting for anything from the guest again.
        write_json(status, evidence)
        evidence["host_cut_ns"] = trace.save("host-sched-before.txt")
        evidence["host_before_events"] = trace.event_count("host-sched-before.txt")
        trace.capture_tasks("host-tasks-trigger.json")
        trace.control("tracing_on", "1")
        evidence["host_restart_ns"] = time.monotonic_ns()
        write_json(status, evidence)

    def clear_suspicion(before, guest_now):
        nonlocal recovery_time
        pending = evidence["trigger"]
        if not pending or "next_cycle" not in pending or before <= pending["host_ns"] or evidence["guest_frozen"]:
            return
        # A buffered reply sent before the trigger may contain only pre-stall progress.
        # Wait for all deadlines due at the first subsequent guest sample.
        due = max(pending["next_cycle"], 1 + (guest_now - flight.first - flight.deadline) // flight.period)
        through = pending.setdefault("check_through_cycle", min(flight.cycles, due))
        if flight.last < through:
            return
        evidence["cleared_triggers"].append({**pending, "cleared_host_ns": time.monotonic_ns()})
        evidence["trigger"] = None
        for key in ("host_cut_ns", "host_restart_ns", "host_before_events"):
            evidence.pop(key)
        for filename in ("host-sched-before.txt", "host-tasks-trigger.json"):
            (args.output / filename).unlink()
        recovery_time = None
        write_json(status, evidence)

    with subprocess.Popen(args.ssh, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0) as process:
        guest = GuestStream(process)
        try:
            with (args.output / "clock-anchors.tsv").open("w", buffering=1, encoding="ascii") as anchors:
                print("host_before_ns\thost_after_ns\tmonotonic_ns\tcycles_before\tcycles_after\tcycles_per_second", file=anchors)
                armed = False
                while not flight.done:
                    before = guest.request("sample")
                    lines = guest.receive(HEARTBEAT_SECONDS if flight.active else 0.5)
                    if lines is None and flight.active:
                        trigger({"kind": "guest_heartbeat_stalled", "next_cycle": flight.last + 1})
                    while lines is None:
                        lines = guest.receive(0.5)
                    received = time.monotonic_ns()
                    clock = flight.update(lines)
                    guest_now = int(clock["monotonic_ns"])
                    print(before, received, guest_now, clock["cycles_before"], clock["cycles_after"],
                          clock["cycles_per_second"], sep="\t", file=anchors)
                    if flight.active and flight.last and not armed:
                        write_json(args.output / "watch-ready.json", {
                            "qemu_pid": trace.pid, "ssh_pid": process.pid, "first_release_ns": flight.first,
                            "host_before_ns": before, "host_after_ns": received, "guest_monotonic_ns": guest_now,
                        })
                        armed = True
                    if flight.anomaly is not None:
                        evidence["observed_anomaly"] = flight.anomaly
                        trigger(flight.anomaly)
                    else:
                        clear_suspicion(before, guest_now)
                        suspect = flight.suspect(guest_now)
                        if suspect is not None:
                            trigger(suspect)
                    if evidence["trigger"] is not None and not evidence["guest_frozen"]:
                        if recovery_time is None:
                            recovery_time = time.monotonic() + RECOVERY_SECONDS
                        if flight.done or time.monotonic() >= recovery_time:
                            guest.request("freeze")
                            response = guest.receive(2)
                            if response != ["FROZEN"]:
                                raise ValueError("Guest did not acknowledge the trace freeze")
                            evidence["guest_frozen"] = True
                            evidence["host_post_cut_ns"] = trace.save("host-sched-after.txt")
                            evidence["host_after_events"] = trace.event_count("host-sched-after.txt")
                            write_json(status, evidence)
                    if not flight.done:
                        time.sleep(SAMPLE_SECONDS)
            process.stdin.close()
            result = process.wait(timeout=4)
            if evidence["trigger"] is None:
                trace.control("tracing_on", "0")
                if trace.event_count() == 0:
                    raise ValueError("The host scheduler ring did not record any QEMU events")
            elif not evidence["host_before_events"] or not evidence.get("host_after_events"):
                raise ValueError("The host scheduler capture was empty")
            evidence["complete"] = result == 0
            return result
        finally:
            if process.poll() is None:
                if not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def interrupted(signum, _frame):
    raise InterruptedError(f"Watcher interrupted by signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tracefs", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("qemu_pid", type=int)
    parser.add_argument("image", type=Path)
    parser.add_argument("cycles", type=int)
    parser.add_argument("period_ns", type=int)
    parser.add_argument("deadline_ns", type=int)
    parser.add_argument("ssh", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupted)

    trace = HostTrace(args.tracefs, args.output, args.qemu_pid, args.image)
    evidence = {"trigger": None, "observed_anomaly": None, "guest_frozen": False,
                "complete": False, "cleared_triggers": []}
    try:
        trace.start()
        return watch(args, trace, evidence)
    except (EOFError, KeyError, IndexError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        evidence["error"] = str(error)
        print(f"ADCS trace watcher: {error}", file=sys.stderr)
        return 1
    finally:
        if evidence["trigger"] is not None and "host_post_cut_ns" not in evidence:
            evidence["host_post_cut_ns"] = trace.save("host-sched-after.txt")
        else:
            trace.control("tracing_on", "0")
        write_json(args.output / "watch.json", evidence)


if __name__ == "__main__":
    sys.exit(main())
