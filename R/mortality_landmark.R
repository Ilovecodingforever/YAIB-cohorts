library(argparser)
library(assertthat)
library(rlang)
library(data.table)
library(vctrs)
library(yaml)

source("src/frequency.R")
source("src/mortality_landmark.R")

p <- arg_parser("Extract configurable-window ICU mortality data")
p <- add_argument(p, "--src", help = "source database: hirid or miiv")
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
observation_hours <- argv$observation_hours
prediction_hours <- argv$prediction_hours
validated <- validate_landmark_arguments(
  src, argv$frequency, observation_hours, prediction_hours
)
frequency <- validated$frequency
landmark <- validated$landmark

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

base <- arrow::read_parquet(base_path)
base_ids <- unique(base$stay_id)

metadata_dir <- file.path(conf$out_dir, "mortality_metadata", src)
metadata_path <- file.path(metadata_dir, "outcome_metadata.parquet")
metadata_provenance_path <- file.path(
  metadata_dir, "provenance.json"
)
metadata_interval <- mins(1L)
metadata_provenance <- landmark_metadata_provenance(
  src,
  "../config.yaml",
  conf$ricu_data_path,
  landmark_metadata_provenance_files(),
  metadata_interval
)
provenance <- landmark_task_provenance(
  src, observation_hours, prediction_hours, frequency,
  base_provenance, "exclude", metadata_provenance
)

metadata_exists <- file.exists(metadata_path)
metadata_provenance_exists <- file.exists(metadata_provenance_path)
if (xor(metadata_exists, metadata_provenance_exists)) {
  stop(
    "Outcome metadata and provenance must be created together; refusing to reuse an incomplete cache.",
    call. = FALSE
  )
}
if (metadata_exists && metadata_provenance_exists) {
  validate_landmark_metadata_provenance(
    metadata_provenance_path,
    metadata_provenance
  )
  metadata <- arrow::read_parquet(metadata_path)
  metadata <- as.data.table(metadata)
} else {
  metadata <- load_mortality_metadata(src, dict, event_interval = metadata_interval)
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
  metadata[stay_id %in% base_ids],
  observation_hours,
  prediction_hours,
  unknown_policy = "exclude"
)
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

dyn <- load_step(dict[dynamic_vars], interval = interval, cache = TRUE)
sta <- load_step(dict[static_vars], cache = TRUE)

formatted <- landmark_output_tables(dyn, sta, patients, labels$labels)
dyn_fmt <- formatted$dyn
sta_fmt <- formatted$sta
outc_fmt <- formatted$outc

out_path <- file.path(path, frequency_output_src(src, frequency))
dir.create(out_path, recursive = TRUE, showWarnings = FALSE)
validate_landmark_outputs(
  dyn_fmt,
  sta_fmt,
  outc_fmt,
  landmark$prediction_start_hours
)

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
