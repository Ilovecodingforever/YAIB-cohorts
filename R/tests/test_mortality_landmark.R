library(data.table)
library(ricu)
library(assertthat)
library(rlang)

source("src/frequency.R")
source("src/obs_time.R")
source("src/steps.R")
source("src/sequential.R")
source("src/mortality_landmark.R")
source("../ricu-extensions/callbacks/callback-icu-mortality.R")

valid_args <- validate_landmark_arguments("hirid", "1h", 24, 12)
stopifnot(valid_args$frequency$label == "1h")
stopifnot(valid_args$landmark$prediction_start_hours == 25)
invalid_hours <- tryCatch(
  validate_landmark_arguments("hirid", "1h", -1, 12),
  error = function(error) conditionMessage(error)
)
stopifnot(grepl("observation_hours", invalid_hours, fixed = TRUE))

unsupported_source <- tryCatch(
  assert_landmark_source("mimic_demo"),
  error = function(error) conditionMessage(error)
)
stopifnot(grepl("hirid, miiv", unsupported_source, fixed = TRUE))

metadata_files <- landmark_metadata_provenance_files()
stopifnot(all(file.exists(metadata_files)))
metadata_cache_dir <- tempfile("landmark_metadata_")
dir.create(metadata_cache_dir)
metadata_config <- file.path(metadata_cache_dir, "config.yaml")
metadata_pipeline <- file.path(metadata_cache_dir, "mortality-helper.R")
writeLines("config: original", metadata_config)
writeLines("extraction: original", metadata_pipeline)
metadata_provenance_1 <- landmark_metadata_provenance(
  "hirid", metadata_config, metadata_cache_dir, metadata_pipeline, mins(1L)
)
writeLines("extraction: changed", metadata_pipeline)
metadata_provenance_2 <- landmark_metadata_provenance(
  "hirid", metadata_config, metadata_cache_dir, metadata_pipeline, mins(1L)
)
stopifnot(!identical(
  metadata_provenance_1$pipeline_md5,
  metadata_provenance_2$pipeline_md5
))
metadata_provenance_path <- file.path(metadata_cache_dir, "provenance.json")
jsonlite::write_json(metadata_provenance_1, metadata_provenance_path, auto_unbox = TRUE)
metadata_cache_error <- tryCatch(
  validate_landmark_metadata_provenance(
    metadata_provenance_path,
    metadata_provenance_2
  ),
  error = function(error) conditionMessage(error)
)
stopifnot(grepl("incompatible", metadata_cache_error, fixed = TRUE))
task_provenance <- landmark_task_provenance(
  "hirid", 24, 12, frequency_spec("1h", "hirid"),
  list(schema_version = 1L), "exclude", metadata_provenance_1
)
stopifnot(identical(
  task_provenance$metadata_provenance$pipeline_md5,
  metadata_provenance_1$pipeline_md5
))
unlink(metadata_cache_dir, recursive = TRUE)

entrypoint_smoke <- system2(
  "Rscript",
  c("mortality_landmark.R", "--src", "mimic_demo"),
  stdout = TRUE,
  stderr = TRUE
)
stopifnot(grepl("supports only", paste(entrypoint_smoke, collapse = "\n"), fixed = TRUE))

make_window <- function(spec, end = hours(168)) {
  as_win_tbl(
    data.table(
      stay_id = 1L,
      start = as.difftime(0, units = units(spec$interval)),
      end = as.difftime(as.numeric(end, units = units(spec$interval)),
                        units = units(spec$interval))
    ),
    id_vars = "stay_id",
    index_var = "start",
    dur_var = "end",
    interval = spec$interval
  )
}

for (w in c(24, 36)) {
  for (frequency in c("1h", "15min", "5min")) {
    spec <- frequency_spec(frequency, "hirid")
    landmark <- landmark_parameters(w, 12, spec$interval)
    window <- make_window(spec)
    stop_obs_at(
      window,
      offset = landmark$context_offset,
      target = window
    )
    grid <- ricu::expand(window, new_index = "time")
    expected_last <- as.numeric(
      landmark$prediction_start - spec$interval,
      units = units(spec$interval)
    )
    stopifnot(as.numeric(tail(grid$time, 1L), units = units(spec$interval)) == expected_last)
    stopifnot(nrow(grid) == round(expected_last / as.numeric(spec$interval)) + 1L)
    stopifnot(all(as.numeric(grid$time, units = "hours") < landmark$prediction_start_hours))
  }
}

