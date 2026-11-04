#!/usr/bin/env python3
"""Compare original and modified YAIB hourly HiRID mortality cohorts."""
import argparse
from pathlib import Path
import numpy as np
import pandas as pd

KEYS = {"dyn.parquet": ["stay_id", "time"],
        "sta.parquet": ["stay_id"],
        "outc.parquet": ["stay_id"]}

def read_table(path):
    if path.suffix == ".csv":
        return pd.read_csv(path)
    return pd.read_parquet(path)

def normalize_time(s):
    # Preserve time as elapsed physical time in seconds across Arrow/Pandas storage.
    if pd.api.types.is_timedelta64_dtype(s):
        return s.dt.total_seconds()
    if pd.api.types.is_datetime64_any_dtype(s):
        return s.astype("int64") / 1e9
    if pd.api.types.is_numeric_dtype(s):
        return s
    try:
        return pd.to_timedelta(s).dt.total_seconds()
    except (TypeError, ValueError):
        return s


def _scalar_equal(left, right):
    try:
        result = left == right
    except (TypeError, ValueError):
        return False
    return isinstance(result, (bool, np.bool_)) and bool(result)


def _exact_values(left, right):
    """Return exact equality for already aligned, non-missing Series."""
    try:
        values = np.asarray(np.equal(left.to_numpy(), right.to_numpy()), dtype=bool)
        if values.shape == (len(left),):
            return values
    except (TypeError, ValueError):
        pass
    return np.fromiter(
        (_scalar_equal(a, b) for a, b in zip(left.tolist(), right.tolist())),
        dtype=bool,
        count=len(left),
    )


def _sort_without_keys(frame):
    """Sort deterministically without imposing ordering across mixed dtypes."""
    columns = sorted(frame.columns)
    sort_frame = frame[columns].apply(lambda column: column.map(lambda value: "<NA>" if pd.isna(value) else repr(value)))
    order = sort_frame.sort_values(columns, kind="mergesort").index
    return frame.loc[order].reset_index(drop=True)


def _prepare_keyed(frame, keys):
    frame = frame.copy()
    if "time" in keys:
        frame["time"] = normalize_time(frame["time"])
    return frame


def _compare_column(name, left, right, atol, rtol):
    left = left.reset_index(drop=True)
    right = right.reset_index(drop=True)
    missing_left = left.isna().to_numpy()
    missing_right = right.isna().to_numpy()
    missing_diff = int(np.count_nonzero(missing_left != missing_right))
    both = ~(missing_left | missing_right)
    exact = _exact_values(left[both], right[both])
    value_diff = int(np.count_nonzero(~exact))

    if missing_diff or value_diff:
        print(
            f"DIFF {name}: missing-mask mismatches={missing_diff}, "
            f"exact value mismatches={value_diff}"
        )

    if pd.api.types.is_float_dtype(left) or pd.api.types.is_float_dtype(right):
        x = left[both].to_numpy(dtype=float)
        y = right[both].to_numpy(dtype=float)
        finite = np.isfinite(x) & np.isfinite(y)
        abs_diff = np.abs(x[finite] - y[finite])
        max_abs = float(abs_diff.max()) if len(abs_diff) else 0.0
        tolerance_equal = np.isclose(x, y, rtol=rtol, atol=atol, equal_nan=False)
        if value_diff:
            print(
                f"FLOAT {name}: exact mismatches={value_diff}, "
                f"outside tolerance={int(np.count_nonzero(~tolerance_equal))}, "
                f"max_abs_diff={max_abs:.17g}"
            )

    return bool(missing_diff or value_diff)

