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

def compare(old_dir, new_dir, filename, atol, rtol, max_examples):
    old_p, new_p = old_dir / filename, new_dir / filename
    if not old_p.exists() or not new_p.exists():
        print(f"\n{filename}: MISSING FILE: {[str(p) for p in (old_p,new_p) if not p.exists()]}")
        return False
    a, b = read_table(old_p), read_table(new_p)
    print(f"\n=== {filename} ===")
    print("rows:", len(a), "(original),", len(b), "(modified)")
    ca, cb = set(a.columns), set(b.columns)
    print("columns only original:", sorted(ca - cb))
    print("columns only modified:", sorted(cb - ca))
    if ca != cb:
        return False
    keys = KEYS.get(filename, [])
    if not keys:
        # Attrition is usually small and has no ID key.
        a = a.sort_values(list(a.columns), na_position="last").reset_index(drop=True)
        b = b.sort_values(list(b.columns), na_position="last").reset_index(drop=True)
    else:
        for name, df in (("original", a), ("modified", b)):
            print(f"{name}: unique stays = {df['stay_id'].nunique()}, duplicate keys = {df.duplicated(keys).sum()}")
            if filename == "outc.parquet" and "label" in df:
                print(f"{name}: positives = {int(df['label'].sum())}; rate = {df['label'].mean():.6%}")
        if a.duplicated(keys).any() or b.duplicated(keys).any():
            print("FAIL: duplicate keys; cannot safely do 1:1 comparison")
            return False
        if "time" in keys:
            a["time"] = normalize_time(a["time"])
            b["time"] = normalize_time(b["time"])
        ka = pd.MultiIndex.from_frame(a[keys])
        kb = pd.MultiIndex.from_frame(b[keys])
        missing_in_new = ~ka.isin(kb)
        missing_in_old = ~kb.isin(ka)
        print("keys only original:", int(missing_in_new.sum()), "; keys only modified:", int(missing_in_old.sum()))
        if missing_in_new.any():
            print("original-only examples:\n", a.loc[missing_in_new, keys].head(max_examples).to_string(index=False))
        if missing_in_old.any():
            print("modified-only examples:\n", b.loc[missing_in_old, keys].head(max_examples).to_string(index=False))
        a = a.set_index(keys).sort_index()
        b = b.set_index(keys).sort_index()
        common = a.index.intersection(b.index)
        a, b = a.loc[common], b.loc[common]
        if not a.index.equals(b.index):
            b = b.reindex(a.index)
    failed = len(read_table(old_p)) != len(read_table(new_p)) or (len(keys)>0 and (missing_in_new.any() or missing_in_old.any()))
    for col in sorted(set(a.columns) - set(keys)):
        x,y = a[col], b[col]
        if pd.api.types.is_timedelta64_dtype(x) or pd.api.types.is_timedelta64_dtype(y):
            x,y=normalize_time(x),normalize_time(y)
        missing_diff = int((x.isna() != y.isna()).sum())
        both = x.notna() & y.notna()
        if pd.api.types.is_numeric_dtype(x) and pd.api.types.is_numeric_dtype(y):
            same = np.isclose(x[both].to_numpy(dtype=float),y[both].to_numpy(dtype=float),
                              rtol=rtol,atol=atol, equal_nan=True)
        else:
            same = x[both].astype(str).to_numpy() == y[both].astype(str).to_numpy()
        value_diff = int((~same).sum())
        if missing_diff or value_diff:
            failed = True
            print(f"DIFF {col}: missing-mask mismatches={missing_diff}, value mismatches={value_diff}")
            different = (x.isna() != y.isna()).to_numpy()
            positions = np.flatnonzero(both.to_numpy())
            different[positions[~same]] = True
            examples = np.flatnonzero(different)[:max_examples]
            for i in examples:
                idx=a.index[i]
                print(f"  {idx}: original={x.iloc[i]!r}; modified={y.iloc[i]!r}")
    print("RESULT:", "DIFFERENT" if failed else "MATCH")
    return not failed

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--original", required=True, type=Path, help="Original mortality24/hirid directory")
    p.add_argument("--modified", required=True, type=Path, help="Modified mortality24/hirid directory")
    p.add_argument("--atol", type=float, default=1e-8)
    p.add_argument("--rtol", type=float, default=1e-6)
    p.add_argument("--examples", type=int, default=5)
    p.add_argument("--base", action="store_true", help="Compare base cohort; directories should point to base/hirid")
    args=p.parse_args()
    names=["dyn.parquet","sta.parquet","attrition.csv"] if args.base else ["dyn.parquet","sta.parquet","outc.parquet","attrition.csv"]
    status=[compare(args.original,args.modified,n,args.atol,args.rtol,args.examples) for n in names]
    print("\nOVERALL:", "ALL MATCH" if all(status) else "DIFFERENCES FOUND")
    raise SystemExit(0 if all(status) else 1)

if __name__ == "__main__":
    main()
