library(argparser)
library(assertthat)
library(rlang)
library(data.table)
library(vctrs)
library(yaml)

source("src/frequency.R")

p <- arg_parser("Extract configurable-window ICU mortality data")
p <- add_argument(p, "--src", help = "source database", default = "mimic_demo")
p <- add_argument(p, "--frequency", help = "5min, 15min, or 1h", default = "1h")
p <- add_argument(
  p, "--observation-hours",
  help = "last included hourly bin index W; prediction starts at W + 1h",
  type = "numeric", default = 24
)
p <- add_argument(
  p, "--prediction-hours",
  help = "prediction horizon H in hours",
  type = "numeric", default = 12
)
argv <- parse_args(p)

src <- argv$src
assert_landmark_source(src)
frequency <- frequency_spec(argv$frequency, src)
observation_hours <- argv$observation_hours
prediction_hours <- argv$prediction_hours

conf <- yaml.load_file("../config.yaml")
path <- file.path(
  conf$out_dir,
  paste0("mortality_w", observation_hours, "_h", prediction_hours)
)
base_path <- file.path(conf$out_dir, "base", src, "sta.parquet")
base_dir <- file.path(conf$out_dir, "base", src)

base_provenance <- canonical_hourly_provenance(
  src,
  "../config.yaml",
  conf$ricu_data_path,
  canonical_provenance_files()
)
if (!file.exists(base_path)) {
  stop(
    "Canonical hourly base cohort not found at ", base_path, ". ",
    "Generate it first with: cd R && Rscript base_cohort.R --src ",
    src, " --frequency 1h",
    call. = FALSE
  )
}
if (frequency$label != "1h") {
  validate_canonical_provenance(base_dir, base_provenance)
}

source(".load_ricu.R")
source("src/misc.R")
source("src/steps.R")
source("src/sequential.R")
source("src/obs_time.R")
source("src/mortality_landmark.R")

cncpt_env <- new.env()
time_flow <- "sequential"
interval <- frequency$interval
static_vars <- c("age", "sex", "height", "weight")
dynamic_vars <- c(
  "alb", "alp", "alt", "ast", "be", "bicar", "bili", "bili_dir",
  "bnd", "bun", "ca", "cai", "ck", "ckmb", "cl", "crea", "crp",
  "dbp", "fgn", "fio2", "glu", "hgb", "hr", "inr_pt", "k", "lact",
  "lymph", "map", "mch", "mchc", "mcv", "methb", "mg", "na", "neut",
  "o2sat", "pco2", "ph", "phos", "plt", "po2", "ptt", "resp", "sbp",
  "temp", "tnt", "urine", "wbc"
)

landmark <- landmark_parameters(observation_hours, prediction_hours, interval)

base <- arrow::read_parquet(base_path)
base_ids <- unique(base$stay_id)

metadata_dir <- file.path(path, src)
metadata_path <- file.path(metadata_dir, "outcome_metadata.parquet")
metadata_provenance_path <- file.path(
  metadata_dir, "outcome_metadata_provenance.json"
)
provenance <- landmark_task_provenance(
  src, observation_hours, prediction_hours, frequency,
  base_provenance, "exclude"
)
metadata_provenance <- provenance
metadata_provenance$frequency <- NULL
metadata_provenance$metadata_interval <- "1min"

if (file.exists(metadata_path) && file.exists(metadata_provenance_path)) {
  recorded <- jsonlite::read_json(
    metadata_provenance_path, simplifyVector = FALSE
  )
  expected <- jsonlite::toJSON(
    metadata_provenance, auto_unbox = TRUE, null = "null"
  )
  actual <- jsonlite::toJSON(recorded, auto_unbox = TRUE, null = "null")
  if (!identical(actual, expected)) {
    stop("Existing landmark metadata provenance is incompatible; remove the task directory and regenerate.")
  }
  metadata <- arrow::read_parquet(metadata_path)
  metadata <- as.data.table(metadata)
} else {
  metadata <- load_mortality_metadata(src, dict, event_interval = mins(1L))
  metadata <- metadata[stay_id %in% base_ids]
  dir.create(metadata_dir, recursive = TRUE, showWarnings = FALSE)
  arrow::write_parquet(metadata, metadata_path)
  jsonlite::write_json(
    metadata_provenance,
    metadata_provenance_path,
    auto_unbox = TRUE,
    pretty = TRUE
  )
}

labels <- construct_landmark_labels(
  metadata,
  observation_hours,
  prediction_hours,
  unknown_policy = "exclude"
)
dir.create(metadata_dir, recursive = TRUE, showWarnings = FALSE)
arrow::write_parquet(labels$metadata, metadata_path)
eligible_ids <- labels$labels$stay_id

patients <- stay_windows(src, interval = interval)
patients <- as_win_tbl(
  patients,
  index_var = "start",
  dur_var = "end",
  interval = interval
)
patients <- patients[id_col(patients) %in% base_ids]
stop_obs_at(
  patients,
  offset = landmark$context_offset,
  by_ref = TRUE,
  target = patients
)
patients <- patients[id_col(patients) %in% eligible_ids]

patient_ids <- patients[, .SD, .SDcols = id_var(patients)]

dyn <- load_step(dict[dynamic_vars], interval = interval, cache = TRUE)
sta <- load_step(dict[static_vars], cache = TRUE)

map_to_patients <- function(x) {
  merge(patient_ids, x, all.x = TRUE)
}

dyn_fmt <- function_step(dyn, map_to_grid, patient_windows = patients)
dyn_fmt <- filter_step(dyn_fmt, patients)
rename_cols(dyn_fmt, c("stay_id", "time"), meta_vars(dyn_fmt), by_ref = TRUE)

sta_fmt <- function_step(sta, map_to_patients)
rename_cols(sta_fmt, c("stay_id"), id_vars(sta), by_ref = TRUE)

outc_fmt <- labels$labels
setcolorder(outc_fmt, c("stay_id", "label"))

out_path <- file.path(path, frequency_output_src(src, frequency))
dir.create(out_path, recursive = TRUE, showWarnings = FALSE)
assert_that(!anyDuplicated(dyn_fmt[, .(stay_id, time)]))

arrow::write_parquet(outc_fmt, file.path(out_path, "outc.parquet"))
arrow::write_parquet(dyn_fmt, file.path(out_path, "dyn.parquet"))
arrow::write_parquet(sta_fmt, file.path(out_path, "sta.parquet"))
fwrite(labels$attrition, file.path(out_path, "attrition.csv"))
jsonlite::write_json(
  provenance,
  file.path(out_path, "task_provenance.json"),
  auto_unbox = TRUE,
  pretty = TRUE
)
