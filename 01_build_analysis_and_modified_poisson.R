# Infertility treatment and small-for-gestational-age birth, U.S. natality 2019
#
# This is a methodological replication of Glatthorn et al. (2021), using the
# public 2019 U.S. natality file. It is not an exact replication: the paper used
# 2015-2019 data and 20 multiple imputations. This script uses one 10% random
# sample and one simple stochastic imputation to limit memory requirements.
#
# Expected repository layout:
#   natality-infertility-sga/
#   |-- 01_build_analysis_and_modified_poisson.R
#   |-- data/       # Local source data; excluded from Git
#   `-- outputs/    # Generated analysis outputs; excluded from Git
#
# The 4.7 GB source file is processed in chunks and is never fully loaded into
# memory. The analysis settings are intended for a computer with 8 GB RAM.

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(sandwich)
  library(tibble)
})

set.seed(20260829) # Ensures reproducible random sampling and imputation.

# -----------------------------------------------------------------------------
# 1. File locations and settings
# -----------------------------------------------------------------------------

# Run this script with the repository as the working directory in RStudio.
project_dir <- normalizePath(".", winslash = "/", mustWork = TRUE)
data_dir <- file.path(project_dir, "data")
output_dir <- file.path(project_dir, "outputs")

raw_file <- Sys.getenv(
  "NATALITY_2019_FILE",
  unset = file.path(data_dir, "Nat2019PublicUS.c20200506.r20200915.txt")
)
talge_pdf <- Sys.getenv(
  "TALGE_2014_PDF",
  unset = file.path(data_dir, "talge2014.pdf")
)

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(raw_file) || !file.exists(talge_pdf)) {
  stop(
    "Source files were not found. Place them in data/ or set NATALITY_2019_FILE ",
    "and TALGE_2014_PDF before running the script."
  )
}

# The script reads 50,000 birth records at a time and retains approximately 10%
# of eligible records, yielding roughly 350,000 records for analysis.
chunk_size <- 50000L
sample_fraction <- 0.10

# A larger fraction increases precision but also increases memory requirements.
stopifnot(sample_fraction > 0, sample_fraction <= 1)

# -----------------------------------------------------------------------------
# 2. Talge et al. (2014) birth-weight reference values
# -----------------------------------------------------------------------------

# The SGA threshold is NOT calculated from the 2019 study sample.
# It comes from the external, sex-specific Talge reference tables.
talge_reference <- tibble(
  gestational_age = 22:44,
  p10_male = c(375, 436, 497, 561, 629, 706, 802, 924, 1068, 1231, 1415,
               1627, 1859, 2105, 2355, 2588, 2782, 2926, 3017, 3065, 3067,
               3067, 3027),
  p90_male = c(621, 717, 819, 941, 1087, 1246, 1422, 1625, 1850, 2094, 2357,
               2639, 2933, 3216, 3481, 3717, 3901, 4033, 4124, 4186, 4271,
               4253, 4271),
  p10_female = c(354, 416, 473, 529, 597, 677, 770, 882, 1018, 1166, 1335,
                 1538, 1772, 2021, 2261, 2477, 2665, 2810, 2904, 2958, 2985,
                 2981, 2952),
  p90_female = c(583, 687, 790, 903, 1035, 1186, 1356, 1548, 1763, 2004, 2267,
                 2549, 2845, 3133, 3383, 3588, 3752, 3954, 4015, 4059, 4091,
                 4091, 4118)
)

# -----------------------------------------------------------------------------
# 3. Small helpers for reading a fixed-width file
# -----------------------------------------------------------------------------

# A fixed-width file has no column headers or commas. For example, positions
# 75-76 contain maternal age in every line. These helpers extract the positions.
read_text <- function(lines, first, last) {
  trimws(substr(lines, first, last))
}

read_integer <- function(lines, first, last) {
  suppressWarnings(as.integer(read_text(lines, first, last)))
}

