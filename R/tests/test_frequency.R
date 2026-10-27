library(data.table)
library(ricu)
library(assertthat)
library(vctrs)
library(rlang)

stopifnot(file.exists("src/frequency.R"), file.exists("src/steps.R"))
source("src/frequency.R")
source("src/misc.R")
source("src/steps.R")
source("src/sequential.R")
source("src/obs_time.R")

expect_error <- function(expr, pattern) {
  error <- tryCatch({
    force(expr)
    NULL
  }, error = function(e) e)
  stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error), fixed = TRUE))
}

stopifnot(frequency_spec(src = "hirid")$label == "1h")
stopifnot(frequency_spec("5min", "hirid")$freq == 5L)
stopifnot(frequency_spec("15min", "hirid")$freq == 15L)
expect_error(frequency_spec("10min", "hirid"), "5min, 15min, 1h")
expect_error(frequency_spec("5min", "mimic_demo"), "only for --src hirid")

specs <- list(
  frequency_spec("1h", "hirid"),
  frequency_spec("15min", "hirid"),
  frequency_spec("5min", "hirid")
)
expected_steps <- list(
  `1h` = c(6L, 12L, 24L, 30L, 168L),
  `15min` = c(24L, 48L, 96L, 120L, 672L),
  `5min` = c(72L, 144L, 288L, 360L, 2016L)
)
for (spec in specs) {
  expected <- expected_steps[[spec$label]]
  stopifnot(identical(as.integer(frequency_steps(hours(6), spec$interval)), expected[1]))
  stopifnot(identical(as.integer(frequency_steps(hours(12), spec$interval)), expected[2]))
  stopifnot(identical(as.integer(frequency_steps(hours(24), spec$interval)), expected[3]))
  stopifnot(identical(as.integer(frequency_steps(hours(30), spec$interval)), expected[4]))
  stopifnot(identical(as.integer(frequency_steps(hours(7 * 24), spec$interval)), expected[5]))
}

expected_grid_rows <- c(`1h` = 25L, `15min` = 97L, `5min` = 289L)
for (spec in specs) {
  unit <- units(spec$interval)
  end <- as.numeric(hours(24), units = unit)
  window <- data.table(
    stay_id = 1L,
    start = as.difftime(0, units = unit),
    end = as.difftime(end, units = unit)
  )
  window <- as_win_tbl(
    window,
    id_vars = "stay_id",
    index_var = "start",
    dur_var = "end",
    interval = spec$interval
  )
  grid <- ricu::expand(window, new_index = "time")
  stopifnot(nrow(grid) == expected_grid_rows[[spec$label]])
  stopifnot(as.numeric(grid$time[1], units = "mins") == 0)
  stopifnot(as.numeric(tail(grid$time, 1L), units = "mins") == 24 * 60)
  stopifnot(!anyDuplicated(grid[, .(stay_id, time)]))
}

# stop_obs_at preserves the same physical window at every resolution. Off-grid
# event times cap the physical window exactly, while expand() retains only the
# aligned grid points at or before that endpoint.
make_window <- function(spec, duration_minutes = 48 * 60) {
  unit <- units(spec$interval)
  end <- as.difftime(duration_minutes, units = "mins")
  end <- as.difftime(as.numeric(end, units = unit), units = unit)
  as_win_tbl(
    data.table(
      stay_id = 1L,
      start = as.difftime(0, units = unit),
      end = end
    ),
    id_vars = "stay_id",
    index_var = "start",
    dur_var = "end",
    interval = spec$interval
  )
}

make_event <- function(spec, event_minutes) {
  unit <- units(spec$interval)
  event <- as.difftime(event_minutes, units = "mins")
  event_in_unit <- as.numeric(event, units = unit)
  aligned <- floor(event_in_unit / as.numeric(spec$interval)) * as.numeric(spec$interval)
  result <- as_ts_tbl(
    data.table(stay_id = 1L, time = as.difftime(aligned, units = unit), event = TRUE),
    id_vars = "stay_id",
    index_var = "time",
    interval = spec$interval
  )
  # Model the raw off-grid timestamp after constructing a valid ricu table.
  data.table::set(result, j = "time", value = as.difftime(event_in_unit, units = unit))
  result
}

