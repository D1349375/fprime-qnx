#!/usr/bin/env python3
"""Count observed cycle outcomes for a finite, seeded FlightSW run."""

import argparse
import csv
from pathlib import Path


def read_fields(log, prefix):
    fields, = [line.split()[1:] for line in log.splitlines() if line.startswith(prefix + " ")]
    return dict(field.split("=", 1) for field in fields)


def check(directory, expected_priority):
    log = (directory / "flight.log").read_text(encoding="utf-8")
    ready = read_fields(log, "READY")
    summary = read_fields(log, "SUMMARY")
    if int(ready["fifo_priority"]) != expected_priority:
        raise ValueError("unexpected FlightSW scheduling configuration")
    cycles = int(summary["expected"])
    if cycles != 230 or summary["exit_ok"] != "1" or summary["record_drops"] != "0":
        raise ValueError("expected a complete 230-cycle observation window without logger drops")
    first_release = int(ready["first_release_ns"])
    period = int(ready["period_ns"])
    late = invalid = previous = observed = 0
    with (directory / "flight.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            cycle = int(row["cycle_id"])
            release, start, finish = (int(row[key]) for key in ("release_ns", "start_ns", "finish_ns"))
            if not previous < cycle <= cycles or release != first_release + (cycle - 1) * period:
                raise ValueError(f"unexpected cycle or release at {cycle}")
            if not release <= start <= finish:
                raise ValueError(f"inconsistent timestamps at cycle {cycle}")
            previous = cycle
            observed += 1
            late += finish > release + period
            invalid += row["submitted"] != "1"
    if not observed or previous != int(summary["last_cycle"]):
        raise ValueError("trace and flight summary disagree")
    return cycles - observed, late, invalid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--fifo-priority", type=int, default=30)
    args = parser.parse_args()
    try:
        print(*check(args.directory, args.fifo_priority), sep="\t")
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"Invalid timing evidence in {args.directory}: {error}\n")


if __name__ == "__main__":
    main()