# Turns Y/N records into Yes/No/Missing. A reporting flag of 1 means the field
# was collected by the state; otherwise the value cannot be interpreted as No.
risk_factor <- function(value, reporting_flag) {
  factor(
    case_when(
      reporting_flag == 1L & value == "Y" ~ "Yes",
      reporting_flag == 1L & value == "N" ~ "No",
      TRUE ~ "Missing"
    ),
    levels = c("No", "Yes", "Missing")
  )
}

# -----------------------------------------------------------------------------
# 4. Turn one small chunk of raw lines into eligible analysis records
# -----------------------------------------------------------------------------

make_analysis_rows <- function(lines) {
  # These positions are from the NCHS 2019 natality data dictionary.
  raw <- tibble(
    maternal_age = read_integer(lines, 75, 76),
    race_ethnicity_code = read_integer(lines, 117, 117),
    marital_code = read_text(lines, 120, 120),
    education_code = read_integer(lines, 124, 124),
    previous_live_births = read_integer(lines, 179, 179),
    cigarettes_before = read_integer(lines, 253, 254),
    cigarettes_trimester1 = read_integer(lines, 255, 256),
    cigarettes_trimester2 = read_integer(lines, 257, 258),
    cigarettes_trimester3 = read_integer(lines, 259, 260),
    cigarettes_before_reported = read_integer(lines, 265, 265),
    cigarettes_trimester1_reported = read_integer(lines, 266, 266),
    cigarettes_trimester2_reported = read_integer(lines, 267, 267),
    cigarettes_trimester3_reported = read_integer(lines, 268, 268),
    prepregnancy_bmi = suppressWarnings(as.numeric(read_text(lines, 283, 286))),
    pregestational_diabetes_code = read_text(lines, 313, 313),
    chronic_hypertension_code = read_text(lines, 315, 315),
    pregestational_diabetes_reported = read_integer(lines, 319, 319),
    chronic_hypertension_reported = read_integer(lines, 321, 321),
    infertility_treatment_code = read_text(lines, 325, 325),
    infertility_treatment_reported = read_integer(lines, 328, 328),
    plurality = read_integer(lines, 454, 454),
    sex = read_text(lines, 475, 475),
    gestational_age = read_integer(lines, 499, 500),
    birth_weight_g = read_integer(lines, 504, 507),
    no_congenital_anomaly = read_integer(lines, 561, 561)
  )

  # Eligibility criteria used by Glatthorn et al.: singleton, no anomaly,
  # 24-44 completed weeks, plausible birth weight, and recorded infant sex.
  eligible <- raw %>%
    filter(
      plurality == 1L,
      no_congenital_anomaly == 1L,
      sex %in% c("M", "F"),
      between(gestational_age, 24L, 44L),
      between(birth_weight_g, 227L, 8165L)
    )

  if (nrow(eligible) == 0L) return(tibble())

  # Obtain external 10th and 90th percentiles for infant sex and gestational age.
  reference_row <- match(eligible$gestational_age, talge_reference$gestational_age)
  p10 <- if_else(eligible$sex == "M", talge_reference$p10_male[reference_row],
                 talge_reference$p10_female[reference_row])
  p90 <- if_else(eligible$sex == "M", talge_reference$p90_male[reference_row],
                 talge_reference$p90_female[reference_row])

  # SGA is birth weight strictly below the external 10th percentile.
  # Large-for-gestational-age births are excluded, as in the published paper.
  eligible <- eligible %>%
    mutate(sga10 = as.integer(birth_weight_g < p10), lga90 = birth_weight_g >= p90) %>%
    filter(!lga90)

  eligible %>%
    transmute(
      sga10,
      gestational_age,
      birth_weight_g,
      infant_sex = factor(if_else(sex == "M", "Male", "Female")),

      # Primary exposure: NCHS variable RF_INFTR (position 325).
      # 1 = any infertility treatment; 0 = no infertility treatment.
      # NA means it was missing or not reported, not necessarily no treatment.
      infertility_treatment_observed = case_when(
        infertility_treatment_reported == 1L & infertility_treatment_code == "Y" ~ 1L,
        infertility_treatment_reported == 1L & infertility_treatment_code == "N" ~ 0L,
        TRUE ~ NA_integer_
      ),

      age_group = factor(
        case_when(
          between(maternal_age, 12L, 14L) ~ "<15",
          between(maternal_age, 15L, 19L) ~ "15-19",
          between(maternal_age, 20L, 24L) ~ "20-24",
          between(maternal_age, 25L, 29L) ~ "25-29",
          between(maternal_age, 30L, 34L) ~ "30-34",
          between(maternal_age, 35L, 39L) ~ "35-39",
          between(maternal_age, 40L, 44L) ~ "40-44",
          between(maternal_age, 45L, 49L) ~ "45-49",
          maternal_age >= 50L ~ ">=50",
          TRUE ~ "Missing"
        ),
        levels = c("25-29", "<15", "15-19", "20-24", "30-34", "35-39",
                   "40-44", "45-49", ">=50", "Missing")
      ),

      parity_group = factor(
        case_when(
          previous_live_births == 1L ~ "1",
          previous_live_births == 2L ~ "2",
          between(previous_live_births, 3L, 8L) ~ ">=3",
          TRUE ~ "Missing"
        ),
        levels = c("1", "2", ">=3", "Missing")
      ),

      education_group = factor(
        case_when(
          education_code %in% 1:2 ~ "Below high school",
          education_code == 3L ~ "High school",
          education_code %in% 4:6 ~ "College",
          education_code %in% 7:8 ~ "Beyond college",
          TRUE ~ "Missing"
        ),
        levels = c("Beyond college", "Below high school", "High school", "College", "Missing")
      ),

      marital_status = factor(
        case_when(
          marital_code == "1" ~ "Married",
          marital_code == "2" ~ "Single/unmarried",
          TRUE ~ "Missing"
        ),
        levels = c("Married", "Single/unmarried", "Missing")
      ),

      race_ethnicity = factor(
        case_when(
          race_ethnicity_code == 1L ~ "Non-Hispanic White",
          race_ethnicity_code == 2L ~ "Non-Hispanic Black",
          race_ethnicity_code == 7L ~ "Hispanic",
          race_ethnicity_code %in% 3:6 ~ "Other",
          TRUE ~ "Missing"
        ),
        levels = c("Non-Hispanic White", "Non-Hispanic Black", "Hispanic", "Other", "Missing")
      ),

      smoking_status = factor(
        case_when(
          cigarettes_before_reported == 1L &
            cigarettes_trimester1_reported == 1L &
            cigarettes_trimester2_reported == 1L &
            cigarettes_trimester3_reported == 1L &
            cigarettes_before == 0L & cigarettes_trimester1 == 0L &
            cigarettes_trimester2 == 0L & cigarettes_trimester3 == 0L ~ "Nonsmoker",
          cigarettes_before_reported == 1L &
            cigarettes_trimester1_reported == 1L &
            cigarettes_trimester2_reported == 1L &
            cigarettes_trimester3_reported == 1L &
            cigarettes_before > 0L & cigarettes_trimester1 == 0L &
            cigarettes_trimester2 == 0L & cigarettes_trimester3 == 0L ~ "Before pregnancy only",
          cigarettes_before_reported == 1L &
            cigarettes_trimester1_reported == 1L &
            cigarettes_trimester2_reported == 1L &
            cigarettes_trimester3_reported == 1L &
            (cigarettes_trimester1 > 0L | cigarettes_trimester2 > 0L |
             cigarettes_trimester3 > 0L) ~ "During pregnancy",
          TRUE ~ "Missing"
        ),
        levels = c("Nonsmoker", "Before pregnancy only", "During pregnancy", "Missing")
      ),

      bmi_group = factor(
        case_when(
          between(prepregnancy_bmi, 13, 18.49) ~ "Underweight",
          between(prepregnancy_bmi, 18.5, 24.99) ~ "Normal weight",
          between(prepregnancy_bmi, 25, 29.99) ~ "Overweight",
          between(prepregnancy_bmi, 30, 34.99) ~ "Obese",
          between(prepregnancy_bmi, 35, 69.9) ~ "Morbidly obese",
          TRUE ~ "Missing"
        ),
        levels = c("Normal weight", "Underweight", "Overweight", "Obese",
                   "Morbidly obese", "Missing")
      ),

      chronic_hypertension = risk_factor(
        chronic_hypertension_code, chronic_hypertension_reported
      ),
      pregestational_diabetes = risk_factor(
        pregestational_diabetes_code, pregestational_diabetes_reported
      )
    )
}

