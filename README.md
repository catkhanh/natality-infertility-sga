# Infertility Treatment and Small-for-Gestational-Age Birth

## Overview

This project is a methodological replication of Glatthorn et al. (2021), *Infertility treatment and the risk of small for gestational age births: a population-based study in the United States* (F&S Reports). The study asks whether births following infertility treatment have a different risk of small-for-gestational-age (SGA) birth than births conceived without recorded infertility treatment.

The project is being developed as an epidemiology portfolio exercise. It focuses on a transparent study population, reproducible variable definitions, missing-data handling, and effect estimation using modified Poisson regression with robust standard errors.

## Research question

- **Exposure:** Any infertility treatment recorded on the birth certificate (`RF_INFTR`).
- **Outcome:** SGA, defined as birth weight below the sex-specific 10th percentile for gestational age from Talge et al. (2014).
- **Population:** Singleton, nonmalformed U.S. live births at 24-44 completed weeks' gestation in the 2019 natality file. Births at or above the 90th percentile are excluded to mirror the paper's analytic population.
- **Design:** Cross-sectional analysis of population-based birth records.

## Data

- **Primary data:** [2019 U.S. Natality public-use file](https://www.cdc.gov/nchs/data_access/vitalstatsonline.htm). The individual-level source file is publicly downloadable without registration.
- **Variable definitions:** [NCHS 2019 natality data dictionary](https://data.nber.org/nvss/natality/programs/codebooks/natality2019us.html).
- **SGA reference:** Talge NM, Mudd LM, Sikorskii A, Basso O. United States birth weight reference corrected for implausible gestational age estimates. *Pediatrics*. 2014;133:844-853. [DOI: 10.1542/peds.2013-3285](https://doi.org/10.1542/peds.2013-3285).
- **Target paper:** Glatthorn HN, Sauer MV, Brandt JS, Ananth CV. *F&S Reports*. 2021;2(4):413-420. [DOI: 10.1016/j.xfre.2021.05.002](https://doi.org/10.1016/j.xfre.2021.05.002).

The raw natality file is not uploaded to this repository because of its size and data-use considerations. It can be downloaded directly from the source above.

## Current preliminary results

The analysis used 3,757,582 raw 2019 records, yielding 3,294,277 eligible births. A reproducible random 10% sample contained 329,360 births.

| Analysis | Adjusted risk ratio for infertility treatment and SGA | 95% confidence interval |
| --- | ---: | ---: |
| Single stochastic exposure imputation | 0.98 | 0.90 to 1.07 |
| Complete-case sensitivity analysis | 0.98 | 0.90 to 1.07 |

In this one-year, 10% sample, there was no clear evidence of an adjusted association between recorded infertility treatment and SGA. These estimates are preliminary and are not expected to exactly reproduce the published five-year MICE analysis.

## Missing-data assessment and limitation

Infertility-treatment status was missing for 1,025 of 329,360 births (**0.311%**). Missingness was similar by outcome: 913 of 295,784 non-SGA births (**0.309%**) and 112 of 33,576 SGA births (**0.334%**). The absolute difference is 0.025 percentage points.

This observed similarity provides no sign of a strong association between exposure missingness and SGA. It does **not** prove that the exposure is missing at random (MAR), because MAR depends on the unobserved true treatment status and other unmeasured factors.

The published study used multiple imputation by chained equations; this portfolio analysis currently uses one simpler stochastic imputation. That approach assumes the exposure is MAR after conditioning on SGA and the included covariates. A more concerning possibility is **missing not at random (MNAR)**: reporting could depend on the unobserved true treatment status, pregnancy outcome, or factors not included in the model. If this occurs, both imputed and complete-case estimates may be biased.


## Planned analysis

1. Build and document the eligible study population.
2. Describe maternal and birth characteristics by infertility-treatment status.
3. Define SGA from the external sex-specific birth-weight reference.
4. Examine missing exposure and covariate data.
5. Estimate crude and adjusted risk ratios using modified Poisson regression with robust standard errors.
6. Compare a simple single-imputation analysis with a complete-case sensitivity analysis.
