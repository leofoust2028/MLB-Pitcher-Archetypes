# install these packages once if needed
# install.packages(c("tidyverse", "janitor", "cluster", "mclust"))

# read in packages
library(tidyverse)
library(janitor)
library(cluster)


# run this file from the project folder or the reports folder
project_dir <- if (file.exists("data/minsavantdata.csv")) "." else ".."
data_dir <- file.path(project_dir, "data")
report_dir <- file.path(project_dir, "reports")
figure_dir <- file.path(project_dir, "figures")
dir.create(figure_dir, showWarnings = FALSE)
dir.create(report_dir, showWarnings = FALSE)

# read in CSV files
savantdata <- read_csv(file.path(data_dir, "minsavantdata.csv"), show_col_types = FALSE) |>
  clean_names() |>
  transmute(pitcher_id = player_id, player_name,
            season_pitches = total_pitches, release_extension)
pitcher_arm_angles <- read_csv(file.path(data_dir, "pitcher_arm_angles-2.csv"), show_col_types = FALSE) |>
  clean_names() |>
  transmute(pitcher_id = pitcher, pitch_hand, release_height = release_ball_z)
pitch_movement <- read_csv(file.path(data_dir, "pitch_movement-2.csv"), show_col_types = FALSE) |>
  clean_names()
spin_direction <- read_csv(file.path(data_dir, "spin-direction-pitches.csv"), show_col_types = FALSE) |>
  clean_names()

# check the season and make sure each join has only one matching row
stopifnot(all(pitch_movement$year == 2025), all(spin_direction$year == 2025),
          !anyDuplicated(savantdata$pitcher_id),
          !anyDuplicated(pitcher_arm_angles$pitcher_id),
          !anyDuplicated(paste(pitch_movement$pitcher_id, pitch_movement$pitch_type)),
          !anyDuplicated(paste(spin_direction$player_id, spin_direction$api_pitch_type)))

# merging pitch tables using pitcher ID and pitch type
all_pitches <- spin_direction |>
  transmute(pitcher_id = player_id, pitch_hand, pitch_type = api_pitch_type,
            n_pitches, spin_rate,
            # converting the clock measurement to degrees between 0 and 360
            spin_axis_deg = (hawkeye_measured_clock_hh * 30 +
                               hawkeye_measured_clock_mm * 0.5) %% 360) |>
  left_join(pitch_movement |>
              transmute(pitcher_id, pitch_type, movement_hand = pitch_hand,
                        avg_vel = avg_speed, avg_ivb = pitcher_break_z_induced,
                        # this export contains movement magnitude, not a signed direction
                        avg_hb = pitcher_break_x),
            by = c("pitcher_id", "pitch_type"), relationship = "one-to-one")
stopifnot(all(all_pitches$pitch_hand == all_pitches$movement_hand, na.rm = TRUE))

# converting directions into circular features for either throwing hand
encode_spin <- function(angle, hand) {
  stopifnot(all(is.finite(angle)), all(hand %in% c("R", "L")))
  # reflecting left-handed directions around the vertical axis
  # this puts mirror-image deliveries on the same side of the clock
  same_hand <- if_else(hand == "L", (360 - angle) %% 360, angle %% 360)
  tibble(
    spin_axis_same_hand = same_hand,
    # using sine and cosine keeps 359 degrees close to 1 degree
    spin_sin = sin(same_hand * pi / 180),
    spin_cos = cos(same_hand * pi / 180),
    # keeping the unreflected version to check the effect of handedness
    spin_sin_unmirrored = sin(angle * pi / 180),
    spin_cos_unmirrored = cos(angle * pi / 180)
  )
}

# keep the same complete pitch rows for every weighted average
complete_pitches <- all_pitches |>
  filter(n_pitches > 0, pitch_hand %in% c("R", "L"),
         if_all(c(spin_rate, spin_axis_deg, avg_vel, avg_ivb, avg_hb), is.finite))
complete_pitches <- bind_cols(
  complete_pitches,
  encode_spin(complete_pitches$spin_axis_deg, complete_pitches$pitch_hand)
)

