# run this file from the project folder after installing the required packages
source("R/analysis.R")

# checking the circular boundary that caused problems with ordinary averages
boundary <- encode_spin(c(359, 1, 180), c("R", "R", "R"))
stopifnot(abs(mean(boundary$spin_sin[1:2])) < 1e-10,
          mean(boundary$spin_cos[1:2]) > 0.99,
          boundary$spin_cos[3] < -0.99)

# checking that equivalent clock directions stay the same after one full turn
wrapped <- encode_spin(c(0, 360, 720), c("R", "R", "R"))
stopifnot(max(abs(wrapped$spin_sin)) < 1e-10,
          max(abs(wrapped$spin_cos - 1)) < 1e-10)

# checking that mirror-image deliveries have matching circular features
mirrored <- encode_spin(c(45, 315), c("R", "L"))
stopifnot(abs(diff(mirrored$spin_sin)) < 1e-10,
          abs(diff(mirrored$spin_cos)) < 1e-10)

# checking that the spin pair has one shared unit of variance
stopifnot(abs(sum(apply(cluster_vars[, 7:8], 2, var)) - 1) < 1e-10,
          all(abs(apply(cluster_vars[, 1:6], 2, var) - 1) < 1e-10))

# checking that coverage uses the season total and the complete matched pitches
coverage_check <- complete_pitches |>
  group_by(pitcher_id) |> summarise(n = sum(n_pitches), .groups = "drop") |>
  inner_join(pitcher_data, by = "pitcher_id", relationship = "one-to-one")
stopifnot(all(coverage_check$n == coverage_check$represented_pitches),
          all(abs(coverage_check$n / coverage_check$season_pitches -
                    coverage_check$pitch_coverage) < 1e-10),
          all(pitcher_data$season_pitches >= 300),
          all(pitcher_data$pitch_coverage >= 0.80),
          all(pitcher_data$pitch_coverage <= 1),
          !anyDuplicated(pitcher_data$pitcher_id))

# checking that the saved assignments and summaries match the fitted model
saved <- read_csv("reports/pitcher_cluster_assignments.csv", show_col_types = FALSE)
stopifnot(nrow(saved) == nrow(pitcher_data),
          identical(saved$pitcher_id, pitcher_data$pitcher_id),
          all(as.character(saved$cluster) == as.character(pitcher_data$cluster)),
          sum(cluster_summary$n_pitchers) == nrow(pitcher_data),
          sum(comparison_table) == nrow(pitcher_data),
          nrow(subsample_stability) == 400,
          all(is.finite(subsample_stability$ari)),
          all(is.finite(saved$silhouette_width)))

# keeping the individual checks visible when running from a clean R session
cat("Circular direction, handedness reflection, feature weights, coverage, and output checks passed.\n")
