library(data.table)
library(ricu)
library(assertthat)
library(rlang)

source("src/frequency.R")
source("src/obs_time.R")
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

cat("synthetic landmark mortality tests passed\n")