# averaging the pitch types available in both exports
pitcher_average <- complete_pitches |>
  group_by(pitcher_id, pitch_hand) |>
  summarise(
    represented_pitches = sum(n_pitches),
    represented_pitch_types = n(),
    across(c(avg_vel, avg_ivb, avg_hb, spin_sin, spin_cos,
             spin_sin_unmirrored, spin_cos_unmirrored),
           ~ weighted.mean(.x, n_pitches)),
    avg_spin = weighted.mean(spin_rate, n_pitches),
    .groups = "drop"
  ) |>
  left_join(savantdata, by = "pitcher_id", relationship = "one-to-one") |>
  left_join(pitcher_arm_angles |> rename(arm_hand = pitch_hand),
            by = "pitcher_id", relationship = "one-to-one") |>
  mutate(
    # comparing represented pitches with the full season total
    pitch_coverage = represented_pitches / season_pitches,
    # values close to zero mean the spin directions cancel across pitch types
    spin_concentration = sqrt(spin_sin^2 + spin_cos^2)
  )
stopifnot(all(pitcher_average$pitch_hand == pitcher_average$arm_hand, na.rm = TRUE),
          all(pitcher_average$pitch_coverage <= 1.001, na.rm = TRUE))

# exporting coverage for every pitcher in the season-total file
coverage_audit <- savantdata |>
  select(pitcher_id, player_name, season_pitches) |>
  left_join(pitcher_average |>
              select(pitcher_id, represented_pitches, represented_pitch_types,
                     pitch_coverage, release_height, release_extension),
            by = "pitcher_id", relationship = "one-to-one") |>
  mutate(included = season_pitches >= 300 & !is.na(pitch_coverage) &
           pitch_coverage >= 0.80 & is.finite(release_height) &
           is.finite(release_extension))
write_csv(coverage_audit, file.path(report_dir, "pitch_coverage_audit.csv"))

# requiring 300 season pitches and at least 80 percent coverage
# 70 and 90 percent coverage are checked later instead of assuming 80 is perfect
eligible_pitchers <- pitcher_average |>
  filter(season_pitches >= 300,
         if_all(c(avg_vel, avg_spin, avg_ivb, avg_hb, release_height,
                  release_extension, spin_sin, spin_cos), is.finite))
pitcher_data <- eligible_pitchers |> filter(pitch_coverage >= 0.80) |>
  arrange(pitcher_id)
stopifnot(!anyDuplicated(pitcher_data$pitcher_id))

# scaling the six ordinary measurements and the two spin components
scale_features <- function(data, spin = "mirrored") {
  ordinary <- data |> select(avg_vel, avg_spin, avg_ivb, avg_hb,
                             release_extension, release_height)
  z <- scale(ordinary)
  if (spin != "none") {
    direction <- if (spin == "mirrored") data |> select(spin_sin, spin_cos) else
      data |> select(spin_sin_unmirrored, spin_cos_unmirrored)
    # giving both spin components one shared scale preserves circular distances
    # their combined variance equals one ordinary standardized variable
    direction <- scale(direction, center = TRUE, scale = FALSE)
    direction <- direction / sqrt(sum(apply(direction, 2, var)))
    z <- cbind(z, direction)
  }
  stopifnot(all(is.finite(z)))
  z
}
cluster_vars <- scale_features(pitcher_data)

# comparing cluster counts using within-cluster variation and silhouette width
# larger silhouette values indicate better separation in the selected features
set.seed(100)
fits <- lapply(1:8, function(k) kmeans(cluster_vars, centers = k, nstart = 50, iter.max = 100))
distance_matrix <- dist(cluster_vars)
k_diagnostics <- map_dfr(2:8, function(k) {
  tibble(k = k, within_ss = fits[[k]]$tot.withinss,
         mean_silhouette = mean(silhouette(fits[[k]]$cluster, distance_matrix)[, 3]),
         smallest_cluster = min(fits[[k]]$size))
})

# keeping three groups as an interpretable summary of the original question
# the diagnostics below show whether another count separates the data better
set.seed(100)
k3 <- kmeans(cluster_vars, centers = 3, nstart = 50, iter.max = 100)

# ordering the labels by vertical break so the figures use consistent numbers
cluster_order <- order(tapply(pitcher_data$avg_ivb, k3$cluster, mean), decreasing = TRUE)
cluster_labels <- match(k3$cluster, cluster_order)
pitcher_data <- pitcher_data |> mutate(cluster = factor(cluster_labels))

