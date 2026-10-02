# read in the packages used for analysis and rendering
packages <- c("tidyverse", "dplyr", "janitor", "readr", "knitr", "rmarkdown", "cluster", "mclust")
# check which packages still need to be installed
missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
# install missing packages from CRAN
if (length(missing)) install.packages(missing, repos = "https://cloud.r-project.org")