# Exercise real ricu interval aggregation using synthetic raw measurements.
for (frequency in c("1h", "15min", "5min")) {
  spec <- frequency_spec(frequency, "hirid")
  landmark <- landmark_parameters(24, 12, spec$interval)
  start_min <- 25 * 60
  raw_times <- as.difftime(c(start_min - 1, start_min, start_min + 1), units = "mins")
  synthetic_loader <- function(x, id_type = "icustay", interval = hours(1), ...) {
    as_ts_tbl(
      data.table(stay_id = 1L, time = raw_times, val_var = c(1, 2, 3)),
      id_vars = "stay_id",
      index_var = "time",
      interval = mins(1)
    )
  }
  synthetic_item <- ricu:::new_itm(
    "synthetic_landmark",
    target = "ts_tbl",
    class = "fun_itm",
    callback = synthetic_loader
  )
  synthetic_concept <- ricu:::new_cncpt(
    "value",
    synthetic_item,
    aggregate = "median"
  )
  aggregated <- ricu::load_concepts(
    synthetic_concept,
    interval = spec$interval,
    verbose = FALSE
  )
  included <- aggregated[time < landmark$prediction_start]
  stopifnot(nrow(included) == 1L)
  stopifnot(
    as.numeric(included$time, units = "hours") ==
      as.numeric(landmark$prediction_start - spec$interval, units = "hours")
  )
}

# ricu's interval conversion floors second-resolution timestamps to the target
# interval. This is the actual precision available to the landmark extractor.
boundary_seconds <- c(
  24 * 3600 + 59 * 60 + 59,
  25 * 3600,
  25 * 3600 + 1,
  36 * 3600 + 59 * 60 + 59,
  37 * 3600,
  37 * 3600 + 1
)
boundary_raw <- as_ts_tbl(
  data.table(
    stay_id = 1L,
    time = as.difftime(boundary_seconds, units = "secs"),
    value = seq_along(boundary_seconds)
  ),
  id_vars = "stay_id",
  index_var = "time",
  interval = secs(1L)
)
boundary_minute <- ricu::change_interval(boundary_raw, mins(1L), "time")
stopifnot(identical(
  as.numeric(boundary_minute$time, units = "mins"),
  floor(boundary_seconds / 60)
))
boundary_labels <- construct_landmark_labels(
  data.table(
    stay_id = 1:6,
    icu_start_hours = 0,
    icu_end_hours = 80,
    death_time_hours = as.numeric(boundary_minute$time, units = "hours"),
    outcome_status = "dead"
  ),
  24,
  12
)$labels
stopifnot(identical(boundary_labels$stay_id, 4:6))
stopifnot(identical(boundary_labels$label, rep(1L, 3)))

