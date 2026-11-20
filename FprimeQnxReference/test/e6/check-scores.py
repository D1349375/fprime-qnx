#!/usr/bin/env python3
"""Check both builds against fixture math and against each other."""
import csv
import math
import sys
from pathlib import Path


def scores(path):
    with Path(path).open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if [row["case"] for row in rows] != ["0", "1", "2", "3"]:
        raise ValueError(f"Unexpected cases in {path}")
    return [(float(row["score"]), int(row["label"])) for row in rows]


def reference(path):
    w = [float(value) for value in Path(path).read_text().split()]
    for x, y in ((-1, -1), (1, 0.5), (0.25, -0.25), (0, 0.75)):
        hidden = [max(0.0, w[i] * x + w[3+i] * y + w[6+i]) for i in range(3)]
        score = 1 / (1 + math.exp(-(sum(h * weight for h, weight in zip(hidden, w[9:12])) + w[12])))
        yield score, int(score >= 0.5)


def main():
    host, target, weights = sys.argv[1:]
    tolerance = 1e-9
    for i, (a, b, truth) in enumerate(zip(scores(host), scores(target), reference(weights))):
        error = max(abs(a[0] - b[0]), abs(a[0] - truth[0]), abs(b[0] - truth[0]))
        if (not all(math.isfinite(value) for value in (a[0], b[0], truth[0])) or
                error > tolerance or a[1] != b[1] or a[1] != truth[1]):
            raise SystemExit(f"FAIL case={i} host={a} qnx={b} expected={truth}")
        print(f"case={i} host={a[0]:.12g} qnx={b[0]:.12g} label={a[1]} max_abs_error={error:.3g}")
    print(f"PASS E6 score_tolerance={tolerance} labels=4/4")


if __name__ == "__main__":
    main()
