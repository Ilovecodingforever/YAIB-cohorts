frequency_spec <- function(frequency = "1h", src = NULL) {
  if (length(frequency) != 1L || is.na(frequency) || !is.character(frequency)) {
    stop("--frequency must be one of: 5min, 15min, 1h", call. = FALSE)
  }

  spec <- switch(
    frequency,
    `1h` = list(time_unit = function(...) as.difftime(c(...), units = "hours"), freq = 1L),
    `15min` = list(time_unit = function(...) as.difftime(c(...), units = "mins"), freq = 15L),
    `5min` = list(time_unit = function(...) as.difftime(c(...), units = "mins"), freq = 5L),
    NULL
  )

  if (is.null(spec)) {
    stop("--frequency must be one of: 5min, 15min, 1h", call. = FALSE)
  }

  if (frequency != "1h" && !identical(src, "hirid")) {
    stop(
      "Non-hourly frequencies are supported only for --src hirid; ",
      "got --src ", src, " --frequency ", frequency,
      call. = FALSE
    )
  }

  spec$label <- frequency
  spec$interval <- spec$time_unit(spec$freq)
  spec$suffix <- if (frequency == "1h") "" else paste0("_", frequency)
  spec
}


frequency_output_src <- function(src, spec) {
  paste0(src, spec$suffix)
}


frequency_offset <- function(duration, interval) {
  ricu:::re_time(duration, interval)
}


frequency_steps <- function(duration, interval) {
  rounded <- frequency_offset(duration, interval)
  as.numeric(rounded) / as.numeric(interval)
}


frequency_index_value <- function(duration, interval) {
  as.numeric(frequency_offset(duration, interval))
}


mortality_canonical_interval <- function() {
  as.difftime(1, units = "hours")
}


mortality_cutoff_value <- function(interval = mortality_canonical_interval()) {
  frequency_index_value(as.difftime(30, units = "hours"), interval)
}
