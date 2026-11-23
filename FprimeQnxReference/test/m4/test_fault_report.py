"""Exercise the public summary with synthetic records in the benchmark's existing format."""

import csv
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


REPORT = Path(__file__).with_name("fault-report.py")
PRIVATE_FIELDS = re.compile(r"[0-9.]+ ?(?:ms|µs|us|ns)\b|p50|p99|deadline|flight.csv|fault-report.md", re.I)
SEED = 3001
CYCLES = 6
PERIOD = 10
OLD_SESSION = 11
NEW_SESSION = 22
NEW_RESULT = 143


def rows(path, data, headers=None, delimiter=","):
    with path.open("w", newline="", encoding="utf-8") as target:
        writer = csv.DictWriter(target, fieldnames=headers or list(data[0]), delimiter=delimiter)
        writer.writeheader()
        writer.writerows(data)


def write_case(run, run_id, group, *, rejoined=None, omitted=(), late=False, rejected=True):
    repair = "restart" if group == "q1" else "none"
    if rejoined is None:
        rejoined = group == "q1"
    case = run / run_id
    case.mkdir()
    config = {
        "run_id": run_id, "seed": SEED, "group": group, "repair": repair, "scenario": "crash",
        "advisor": "learned", "cycles": CYCLES, "period_ns": PERIOD, "deadline_ns": PERIOD,
        "freshness_ns": 35, "fallback_limit_ns": 40, "q1_rejoin_limit_ns": 80, "injection_cycle": 2,
        "min_warmup_cycles": 1, "exit_observer": "procmgr", "angle_limit_deg": 2, "stable_cycles": 2,
    }
    (case / "config.txt").write_text("".join(f"{key}={value}\n" for key, value in config.items()), encoding="utf-8")

    frame_defaults = {
        "valid": 1, "submitted": 1, "isolated": 0, "sensor_fault": 0, "snapshot_drops": 0,
        "sun_x": 1, "sun_y": 0, "sun_z": 0, "truth_x": 1, "truth_y": 0, "truth_z": 0,
        "fallback": "", "fallback_ns": 0, "gate": "", "fdir_gate": "", "gate_ns": 0,
        "checked_session": 0, "checked_cycle": 0, "checked_sample_ns": 0,
        "advisor_sample_ns": 100, "rejoin": 0, "action": 0, "channel": 0,
    }
    frames = []
    for cycle in range(1, CYCLES + 1):
        if cycle in omitted:
            continue
        release = 100 + (cycle - 1) * PERIOD
        after_rejoin = cycle >= 5 and rejoined
        frame = dict(frame_defaults, cycle_id=cycle, release_ns=release, start_ns=release + 1,
                     finish_ns=release + (PERIOD + 1 if late and cycle == CYCLES else 5),
                     fdir=int(cycle >= 3 and not after_rejoin), excluded=int(cycle >= 3),
                     advisor_session=NEW_SESSION if after_rejoin else OLD_SESSION if cycle < 3 else 0)
        if cycle == 1:
            frame.update(rejoin=1, checked_session=OLD_SESSION, checked_cycle=1, checked_sample_ns=100, gate_ns=103)
        elif cycle == 3:
            frame.update(fallback="RESULT_TIMEOUT", fallback_ns=121, fdir_gate="APPROVED")
        elif cycle == 4 and rejected:
            frame.update(gate="R2_SESSION", gate_ns=133, checked_session=OLD_SESSION)
        elif cycle == 5 and rejoined:
            frame.update(rejoin=1, checked_session=NEW_SESSION, checked_cycle=5, checked_sample_ns=139,
                         advisor_sample_ns=139, gate_ns=NEW_RESULT)
        frames.append(frame)
    rows(case / "flight.csv", frames)
    events = [
        (95, "SESSION", 10, OLD_SESSION, 0, 0),
        (100, "ISSUED", 10, OLD_SESSION, 1, 100),
        (101, "QUEUED", 10, OLD_SESSION, 1, 100),
        (110, "ISSUED", 10, OLD_SESSION, 2, 110),
    ]
    if rejoined:
        events.extend([
            (132, "SESSION", 20, NEW_SESSION, 0, 0),
            (139, "ISSUED", 20, NEW_SESSION, 5, 139),
            (141, "QUEUED", 20, NEW_SESSION, 5, 139),
        ])
    link_fields = ("ns", "event", "pid", "session", "cycle", "sample_ns")
    rows(case / "link.csv", [dict(zip(link_fields, event)) for event in events])
    (case / "flight.log").write_text(
        f"READY pid=1 first_release_ns=100 period_ns={PERIOD}\n"
        f"SUMMARY expected={CYCLES} last_cycle={frames[-1]['cycle_id']} record_drops=0 result_drops=0 "
        f"link_drops=0 accepted={1 + rejoined} timer_overruns=0 exit_ok=1\n", encoding="utf-8",
    )
    advisor = f"READY pid=10 client=90\nEVENT CRASH_BEGIN pid=10 session={OLD_SESSION} cycle=2 ns=113\n"
    if rejoined:
        advisor += "READY pid=20 client=129\n"
    (case / "advisor.log").write_text(advisor, encoding="utf-8")
    rows(case / "death.csv", [{"ns": 114, "pid": 10}])
    (case / "target-status.txt").write_text("0\n", encoding="utf-8")
    (case / "timing.txt").write_text("p50=9876.5 ms\n", encoding="utf-8")

    adcs_exit = int(bool(omitted))
    if not adcs_exit:
        adcs = {"group": group, "seed": SEED, "verified_rejoins": (
            [{"session": NEW_SESSION, "gate_ns": NEW_RESULT}] if rejoined else []
        )}
        (case / "adcs.json").write_text(json.dumps(adcs), encoding="utf-8")
    timing_exit = int(bool(omitted or late or (group == "q1" and not rejoined) or (group == "q2" and rejoined)))
    outcome = "FAIL" if timing_exit or adcs_exit else "PASS"
    return dict(run_id=run_id, group=group, seed=SEED, target_exit=0, timing_exit=timing_exit,
                adcs_exit=adcs_exit, verdict=outcome)


