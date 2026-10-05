# Data Sources and Methods

The project was originally developed in November–December 2025. The report was dated December 15, 2025. The October 2026 update keeps the original baseball question and source CSVs, but corrects feature construction and adds validation. It does not add 2026 playing data.

## Source files

| File | Measurements used | Join key |
| --- | --- | --- |
| `minsavantdata.csv` | Season pitch total, player name, release extension | Player ID |
| `pitcher_arm_angles-2.csv` | Throwing hand, release height | Pitcher ID |
| `pitch_movement-2.csv` | Velocity, induced vertical break, horizontal movement magnitude | Pitcher ID and pitch type |
| `spin-direction-pitches.csv` | Spin rate, clock direction, pitch count, throwing hand | Player ID and pitch type |

The movement and spin exports contain a year column; all rows are 2025. The other two files came from the original 2025 project and do not contain a season column, so their season cannot be independently verified from those files alone. The four raw files are unchanged from the original project.

The original export settings were not saved. Baseball Savant's [movement leaderboard](https://baseballsavant.mlb.com/leaderboard/pitch-movement) and [spin-direction leaderboard](https://baseballsavant.mlb.com/leaderboard/spin-direction-pitches) expose qualification filters. The available files therefore should not be treated as complete pitch-by-pitch season data.

## Coverage and weighted averages

Pitch-type rows are joined by pitcher ID and pitch type. Duplicate keys, inconsistent throwing hands, and incorrect years cause the analysis to stop. A pitch row must contain all movement and spin measurements before it is included in any weighted average. This keeps each average based on the same pitches.

Represented pitches are the sum of `n_pitches` from these complete spin rows. Coverage is represented pitches divided by `total_pitches` in the custom leaderboard. The denominator is the season total, not the smaller sum of the exported pitch types. Release height and extension come from their separate pitcher-level exports.

The main sample requires at least 300 season pitches, 80% coverage, and complete release measurements. This produces 185 pitchers. The 80% cutoff is a practical coverage requirement, not a statistically optimal threshold. Checks at 70% and 90% show how it affects the result. The coverage audit includes all 573 players in the season-total file, including those excluded from the model.

The averages describe the represented pitch types, with their counts renormalized within each pitcher. They are not guaranteed full-arsenal averages. A pitcher who throws several pitches can still have only one pitch type represented in a filtered export.

## Spin direction and movement

The clock direction is converted to degrees and wrapped into [0, 360). Left-handed clock directions are reflected using `(360 - angle) %% 360`. This changes the coordinate convention so mirror-image deliveries can be compared; it does not assert that left- and right-handed pitchers have identical mechanics.

The sine and cosine of each direction are averaged using pitch counts. Unlike averaging degree values, this keeps directions on either side of the clock boundary close together. The vector length also retains information about how much the represented pitch-type directions agree or cancel. This is variation across pitch-type averages, not pitch-to-pitch spin variation.

The original clock fields are rounded. They are retained to keep the spin definition consistent with the original project, rather than mixing them with a different undocumented angular field.

The six ordinary measurements are standardized separately. Both circular components are centered and divided by the square root of their combined sample variance. This preserves their relative circular geometry and gives the pair the same total variance as one ordinary standardized feature. PCA uses this same matrix without scaling it again.

`pitcher_break_x` is nonnegative throughout the source file and is treated as horizontal movement magnitude. The analysis does not reconstruct direction from pitch labels or claim that it distinguishes arm-side run from glove-side sweep.

## Clustering and validation

K-means is fit with 50 starts, a maximum of 100 iterations, and a recorded seed. The elbow plot covers one through eight groups; silhouette scores cover two through eight. Two has the highest silhouette score. The three-group result is retained as an exploratory description of finer profiles, not as the optimal cluster count.

Three-group labels are ordered by average induced vertical break, from highest to lowest. Two-group labels are ordered separately. Numbers are identifiers, not quality rankings, and there is no requirement that labels agree between models.

Ward's D2 hierarchical clustering uses the same feature matrix and Euclidean distances. A three-group cut is compared with three-group K-means using both best-matched label agreement and the adjusted Rand index. A dendrogram can always be cut into three groups; that cut alone does not validate three natural types.

The adjusted Rand index accounts for chance agreement: 1 means identical partitions, and random partitions have expected value 0. Negative values are possible. It is not a percentage of correct predictions. [mclust documentation](https://mclust-org.github.io/mclust/reference/adjustedRandIndex.html).

For each of two through five groups, 100 samples contain 80% of pitchers without replacement. Scaling is recalculated and K-means is refit in each sample. Agreement is measured against the corresponding full-sample model on shared pitchers. The reported 10th and 90th percentiles describe the distribution of these checks; they are not confidence intervals or out-of-sample forecast accuracy.

Other checks use 20 initialization seeds, coverage thresholds, 1,000 season pitches, omitted spin direction, and omitted handedness reflection. Changing coverage changes the population as well as the fit. Agreement in those checks is measured only on shared pitchers. Results are not independent validation against a known true set of archetypes.

## Running the analysis

Open `R/analysis.R` in RStudio with the project folder as your working directory. The first comment lists the required packages. Run the script, or use `Rscript --vanilla R/analysis.R` from the project folder.

The script creates the plots, pitcher assignments, and supporting CSV tables. The extra tables stay local and are excluded from GitHub to keep the repository focused. No saved R workspace is needed.

## References

- [Baseball Savant custom leaderboards](https://baseballsavant.mlb.com/leaderboard/custom)
- [R silhouette documentation](https://stat.ethz.ch/R-manual/R-devel/library/cluster/html/silhouette.html)
- [Circular mean](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.circmean.html)
- [Ward's hierarchical clustering in R](https://www.r-bloggers.com/2017/12/how-to-perform-hierarchical-clustering-using-r/)
- [Gao et al., overview of clustering methods](https://doi.org/10.1016/j.psychres.2023.115265)

## What changed in October 2026

- Replaced ordinary spin-angle averages with weighted circular components and a documented handedness reflection.
- Used season totals for the pitch requirement and added coverage checks.
- Used complete matched pitch rows consistently across features.
- Treated horizontal movement as a magnitude and updated the profile names and player examples.
- Added cluster-count, initialization, subsampling, coverage, playing-time, and feature-sensitivity checks.
- Reported two-group evidence alongside the exploratory three-group view and removed claims that PCA or a three-branch cut proves three natural types.

The original 2025 files remain separate from this publication copy. The current README describes the updated analysis.
