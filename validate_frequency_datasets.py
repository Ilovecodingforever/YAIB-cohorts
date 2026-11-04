#!/usr/bin/env python3
"""Read-only validation of processed YAIB frequency cohorts.

The script intentionally reads only processed parquet/CSV files.  It uses
PyArrow batches for dynamic-variable summaries so the 5-minute base cohorts
are not loaded into memory as a single table.
"""

from __future__ import annotations

import argparse
import json
import math
import warnings
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import polars as pl
import pyarrow.parquet as pq


SOURCES = {
    "HiRID": {"prefix": "hirid", "frequencies": ("1h", "15min", "5min")},
    "MIMIC-IV": {"prefix": "miiv", "frequencies": ("1h", "15min", "5min")},
}
FREQUENCY_STEPS = {"1h": 1.0, "15min": 0.25, "5min": 1.0 / 12.0}
COHORTS = {"base": 168.0, "mortality24": 24.0}
STAY = "stay_id"
TIME = "time"
LABEL = "label"
TOL = 1e-9
DEFAULT_ROOT = Path("/heinz-georgenas/users/mingzhul/Simultaneous-EHR/yaib/data")
DEFAULT_OUT = Path("validation_results/frequency_validation")


def source_name(prefix: str, frequency: str) -> str:
    return prefix if frequency == "1h" else f"{prefix}_{frequency}"


def path_for(root: Path, cohort: str, prefix: str, frequency: str, table: str) -> Path:
    return root / cohort / source_name(prefix, frequency) / table


def missing_expr(column: str) -> pl.Expr:
    return pl.col(column).is_null() | pl.col(column).cast(pl.Float64).is_nan()


def normalise_nulls(frame: pl.DataFrame) -> pl.DataFrame:
    expressions = []
    for column, dtype in zip(frame.columns, frame.dtypes):
        if dtype in (pl.Float32, pl.Float64):
            expressions.append(
                pl.when(pl.col(column).is_nan()).then(None).otherwise(pl.col(column)).alias(column)
            )
    return frame.with_columns(expressions) if expressions else frame


def compare_frames(left: pl.DataFrame, right: pl.DataFrame, keys: list[str]) -> tuple[bool, str]:
    left = normalise_nulls(left.sort(keys))
    right = normalise_nulls(right.sort(keys))
    if left.columns != right.columns:
        return False, f"columns differ: {left.columns} != {right.columns}"
    if left.dtypes != right.dtypes:
        return False, f"dtypes differ: {left.dtypes} != {right.dtypes}"
    if left.height != right.height:
        return False, f"rows differ: {left.height} != {right.height}"
    if left.equals(right, null_equal=True):
        return True, "exact logical equality"
    joined = left.join(right, on=keys, how="full", suffix="_other")
    mismatches = 0
    examples: list[dict[str, Any]] = []
    for column in left.columns:
        if column in keys:
            continue
        other = f"{column}_other"
        if other not in joined.columns:
            mismatches += joined.height
            continue
        equal = (
            (pl.col(column).is_null() & pl.col(other).is_null())
            | (pl.col(column).is_not_null() & pl.col(other).is_not_null() & (pl.col(column) == pl.col(other)))
        )
        bad = joined.filter(~equal)
        mismatches += bad.height
        if bad.height and len(examples) < 3:
            examples.extend(bad.select(keys + [column, other]).head(3).to_dicts())
    detail = f"{mismatches} cell mismatches"
    if examples:
        detail += f"; examples={examples}"
    return False, detail


def read_small(path: Path) -> pl.DataFrame:
    return pl.read_csv(path) if path.suffix == ".csv" else pl.read_parquet(path)


