


stop_obs_at <- function(x, offset, by_ref = TRUE, target = NULL) {
  if (is.null(target))
    target <- patients

  assert_that(is_atomic(offset), 
              ricu:::is_interval(offset), 
              units(offset) == units(index_col(x)), 
              units(offset) == units(index_col(target)))
  
  if (!by_ref) {
    target <- copy(target)
    x <- copy(x)
  }
  
  ids <- id_vars(x)
  idx <- index_var(x)
  
  x <- x[, .(...time = min(.SD[[idx]]) + offset), by = c(ids)]
  target[x, end := pmin(end, ...time), on = c(ids)] # Check if on=ids is correct
  invisible(target)
}
