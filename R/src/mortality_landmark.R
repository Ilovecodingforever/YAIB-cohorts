landmark_supported_sources <- c("hirid", "miiv")


assert_landmark_source <- function(src) {
  assert_that(
    length(src) == 1L && src %in% landmark_supported_sources,
    msg = paste0(
      "mortality_landmark supports only: ",
      paste(landmark_supported_sources, collapse = ", ")
    )
  )
  invisible(src)
}


landmark_parameters <- function(observation_hours, prediction_hours, interval) {
  assert_that(
    is.numeric(observation_hours), length(observation_hours) == 1L,
    is.finite(observation_hours), observation_hours >= 0,
    is.numeric(prediction_hours), length(prediction_hours) == 1L,
    is.finite(prediction_hours), prediction_hours > 0
  )

  interval_hours <- as.numeric(interval, units = "hours")
  prediction_start_hours <- observation_hours + 1
  alignment <- prediction_start_hours / interval_hours
  assert_that(
    abs(alignment - round(alignment)) < 1e-8,
    msg = paste0(
      "observation-hours + 1 must align to the feature frequency; got ",
      prediction_start_hours, " hours at ", interval_hours, " hours"
    )
  )

  prediction_start <- as.difftime(prediction_start_hours, units = "hours")
  prediction_end <- as.difftime(
    prediction_start_hours + prediction_hours,
    units = "hours"
  )

  list(
    observation_hours = observation_hours,
    prediction_hours = prediction_hours,
    prediction_start_hours = prediction_start_hours,
    prediction_end_hours = prediction_start_hours + prediction_hours,
    prediction_start = prediction_start,
    prediction_end = prediction_end,
    context_offset = frequency_offset(prediction_start - interval, interval)
  )
}


landmark_as_hours <- function(x) {
  if (inherits(x, "difftime")) {
    as.numeric(x, units = "hours")
  } else {
    as.numeric(x)
  }
}


landmark_metadata_from_stays <- function(stays) {
  dat <- data.table::as.data.table(stays)
  id <- id_vars(stays)[1L]
  assert_that(all(c("start", "end") %in% names(dat)))
  dat[, .(
    stay_id = get(id),
    icu_start_hours = landmark_as_hours(start),
    icu_end_hours = landmark_as_hours(end)
  )]
}


landmark_death_metadata <- function(death) {
  dat <- data.table::as.data.table(death)
  id <- id_vars(death)[1L]
  ind <- index_var(death)[1L]
  val <- data_var(death)[1L]
  dat <- dat[get(val) == TRUE]
  assert_that(!anyDuplicated(dat[[id]]), msg = "death_icu returned duplicate stay events")
  dat[, .(
    stay_id = get(id),
    death_time_hours = landmark_as_hours(get(ind))
  )]
}


landmark_status_metadata <- function(status) {
  dat <- data.table::as.data.table(status)
  id <- id_vars(status)[1L]
  val <- data_var(status)[1L]
  dat <- dat[, .(
    stay_id = get(id),
    raw_status = as.character(get(val))
  )]
  dat <- dat[, .(raw_status = raw_status[1L]), by = stay_id]
  dat[, outcome_status := data.table::fcase(
    tolower(trimws(raw_status)) == "dead", "dead",
    tolower(trimws(raw_status)) == "alive", "alive",
    default = "unknown"
  )]
  dat[, raw_status := NULL]
  dat
}


load_mortality_metadata <- function(src, dict, event_interval = mins(1L)) {
  assert_landmark_source(src)
  stays <- stay_windows(src, interval = event_interval)
  metadata <- landmark_metadata_from_stays(stays)

  death <- load_step(dict["death_icu"], interval = event_interval)
  death <- landmark_death_metadata(death)
  metadata <- merge(metadata, death, by = "stay_id", all.x = TRUE)
  assert_that(!anyDuplicated(metadata$stay_id))

  if (src == "hirid") {
    status <- load_step(dict["icu_discharge_status"], cache = TRUE)
    status <- landmark_status_metadata(status)
    metadata <- merge(metadata, status, by = "stay_id", all.x = TRUE)
  } else {
    metadata[, outcome_status := data.table::fifelse(
      !is.na(death_time_hours), "dead", "alive"
    )]
  }

  metadata[, event_time_kind := if (src == "hirid") {
    "hirid_last_map_hr_proxy"
  } else {
    "mimic_iv_deathtime"
  }]
  metadata[, icu_end_kind := if (src == "hirid") {
    "hirid_last_observation_proxy"
  } else {
    "mimic_iv_icustays_outtime"
  }]
  metadata[]
}


