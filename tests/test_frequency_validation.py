from datetime import timedelta
from pathlib import Path
import sys

import polars as pl

sys.path.insert(0, str(Path(__file__).parents[1] / "notebooks"))
import validate_frequency_datasets as validation


def _write_dynamic(path: Path, rows: list[dict]) -> None:
    pl.DataFrame(rows).with_columns(pl.col("time").cast(pl.Duration("ms"))).write_parquet(path)


def test_backend_declares_both_sources_at_all_resolutions():
    assert validation.SOURCES["HiRID"]["frequencies"] == ("1h", "15min", "5min")
    assert validation.SOURCES["MIMIC-IV"]["frequencies"] == ("1h", "15min", "5min")
    assert validation.source_name("miiv", "1h") == "miiv"
    assert validation.source_name("miiv", "15min") == "miiv_15min"
    assert validation.source_name("miiv", "5min") == "miiv_5min"


def test_compare_frames_normalizes_nan_and_null_as_same_missing_value():
    left = pl.DataFrame({"stay_id": [1, 2], "value": [float("nan"), None]})
    right = pl.DataFrame({"stay_id": [2, 1], "value": [None, float("nan")]})
    equal, detail = validation.compare_frames(left, right, ["stay_id"])
    assert equal
    assert detail == "exact logical equality"


def test_grid_stats_accepts_shorter_endpoint_inclusive_windows(tmp_path):
    dynamic = tmp_path / "dyn.parquet"
    _write_dynamic(
        dynamic,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 80.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": 81.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 82.0},
            {"stay_id": 2, "time": timedelta(hours=0), "hr": 70.0},
            {"stay_id": 2, "time": timedelta(hours=1), "hr": 71.0},
        ],
    )
    stats = validation.grid_stats(dynamic, step=1.0, max_hours=2.0)
    assert stats["stays"] == 2
    assert stats["min_steps"] == 2
    assert stats["max_steps"] == 3
    assert stats["shorter_than_max_window"] == 1
    assert stats["expected_from_bounds_mismatch"] == 0
    assert stats["irregular_gaps"] == 0
    assert stats["duplicate_timestamp_rows"] == 0


def test_measurement_stats_reports_missingness_density_and_observed_gaps(tmp_path):
    dynamic = tmp_path / "dyn.parquet"
    _write_dynamic(
        dynamic,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 80.0, "alb": None},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": None, "alb": 2.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 82.0, "alb": None},
            {"stay_id": 2, "time": timedelta(hours=0), "hr": None, "alb": None},
            {"stay_id": 2, "time": timedelta(hours=1), "hr": None, "alb": None},
        ],
    )
    rows, _ = validation.measurement_stats(
        dynamic, ["hr", "alb"], stay_ids=pl.Series([1, 2]).to_numpy(), exposure_hours=3.0
    )
    by_variable = {row["variable"]: row for row in rows}
    assert by_variable["hr"]["observed"] == 2
    assert by_variable["hr"]["observed_stays"] == 1
    assert by_variable["hr"]["no_observation_stays"] == 1
    assert by_variable["hr"]["gap_count"] == 1
    assert by_variable["hr"]["gap_mean_hours"] == 2.0
    assert by_variable["alb"]["observed"] == 1
    assert by_variable["alb"]["observations_per_patient_hour"] == 1 / 3


def test_aggregation_stats_preserves_empty_hourly_bins(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 30.0},
        ],
    )
    _write_dynamic(
        fine,
        [
            {"stay_id": 1, "time": timedelta(minutes=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=15), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=30), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=45), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=15), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=30), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=45), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 30.0},
        ],
    )
    result = validation.aggregation_stats(hourly, fine, ["hr"], step=0.25)[0]
    assert result["hour_rows"] == 3
    assert result["comparable_hourly_bins"] == 3
    assert result["fine_hour_bins"] == 3
    assert result["missing_both"] == 1
    assert result["missingness_disagreements"] == 0
    assert result["numeric_differences"] == 0
    assert result["exact_matches"] == 2


