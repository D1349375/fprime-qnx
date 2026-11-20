#!/usr/bin/env python3
"""Fit on training rows, choose the cutoff on validation, then emit held-out cases."""

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import sklearn
from sklearn.metrics import matthews_corrcoef
from sklearn.neural_network import MLPClassifier
from threadpoolctl import threadpool_limits


OPSSAT_DOI = "10.5281/zenodo.15108715"
OPSSAT_FILES = {
    "dataset.csv": "b524177da6f516d5c9f63c7acbc385341f0ad42046ef20c1bed2d25e51b98f02",
    "segments.csv": "d5201e9e751eb2a53a0ff7c11567dc4239f594ea4b479b2aa66fe67ddcbcb9ba",
    "LICENSE": "76d2ff9834ed2bb1356d9f7eb303c289817374bb1d5bbe5af86817e73e0f47d2",
    "modeling_examples.ipynb": "224f8a73561c25e421f1eb72b84a850118002eecf278642c690e8b4fce2d4faa",
}
OPSSAT_FEATURES = (
    "mean", "var", "std", "len", "duration", "len_weighted", "gaps_squared", "n_peaks",
    "smooth10_n_peaks", "smooth20_n_peaks", "var_div_duration", "var_div_len",
    "diff_peaks", "diff2_peaks", "diff_var", "diff2_var", "kurtosis", "skew",
)
ADCS_FEATURES = ("x", "y", "z", "xy", "residual")


def csv_rows(path):
    with path.open(newline="", encoding="utf-8") as file:
        yield from csv.DictReader(file)


def segment_key(row):
    return row["channel"], int(row["segment"])


def segment_flags(row):
    return int(row["train"]), int(row["anomaly"])


def opssat_splits(source):
    for filename, expected in OPSSAT_FILES.items():
        with (source / filename).open("rb") as file:
            if hashlib.file_digest(file, "sha256").hexdigest() != expected:
                raise ValueError(f"Unexpected Zenodo v2 file: {filename}")
    metadata = json.loads((source / "record.json").read_text(encoding="utf-8"))["metadata"]
    rights = {item["id"] for item in metadata.get("rights") or []}
    rights.add((metadata.get("license") or {}).get("id"))
    if metadata["doi"] != OPSSAT_DOI or "cc-by-4.0" not in rights:
        raise ValueError("Expected the pinned version DOI and Zenodo's CC BY 4.0 record")

    rows = sorted(csv_rows(source / "dataset.csv"), key=segment_key)
    split_flags = {segment_key(row): segment_flags(row) for row in rows}
    counts = Counter(split_flags.values())
    if len(rows) != len(split_flags) or counts != {(1, 0): 1273, (1, 1): 321, (0, 0): 416, (0, 1): 113}:
        raise ValueError(f"Unexpected author split {counts}")

    raw_keys = set()
    for row in csv_rows(source / "segments.csv"):
        key = segment_key(row)
        if split_flags.get(key) != segment_flags(row):
            raise ValueError(f"Author split or label disagrees in the raw file at {key}")
        raw_keys.add(key)
    if raw_keys != split_flags.keys():
        raise ValueError("Raw and prepared datasets contain different segment keys")

    groups = defaultdict(list)
    test = []
    for row in rows:
        row["case"] = f"{row['channel']}-{row['segment']}"
        row["label"] = int(row["anomaly"])
        if row["train"] == "1":
            groups[row["channel"], row["label"]].append(row)
        else:
            test.append(row)

    rng = np.random.default_rng(2137)
    fit, validation = [], []
    for key in sorted(groups):
        group = groups[key]
        if len(group) < 2:
            raise ValueError(f"Cannot hold out part of training stratum {key}")
        count = max(1, round(len(group) / 5))
        held = set(rng.permutation(len(group))[:count])
        for index, row in enumerate(group):
            (validation if index in held else fit).append(row)
    return {"fit": fit, "validation": validation, "test": test}


def adcs_splits(source):
    splits = defaultdict(list)
    seeds = defaultdict(set)
    for row in csv_rows(source):
        row["label"] = int(row["label"])
        row["case"] = f"{row['seed']}-{row['bias']}-{row['cycle']}"
        splits[row["split"]].append(row)
        seeds[row["split"]].add(int(row["seed"]))
    if (seeds != {"fit": set(range(1001, 1017)), "validation": set(range(2001, 2005)),
                  "test": set(range(3001, 3005))} or
            any(len(group) != 460 * len(seeds[name]) for name, group in splits.items())):
        raise ValueError("Seed or case count does not match the ADCS split contract")
    validation_nominal = (row for row in splits["validation"] if row["label"] == 0)
    if any(int(row["fdir_candidate"]) >= 0 for row in validation_nominal):
        raise ValueError("Independent FDIR exceeds the validation cap of zero nominal alerts")
    return splits


def matrix(rows, features):
    values = np.array([[float(row[name]) for name in features] for row in rows])
    if not np.isfinite(values).all():
        raise ValueError("Cannot use a non-finite feature")
    return values


def labels(rows):
    return np.array([row["label"] for row in rows])


def compress(values, scales):
    result = values.copy()
    active = scales > 0
    selected = result[:, active]
    result[:, active] = np.copysign(np.log1p(np.abs(selected) / scales[active]), selected)
    return result