# keeping the two-group result because it has the best silhouette score
k2_order <- order(tapply(pitcher_data$avg_ivb, fits[[2]]$cluster, mean), decreasing = TRUE)
pitcher_data <- pitcher_data |>
  mutate(cluster_k2 = factor(match(fits[[2]]$cluster, k2_order)))
k2_summary <- pitcher_data |>
  group_by(cluster_k2) |>
  summarise(n_pitchers = n(),
            across(c(avg_vel, avg_spin, avg_ivb, avg_hb, release_height,
                     release_extension), mean), .groups = "drop")
write_csv(k2_summary, file.path(report_dir, "two_group_summary.csv"))

# using Ward's D2 method for hierarchical clustering
h_clust <- hclust(distance_matrix, method = "ward.D2")
pitcher_data <- pitcher_data |> mutate(hc_cluster = factor(cutree(h_clust, k = 3)))
comparison_table <- table(pitcher_data$cluster, pitcher_data$hc_cluster)

# matching arbitrary cluster labels before counting agreement
label_orders <- rbind(c(1, 2, 3), c(1, 3, 2), c(2, 1, 3),
                      c(2, 3, 1), c(3, 1, 2), c(3, 2, 1))
matched_agreement <- max(apply(label_orders, 1, function(x) {
  sum(comparison_table[cbind(1:3, x)])
})) / nrow(pitcher_data)
hc_ari <- mclust::adjustedRandIndex(pitcher_data$cluster, pitcher_data$hc_cluster)

# summarizing the measurements in their original units
cluster_summary <- pitcher_data |>
  group_by(cluster) |>
  summarise(n_pitchers = n(),
            across(c(avg_vel, avg_spin, avg_ivb, avg_hb, release_height,
                     release_extension, spin_concentration, pitch_coverage), mean),
            right_handed = sum(pitch_hand == "R"),
            left_handed = sum(pitch_hand == "L"), .groups = "drop")

# keeping each pitcher's silhouette score to show uncertain assignments
pitcher_data <- pitcher_data |>
  mutate(silhouette_width = as.numeric(silhouette(cluster_labels, distance_matrix)[, 3]))

# comparing handedness with the group labels, without using it as an outcome
hand_ari <- mclust::adjustedRandIndex(pitcher_data$cluster, pitcher_data$pitch_hand)
set.seed(100)
unmirrored_fit <- kmeans(scale_features(pitcher_data, "unmirrored"),
                        centers = 3, nstart = 50, iter.max = 100)
unmirrored_hand_ari <- mclust::adjustedRandIndex(unmirrored_fit$cluster, pitcher_data$pitch_hand)

# checking new random starts on the same sample
seed_stability <- map_dfr(1:20, function(seed) {
  set.seed(seed)
  fit <- kmeans(cluster_vars, centers = 3, nstart = 50, iter.max = 100)
  tibble(seed, ari = mclust::adjustedRandIndex(cluster_labels, fit$cluster))
})

# repeating the analysis on 80 percent of pitchers, without replacement
# scaling is recalculated in each sample instead of reusing the full sample scale
# agreement is measured on the sampled pitchers, not as prediction accuracy
subsample_stability <- map_dfr(2:5, function(k) {
  set.seed(100 + k)
  reference <- kmeans(cluster_vars, centers = k, nstart = 50, iter.max = 100)$cluster
  map_dfr(1:100, function(repetition) {
    set.seed(1000 * k + repetition)
    rows <- sample(seq_len(nrow(pitcher_data)), floor(0.8 * nrow(pitcher_data)))
    fit <- kmeans(scale_features(pitcher_data[rows, ]), centers = k,
                  nstart = 50, iter.max = 100)
    tibble(k, repetition, ari = mclust::adjustedRandIndex(reference[rows], fit$cluster))
  })
})
stability_summary <- subsample_stability |>
  group_by(k) |>
  summarise(median_ari = median(ari), p10_ari = quantile(ari, 0.1),
            p90_ari = quantile(ari, 0.9), .groups = "drop")