def compare(old_dir, new_dir, filename, atol, rtol, max_examples):
    old_p, new_p = old_dir / filename, new_dir / filename
    if not old_p.exists() or not new_p.exists():
        missing = [str(p) for p in (old_p, new_p) if not p.exists()]
        print(f"\n{filename}: STATUS: NOT RUN (missing: {missing})")
        return None

    old, new = read_table(old_p).copy(), read_table(new_p).copy()
    print(f"\n=== {filename} ===")
    print("rows:", len(old), "(original),", len(new), "(modified)")
    old_columns, new_columns = set(old.columns), set(new.columns)
    print("columns only original:", sorted(old_columns - new_columns))
    print("columns only modified:", sorted(new_columns - old_columns))
    logical_failed = len(old) != len(new) or old_columns != new_columns

    keys = KEYS.get(filename, [])
    if keys and old_columns == new_columns:
        old, new = _prepare_keyed(old, keys), _prepare_keyed(new, keys)
        for key in keys:
            if str(old[key].dtype) != str(new[key].dtype):
                print(f"TYPE DIFF {key}: original={old[key].dtype}, modified={new[key].dtype}")
                logical_failed = True
        for label, frame in (("original", old), ("modified", new)):
            duplicate_count = int(frame.duplicated(keys).sum())
            print(f"{label}: unique stays = {frame['stay_id'].nunique()}, duplicate keys = {duplicate_count}")
            if filename == "outc.parquet" and "label" in frame:
                print(f"{label}: positives = {int(frame['label'].sum())}; rate = {frame['label'].mean():.6%}")
            logical_failed |= duplicate_count > 0

        if not old.duplicated(keys).any() and not new.duplicated(keys).any():
            old_keys = pd.MultiIndex.from_frame(old[keys])
            new_keys = pd.MultiIndex.from_frame(new[keys])
            missing_in_new = ~old_keys.isin(new_keys)
            missing_in_old = ~new_keys.isin(old_keys)
            print("keys only original:", int(missing_in_new.sum()), "; keys only modified:", int(missing_in_old.sum()))
            if missing_in_new.any():
                print("original-only examples:\n", old.loc[missing_in_new, keys].head(max_examples).to_string(index=False))
            if missing_in_old.any():
                print("modified-only examples:\n", new.loc[missing_in_old, keys].head(max_examples).to_string(index=False))
            logical_failed |= bool(missing_in_new.any() or missing_in_old.any())
            old, new = old.set_index(keys), new.set_index(keys)
            common = old.index.intersection(new.index).sort_values()
            old, new = old.loc[common], new.loc[common]
    elif not keys and old_columns == new_columns:
        old, new = _sort_without_keys(old), _sort_without_keys(new)

    if old_columns == new_columns and len(old) == len(new):
        for column in sorted(old_columns - set(keys)):
            if str(old[column].dtype) != str(new[column].dtype):
                print(f"TYPE DIFF {column}: original={old[column].dtype}, modified={new[column].dtype}")
                logical_failed = True
            logical_failed |= _compare_column(column, old[column], new[column], atol, rtol)

    byte_equal = old_p.read_bytes() == new_p.read_bytes()
    print("LOGICAL STATUS:", "FAIL" if logical_failed else "PASS")
    print("BYTE STATUS:", "PASS" if byte_equal else "DIFFERENT")
    return not logical_failed

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--original", required=True, type=Path)
    p.add_argument("--modified", required=True, type=Path)
    p.add_argument("--atol", type=float, default=1e-8, help="diagnostic tolerance only")
    p.add_argument("--rtol", type=float, default=1e-6, help="diagnostic tolerance only")
    p.add_argument("--examples", type=int, default=5)
    p.add_argument("--base", action="store_true", help="Compare base cohort; directories should point to base/hirid")
    args=p.parse_args()
    names = ["dyn.parquet", "sta.parquet", "attrition.csv"] if args.base else [
        "dyn.parquet", "sta.parquet", "outc.parquet", "attrition.csv"
    ]
    statuses = [compare(args.original, args.modified, name, args.atol, args.rtol, args.examples) for name in names]
    if any(status is False for status in statuses):
        overall, exit_code = "FAIL", 1
    elif any(status is None for status in statuses):
        overall, exit_code = "NOT RUN", 2
    else:
        overall, exit_code = "PASS", 0
    print("\nOVERALL:", overall)
    raise SystemExit(exit_code)

if __name__ == "__main__":
    main()