construct_landmark_labels <- function(
    metadata,
    observation_hours,
    prediction_hours,
    unknown_policy = c("exclude", "flag")
) {
  unknown_policy <- match.arg(unknown_policy)
  assert_that(is.data.frame(metadata))
  required <- c(
    "stay_id", "icu_start_hours", "icu_end_hours",
    "death_time_hours", "outcome_status"
  )
  assert_that(all(required %in% names(metadata)))

  dat <- data.table::copy(data.table::as.data.table(metadata))
  assert_that(!anyDuplicated(dat$stay_id), msg = "landmark metadata must contain one row per stay")
  old_columns <- intersect(c("reason", "label"), names(dat))
  if (length(old_columns)) {
    dat[, (old_columns) := NULL]
  }
  start <- observation_hours + 1
  end <- start + prediction_hours

  dat[, reason := "eligible"]
  dat[
    is.na(icu_start_hours) | is.na(icu_end_hours) |
      icu_start_hours > icu_end_hours,
    reason := "invalid_icu_window"
  ]
  dat[
    reason == "eligible" &
      !outcome_status %in% c("alive", "dead"),
    reason := "unknown_outcome_status"
  ]
  dat[
    reason == "eligible" & outcome_status == "dead" &
      is.na(death_time_hours),
    reason := "missing_death_time"
  ]
  dat[
    reason == "eligible" & outcome_status == "alive" &
      !is.na(death_time_hours),
    reason := "alive_status_with_death_time"
  ]
  dat[
    reason == "eligible" & icu_end_hours <= start,
    reason := "icu_discharge_at_or_before_prediction_start"
  ]
  dat[
    reason == "eligible" & icu_start_hours > start,
    reason := "icu_admission_after_prediction_start"
  ]
  dat[
    reason == "eligible" & !is.na(death_time_hours) &
      death_time_hours <= start,
    reason := "death_at_or_before_prediction_start"
  ]
  dat[
    reason == "eligible" & !is.na(death_time_hours) &
      death_time_hours < icu_start_hours,
    reason := "death_before_icu_start"
  ]
  dat[
    reason == "eligible" & !is.na(death_time_hours) &
      death_time_hours > icu_end_hours,
    reason := "death_after_icu_end"
  ]

  dat[reason == "eligible", label := as.integer(
    !is.na(death_time_hours) & death_time_hours <= end
  )]
  dat[reason == "eligible" & label == 1L, reason := "positive"]
  dat[reason == "eligible" & label == 0L, reason := "negative"]

  excluded <- dat[reason != "positive" & reason != "negative"]
  if (unknown_policy == "flag") {
    excluded[, label := NA_integer_]
  }

  labels <- dat[reason %in% c("positive", "negative"), .(stay_id, label)]
  attrition <- dat[, .(n = .N), by = reason][order(reason)]

  list(
    labels = labels,
    metadata = dat,
    excluded = excluded,
    attrition = attrition
  )
}


landmark_task_provenance <- function(
    src,
    observation_hours,
    prediction_hours,
    frequency,
    base_provenance,
    unknown_policy
) {
  list(
    schema_version = 1L,
    source = src,
    observation_hours = observation_hours,
    prediction_hours = prediction_hours,
    observation_convention = "hourly bin indices 0..W; physical period [0,W+1h)",
    prediction_start_hours = observation_hours + 1,
    prediction_end_hours = observation_hours + 1 + prediction_hours,
    frequency = frequency$label,
    label_interval = "(prediction_start, prediction_end]",
    unknown_policy = unknown_policy,
    base_provenance = base_provenance
  )
}