def exact_file_comparison(root: Path, cohort: str, prefix: str, frequencies: tuple[str, ...]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    hourly = source_name(prefix, "1h")
    tables = ["dyn.parquet", "sta.parquet"] + (["outc.parquet"] if cohort == "mortality24" else []) + ["attrition.csv"]
    for table in tables:
        base_path = root / cohort / hourly / table
        if not base_path.exists():
            rows.append({"cohort": cohort, "source": prefix, "check": f"{table} exact across frequencies", "status": "NOT RUN", "detail": str(base_path)})
            continue
        base = read_small(base_path) if table != "dyn.parquet" else None
        base_ids = None
        if table == "dyn.parquet":
            base_ids = pl.scan_parquet(base_path).select(STAY).unique().collect().sort(STAY)
        for frequency in frequencies[1:]:
            path = root / cohort / source_name(prefix, frequency) / table
            check = f"{table} exact hourly-vs-{frequency}"
            if not path.exists():
                rows.append({"cohort": cohort, "source": prefix, "check": check, "status": "NOT RUN", "detail": str(path)})
                continue
            if table == "dyn.parquet":
                candidate_ids = pl.scan_parquet(path).select(STAY).unique().collect().sort(STAY)
                ok, detail = compare_frames(base_ids, candidate_ids, [STAY])
            else:
                candidate = read_small(path)
                ok, detail = compare_frames(base, candidate, [STAY] if STAY in base.columns else base.columns)
            rows.append({"cohort": cohort, "source": prefix, "check": check, "status": "PASS" if ok else "FAIL", "detail": detail})
    return rows


def dynamic_schema(path: Path) -> dict[str, pl.DataType]:
    return dict(pl.scan_parquet(path).collect_schema())


def duplicate_keys(path: Path) -> int:
    return int(
        pl.scan_parquet(path)
        .group_by([STAY, TIME])
        .agg(pl.len().alias("n"))
        .filter(pl.col("n") > 1)
        .select(pl.len())
        .collect(engine="streaming")
        .item()
    )


def _duration_hours(values: np.ndarray) -> np.ndarray:
    if np.issubdtype(values.dtype, np.timedelta64):
        return values.astype("timedelta64[ms]").astype(np.float64) / 3_600_000.0
    return values.astype(np.float64) / 3_600_000.0


def grid_stats(path: Path, step: float, max_hours: float) -> dict[str, Any]:
    parquet = pq.ParquetFile(path)
    stay_counts: dict[int, int] = {}
    stay_min: dict[int, float] = {}
    stay_max: dict[int, float] = {}
    gaps = 0
    irregular = 0
    zero_gaps = 0
    gap_sum = 0.0
    gap_min = math.inf
    gap_max = -math.inf
    previous_stay: int | None = None
    previous_time: float | None = None
    alignment_max = 0.0
    for batch in parquet.iter_batches(columns=[STAY, TIME], batch_size=250_000):
        stays = batch.column(0).to_numpy(zero_copy_only=False)
        times = _duration_hours(batch.column(1).to_numpy(zero_copy_only=False))
        unique_stays, counts = np.unique(stays, return_counts=True)
        for stay, count in zip(unique_stays.tolist(), counts.tolist()):
            stay = int(stay)
            stay_counts[stay] = stay_counts.get(stay, 0) + int(count)
        starts = np.r_[previous_stay, stays[:-1]] if previous_stay is not None else stays[:-1]
        prior_times = np.r_[previous_time, times[:-1]] if previous_time is not None else times[:-1]
        if len(times):
            comparison_stays = stays if previous_stay is not None else stays[1:]
            current_times = times if previous_stay is not None else times[1:]
            same = comparison_stays == starts
            current_times = current_times[same]
            prior_times = prior_times[same]
            local_gaps = current_times - prior_times
            if len(local_gaps):
                gaps += len(local_gaps)
                zero_gaps += int(np.sum(np.isclose(local_gaps, 0.0, atol=TOL)))
                irregular += int(np.sum(~np.isclose(local_gaps, step, atol=TOL)))
                gap_sum += float(local_gaps.sum())
                gap_min = min(gap_min, float(local_gaps.min()))
                gap_max = max(gap_max, float(local_gaps.max()))
        alignment = np.abs(times / step - np.rint(times / step))
        if len(alignment):
            alignment_max = max(alignment_max, float(alignment.max()))
        previous_stay = int(stays[-1]) if len(stays) else previous_stay
        previous_time = float(times[-1]) if len(times) else previous_time
    lengths = np.asarray(list(stay_counts.values()), dtype=np.int64)
    mins: dict[int, float] = {}
    maxs: dict[int, float] = {}
    # Keep only one aggregate per contiguous stay in each batch; no timestamp
    # matrix is retained for the large 5-minute files.
    for batch in parquet.iter_batches(columns=[STAY, TIME], batch_size=250_000):
        stays = batch.column(0).to_numpy(zero_copy_only=False)
        times = _duration_hours(batch.column(1).to_numpy(zero_copy_only=False))
        if not len(stays):
            continue
        starts = np.r_[0, np.flatnonzero(stays[1:] != stays[:-1]) + 1]
        ends = np.r_[starts[1:] - 1, len(stays) - 1]
        for start, end in zip(starts.tolist(), ends.tolist()):
            stay = int(stays[start])
            mins[stay] = min(mins.get(stay, math.inf), float(times[start]))
            maxs[stay] = max(maxs.get(stay, -math.inf), float(times[end]))
    expected_lengths = np.asarray([round((maxs[s] - mins[s]) / step) + 1 for s in stay_counts], dtype=np.int64)
    length_values = np.asarray([stay_counts[s] for s in stay_counts], dtype=np.int64)
    span_values = np.asarray([maxs[s] - mins[s] for s in stay_counts], dtype=float)
    return {
        "stays": len(lengths),
        "rows": int(lengths.sum()),
        "exposure_hours": float(span_values.sum()) if len(span_values) else 0.0,
        "min_timestamp_hours": float(min(mins.values())) if mins else None,
        "max_timestamp_hours": float(max(maxs.values())) if maxs else None,
        "min_steps": int(length_values.min()) if len(length_values) else None,
        "max_steps": int(length_values.max()) if len(length_values) else None,
        "expected_from_bounds_mismatch": int(np.sum(length_values != expected_lengths)),
        "complete_max_window": int(np.sum(np.isclose(span_values, max_hours, atol=TOL))),
        "shorter_than_max_window": int(np.sum(span_values < max_hours - TOL)),
        "over_max_window": int(np.sum(span_values > max_hours + TOL)),
        "duplicate_timestamp_rows": zero_gaps,
        "observed_gaps": gaps,
        "irregular_gaps": irregular,
        "gap_min_hours": None if not gaps else gap_min,
        "gap_mean_hours": None if not gaps else gap_sum / gaps,
        "gap_max_hours": None if not gaps else gap_max,
        "alignment_max_steps": alignment_max,
        "time_dtype": str(dynamic_schema(path)[TIME]),
    }


def _to_numpy(array: Any) -> np.ndarray:
    try:
        return array.to_numpy(zero_copy_only=False, na_value=np.nan)
    except TypeError:
        return np.asarray(array.to_pandas())


def measurement_stats(path: Path, variables: list[str], stay_ids: np.ndarray, exposure_hours: float, seed: int = 42) -> tuple[list[dict[str, Any]], dict[str, np.ndarray]]:
    del seed
    n_stays = len(stay_ids)
    scan = pl.scan_parquet(path)
    length = int(scan.select(pl.len()).collect(engine="streaming").item())
    observed = [f"{variable}__observed" for variable in variables]
    nonfinite = [f"{variable}__nonfinite" for variable in variables]
    total_exprs = []
    for variable, observed_name, nonfinite_name in zip(variables, observed, nonfinite):
        missing = missing_expr(variable)
        total_exprs.extend([
            (~missing).sum().alias(observed_name),
            ((pl.col(variable).cast(pl.Float64).is_nan()) & pl.col(variable).is_not_null()).sum().alias(nonfinite_name),
        ])
    totals = scan.select(total_exprs).collect(engine="streaming").to_dicts()[0]
    per_stay_exprs = []
    for variable in variables:
        per_stay_exprs.append((~missing_expr(variable)).sum().alias(variable))
    per_stay = scan.group_by(STAY).agg(per_stay_exprs).collect(engine="streaming")
    samples_frame = scan.select(variables).head(100_000).collect(engine="streaming")
    samples = {}
    for variable in variables:
        values = samples_frame.get_column(variable).cast(pl.Float64).drop_nulls().to_numpy()
        values = values[np.isfinite(values)][:20_000]
        samples[variable] = values
    gap_summary = observed_gap_stats(path, variables)
    rows = []
    for variable in variables:
        counts = per_stay.get_column(variable).to_numpy().astype(np.float64, copy=False)
        total = int(totals[f"{variable}__observed"] or 0)
        values = samples[variable]
        observed_stays = int(np.sum(counts > 0))
        rows.append({
            "variable": variable,
            "rows": length,
            "observed": total,
            "observed_rate": float(total / length) if length else None,
            "missing_rate": float(1.0 - total / length) if length else None,
            "observed_stays": observed_stays,
            "no_observation_stays": int(n_stays - observed_stays),
            "observations_per_stay_mean": float(counts.mean()) if n_stays else None,
            "observations_per_stay_median": float(np.median(counts)) if n_stays else None,
            "observations_per_stay_p95": float(np.quantile(counts, 0.95)) if n_stays else None,
            "observations_per_patient_hour": float(total / max(1.0, exposure_hours)),
            "gap_count": gap_summary[variable]["count"],
            "gap_mean_hours": gap_summary[variable]["mean"],
            "gap_min_hours": gap_summary[variable]["min"],
            "gap_p95_hours": gap_summary[variable]["p95"],
            "gap_max_hours": gap_summary[variable]["max"],
            "nonfinite": int(totals[f"{variable}__nonfinite"] or 0),
            "sample_min": None if not len(values) else float(values.min()),
            "sample_median": None if not len(values) else float(np.median(values)),
            "sample_max": None if not len(values) else float(values.max()),
        })
    return rows, samples


def observed_gap_stats(path: Path, variables: list[str]) -> dict[str, dict[str, Any]]:
    counts = np.zeros(len(variables), dtype=np.int64)
    sums = np.zeros(len(variables), dtype=np.float64)
    minimum = np.full(len(variables), np.inf)
    maximum = np.full(len(variables), -np.inf)
    samples = [[] for _ in variables]
    for _, times, values in stay_groups(path, variables):
        for index in range(len(variables)):
            observed_times = times[np.isfinite(values[:, index])]
            gaps = np.diff(observed_times)
            if not len(gaps):
                continue
            counts[index] += len(gaps)
            sums[index] += float(gaps.sum())
            minimum[index] = min(minimum[index], float(gaps.min()))
            maximum[index] = max(maximum[index], float(gaps.max()))
            if len(samples[index]) < 20_000:
                samples[index].extend(gaps[:20_000 - len(samples[index])].tolist())
    result = {}
    for index, variable in enumerate(variables):
        sample = np.asarray(samples[index], dtype=float)
        result[variable] = {
            "count": int(counts[index]),
            "mean": None if not counts[index] else float(sums[index] / counts[index]),
            "min": None if not counts[index] else float(minimum[index]),
            "p95": None if not len(sample) else float(np.quantile(sample, 0.95)),
            "max": None if not counts[index] else float(maximum[index]),
        }
    return result


def stay_groups(path: Path, variables: list[str]):
    """Yield one stay at a time, keeping at most one stay in memory."""
    parquet = pq.ParquetFile(path)
    current_stay = None
    current_times: list[np.ndarray] = []
    current_values: list[np.ndarray] = []
    for batch in parquet.iter_batches(columns=[STAY, TIME, *variables], batch_size=250_000):
        stays = batch.column(0).to_numpy(zero_copy_only=False).astype(np.int64, copy=False)
        times = _duration_hours(batch.column(1).to_numpy(zero_copy_only=False))
        values = np.column_stack([
            _to_numpy(batch.column(index + 2)).astype(np.float64, copy=False)
            for index in range(len(variables))
        ])
        if not len(stays):
            continue
        starts = np.r_[0, np.flatnonzero(stays[1:] != stays[:-1]) + 1]
        ends = np.r_[starts[1:], len(stays)]
        for start, end in zip(starts.tolist(), ends.tolist()):
            stay = int(stays[start])
            if current_stay is not None and stay != current_stay:
                yield current_stay, np.concatenate(current_times), np.concatenate(current_values, axis=0)
                current_times = []
                current_values = []
            current_stay = stay
            current_times.append(times[start:end])
            current_values.append(values[start:end, :])
    if current_stay is not None:
        yield current_stay, np.concatenate(current_times), np.concatenate(current_values, axis=0)


def aggregation_stats(hourly: Path, fine: Path, variables: list[str], step: float) -> list[dict[str, Any]]:
    count = len(variables)
    hour_rows = np.zeros(count, dtype=np.int64)
    fine_bin_count = np.zeros(count, dtype=np.int64)
    both_observed = np.zeros(count, dtype=np.int64)
    missing_disagreements = np.zeros(count, dtype=np.int64)
    exact = np.zeros(count, dtype=np.int64)
    different = np.zeros(count, dtype=np.int64)
    abs_sum = np.zeros(count, dtype=np.float64)
    max_abs = np.full(count, np.nan)
    for hourly_group, fine_group in zip(stay_groups(hourly, variables), stay_groups(fine, variables)):
        hourly_stay, hourly_times, hourly_values = hourly_group
        fine_stay, fine_times, fine_values = fine_group
        if hourly_stay != fine_stay:
            missing_disagreements += 1
            continue
        hour_rows += len(hourly_times)
        fine_bin_count += len(hourly_times)
        bins_per_hour = int(round(1.0 / step))
        complete_hours = len(hourly_times) - 1
        expected_fine_rows = complete_hours * bins_per_hour + 1
        if len(fine_times) != expected_fine_rows:
            missing_disagreements += abs(len(fine_times) - expected_fine_rows)
            continue
        fine_matrix = fine_values[:complete_hours * bins_per_hour]
        fine_matrix = fine_matrix.reshape(complete_hours, bins_per_hour, count)
        fine_matrix[~np.isfinite(fine_matrix)] = np.nan
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            fine_medians = np.nanmedian(fine_matrix, axis=1)
        fine_medians[np.sum(np.isfinite(fine_matrix), axis=1) == 0] = np.nan
        fine_medians = np.vstack([fine_medians, fine_values[-1]])
        # The native hourly grid is already one row per hour; retain the
        # matrix shape so all variables are compared in one vectorized pass.
        hour_matrix = hourly_values.astype(np.float64, copy=False)
        hour_matrix[~np.isfinite(hour_matrix)] = np.nan
        hour_missing = np.isnan(hour_matrix)
        fine_missing = np.isnan(fine_medians)
        missing_disagreements += np.sum(hour_missing ^ fine_missing, axis=0)
        both = ~hour_missing & ~fine_missing
        both_observed += np.sum(both, axis=0)
        differences = np.abs(hour_matrix - fine_medians)
        differences[~both] = 0.0
        abs_sum += differences.sum(axis=0)
        changed = both & (differences > TOL)
        different += np.sum(changed, axis=0)
        exact += np.sum((hour_missing & fine_missing) | (both & ~changed), axis=0)
        max_abs = np.fmax(max_abs, differences.max(axis=0))
    rows = []
    for index, variable in enumerate(variables):
        rows.append({
            "variable": variable,
            "hour_rows": int(hour_rows[index]),
            "fine_hour_bins": int(fine_bin_count[index]),
            "both_observed": int(both_observed[index]),
            "missingness_disagreements": int(missing_disagreements[index]),
            "exact_matches": int(exact[index]),
            "numeric_differences": int(different[index]),
            "max_abs_difference": None if np.isnan(max_abs[index]) else float(max_abs[index]),
            "mean_abs_difference": float(abs_sum[index] / both_observed[index]) if both_observed[index] else None,
        })
    return rows


def save_figures(out: Path, stats: pl.DataFrame, samples: dict[tuple[str, str, str], dict[str, np.ndarray]], variables: list[str]) -> None:
    import matplotlib.pyplot as plt

    for source in SOURCES:
        for cohort in COHORTS:
            subset = stats.filter((pl.col("source") == source) & (pl.col("cohort") == cohort))
            if subset.is_empty():
                continue
            freqs = list(SOURCES[source]["frequencies"])
            fig, ax = plt.subplots(figsize=(15, 5))
            for frequency in freqs:
                frame = subset.filter(pl.col("frequency") == frequency).sort("variable")
                ax.plot(frame["variable"].to_list(), frame["missing_rate"].to_numpy() * 100, marker=".", label=frequency)
            ax.set_ylabel("Missing bins (%)")
            ax.set_title(f"{source} {cohort}: dynamic-variable missingness")
            ax.tick_params(axis="x", rotation=90)
            ax.legend()
            fig.tight_layout()
            fig.savefig(out / f"{source.lower().replace('-', '')}_{cohort}_missingness.png", dpi=140)
            plt.close(fig)

            core = [v for v in variables if v in {"hr", "sbp", "dbp", "map", "resp", "temp", "o2sat", "glu", "crea", "lact"}]
            fig, axes = plt.subplots(2, 5, figsize=(15, 6), squeeze=False)
            for ax, variable in zip(axes.flat, core):
                for frequency in freqs:
                    values = samples.get((source, cohort, frequency), {}).get(variable, np.array([]))
                    values = values[np.isfinite(values)]
                    if len(values):
                        ax.hist(values, bins=30, density=True, alpha=0.35, label=frequency)
                ax.set_title(variable)
            axes[0, 0].legend(fontsize=8)
            fig.suptitle(f"{source} {cohort}: sampled processed-value distributions")
            fig.tight_layout()
            fig.savefig(out / f"{source.lower().replace('-', '')}_{cohort}_feature_distributions.png", dpi=140)
            plt.close(fig)

            fig, ax = plt.subplots(figsize=(15, 5))
            for frequency in freqs:
                frame = subset.filter(pl.col("frequency") == frequency).sort("variable")
                ax.plot(frame["variable"].to_list(), frame["observations_per_stay_median"].to_numpy(), marker=".", label=frequency)
            ax.set_ylabel("Median observations per stay")
            ax.set_title(f"{source} {cohort}: measurement density")
            ax.tick_params(axis="x", rotation=90)
            ax.legend()
            fig.tight_layout()
            fig.savefig(out / f"{source.lower().replace('-', '')}_{cohort}_density.png", dpi=140)
            plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)
    result_rows: list[dict[str, Any]] = []
    grid_rows: list[dict[str, Any]] = []
    stats_rows: list[dict[str, Any]] = []
    aggregation_rows: list[dict[str, Any]] = []
    samples: dict[tuple[str, str, str], dict[str, np.ndarray]] = {}

    for source, config in SOURCES.items():
        prefix = config["prefix"]
        for cohort, max_hours in COHORTS.items():
            available = []
            for frequency in config["frequencies"]:
                directory = args.data_root / cohort / source_name(prefix, frequency)
                required = [directory / "dyn.parquet", directory / "sta.parquet", directory / "attrition.csv"]
                if cohort == "mortality24":
                    required.append(directory / "outc.parquet")
                if all(path.exists() for path in required):
                    available.append(frequency)
                else:
                    result_rows.append({"cohort": cohort, "source": source, "check": f"files {frequency}", "status": "NOT RUN", "detail": ", ".join(str(p) for p in required if not p.exists())})
            if len(available) != 3:
                continue
            prefix_rows = exact_file_comparison(args.data_root, cohort, prefix, tuple(available))
            result_rows.extend(prefix_rows)
            for frequency in available:
                dyn = path_for(args.data_root, cohort, prefix, frequency, "dyn.parquet")
                sta = path_for(args.data_root, cohort, prefix, frequency, "sta.parquet")
                schema = dynamic_schema(dyn)
                variables = [column for column in schema if column not in {STAY, TIME}]
                stay_ids = np.asarray(pl.read_parquet(sta, columns=[STAY]).get_column(STAY).unique().sort().to_list(), dtype=np.int64)
                grid = grid_stats(dyn, FREQUENCY_STEPS[frequency], max_hours)
                grid.update({"source": source, "cohort": cohort, "frequency": frequency})
                grid_rows.append(grid)
                result_rows.append({"cohort": cohort, "source": source, "check": f"grid {frequency}", "status": "PASS" if grid["irregular_gaps"] == 0 and grid["expected_from_bounds_mismatch"] == 0 and grid["over_max_window"] == 0 and grid["alignment_max_steps"] < TOL else "FAIL", "detail": json.dumps(grid, sort_keys=True)})
                result_rows.append({"cohort": cohort, "source": source, "check": f"duplicate (stay_id,time) {frequency}", "status": "PASS" if grid["duplicate_timestamp_rows"] == 0 else "FAIL", "detail": str(grid["duplicate_timestamp_rows"])})
                rows, sample = measurement_stats(dyn, variables, stay_ids, grid["exposure_hours"])
                for row in rows:
                    row.update({"source": source, "cohort": cohort, "frequency": frequency})
                    stats_rows.append(row)
                samples[(source, cohort, frequency)] = {key: np.asarray(value, dtype=float) for key, value in sample.items()}
            hourly = path_for(args.data_root, cohort, prefix, "1h", "dyn.parquet")
            variables = [c for c in dynamic_schema(hourly) if c not in {STAY, TIME}]
            for frequency in available[1:]:
                fine = path_for(args.data_root, cohort, prefix, frequency, "dyn.parquet")
                for row in aggregation_stats(hourly, fine, variables, FREQUENCY_STEPS[frequency]):
                    aggregation_rows.append({"source": source, "cohort": cohort, "frequency": frequency, **row})

    result = pl.DataFrame(result_rows)
    grids = pl.DataFrame(grid_rows)
    stats = pl.DataFrame(stats_rows)
    aggregations = pl.DataFrame(aggregation_rows)
    result.write_csv(out / "validation_checks.csv")
    grids.write_csv(out / "temporal_grid_summary.csv")
    stats.write_csv(out / "dynamic_measurement_statistics.csv")
    aggregations.write_csv(out / "hourly_aggregation_diagnostics.csv")
    save_figures(out, stats, samples, sorted(stats["variable"].unique().to_list()) if not stats.is_empty() else [])
    print(result.group_by("status").len().sort("status"))
    print(f"outputs: {out}")
    return 1 if result.filter(pl.col("status") == "FAIL").height else 0


if __name__ == "__main__":
    raise SystemExit(main())
