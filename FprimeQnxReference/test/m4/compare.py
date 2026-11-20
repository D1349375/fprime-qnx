#!/usr/bin/env python3
"""Account for every expected inference and compare scores and labels to the frozen model."""

import argparse
import csv
import math
from pathlib import Path
from dataclasses import dataclass

from sklearn.metrics import average_precision_score, matthews_corrcoef, precision_score, recall_score


ABS_TOL = 1e-10
REL_TOL = 1e-9


@dataclass
class Prediction:
    score: float
    label: int
    ns: int


def score_close(a, b):
    return math.isclose(a, b, abs_tol=ABS_TOL, rel_tol=REL_TOL)


def read_predictions(path):
    observations = {}
    if not path.is_file():
        return observations
    with path.open(newline="", encoding="utf-8") as file:
        for row in csv.DictReader(file):
            case = row["case"]
            if case in observations:
                observations[case] = "duplicate"
                continue
            try:
                if row["status"] != "ok" or None in row or None in row.values():
                    raise ValueError("failed CSV result")
                score, label, ns = float(row["score"]), int(row["label"]), int(row["inference_ns"])
                if not 0.0 <= score <= 1.0 or label not in (0, 1) or ns < 0:
                    raise ValueError("invalid result")
                observations[case] = Prediction(score, label, ns)
            except (ValueError, KeyError):
                observations[case] = "failed"
    return observations


def benchmark(name, expected, results):
    pairs = [(int(row["truth"]), results[row["case"]]) for row in expected
             if isinstance(results.get(row["case"]), Prediction)]
    print(f"{name}_scored={len(pairs)}/{len(expected)}")
    if not pairs:
        return
    y, predictions = zip(*pairs)
    scores = [prediction.score for prediction in predictions]
    labels = [prediction.label for prediction in predictions]
    true_positives = sum(a == b == 1 for a, b in zip(y, labels))
    false_positives = sum(a == 0 and b == 1 for a, b in zip(y, labels))
    false_negatives = sum(a == 1 and b == 0 for a, b in zip(y, labels))
    print(f"{name} AP={average_precision_score(y, scores):.9f} "
          f"precision={precision_score(y, labels, zero_division=0):.9f} "
          f"recall={recall_score(y, labels, zero_division=0):.9f} MCC={matthews_corrcoef(y, labels):.9f} "
          f"tp={true_positives} fp={false_positives} fn={false_negatives} "
          f"tn={len(y) - true_positives - false_positives - false_negatives}")
    ordered = sorted(prediction.ns for prediction in predictions)
    print(f"{name}_ns p50={ordered[math.ceil(len(ordered) * .50)-1]} "
          f"p99={ordered[math.ceil(len(ordered) * .99)-1]} max={ordered[-1]}")


def compare(directory):
    with (directory / "expected.csv").open(newline="", encoding="utf-8") as file:
        expected = list(csv.DictReader(file))
    cases = {row["case"] for row in expected}
    if not cases or len(cases) != len(expected):
        raise ValueError("Expected a nonempty, unique set of evaluation cases")
    threshold = float((directory / "model.txt").read_text().splitlines()[0].split()[-1])
    host = read_predictions(directory / "host.csv")
    qnx = read_predictions(directory / "qnx.csv")

    host_failed, qnx_failed = 0, 0
    pairs, score_diff, label_diff, reference_diff = 0, 0, 0, 0
    max_abs, max_ref_abs = 0.0, 0.0
    with (directory / "comparison.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(("case", "host_status", "qnx_status", "host_qnx_abs", "scores_agree",
                         "labels_agree", "host_reference_agrees", "qnx_reference_agrees"))
        for row in expected:
            case = row["case"]
            reference_score = float(row["reference_score"])
            reference_label = int(reference_score >= threshold)
            a, b = host.get(case, "missing"), qnx.get(case, "missing")
            a_ok, b_ok = isinstance(a, Prediction), isinstance(b, Prediction)
            host_failed += not a_ok
            qnx_failed += not b_ok
            a_ref, b_ref = "", ""
            if a_ok:
                a_ref = score_close(a.score, reference_score) and a.label == reference_label
                reference_diff += not a_ref
                max_ref_abs = max(max_ref_abs, abs(a.score - reference_score))
            if b_ok:
                b_ref = score_close(b.score, reference_score) and b.label == reference_label
                reference_diff += not b_ref
                max_ref_abs = max(max_ref_abs, abs(b.score - reference_score))
            error, scores_match, labels_match = "", "", ""
            if a_ok and b_ok:
                pairs += 1
                error = abs(a.score - b.score)
                max_abs = max(max_abs, error)
                scores_match = score_close(a.score, b.score)
                labels_match = a.label == b.label
                score_diff += not scores_match
                label_diff += not labels_match
            writer.writerow((case, "ok" if a_ok else a, "ok" if b_ok else b, error, scores_match, labels_match,
                             a_ref, b_ref))

    n = len(cases)
    extra = len(host.keys() - cases) + len(qnx.keys() - cases)
    print(f"expected_per_platform={n} host_failures={host_failed}/{n} qnx_failures={qnx_failed}/{n} extra={extra}")
    print(f"compared_pairs={pairs}/{n} score_mismatches={score_diff}/{n} label_mismatches={label_diff}/{n} "
          f"reference_mismatches={reference_diff}/{2*n} score_atol={ABS_TOL:g} score_rtol={REL_TOL:g} "
          f"max_abs={max_abs:.6g} max_reference_abs={max_ref_abs:.6g}")
    benchmark("linux", expected, host)
    benchmark("qnx", expected, qnx)
    return bool(host_failed or qnx_failed or extra or score_diff or label_diff or reference_diff)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    return compare(args.directory)


if __name__ == "__main__":
    raise SystemExit(main())