def write_manifests(run, outcomes, config=("PASS",)):
    pairs = [
        dict(pair=i, seed=SEED, first="q1", q1=f"{i:03d}-q1", q2=f"{i:03d}-q2", slm_config=status)
        for i, status in enumerate(config, 1)
    ]
    rows(run / "pairs.tsv", pairs, delimiter="\t")
    rows(run / "results.tsv", outcomes, delimiter="\t")


class FaultReportTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.run_dir = Path(workspace.name)

    def cli(self, *flags):
        return subprocess.run(
            [sys.executable, "-B", str(REPORT), str(self.run_dir), *flags],
            capture_output=True, text=True, encoding="utf-8", check=False,
        )

    def public(self, *flags):
        completed = self.cli("--public", *flags)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertNotRegex(completed.stdout, PRIVATE_FIELDS)
        return completed.stdout

    def test_public_behavior_can_be_verified_when_timing_fails(self):
        q1 = write_case(self.run_dir, "001-q1", "q1", late=True)
        q2 = write_case(self.run_dir, "001-q2", "q2")
        write_manifests(self.run_dir, [q1, q2])
        output = self.public()
        self.assertIn("rejoined with a new session in 1 of 1", output)
        self.assertIn("matched the held-out replay in 1 of 1", output)
        self.assertIn("rejected advice from the revoked session in 1 of 1", output)
        self.assertNotRegex(output, r"Q2|repair disabled|Disabled-repair|FDIR")
        self.assertIn("FDIR held through the observation window in 1 of 1", self.public("--with-q2"))

    def test_missing_evidence_and_failed_pair_configuration_stay_in_denominator(self):
        partial = write_case(self.run_dir, "001-q1", "q1", omitted=(2,))
        invalid_pair = write_case(self.run_dir, "002-q1", "q1")
        write_manifests(self.run_dir, [partial, invalid_pair], config=("PASS", "FAIL", "PASS"))
        output = self.public()
        self.assertIn("settings check passed in 2 of 3", output)
        self.assertIn("rejoined with a new session in 1 of 3", output)
        self.assertIn("matched the held-out replay in 0 of 3", output)
        self.assertIn("Behavior evidence was missing or inconclusive in 3 of 3 restart trials.", output)

    def test_repair_disabled_result_cannot_claim_fdir_after_a_rejoin(self):
        q1 = write_case(self.run_dir, "001-q1", "q1")
        q2 = write_case(self.run_dir, "001-q2", "q2", rejoined=True)
        write_manifests(self.run_dir, [q1, q2])
        output = self.public("--with-q2")
        self.assertIn("FDIR held through the observation window in 0 of 1", output)
        self.assertIn("advisor rejoin was observed in 1 of 1", output)

    def test_replay_evidence_must_match_the_rejoined_session(self):
        q1 = write_case(self.run_dir, "001-q1", "q1", rejected=False)
        write_manifests(self.run_dir, [q1])
        replay = self.run_dir / "001-q1" / "adcs.json"
        data = json.loads(replay.read_text(encoding="utf-8"))
        data["verified_rejoins"][0]["session"] = OLD_SESSION
        replay.write_text(json.dumps(data), encoding="utf-8")
        output = self.public()
        self.assertIn("rejoined with a new session in 1 of 1", output)
        self.assertIn("matched the held-out replay in 0 of 1", output)
        self.assertIn("advice from the revoked session in 0 of 1", output)

    def test_incomplete_repair_disabled_trace_cannot_prove_sustained_fdir(self):
        q1 = write_case(self.run_dir, "001-q1", "q1")
        q2 = write_case(self.run_dir, "001-q2", "q2", omitted=(4,))
        write_manifests(self.run_dir, [q1, q2])
        output = self.public("--with-q2")
        self.assertIn("FDIR held through the observation window in 0 of 1", output)
        self.assertIn("Behavior evidence was missing or inconclusive in 1 of 1 trials with repair disabled.", output)

    def test_with_q2_requires_public(self):
        completed = self.cli("--with-q2")
        self.assertEqual(completed.returncode, 2)
        self.assertIn("--with-q2 requires --public", completed.stderr)


if __name__ == "__main__":
    unittest.main()
