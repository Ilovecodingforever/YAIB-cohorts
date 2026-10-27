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


canonical_provenance_path <- function(directory) {
  file.path(directory, "cohort_provenance.json")
}


canonical_provenance_files <- function() {
  sort(unique(c(
    "base_cohort.R",
    ".load_ricu.R",
    "src/frequency.R",
    "src/steps.R",
    "src/sequential.R",
    "src/obs_time.R",
    list.files("../ricu-extensions", recursive = TRUE, full.names = TRUE)
  )))
}


canonical_file_fingerprint <- function(paths) {
  paths <- normalizePath(paths, mustWork = TRUE)
  hashes <- tools::md5sum(paths)
  paste(paste(names(hashes), unname(hashes), sep = "="), collapse = ";")
}


canonical_hourly_provenance <- function(src, config_path, ricu_data_path, pipeline_files) {
  list(
    schema_version = 1L,
    source = src,
    cohort = "base",
    frequency = "1h",
    eligibility_frequency = "1h",
    config_md5 = unname(tools::md5sum(normalizePath(config_path, mustWork = TRUE))),
    pipeline_md5 = canonical_file_fingerprint(pipeline_files),
    ricu_data_path = normalizePath(ricu_data_path, mustWork = FALSE),
    ricu_version = if (requireNamespace("ricu", quietly = TRUE)) {
      as.character(utils::packageVersion("ricu"))
    } else {
      NA_character_
    }
  )
}


write_canonical_provenance <- function(directory, provenance) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("jsonlite is required to write cohort provenance metadata", call. = FALSE)
  }
  jsonlite::write_json(
    provenance,
    canonical_provenance_path(directory),
    auto_unbox = TRUE,
    pretty = TRUE
  )
}


validate_canonical_provenance <- function(directory, expected) {
  path <- canonical_provenance_path(directory)
  if (!file.exists(path)) {
    stop(
      "Canonical hourly cohort provenance is missing at ", path,
      ". Regenerate the hourly cohort before requesting a finer frequency.",
      call. = FALSE
    )
  }
  actual <- jsonlite::read_json(path, simplifyVector = TRUE)
  fields <- c(
    "schema_version", "source", "cohort", "frequency", "eligibility_frequency",
    "config_md5", "pipeline_md5", "ricu_data_path", "ricu_version"
  )
  mismatched <- fields[!vapply(fields, function(field) {
    identical(as.character(actual[[field]]), as.character(expected[[field]]))
  }, logical(1))]
  if (length(mismatched)) {
    stop(
      "Canonical hourly cohort provenance is incompatible (",
      paste(mismatched, collapse = ", "),
      "). Regenerate the hourly cohort before requesting a finer frequency.",
      call. = FALSE
    )
  }
  invisible(actual)
}