metadata <- data.table(
  stay_id = 1:10,
  icu_start_hours = c(0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
  icu_end_hours = c(100, 100, 100, 100, 100, 24.9, 30, 40, 40, 40),
  death_time_hours = c(24, 25, 25 + 1 / 60, 37, 37 + 1 / 60, NA, NA, NA, NA, 30),
  outcome_status = c("dead", "dead", "dead", "dead", "dead", "alive", "alive", "unknown", "dead", "alive"),
  event_time_kind = "mimic_iv_deathtime"
)

labels <- construct_landmark_labels(metadata, 24, 12)
metadata_before_labels <- copy(metadata)
setorder(labels$labels, stay_id)
stopifnot(identical(labels$labels$stay_id, c(3L, 4L, 5L, 7L)))
stopifnot(identical(labels$labels$label, c(1L, 1L, 0L, 0L)))
stopifnot(labels$metadata[stay_id == 1L, reason] == "death_at_or_before_prediction_start")
stopifnot(labels$metadata[stay_id == 2L, reason] == "death_at_or_before_prediction_start")
stopifnot(labels$metadata[stay_id == 6L, reason] == "icu_discharge_at_or_before_prediction_start")
stopifnot(labels$metadata[stay_id == 8L, reason] == "unknown_outcome_status")
stopifnot(labels$metadata[stay_id == 9L, reason] == "missing_death_time")
stopifnot(labels$metadata[stay_id == 10L, reason] == "alive_status_with_death_time")
stopifnot(identical(metadata, metadata_before_labels))
stopifnot(!"reason" %in% names(metadata))

late_admission <- construct_landmark_labels(
  data.table(
    stay_id = 1L,
    icu_start_hours = 26,
    icu_end_hours = 50,
    death_time_hours = NA_real_,
    outcome_status = "alive"
  ),
  24,
  12
)
stopifnot(late_admission$metadata$reason == "icu_admission_after_prediction_start")

boundary_metadata <- data.table(
  stay_id = 1:4,
  icu_start_hours = 0,
  icu_end_hours = 80,
  # Fractional-minute event times are accepted by the label layer even though
  # the current ricu extraction path normalizes source events to minutes.
  death_time_hours = c(49, 49 + 0.5 / 60, 37, 37 + 0.5 / 60),
  outcome_status = rep("dead", 4)
)
labels_24_24 <- construct_landmark_labels(boundary_metadata, 24, 24)$labels
setorder(labels_24_24, stay_id)
stopifnot(identical(labels_24_24$stay_id, c(1L, 2L, 3L, 4L)))
stopifnot(identical(labels_24_24$label, c(1L, 0L, 1L, 1L)))

labels_36_12 <- construct_landmark_labels(
  data.table(
    stay_id = 1:3,
    icu_start_hours = 0,
    icu_end_hours = 80,
    death_time_hours = c(36, 37 + 1 / 60, 49),
    outcome_status = rep("dead", 3)
  ),
  36,
  12
)$labels
setorder(labels_36_12, stay_id)
stopifnot(identical(labels_36_12$stay_id, c(2L, 3L)))
stopifnot(identical(labels_36_12$label, c(1L, 1L)))

stopifnot(identical(
  construct_landmark_labels(metadata, 24, 12)$labels,
  construct_landmark_labels(metadata, 24, 12)$labels
))

# The MIMIC ICU callback keeps a death only for the ICU stay whose last ward
# is an ICU; an earlier stay ending on a ward is not labeled as the death stay.
synthetic_death <- as_ts_tbl(
  data.table(
    stay_id = c(10L, 20L),
    time = as.difftime(c(20 * 60, 40 * 60), units = "mins"),
    death_icu = 1L
  ),
  id_vars = "stay_id",
  index_var = "time",
  interval = mins(1)
)
synthetic_transfers <- as_ts_tbl(
  data.table(
    stay_id = c(10L, 10L, 20L, 20L),
    time = as.difftime(c(10, 20, 30, 40) * 60, units = "mins"),
    eventtype = c("transfer", "discharge", "transfer", "discharge"),
    ward = c("WARD", "WARD", "ICU", "ICU")
  ),
  id_vars = "stay_id",
  index_var = "time",
  interval = mins(1)
)
callback_result <- mi_death_icu(
  synthetic_death,
  synthetic_transfers,
  "ICU"
)
stopifnot(callback_result[stay_id == 10L, death_icu] == FALSE)
stopifnot(callback_result[stay_id == 20L, death_icu] == TRUE)

# Exercise the MIIV wrapper contract: hospital transfers are loaded by hadm_id,
# converted to ICU stay IDs, then attributed by the last care unit. The actual
# MIIV source is unavailable in this checkout, so only the ricu boundary is
# mocked; no patient table is read.
synthetic_hospital_transfers <- data.table(
  hadm_id = rep(100L, 4),
  eventtype = c("transfer", "discharge", "transfer", "discharge"),
  careunit = c("WARD", "WARD", "ICU", "ICU")
)
synthetic_miiv_transfers <- as_ts_tbl(
  data.table(
    stay_id = c(10L, 10L, 20L, 20L),
    time = as.difftime(c(10, 20, 30, 40) * 60, units = "mins"),
    eventtype = synthetic_hospital_transfers$eventtype,
    careunit = synthetic_hospital_transfers$careunit
  ),
  id_vars = "stay_id",
  index_var = "time",
  interval = mins(1)
)
callback_state <- new.env(parent = emptyenv())
callback_state$converted <- FALSE
miiv_callback <- miiv_death_icu
environment(miiv_callback) <- list2env(
  list(
    load_ts = function(x, id_var, index_var, interval, ...) {
      callback_state$load_args <- list(
        id_var = id_var, index_var = index_var, interval = interval
      )
      synthetic_hospital_transfers
    },
    change_id = function(x, target_id, src, id_type = FALSE, ...) {
      callback_state$converted <- TRUE
      stopifnot(target_id == "icustay", isTRUE(id_type))
      synthetic_miiv_transfers
    },
    as_src_cfg = function(x) x,
    rename_cols = ricu::rename_cols,
    mi_death_icu = mi_death_icu,
    mins = ricu::mins
  ),
  parent = environment(miiv_death_icu)
)
miiv_result <- miiv_callback(
  synthetic_death,
  list(
    icustays = data.table(first_careunit = "ICU"),
    transfers = synthetic_hospital_transfers
  )
)
stopifnot(callback_state$converted)
stopifnot(callback_state$load_args$id_var == "hadm_id")
stopifnot(miiv_result[stay_id == 10L, death_icu] == FALSE)
stopifnot(miiv_result[stay_id == 20L, death_icu] == TRUE)

duplicate_death <- as_ts_tbl(
  data.table(
    stay_id = c(20L, 20L),
    time = as.difftime(c(40, 40) * 60, units = "mins"),
    death_icu = c(TRUE, TRUE)
  ),
  id_vars = "stay_id",
  index_var = "time",
  interval = mins(1)
)
duplicate_error <- tryCatch(
  landmark_death_metadata(duplicate_death),
  error = function(error) conditionMessage(error)
)
stopifnot(grepl("duplicate stay events", duplicate_error, fixed = TRUE))

outside_icu <- construct_landmark_labels(
  data.table(
    stay_id = c(10L, 20L),
    icu_start_hours = c(0, 0),
    icu_end_hours = c(20, 50),
    death_time_hours = c(12, 60),
    outcome_status = c("dead", "dead")
  ),
  12,
  12
)
stopifnot(outside_icu$metadata[stay_id == 10L, reason] == "death_at_or_before_prediction_start")
stopifnot(outside_icu$metadata[stay_id == 20L, reason] == "death_after_icu_end")
stopifnot(nrow(outside_icu$labels) == 0L)

validation_dyn <- data.table(
  stay_id = c(3L, 3L, 4L, 4L),
  time = as.difftime(c(0, 24, 0, 24), units = "hours"),
  hr = c(70, 71, 72, 73)
)
validation_sta <- data.table(stay_id = c(3L, 4L), age = c(50, 60))
validation_outc <- data.table(stay_id = c(3L, 4L), label = c(1L, 0L))
stopifnot(validate_landmark_outputs(
  validation_dyn,
  validation_sta,
  validation_outc,
  prediction_start_hours = 25
))

expect_landmark_error <- function(call, expected) {
  message <- tryCatch(
    call(),
    error = function(error) conditionMessage(error)
  )
  stopifnot(is.character(message), grepl(expected, message, fixed = TRUE))
}
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn[0], validation_sta[0], validation_outc[0], 25
  ),
  "no labeled stays"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn, validation_sta, data.table(stay_id = 3L), 25
  ),
  "missing stay_id or label"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn, validation_sta, data.table(stay_id = c(3L, 4L), label = c(0L, 2L)), 25
  ),
  "labels must be non-missing"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn, validation_sta, data.table(stay_id = c(3L, 3L), label = c(0L, 1L)), 25
  ),
  "duplicate stay IDs"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn, data.table(stay_id = c(3L, 3L)), validation_outc, 25
  ),
  "sta.parquet contains duplicate"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn[c(1, 1, 3, 4)], validation_sta, validation_outc, 25
  ),
  "duplicate"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    data.table(stay_id = 3L, time = as.difftime(0, units = "hours"), hr = 70),
    validation_sta, validation_outc, 25
  ),
  "stay IDs do not match"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    data.table(stay_id = c(3L, 4L), time = as.difftime(c(0, Inf), units = "hours"), hr = c(70, 72)),
    validation_sta, validation_outc, 25
  ),
  "timestamps must be finite"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    data.table(stay_id = c(3L, 3L, 4L, 4L), time = as.difftime(c(0, 25, 0, 24), units = "hours"), hr = 1:4),
    validation_sta, validation_outc, 25
  ),
  "reach or exceed"
)
expect_landmark_error(
  function() validate_landmark_outputs(
    validation_dyn,
    data.table(stay_id = c(3L, 4L), death_time_hours = c(10, 20)),
    validation_outc,
    25
  ),
  "outcome metadata"
)