for (spec in specs) {
  window <- make_window(spec)
  stop_obs_at(
    make_event(spec, 6 * 60 + 2),
    offset = frequency_offset(as.difftime(0, units = "hours"), spec$interval),
    target = window
  )
  stopifnot(as.numeric(window$end, units = "mins") == 6 * 60 + 2)

  grid <- ricu::expand(window, new_index = "time")
  last_grid_minute <- as.numeric(tail(grid$time, 1L), units = "mins")
  step_minutes <- as.numeric(spec$interval, units = "mins")
  stopifnot(last_grid_minute <= 6 * 60 + 2)
  stopifnot(last_grid_minute + step_minutes > 6 * 60 + 2)
  stopifnot(!anyDuplicated(grid[, .(stay_id, time)]))

  endpoint_window <- make_window(spec)
  stop_obs_at(
    make_event(spec, 24 * 60),
    offset = frequency_offset(as.difftime(0, units = "hours"), spec$interval),
    target = endpoint_window
  )
  endpoint_grid <- ricu::expand(endpoint_window, new_index = "time")
  stopifnot(as.numeric(endpoint_window$end, units = "mins") == 24 * 60)
  stopifnot(as.numeric(tail(endpoint_grid$time, 1L), units = "mins") == 24 * 60)
  stopifnot(nrow(endpoint_grid) == expected_grid_rows[[spec$label]])

  after_endpoint <- make_window(spec)
  stop_obs_at(
    make_event(spec, 24 * 60 + 1),
    offset = frequency_offset(as.difftime(0, units = "hours"), spec$interval),
    target = after_endpoint
  )
  stop_obs_at(
    after_endpoint,
    offset = frequency_offset(as.difftime(24, units = "hours"), spec$interval),
    target = after_endpoint
  )
  stopifnot(as.numeric(after_endpoint$end, units = "mins") == 24 * 60)
}

# The default target behavior remains equivalent to the original hourly call
# pattern, which relied on the caller's global `patients` object.
patients <- make_window(frequency_spec("1h", "hirid"))
legacy_event <- make_event(frequency_spec("1h", "hirid"), 6 * 60 + 2)
stop_obs_at(legacy_event, offset = hours(0))
stop_obs_at(patients, offset = hours(24))

explicit_patients <- make_window(frequency_spec("1h", "hirid"))
explicit_event <- make_event(frequency_spec("1h", "hirid"), 6 * 60 + 2)
stop_obs_at(explicit_event, offset = hours(0), target = explicit_patients)
stop_obs_at(explicit_patients, offset = hours(24), target = explicit_patients)
stopifnot(
  as.numeric(patients$end, units = "mins") ==
    as.numeric(explicit_patients$end, units = "mins")
)

# Synthetic ricu-style binning: floor timestamps to each requested interval and
# retain ricu's default median aggregation for numeric values.
for (spec in specs) {
  step_minutes <- as.numeric(spec$interval, units = "mins")
  unit <- units(spec$interval)
  raw <- data.table(
    stay_id = 1L,
    time = as.difftime(c(1, step_minutes - 1, step_minutes + 1), units = "mins"),
    value = c(10, 20, 30)
  )
  raw[, time := as.difftime(
    ricu:::round_to(as.numeric(time), step_minutes),
    units = "mins"
  )]
  raw[, time := as.difftime(as.numeric(time, units = unit), units = unit)]
  observed <- as_ts_tbl(raw, id_vars = "stay_id", index_var = "time", interval = spec$interval)
  aggregated <- stats::aggregate(observed)
  stopifnot(aggregated[time == as.difftime(0, units = unit), value] == 15)
  step_time <- as.difftime(step_minutes, units = "mins")
  step_time <- as.difftime(as.numeric(step_time, units = unit), units = unit)
  stopifnot(aggregated[time == step_time, value] == 30)

  end <- as.difftime(2 * step_minutes, units = "mins")
  end <- as.difftime(as.numeric(end, units = unit), units = unit)
  window <- data.table(
    stay_id = 1L,
    start = as.difftime(0, units = unit),
    end = end
  )
  window <- as_win_tbl(window, id_vars = "stay_id", index_var = "start", dur_var = "end", interval = spec$interval)
  grid <- ricu::expand(window, new_index = "time")
  merged <- merge(grid, aggregated, all.x = TRUE)
  end_time <- as.difftime(2 * step_minutes, units = "mins")
  end_time <- as.difftime(as.numeric(end_time, units = unit), units = unit)
  stopifnot(is.na(merged[time == end_time, value]))
}

