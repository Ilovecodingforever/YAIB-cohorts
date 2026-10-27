library(data.table)
library(ricu)
library(assertthat)

stopifnot(file.exists("src/frequency.R"), file.exists("src/steps.R"))
source("src/frequency.R")
source("src/misc.R")
source("src/steps.R")

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
  stopifnot(as.numeric(grid$time[.N], units = "mins") == 24 * 60)
  stopifnot(!anyDuplicated(grid[, .(stay_id, time)]))
}

# Synthetic ricu-style binning: floor timestamps to the requested interval and
# retain ricu's default median aggregation for numeric values.
spec <- frequency_spec("5min", "hirid")
raw <- data.table(
  stay_id = 1L,
  time = as.difftime(c(1, 4, 11), units = "mins"),
  value = c(10, 20, 30)
)
raw[, time := as.difftime(
  ricu:::round_to(as.numeric(time), as.numeric(spec$interval)),
  units = "mins"
)]
observed <- as_ts_tbl(raw, id_vars = "stay_id", index_var = "time", interval = spec$interval)
aggregated <- stats::aggregate(observed)
stopifnot(aggregated[time == as.difftime(0, units = "mins"), value] == 15)
stopifnot(aggregated[time == as.difftime(10, units = "mins"), value] == 30)

window <- data.table(
  stay_id = 1L,
  start = as.difftime(0, units = "mins"),
  end = as.difftime(15, units = "mins")
)
window <- as_win_tbl(window, id_vars = "stay_id", index_var = "start", dur_var = "end", interval = spec$interval)
grid <- ricu::expand(window, new_index = "time")
merged <- merge(grid, aggregated, all.x = TRUE)
stopifnot(is.na(merged[time == as.difftime(5, units = "mins"), value]))

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
    labels = labels
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

# Every output frequency reuses the same canonical cohort and labels while its
# dynamic window has its own expected grid.
for (spec in specs) {
  unit <- units(spec$interval)
  window <- data.table(
    stay_id = canonical_result$ids,
    start = as.difftime(rep(0, length(canonical_result$ids)), units = unit),
    end = as.difftime(rep(24 * 60, length(canonical_result$ids)), units = "mins")
  )
  window[, end := as.difftime(as.numeric(end, units = unit), units = unit)]
  window <- as_win_tbl(window, id_vars = "stay_id", index_var = "start", dur_var = "end", interval = spec$interval)
  grid <- ricu::expand(window, new_index = "time")
  stopifnot(nrow(grid) == expected_grid_rows[[spec$label]] * length(canonical_result$ids))
  stopifnot(!anyDuplicated(grid[, .(stay_id, time)]))
  stopifnot(identical(canonical_mortality_result(), canonical_result))
}

# The new default-hourly path matches the original strict hourly cutoff.
legacy_cutoff <- frequency_index_value(hours(30), hours(1))
stopifnot(legacy_cutoff == mortality_cutoff_value(mortality_canonical_interval()))
stopifnot(identical(canonical_result$ids, c(2L, 3L, 4L)))

stopifnot(step_cache_key("hirid", "hr", mins(5)) != step_cache_key("hirid", "hr", mins(15)))
stopifnot(step_cache_key("hirid", "hr", mins(5)) != step_cache_key("mimic", "hr", mins(5)))
stopifnot(step_cache_key("hirid", "hr", mins(5)) != step_cache_key("hirid", "temp", mins(5)))
stopifnot(step_cache_key("hirid", "hr", hours(1)) == step_cache_key("hirid", "hr", mins(60)))

stopifnot(frequency_output_src("hirid", frequency_spec("1h", "hirid")) == "hirid")
stopifnot(frequency_output_src("hirid", frequency_spec("5min", "hirid")) == "hirid_5min")
stopifnot(frequency_output_src("hirid", frequency_spec("15min", "hirid")) == "hirid_15min")

cat("frequency tests passed\n")