make_synthetic_landmark_output <- function(frequency, observation_hours) {
  spec <- frequency_spec(frequency, "hirid")
  landmark <- landmark_parameters(observation_hours, 12, spec$interval)
  patients <- as_win_tbl(
    data.table(
      stay_id = c(1L, 2L),
      start = as.difftime(c(0, 0), units = units(spec$interval)),
      end = as.difftime(c(168, 168), units = "hours")
    ),
    id_vars = "stay_id",
    index_var = "start",
    dur_var = "end",
    interval = spec$interval
  )
  stop_obs_at(
    patients,
    offset = landmark$context_offset,
    target = patients
  )
  grid <- ricu::expand(patients, new_index = "time")
  grid <- data.table::as.data.table(grid)
  grid[, value := as.numeric(time, units = "hours")]
  dyn <- as_ts_tbl(
    grid[, .(stay_id, time, value)],
    id_vars = "stay_id",
    index_var = "time",
    interval = spec$interval
  )
  sta <- as_id_tbl(
    data.table(stay_id = c(1L, 2L), age = c(50, 60)),
    id_vars = "stay_id"
  )
  metadata <- data.table(
    stay_id = c(1L, 2L),
    icu_start_hours = c(0, 0),
    icu_end_hours = c(168, 168),
    death_time_hours = c(observation_hours + 2, NA_real_),
    outcome_status = c("dead", "alive")
  )
  labels <- construct_landmark_labels(metadata, observation_hours, 12)$labels
  outputs <- landmark_output_tables(dyn, sta, patients, labels)
  validate_landmark_outputs(
    outputs$dyn,
    outputs$sta,
    outputs$outc,
    landmark$prediction_start_hours
  )
  outputs
}