# -----------------------------------------------------------------------------
# 5. Read the source file gradually, then take a random sample
# -----------------------------------------------------------------------------

# The source file is processed in small blocks rather than imported at once.
# Each block is cleaned before a 10% random sample of eligible records is retained.
connection <- file(raw_file, open = "r")
on.exit(close(connection), add = TRUE)

sampled_chunks <- list()
records_read <- 0L
eligible_records <- 0L
sampled_records <- 0L
chunk_number <- 0L

repeat {
  lines <- readLines(connection, n = chunk_size, warn = FALSE)
  if (length(lines) == 0L) break

  chunk_number <- chunk_number + 1L
  records_read <- records_read + length(lines)

  cleaned_chunk <- make_analysis_rows(lines)
  eligible_records <- eligible_records + nrow(cleaned_chunk)

  # Bernoulli sampling: each eligible birth has a 10% chance of being retained.
  keep_this_row <- runif(nrow(cleaned_chunk)) < sample_fraction
  sampled_chunk <- cleaned_chunk[keep_this_row, ]
  sampled_records <- sampled_records + nrow(sampled_chunk)

  if (nrow(sampled_chunk) > 0L) {
    sampled_chunks[[length(sampled_chunks) + 1L]] <- sampled_chunk
  }

  if (chunk_number %% 10L == 0L) {
    message("Read ", format(records_read, big.mark = ","), " records; kept ",
            format(sampled_records, big.mark = ","), " for analysis.")
  }
}