# Mortality is evaluated once on the canonical hourly grid, then reused for
# every requested output grid.
canonical_mortality_result <- function() {
  interval <- mortality_canonical_interval()
  stays <- data.table(stay_id = 1:4, start = hours(0), end = hours(48))
  stays <- as_win_tbl(
    stays,
    id_vars = "stay_id",
    index_var = "start",
    dur_var = "end",
    interval = interval
  )
  deaths <- data.table(
    stay_id = c(1L, 2L, 3L),
    time = hours(c(29, 30, 31)),
    death = TRUE
  )
  deaths <- as_ts_tbl(deaths, id_vars = "stay_id", index_var = "time", interval = interval)

  early <- filter_step(deaths, ~ . == TRUE)
  early <- filter_step(early, ~ . < mortality_cutoff_value(interval), col = index_col)
  cohort <- exclude(stays, list(unique(early[, id_vars(early), with = FALSE])))
  eligible <- cohort$incl

  labels <- merge(
    eligible[, .(stay_id)],
    deaths[, .(stay_id, label = as.integer(death))],
    by = "stay_id",
    all.x = TRUE
  )
  labels[is.na(label), label := 0L]
  setorder(labels, stay_id)

  list(
    ids = eligible[order(stay_id), stay_id],
    labels = labels,
    cohort = eligible,
    events = deaths
  )
}

canonical_result <- canonical_mortality_result()
stopifnot(identical(canonical_result$ids, c(2L, 3L, 4L)))
stopifnot(identical(canonical_result$labels$label, c(1L, 1L, 0L)))

# Deaths immediately before, at, and after 30h: only the pre-cutoff death is
# excluded; a death exactly at 30h remains eligible.
stopifnot(mortality_cutoff_value(mortality_canonical_interval()) == 30)
stopifnot(frequency_index_value(hours(29), mortality_canonical_interval()) < 30)
stopifnot(frequency_index_value(hours(30), mortality_canonical_interval()) == 30)
stopifnot(frequency_index_value(hours(31), mortality_canonical_interval()) > 30)

build_synthetic_outputs <- function(spec, mortality) {
  unit <- units(spec$interval)
  ids <- mortality$ids
  end <- as.difftime(48 * 60, units = "mins")
  end <- as.difftime(as.numeric(end, units = unit), units = unit)
  patients <- as_win_tbl(
    data.table(
      stay_id = ids,
      start = as.difftime(rep(0, length(ids)), units = unit),
      end = rep(end, length(ids))
    ),
    id_vars = "stay_id",
    index_var = "start",
    dur_var = "end",
    interval = spec$interval
  )
  stop_obs_at(
    patients,
    offset = frequency_offset(as.difftime(24, units = "hours"), spec$interval),
    target = patients
  )
  assign("patients", patients, envir = .GlobalEnv)

  measurement_time <- as.difftime(c(0, 6 * 60), units = "mins")
  measurement_time <- as.difftime(as.numeric(measurement_time, units = unit), units = unit)
  dynamic <- as_ts_tbl(
    data.table(
      stay_id = rep(ids, each = 2L),
      time = rep(measurement_time, length(ids)),
      value = seq_len(2L * length(ids))
    ),
    id_vars = "stay_id",
    index_var = "time",
    interval = spec$interval
  )
  dyn_fmt <- function_step(dynamic, map_to_grid)
  dyn_fmt <- filter_step(dyn_fmt, patients)
  rename_cols(dyn_fmt, c("stay_id", "time"), meta_vars(dyn_fmt), by_ref = TRUE)

  cohort_patients <- mortality$cohort
  map_to_patients <- function(x) {
    grid <- cohort_patients[, .SD, .SDcols = id_var(cohort_patients)]
    merge(grid, x, all.x = TRUE)
  }
  outc_fmt <- function_step(mortality$events, map_to_patients)
  outc_fmt <- mutate_step(outc_fmt, ricu::replace_na, val = FALSE)
  outc_fmt <- mutate_step(outc_fmt, as.integer)
  ind <- index_var(outc_fmt)
  outc_fmt[, c(ind) := NULL]
  rename_cols(outc_fmt, c("stay_id", "label"), by_ref = TRUE)

  sta <- as_id_tbl(
    data.table(stay_id = 1:4, age = 18:21),
    id_vars = "stay_id"
  )
  sta_fmt <- function_step(sta, map_to_patients)
  rename_cols(sta_fmt, c("stay_id"), id_vars(sta), by_ref = TRUE)

  list(dyn = dyn_fmt, outc = outc_fmt, sta = sta_fmt)
}