expected_bins <- function(observation_hours, frequency) {
  start <- observation_hours + 1
  if (frequency == "1h") start else if (frequency == "15min") start * 4 else start * 12
}

for (observation_hours in c(24, 36)) {
  outputs <- lapply(
    c("1h", "15min", "5min"),
    make_synthetic_landmark_output,
    observation_hours = observation_hours
  )
  stopifnot(all(vapply(outputs, function(x) nrow(x$outc) == 2L, logical(1))))
  stopifnot(all(vapply(outputs, function(x) identical(x$outc$label, c(1L, 0L)), logical(1))))
  stopifnot(all(vapply(outputs, function(x) identical(x$sta$age, c(50, 60)), logical(1))))
  for (i in seq_along(outputs)) {
    frequency <- c("1h", "15min", "5min")[i]
    output <- outputs[[i]]
    stopifnot(nrow(output$dyn) == 2L * expected_bins(observation_hours, frequency))
    stopifnot(
      all(as.numeric(output$dyn$time, units = "hours") < observation_hours + 1)
    )
    stopifnot(!anyDuplicated(output$dyn[, .(stay_id, time)]))
    stopifnot(identical(names(output$outc), c("stay_id", "label")))
    stopifnot(identical(names(output$sta), c("stay_id", "age")))
    stopifnot(identical(names(output$dyn), c("stay_id", "time", "value")))
  }
}

cat("synthetic landmark mortality tests passed\n")