def validation_threshold(truth, score, zero_false_positives):
    unique = np.unique(score)
    boundaries = np.concatenate(([0.0], unique[:-1] + (unique[1:] - unique[:-1]) / 2, [1.0]))
    trials = []
    for cutoff in boundaries:
        predicted = score >= cutoff
        if zero_false_positives and np.any(predicted & (truth == 0)):
            continue
        trials.append((matthews_corrcoef(truth, predicted), -abs(cutoff - 0.5), float(cutoff)))
    if not trials:
        raise ValueError("No threshold meets the validation false alert cap")
    return max(trials)[2]


def freeze(schema, model, threshold, compression, center, spread, path):
    # A sklearn Linear coefficient array is input-by-output. Row-major iteration
    # writes it in the column-major order of the output-by-input mlpack matrix.
    weights = np.concatenate([
        model.coefs_[0].ravel(), model.intercepts_[0],
        model.coefs_[1].ravel(), model.intercepts_[1],
    ])
    with path.open("w", encoding="ascii") as file:
        print("m4-ffn-v1", schema, model.n_features_in_, model.hidden_layer_sizes[0],
              format(threshold, ".17g"), file=file)
        for row in zip(compression, center, spread):
            print(*(format(value, ".17g") for value in row), file=file)
        print(*(format(value, ".17g") for value in weights), file=file)


def train(schema, source, out, pilot):
    adcs = schema == "adcs-bias"
    features = ADCS_FEATURES if adcs else OPSSAT_FEATURES
    splits = adcs_splits(source) if adcs else opssat_splits(source)
    fit, validation = splits["fit"], splits["validation"]
    x_fit = matrix(fit, features)
    compression = np.zeros(len(features))
    if not adcs:
        for i, col in enumerate(x_fit.T):
            magnitudes = np.abs(col[col != 0])
            compression[i] = np.median(magnitudes) if magnitudes.size else 1.0
    x_fit = compress(x_fit, compression)
    center, spread = x_fit.mean(axis=0), x_fit.std(axis=0)
    spread[spread == 0.0] = 1.0
    model = MLPClassifier(
        hidden_layer_sizes=(8 if adcs else 16,), activation="relu", solver="lbfgs",
        random_state=103 if adcs else 2137, alpha=0.05, max_fun=40000, max_iter=2000, tol=1e-6,
    )
    model.fit((x_fit - center) / spread, labels(fit))
    if model.n_iter_ >= model.max_iter:
        raise ValueError("L-BFGS iteration budget exhausted")
    x_val = (compress(matrix(validation, features), compression) - center) / spread
    val_scores = model.predict_proba(x_val)[:, 1]
    truth = labels(validation)
    cutoff = validation_threshold(truth, val_scores, zero_false_positives=adcs)
    val_labels = val_scores >= cutoff
    if adcs and np.any(val_labels != truth):
        raise ValueError("The bias model did not separate the ADCS validation trajectories")
    freeze(schema, model, cutoff, compression, center, spread, out / "model.txt")
    partition = {
        name: {"nominal": sum(row["label"] == 0 for row in rows),
               "anomaly": sum(row["label"] == 1 for row in rows)}
        for name, rows in splits.items()
    }
    if adcs:
        for name, rows in splits.items():
            partition[name]["seeds"] = sorted({int(row["seed"]) for row in rows})
    print(json.dumps({
        "schema": schema, "features": features, "python": sys.version.split()[0],
        "numpy": np.__version__, "sklearn": sklearn.__version__,
        "partition": partition, "iterations": model.n_iter_, "threshold": cutoff,
        "validation_mcc": matthews_corrcoef(truth, val_labels),
        "validation_fp": int(np.count_nonzero(val_labels & (truth == 0))),
        "validation_fn": int(np.count_nonzero(~val_labels & (truth == 1))),
        "evaluated_split": "validation" if pilot else "test",
    }, indent=2))
    with (out / "split.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(("case", "split", "truth"))
        for name, rows in splits.items():
            writer.writerows((row["case"], name, row["label"]) for row in rows)

    # The model, preprocessing and cutoff have already been frozen.
    holdout = validation if pilot else splits["test"]
    x_test = matrix(holdout, features)
    scores = model.predict_proba((compress(x_test, compression) - center) / spread)[:, 1]
    with (out / "input.csv").open("w", newline="", encoding="utf-8") as inputs, \
         (out / "expected.csv").open("w", newline="", encoding="utf-8") as expected:
        x_writer = csv.writer(inputs, lineterminator="\n")
        y_writer = csv.writer(expected, lineterminator="\n")
        y_writer.writerow(("case", "truth", "reference_score"))
        for row, vector, score in zip(holdout, x_test, scores):
            x_writer.writerow((row["case"], *(format(value, ".17g") for value in vector)))
            y_writer.writerow((row["case"], row["label"], format(score, ".17g")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", choices=["adcs-bias", "opssat-segment"])
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pilot", action="store_true")
    args = parser.parse_args()
    if args.pilot and args.schema != "adcs-bias":
        parser.error("--pilot requires the ADCS generator")
    with threadpool_limits(limits=1):
        train(args.schema, args.source, args.output, args.pilot)


if __name__ == "__main__":
    main()