close(connection)

analysis_dataset <- bind_rows(sampled_chunks) %>% droplevels()
rm(sampled_chunks)
gc()

flow <- tibble(
  step = c(
    "All records read from the 2019 file",
    "Eligible singleton, nonmalformed births; 24-44 weeks; LGA excluded",
    paste0("Random analysis sample (", sample_fraction * 100, "%)")
  ),
  n = c(records_read, eligible_records, nrow(analysis_dataset))
)

if (nrow(analysis_dataset) == 0L) {
  stop("No records reached the analysis dataset. Check the input file path and format.")
}

# -----------------------------------------------------------------------------
# 6. Missing exposure: a simple single stochastic imputation
# -----------------------------------------------------------------------------

# The published paper used MICE with 20 imputed data sets. That would be much
# heavier on a computer with 8 GB RAM. This analysis uses ONE logistic model to
# predict the chance of infertility treatment for records with missing exposure,
# then randomly draws Yes/No according to that probability. This is an
# approximation, not MICE.
#
# Including SGA in this imputation model helps preserve the observed
# exposure-outcome relationship. Covariate "Missing" levels keep records with
# missing covariates in the model; this is a pragmatic approach, not a causal
# solution.
imputation_formula <- infertility_treatment_observed ~
  sga10 + age_group + parity_group + education_group + marital_status +
  race_ethnicity + smoking_status + bmi_group + chronic_hypertension +
  pregestational_diabetes

observed_exposure <- !is.na(analysis_dataset$infertility_treatment_observed)
missing_exposure <- !observed_exposure

imputation_model <- glm(
  imputation_formula,
  family = binomial(link = "logit"),
  data = analysis_dataset[observed_exposure, ]
)

analysis_dataset$infertility_treatment_imputed <-
  analysis_dataset$infertility_treatment_observed