# Every output frequency reuses the same canonical cohort and labels while its
# dynamic window has its own grid and output construction.
hourly_outputs <- NULL
for (spec in specs) {
  outputs <- build_synthetic_outputs(spec, canonical_result)
  stopifnot(nrow(outputs$dyn) == expected_grid_rows[[spec$label]] * length(canonical_result$ids))
  stopifnot(!anyDuplicated(outputs$dyn[, .(stay_id, time)]))
  stopifnot(as.numeric(tail(outputs$dyn$time, 1L), units = "mins") == 24 * 60)
  stopifnot(identical(outputs$outc$stay_id, canonical_result$labels$stay_id))
  stopifnot(identical(outputs$outc$label, canonical_result$labels$label))
  stopifnot(identical(outputs$sta$stay_id, canonical_result$ids))
  if (is.null(hourly_outputs)) {
    hourly_outputs <- outputs[c("outc", "sta")]
  } else {
    stopifnot(identical(outputs$outc, hourly_outputs$outc))
    stopifnot(identical(outputs$sta, hourly_outputs$sta))
  }
}

# The new default-hourly path matches the original strict hourly cutoff.
legacy_cutoff <- frequency_index_value(hours(30), hours(1))
stopifnot(legacy_cutoff == mortality_cutoff_value(mortality_canonical_interval()))
stopifnot(identical(canonical_result$ids, c(2L, 3L, 4L)))

stopifnot(step_cache_key("hirid", "hr", mins(5)) != step_cache_key("hirid", "hr", mins(15)))
stopifnot(step_cache_key("hirid", "hr", mins(5)) != step_cache_key("mimic", "hr", mins(5)))
stopifnot(step_cache_key("hirid", "hr", mins(5)) != step_cache_key("hirid", "temp", mins(5)))
stopifnot(step_cache_key("hirid", "hr", hours(1)) == step_cache_key("hirid", "hr", mins(60)))

# Exercise load_step.cncpt() retrieval and miss-then-hit behavior without
# invoking a source loader or touching patient data.
src <- "hirid"
cncpt_env <- new.env()
synthetic_concept <- structure(list(name = "hr"), class = c("cncpt", "num_cncpt"))
assign(step_cache_key(src, "hr", mins(5)), list(value = "five"), cncpt_env)
assign(step_cache_key(src, "hr", mins(15)), list(value = "fifteen"), cncpt_env)
stopifnot(load_step.cncpt(synthetic_concept, interval = mins(5))$value == "five")
stopifnot(load_step.cncpt(synthetic_concept, interval = mins(15))$value == "fifteen")

load_calls <- 0L
load_concepts <- function(...) {
  load_calls <<- load_calls + 1L
  list(value = "fresh")
}
fresh <- load_step.cncpt(synthetic_concept, interval = mins(1), cache = TRUE)
fresh_again <- load_step.cncpt(synthetic_concept, interval = mins(1), cache = TRUE)
stopifnot(fresh$value == "fresh", fresh_again$value == "fresh", load_calls == 1L)
rm(load_concepts)

stopifnot(frequency_output_src("hirid", frequency_spec("1h", "hirid")) == "hirid")
stopifnot(frequency_output_src("hirid", frequency_spec("5min", "hirid")) == "hirid_5min")
stopifnot(frequency_output_src("hirid", frequency_spec("15min", "hirid")) == "hirid_15min")

cat("frequency tests passed\n")
