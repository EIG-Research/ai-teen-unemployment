* ══════════════════════════════════════════════════════════════════════════════
* USER CONFIGURATION
* Change ONLY this line to match your local repo location.
* Everything below references $root and does not need editing.
* ══════════════════════════════════════════════════════════════════════════════
global root ""

* Derived paths — built from $root, do not edit
global code      "$root/code"
global raw       "$root/data/raw"
global processed "$root/data/processed"
global output    "$root/output"
* ══════════════════════════════════════════════════════════════════════════════


* FIRST YOU HAVE TO RUN THE CPS BUILD FILE BUILT BY NATHAN AND SARAH
* I HAVE TWEAKED IT ONLY SLIGHTLY
do "$code/02_cps_build.do"


* ── RELATIVE UNEMPLOYMENT RATES ──────────────────────────────────────────────
use "$raw/cps/cps_00181.dta", clear

keep if (age >= 15 & age <= 18) | (age >= 22 & age <= 25 & educ >= 111)
keep if labforce == 2
g unemployed = inlist(empstat, 20, 21, 22)
g ym = ym(year, month)
format ym %tm
g agegroup = "1518" if age >= 15 & age <= 18
replace agegroup = "2225" if age >= 22 & age <= 25 & educ >= 111

collapse (mean) unemployed [fw = round(wtfinl,1)], by(ym year month agegroup)
reshape wide unemployed, i(ym year month) j(agegroup) string

tsset ym
tssmooth ma unemployed1518_ma12 = unemployed1518, window(11 1 0)
tssmooth ma unemployed2225_ma12 = unemployed2225, window(11 1 0)

preserve
keep if year >= 2015
keep ym year month unemployed1518_ma12 unemployed2225_ma12
export delimited using "$output/unemployment_rate_chart_data.csv", replace
restore

twoway (line unemployed1518_ma12 ym) ///
       (line unemployed2225_ma12 ym) if year >= 2015, ///
       legend(label(1 "Age 15 to 18") label(2 "College grads age 22 to 25")) ///
       title(Unemployment rate)


* ── RELATIVE EMPLOYMENT RATES ────────────────────────────────────────────────
use "$raw/cps/cps_00181.dta", clear

keep if age >= 15 & age <= 22
g employed = inlist(empstat, 10, 12)
g ym = ym(year, month)
format ym %tm
g agegroup = "1518" if age >= 15 & age <= 18
replace agegroup = "1922" if age >= 19 & age <= 22

collapse (mean) employed [fw = round(wtfinl,1)], by(ym year month agegroup)
reshape wide employed, i(ym year month) j(agegroup) string

tsset ym
tssmooth ma employed1518_ma12 = employed1518, window(11 1 0)
tssmooth ma employed1922_ma12 = employed1922, window(11 1 0)

* ── Index to January 2020 = 100 ──
foreach grp in 1518 1922 {

    quietly summarize employed`grp'_ma12 if year == 2020 & month == 1
    local base_`grp' = r(mean)

    if missing(`base_`grp'') {
        display as error "WARNING: January 2020 MA baseline not found for group `grp'"
    }

    g idx_`grp' = (employed`grp'_ma12 / `base_`grp'') * 100
    label variable idx_`grp' "Employment rate index, age `grp' (Jan 2020 MA = 100)"
}

preserve
keep if year >= 2015
keep ym year month employed1518_ma12 employed1922_ma12 idx_1518 idx_1922
rename employed1518_ma12 emprate_1518_ma12
rename employed1922_ma12 emprate_1922_ma12
rename idx_1518           emprate_1518_idx2020
rename idx_1922           emprate_1922_idx2020
export delimited using "$output/employment_rate_chart_data.csv", replace
restore

twoway (line employed1518_ma12 ym) ///
       (line employed1922_ma12 ym, yaxis(2)) if year >= 2015, ///
       legend(label(1 "Age 15 to 18") label(2 "Age 19 to 22")) ///
       title(Employment to Population Rates)


* ── GETTING MAJOR INDUSTRIES FOR TEENS ───────────────────────────────────────
import excel "$raw/ipums_cps_ind_2020_codes.xlsx", ///
    sheet("IND 2020 Codes") firstrow clear
rename IndustryCode ind
destring ind, replace
sort ind
save "$processed/ind_labels.dta", replace

use "$processed/cps_monthly_xposure.dta", clear
drop _merge
sort ind
merge m:1 ind using "$processed/ind_labels.dta"
g employed = inlist(empstat, 10, 12)


* ── AI exposure quintiles ──
tempfile combined
local i = 0

foreach var of varlist aioe_quint_wgt gpt4_beta_quint_admin estz_core_quint_admin {

    preserve

    keep if year >= 2022 & year <= 2024 & employed == 1 & age <= 18
    drop if missing(`var')

    g wt = round(wtfinl, 1)
    collapse (sum) weighted_n = wt, by(`var')

    egen total = sum(weighted_n)
    g share_`var' = weighted_n / total
    drop total

    rename `var' quintile
    keep quintile share_`var'

    local i = `i' + 1
    if `i' == 1 {
        save `combined', replace
    }
    else {
        merge 1:1 quintile using `combined', nogenerate
        save `combined', replace
    }

    restore
}

* ── Major sector ──
preserve
keep if year >= 2022 & year <= 2024 & employed & age <= 18
g wt = round(wtfinl, 1)
collapse (sum) weighted_n = wt (count) unweighted_n = wt, by(MajorSector)
egen total = sum(weighted_n)
g share = (weighted_n / total) * 100
drop total
gsort -share
export delimited using "$output/tab_MajorSector.csv", replace
restore

* ── Load, clean, and export AI exposure shares ──
use `combined', clear
rename share_aioe_quint_wgt        share_AIOE
rename share_gpt4_beta_quint_admin share_GPT4
rename share_estz_core_quint_admin share_ESTZ
sort quintile
export delimited using "$output/tab_ai_exposure_shares.csv", replace
