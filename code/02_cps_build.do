/*==============================================================================
  02_cps_build.do

  Build CPS monthly microdata with AI exposure measures:
    1. Load CPS Basic Monthly extract from IPUMS
    2. Crosswalk pre-2020 occ2010 codes to occ2018 (probabilistic assignment)
    3. Merge four AI exposure measures (Felten, GPTs, Eisfeldt, Webb)
    4. Save processed dataset

  Input:  data/raw/cps/cps_00181.dta
          data/raw/crosswalks/ (5 crosswalk CSVs)
  Output: data/processed/cps_monthly_xposure.dta
==============================================================================*/

*--------------------------------------------------
* PROGRAM SETUP
*--------------------------------------------------
capture log close
clear all
set more off
set linesize 80
set type double
local dt = "`c(current_date)' `c(current_time)'"
local dt = subinstr("`dt'", ":", "", .)
local dt = subinstr("`dt'", " ", "", .)
log using "02_cps_build_`dt'.log", replace
di c(current_date) " " c(current_time)

* --- Paths ---
* Enter your project path here
global root ""
global raw "$root/data/raw"
global crosswalks "$raw/crosswalks"
global processed "$root/data/processed"

cap mkdir "$processed"

*==============================================================================
* PART 1: IMPORT CROSSWALK FILES
*==============================================================================

* --- Occ 2010 -> Occ 2018 crosswalk (many-to-many, population weighted) ---
import delimited "$crosswalks/census_occ_2010_occ_2018_xwalk_cleaned_population_weighted.csv", clear varnames(1)
drop v1
rename xwalk_wt_fnl xwalk_wt
tempfile occ_xwalk
save `occ_xwalk'

* --- Felten ---
import delimited "$crosswalks/xposure_felten_measures_xwalk.csv", clear varnames(1)
drop v1
rename census_2018 occ
destring occ, replace force
drop if missing(occ)
foreach v in aioe_sim aioe_quint_sim aioe_admin aioe_quint_admin aioe_wgt aioe_quint_wgt {
    destring `v', replace force
}
tempfile felten
save `felten'

* --- GPTs are GPTs ---
import delimited "$crosswalks/xposure_gpts_r_gpts_measures_xwalk.csv", clear varnames(1)
drop v1
rename census_2018 occ
destring occ, replace force
drop if missing(occ)
foreach v in gpt4_beta_sim human_beta_sim gpt4_beta_quint_sim human_beta_quint_sim gpt4_beta_admin human_beta_admin gpt4_beta_quint_admin human_beta_quint_admin {
    destring `v', replace force
}
tempfile gpts
save `gpts'

* --- Eisfeldt ---
import delimited "$crosswalks/xposure_eisfeldt_measures_xwalk.csv", clear varnames(1)
drop v1
rename census_2018 occ
destring occ, replace force
drop if missing(occ)
foreach v in estz_total_sim estz_core_sim estz_supplemental_sim estz_total_quint_sim estz_core_quint_sim estz_supplemental_quint_sim estz_total_admin estz_core_admin estz_supplemental_admin estz_total_quint_admin estz_core_quint_admin estz_supplemental_quint_admin {
    destring `v', replace force
}
tempfile eisfeldt
save `eisfeldt'

* --- Webb ---
import delimited "$crosswalks/xposure_webb_xwalk.csv", clear varnames(1)
drop v1
destring pct_ai, replace force
destring pct_ai_quint, replace force
* Webb has multiple rows per occ1990 (via occ1990dd). Collapse to occ1990 level.
* Keep mean of pct_ai and modal quintile.
collapse (mean) pct_ai pct_ai_quint, by(occ1990)
replace pct_ai_quint = round(pct_ai_quint)
tempfile webb
save `webb'

*==============================================================================
* PART 2: LOAD CPS MONTHLY
*==============================================================================

local cps_files : dir "$raw/cps" files "*.dta"
local cps_file : word 1 of `cps_files'
assert "`cps_file'" != ""
di "Using CPS file: `cps_file'"
use "$raw/cps/`cps_file'", clear

*DROPPING A VARIABLE I USE BUT NATHAN DOESN'T AND HE CREATES BELOW
drop occ2010 

*THE SAMPLE THAT MATTERS TO ME
keep if age>=15 & age<=22


count
di "CPS monthly loaded: `r(N)' observations"

* Save original occ as occ_raw
rename occ occ_raw

*==============================================================================
* PART 3: CROSSWALK PRE-2020 OCC CODES (OCC2010 -> OCC2018)
*==============================================================================

* For year > 2019, occ is already occ2018. For year <= 2019, need crosswalk.
* The R code does probabilistic assignment: for each person with a m:m occ,
* randomly sample one occ2018 based on population weights.

* Step 3a: Merge crosswalk onto pre-2020 observations
* joinby expands rows: each person gets one row per possible occ2018 mapping
gen long _obsid = _n
preserve

keep if year <= 2019
rename occ_raw occ2010
joinby occ2010 using `occ_xwalk', unmatched(master)

* Step 3b: Probabilistic assignment — keep one occ2018 per person
* Draw uniform random and pick the occ2018 whose cumulative weight bracket contains it
set seed 123

* Compute cumulative weights within each original observation
bysort _obsid (occ2018): gen double cum_wt = sum(xwalk_wt)
bysort _obsid: gen double tot_wt = cum_wt[_N]
replace cum_wt = cum_wt / tot_wt

* Draw one uniform random per original observation
bysort _obsid: gen double _u = runiform() if _n == 1
bysort _obsid: replace _u = _u[1]

* Keep the first row where cumulative weight exceeds the draw
gen byte _keep = (cum_wt >= _u)
bysort _obsid: gen _first_keep = (_keep == 1 & sum(_keep) == 1)
keep if _first_keep == 1

* For unmatched (occ2010 not in crosswalk), occ2018 will be missing.
* These are NIU codes (0) — assign 0.
replace occ2018 = occ2010 if missing(occ2018)

rename occ2010 occ_raw
drop xwalk_wt cum_wt tot_wt _u _keep _first_keep

tempfile pre2020
save `pre2020'

restore

* Step 3c: Post-2020 observations — occ is already occ2018
keep if year > 2019
gen occ2018 = occ_raw

tempfile post2020
save `post2020'

* Step 3d: Combine
use `pre2020', clear
append using `post2020'

* Final occ variable for merging exposure measures
gen occ = occ2018

* Verify no observations were lost
count
di "After crosswalk: `r(N)' observations"

drop _obsid

*==============================================================================
* PART 4: SEPARATE NIU (OCC == 0) BEFORE MERGING EXPOSURE
*==============================================================================

preserve
keep if occ == 0
tempfile niu
save `niu'
restore

drop if occ == 0

*==============================================================================
* PART 5: MERGE AI EXPOSURE MEASURES
*==============================================================================

* --- Felten ---
merge m:1 occ using `felten', keep(master match) nogen

* --- GPTs are GPTs ---
merge m:1 occ using `gpts', keep(master match) nogen

* --- Eisfeldt ---
merge m:1 occ using `eisfeldt', keep(master match) nogen

* --- Webb (on occ1990) ---
merge m:1 occ1990 using `webb', keep(master match) nogen

*==============================================================================
* PART 6: APPEND NIU OBSERVATIONS BACK
*==============================================================================

append using `niu'

count
di "Final dataset: `r(N)' observations"

*==============================================================================
* PART 7: SAVE
*==============================================================================

compress
save "$processed/cps_monthly_xposure.dta", replace

di "Saved to $processed/cps_monthly_xposure.dta"

log close