if (any(missing_exposure)) {
  # The observed-exposure data may not contain every factor level. Unsupported
  # levels are converted to NA before prediction and receive the fallback below.
  imputation_newdata <- analysis_dataset[missing_exposure, ]
  for (variable in names(imputation_model$xlevels)) {
    imputation_newdata[[variable]] <- factor(
      as.character(imputation_newdata[[variable]]),
      levels = imputation_model$xlevels[[variable]]
    )
  }

  probability_treated <- predict(
    imputation_model,
    newdata = imputation_newdata,
    type = "response"
  )

  # A rare factor level or combination can be impossible to predict in a 10% sample.
  # For only those records, use the observed overall treatment prevalence.
  probability_treated[is.na(probability_treated)] <- mean(
    analysis_dataset$infertility_treatment_observed[observed_exposure]
  )

  analysis_dataset$infertility_treatment_imputed[missing_exposure] <- rbinom(
    n = sum(missing_exposure), size = 1L, prob = probability_treated
  )
}

stopifnot(!anyNA(analysis_dataset$infertility_treatment_imputed))

# -----------------------------------------------------------------------------
# 7. Modified Poisson regression with robust standard errors
# -----------------------------------------------------------------------------

# The outcome SGA is binary. A Poisson model with a log link estimates log risk
# ratios; the sandwich variance below corrects the standard errors because SGA
# is not truly a Poisson count.
analysis_formula <- sga10 ~ infertility_treatment_imputed +
  age_group + parity_group + education_group + marital_status +
  race_ethnicity + smoking_status + bmi_group + chronic_hypertension +
  pregestational_diabetes

fit_imputed <- glm(
  analysis_formula,
  family = poisson(link = "log"),
  data = analysis_dataset
)

# Sensitivity analysis: repeat the model using only births whose exposure was
# observed. This shows how much the single imputation choice matters.
fit_complete_case <- glm(
  update(
    analysis_formula,
    sga10 ~ . - infertility_treatment_imputed + infertility_treatment_observed
  ),
  family = poisson(link = "log"),
  data = filter(analysis_dataset, !is.na(infertility_treatment_observed))
)

make_rr_table <- function(model, analysis_name) {
  coefficients <- coef(model)
  keep <- !is.na(coefficients)
  # HC0 is the basic Huber-White robust (sandwich) variance estimator.
  # Install once with install.packages("sandwich") if this package is absent.
  robust_se <- sqrt(diag(sandwich::vcovHC(model, type = "HC0")))[keep]
  z_value <- coefficients[keep] / robust_se

  tibble(
    analysis = analysis_name,
    term = names(coefficients)[keep],
    risk_ratio = exp(coefficients[keep]),
    robust_se = robust_se,
    ci_low = exp(coefficients[keep] - 1.96 * robust_se),
    ci_high = exp(coefficients[keep] + 1.96 * robust_se),
    p_value = 2 * pnorm(abs(z_value), lower.tail = FALSE)
  )
}

results <- bind_rows(
  make_rr_table(fit_imputed, "Single stochastic exposure imputation"),
  make_rr_table(fit_complete_case, "Complete-case exposure sensitivity")
)

# -----------------------------------------------------------------------------
# 8. Save outputs
# -----------------------------------------------------------------------------

write_csv(flow, file.path(output_dir, "eligibility_flow_2019.csv"))
write_csv(results, file.path(output_dir, "modified_poisson_robust_rr_2019.csv"))
saveRDS(analysis_dataset, file.path(output_dir, "analysis_dataset_2019_10pct.rds"), compress = "xz")
saveRDS(talge_reference, file.path(output_dir, "talge2014_reference_cutoffs.rds"))

message("Finished. Outputs are in: ", output_dir)
print(filter(results, grepl("infertility_treatment", term)))

library(dplyr)

analysis_dataset <- readRDS(
  "/Users/catkhanh/Desktop/natality-infertility-sga/outputs/analysis_dataset_2019_10pct.rds"
)

analysis_dataset %>%
  summarise(
    total_births = n(),
    missing_exposure_n = sum(is.na(infertility_treatment_observed)),
    missing_exposure_percent = 100 * mean(is.na(infertility_treatment_observed))
  )

analysis_dataset %>%
  mutate(exposure_missing = is.na(infertility_treatment_observed)) %>%
  count(sga10, exposure_missing) %>%
  group_by(sga10) %>%
  mutate(percent_within_sga_group = 100 * n / sum(n))