# checking coverage cutoffs, playing time, and the effect of spin direction
sensitivity_check <- function(data, name, spin = "mirrored") {
  set.seed(100)
  fit <- kmeans(scale_features(data, spin), centers = 3, nstart = 50, iter.max = 100)
  shared <- match(pitcher_data$pitcher_id, data$pitcher_id)
  keep <- !is.na(shared)
  tibble(check = name, n_pitchers = nrow(data), shared_pitchers = sum(keep),
         ari = mclust::adjustedRandIndex(cluster_labels[keep], fit$cluster[shared[keep]]))
}
sensitivity <- bind_rows(
  sensitivity_check(eligible_pitchers |> filter(pitch_coverage >= 0.70), "70% coverage"),
  sensitivity_check(eligible_pitchers |> filter(pitch_coverage >= 0.90), "90% coverage"),
  sensitivity_check(pitcher_data |> filter(season_pitches >= 1000), "1000 season pitches"),
  sensitivity_check(pitcher_data, "Without spin direction", "none"),
  sensitivity_check(pitcher_data, "Without handedness reflection", "unmirrored")
)

# running PCA on the same weighted features used for clustering
# scaling again here would undo the shared scale for spin direction
pca_res <- prcomp(cluster_vars, center = FALSE, scale. = FALSE)
pca_variance <- pca_res$sdev^2 / sum(pca_res$sdev^2)
pca_df <- as_tibble(pca_res$x) |>
  bind_cols(pitcher_data |> select(pitcher_id, player_name, cluster))
plot_colors <- c("1" = "#277DA1", "2" = "#D97706", "3" = "#7C3AED")
pca_plot <- ggplot(pca_df, aes(PC1, PC2, color = cluster)) +
  geom_point(alpha = 0.8, size = 2) +
  scale_color_manual(values = plot_colors) +
  theme_minimal(base_size = 12) +
  labs(title = "PCA of Pitcher Movement/Mechanics Features",
       subtitle = "Each point represents a pitcher; colors show the three K-means groups",
       x = sprintf("Principal Component 1 (%.1f%%)", 100 * pca_variance[1]),
       y = sprintf("Principal Component 2 (%.1f%%)", 100 * pca_variance[2]), color = "Cluster")
ggsave(file.path(figure_dir, "pitcher_clusters_pca.png"), pca_plot,
       width = 9, height = 5.5, dpi = 180)

# showing the two-group view on the same PCA axes for comparison
pca_k2 <- pca_df |> mutate(cluster = pitcher_data$cluster_k2)
pca_k2_plot <- pca_plot + pca_k2 +
  labs(title = "The Two-Group View", subtitle = "The cluster count with the highest average silhouette width")
ggsave(file.path(figure_dir, "pitcher_clusters_k2.png"), pca_k2_plot,
       width = 9, height = 5.5, dpi = 180)

# saving the dendrogram with the three-group cut marked
png(file.path(figure_dir, "hierarchical_clusters.png"), width = 1600, height = 950, res = 180)
plot(h_clust, labels = FALSE, main = "Hierarchical Clustering of MLB Pitchers",
     sub = "Ward's D2 method; boxes show the three-group cut", xlab = "Pitchers")
rect.hclust(h_clust, k = 3, border = "#277DA1")
dev.off()

# showing the elbow and silhouette checks together
elbow_data <- tibble(k = 1:8, value = sapply(fits, function(x) x$tot.withinss),
                     measure = "Within-cluster sum of squares")
diagnostic_plot <- bind_rows(elbow_data,
                             k_diagnostics |> transmute(k, value = mean_silhouette,
                                                        measure = "Average silhouette width")) |>
  ggplot(aes(k, value)) + geom_line(color = "#277DA1") + geom_point(color = "#277DA1") +
  geom_vline(xintercept = 3, linetype = "dashed", color = "grey50") +
  facet_wrap(~ measure, scales = "free_y") + scale_x_continuous(breaks = 1:8) +
  theme_minimal(base_size = 12) + labs(title = "Checking the Number of Clusters", x = "Number of clusters", y = NULL)
ggsave(file.path(figure_dir, "cluster_count_checks.png"), diagnostic_plot,
       width = 10, height = 4.5, dpi = 180)

# comparing the six ordinary measurements on a common standardized scale
profile_data <- as_tibble(cluster_vars[, 1:6]) |>
  mutate(cluster = pitcher_data$cluster) |>
  group_by(cluster) |> summarise(across(everything(), mean), .groups = "drop") |>
  pivot_longer(-cluster, names_to = "variable", values_to = "value")