def test_aggregation_stats_uses_the_bin_median_and_detects_duplicate_keys(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 25.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": None},
        ],
    )
    _write_dynamic(
        fine,
        [
            {"stay_id": 1, "time": timedelta(minutes=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=15), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(minutes=30), "hr": 30.0},
            {"stay_id": 1, "time": timedelta(minutes=45), "hr": 40.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": None},
        ],
    )
    result = validation.aggregation_stats(hourly, fine, ["hr"], step=0.25)[0]
    assert result["numeric_differences"] == 0
    assert result["missingness_disagreements"] == 0
    assert result["missing_both"] == 1
    assert result["exact_matches"] == 1

    duplicate = tmp_path / "duplicate.parquet"
    _write_dynamic(
        duplicate,
        [
            {"stay_id": 1, "time": timedelta(0), "hr": 1.0},
            {"stay_id": 1, "time": timedelta(0), "hr": 2.0},
        ],
    )
    assert validation.duplicate_keys(duplicate) == 1


def test_aggregation_stats_excludes_extra_endpoint_rows_from_missingness(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 30.0},
        ],
    )
    _write_dynamic(
        fine,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=15), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=30), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=45), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=15), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=30), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=45), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 30.0},
            {"stay_id": 1, "time": timedelta(hours=2, minutes=15), "hr": 999.0},
        ],
    )
    result = validation.aggregation_stats(hourly, fine, ["hr"], step=0.25)[0]
    assert result["comparable_hourly_bins"] == 3
    assert result["extra_fine_rows_outside_common_window"] == 1
    assert result["partial_final_hour_bins"] == 0
    assert result["missingness_disagreements"] == 0
    assert result["unmatched_hourly_stays"] == 0
    assert result["unmatched_fine_stays"] == 0


def test_aggregation_stats_handles_partial_final_bin_and_alignment(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 30.0},
        ],
    )
    _write_dynamic(
        fine,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=5), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=20), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=35), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(minutes=50), "hr": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=5), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=20), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=35), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=50), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=55), "hr": 20.0},
        ],
    )
    result = validation.aggregation_stats(hourly, fine, ["hr"], step=0.25)[0]
    assert result["comparable_hourly_bins"] == 2
    assert result["partial_final_hour_bins"] == 1
    assert result["extra_fine_rows_outside_common_window"] == 0
    assert result["missingness_disagreements"] == 0
    assert result["hourly_timestamps_missing_in_fine"] == 1


def test_aggregation_stats_separates_missingness_denominators(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": 20.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": None},
        ],
    )
    _write_dynamic(
        fine,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "hr": None},
            {"stay_id": 1, "time": timedelta(minutes=15), "hr": None},
            {"stay_id": 1, "time": timedelta(minutes=30), "hr": None},
            {"stay_id": 1, "time": timedelta(minutes=45), "hr": None},
            {"stay_id": 1, "time": timedelta(hours=1), "hr": 21.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=15), "hr": 21.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=30), "hr": 21.0},
            {"stay_id": 1, "time": timedelta(hours=1, minutes=45), "hr": 21.0},
            {"stay_id": 1, "time": timedelta(hours=2), "hr": 30.0},
        ],
    )
    result = validation.aggregation_stats(hourly, fine, ["hr"], step=0.25)[0]
    assert result["comparable_hourly_bins"] == 3
    assert result["missing_both"] == 1
    assert result["missingness_disagreements"] == 1
    assert result["both_observed"] == 1
    assert result["numeric_differences"] == 1
    assert result["difference_fraction_of_observed"] == 1.0


def test_aggregation_stats_supports_variable_specific_sum_reference(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [
            {"stay_id": 1, "time": timedelta(hours=0), "urine": 10.0},
            {"stay_id": 1, "time": timedelta(hours=1), "urine": None},
        ],
    )
    _write_dynamic(
        fine,
        [
            {"stay_id": 1, "time": timedelta(minutes=0), "urine": 2.0},
            {"stay_id": 1, "time": timedelta(minutes=15), "urine": 3.0},
            {"stay_id": 1, "time": timedelta(minutes=30), "urine": 5.0},
            {"stay_id": 1, "time": timedelta(hours=1), "urine": None},
        ],
    )
    result = validation.aggregation_stats(
        hourly, fine, ["urine"], step=0.25, aggregation={"urine": "sum"}
    )[0]
    assert result["fine_reference_aggregation"] == "sum"
    assert result["numeric_differences"] == 0
    assert result["missing_both"] == 1


def test_aggregation_stats_pairs_stays_by_id_without_counting_unmatched_stays_as_missing(tmp_path):
    hourly = tmp_path / "hourly.parquet"
    fine = tmp_path / "fine.parquet"
    _write_dynamic(
        hourly,
        [{"stay_id": 1, "time": timedelta(0), "hr": 80.0}],
    )
    _write_dynamic(
        fine,
        [{"stay_id": 2, "time": timedelta(0), "hr": 80.0}],
    )
    result = validation.aggregation_stats(hourly, fine, ["hr"], step=0.25)[0]
    assert result["comparable_hourly_bins"] == 0
    assert result["unmatched_hourly_stays"] == 1
    assert result["unmatched_fine_stays"] == 1
    assert result["missingness_disagreements"] == 0