profile_labels <- c(avg_vel = "Velocity", avg_spin = "Spin rate", avg_ivb = "Vertical break",
                    avg_hb = "Horizontal magnitude", release_extension = "Extension",
                    release_height = "Release height")
profile_plot <- ggplot(profile_data, aes(variable, value, fill = cluster)) +
  geom_col(position = "dodge") + coord_flip() +
  scale_x_discrete(labels = profile_labels) + scale_fill_manual(values = plot_colors) +
  theme_minimal(base_size = 12) +
  labs(title = "What Separates the Three Groups?", x = NULL,
       y = "Average standardized value (0 = sample average)", fill = "Cluster")
ggsave(file.path(figure_dir, "cluster_profiles.png"), profile_plot,
       width = 9, height = 5.5, dpi = 180)

# showing the variation across repeated samples instead of only the average
stability_plot <- ggplot(subsample_stability, aes(factor(k), ari)) +
  geom_boxplot(fill = "#B8D9E8", outlier.alpha = 0.4) +
  theme_minimal(base_size = 12) +
  labs(title = "How Stable Are the Groups?", subtitle = "100 repeated samples of 80% of pitchers for each cluster count",
       x = "Number of clusters", y = "Adjusted Rand index (1 = identical assignments)")
ggsave(file.path(figure_dir, "cluster_stability.png"), stability_plot,
       width = 9, height = 5, dpi = 180)

# keeping the exploratory scatterplots from the original analysis
eda_plots <- list(
  velocity_ivb = ggplot(pitcher_data, aes(avg_vel, avg_ivb)) + geom_point(alpha = 0.6, color = "purple") +
    labs(title = "Velocity vs. Induced Vertical Break", x = "Average velocity (mph)", y = "Induced vertical break (inches)"),
  release_horizontal = ggplot(pitcher_data, aes(release_height, avg_hb)) + geom_point(alpha = 0.6, color = "blue") +
    labs(title = "Release Height vs. Horizontal Movement", x = "Release height (ft)", y = "Horizontal movement magnitude (inches)"),
  spin_ivb = ggplot(pitcher_data, aes(avg_spin, avg_ivb)) + geom_point(alpha = 0.6, color = "darkgreen") +
    labs(title = "Spin Rate vs. Induced Vertical Break", x = "Average spin rate (rpm)", y = "Induced vertical break (inches)")
)
for (name in names(eda_plots)) {
  ggsave(file.path(figure_dir, paste0(name, ".png")), eda_plots[[name]] + theme_minimal(),
         width = 7, height = 4.5, dpi = 180)
}

# exporting results so the report and README can be checked against the model
write_csv(pitcher_data, file.path(report_dir, "pitcher_cluster_assignments.csv"))
write_csv(cluster_summary, file.path(report_dir, "cluster_summary.csv"))
write_csv(k_diagnostics, file.path(report_dir, "cluster_count_checks.csv"))
write_csv(seed_stability, file.path(report_dir, "random_seed_checks.csv"))
write_csv(subsample_stability, file.path(report_dir, "subsample_stability.csv"))
write_csv(stability_summary, file.path(report_dir, "stability_summary.csv"))
write_csv(sensitivity, file.path(report_dir, "sensitivity_checks.csv"))
write_csv(as.data.frame(comparison_table) |> as_tibble() |>
            set_names(c("cluster", "hc_cluster", "n_pitchers")),
          file.path(report_dir, "method_comparison.csv"))
summary_metrics <- tibble(
  n_pitchers = nrow(pitcher_data), median_coverage = median(pitcher_data$pitch_coverage),
  pca_two_components = sum(pca_variance[1:2]), matched_agreement, hc_ari,
  hand_ari, unmirrored_hand_ari,
  k3_silhouette = mean(silhouette(cluster_labels, distance_matrix)[, 3]),
  best_silhouette_k = k_diagnostics$k[which.max(k_diagnostics$mean_silhouette)],
  negative_silhouette_share = mean(silhouette(cluster_labels, distance_matrix)[, 3] < 0)
)
write_csv(summary_metrics, file.path(report_dir, "summary_metrics.csv"))
writeLines(capture.output(sessionInfo()), file.path(project_dir, "session-info.txt"))
print(k2_summary, width = Inf)
print(cluster_summary, width = Inf)
print(summary_metrics, width = Inf)
print(stability_summary)
print(sensitivity)
