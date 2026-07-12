-- =====================================================================
-- CarePulse - Clinical Encounter & 30-Day Patient Readmission Analytics
-- MySQL 8.0 script: schema, CSV load, analytical queries
-- Data: UCI Diabetes 130-US Hospitals (1999-2008)
-- =====================================================================

CREATE DATABASE IF NOT EXISTS carepulse_analytics;
USE carepulse_analytics;

DROP TABLE IF EXISTS fact_clinical_encounters;
DROP TABLE IF EXISTS dim_admission_types;
DROP TABLE IF EXISTS dim_patients;

CREATE TABLE dim_patients (
    patient_nbr  BIGINT       NOT NULL PRIMARY KEY,
    race         VARCHAR(30),
    gender       VARCHAR(20),
    age_band     VARCHAR(10)                      -- from the patient's first encounter
);

CREATE TABLE dim_admission_types (
    admission_type_id          TINYINT      NOT NULL PRIMARY KEY,
    admission_category         VARCHAR(15)  NOT NULL,   -- Emergency / Urgent / Elective / Newborn / Other
    admission_source_category  VARCHAR(40)              -- most common admission source for this type
);

CREATE TABLE fact_clinical_encounters (
    encounter_id          BIGINT       NOT NULL PRIMARY KEY,
    patient_nbr           BIGINT       NOT NULL,
    admission_type_id     TINYINT      NOT NULL,
    time_in_hospital      TINYINT,
    num_lab_procedures    SMALLINT,
    num_medications       SMALLINT,
    number_outpatient     SMALLINT,
    number_emergency      SMALLINT,
    number_inpatient      SMALLINT,
    diag_1_category       VARCHAR(20),
    a1c_result            VARCHAR(5),                 -- >8, >7, Norm, None
    readmitted_raw        VARCHAR(5),                 -- <30, >30, NO
    readmitted_30d_flag   TINYINT,
    readmitted_any_flag   TINYINT,
    predicted_risk_prob   DECIMAL(7,5),               -- out-of-fold logistic regression score
    risk_decile           TINYINT,                    -- 1 = lowest risk, 10 = highest
    CONSTRAINT fk_enc_patient FOREIGN KEY (patient_nbr) REFERENCES dim_patients (patient_nbr),
    CONSTRAINT fk_enc_adm     FOREIGN KEY (admission_type_id) REFERENCES dim_admission_types (admission_type_id),
    INDEX idx_enc_patient (patient_nbr),
    INDEX idx_enc_decile (risk_decile)
);

-- ---------------------------------------------------------------------
-- Load the CSVs (adjust the folder; needs local_infile enabled).
-- Alternatively run the notebook, which loads the tables with pandas.to_sql().
-- ---------------------------------------------------------------------
-- LOAD DATA LOCAL INFILE 'dim_patients.csv'              INTO TABLE dim_patients              FIELDS TERMINATED BY ',' IGNORE 1 LINES;
-- LOAD DATA LOCAL INFILE 'dim_admission_types.csv'       INTO TABLE dim_admission_types       FIELDS TERMINATED BY ',' IGNORE 1 LINES;
-- LOAD DATA LOCAL INFILE 'fact_clinical_encounters.csv'  INTO TABLE fact_clinical_encounters  FIELDS TERMINATED BY ',' IGNORE 1 LINES;

-- ---------------------------------------------------------------------
-- Analytical queries (30-day readmission = readmitted_30d_flag = 1)
-- ---------------------------------------------------------------------

-- 1. Row counts across the three tables
SELECT 'dim_patients' AS table_name, COUNT(*) AS row_count FROM dim_patients
UNION ALL SELECT 'dim_admission_types', COUNT(*) FROM dim_admission_types
UNION ALL SELECT 'fact_clinical_encounters', COUNT(*) FROM fact_clinical_encounters;


-- 2. Headline KPIs
SELECT COUNT(*)                                          AS encounters,
       SUM(readmitted_30d_flag)                          AS readmitted_30d,
       ROUND(100.0 * AVG(readmitted_30d_flag), 2)        AS readmission_30d_pct,
       ROUND(100.0 * AVG(readmitted_any_flag), 2)        AS readmission_any_pct,
       ROUND(AVG(time_in_hospital), 2)                   AS avg_length_of_stay_days
FROM fact_clinical_encounters;


-- 3. 30-day readmission by admission category (DENSE_RANK)
WITH by_category AS (
    SELECT a.admission_category,
           COUNT(*)                         AS encounters,
           SUM(f.readmitted_30d_flag)       AS readmitted_30d,
           AVG(f.readmitted_30d_flag)       AS rate_30d
    FROM fact_clinical_encounters f
    JOIN dim_admission_types a ON a.admission_type_id = f.admission_type_id
    GROUP BY a.admission_category
)
SELECT admission_category, encounters, readmitted_30d,
       ROUND(100 * rate_30d, 2) AS readmission_30d_pct,
       DENSE_RANK() OVER (ORDER BY rate_30d DESC) AS risk_rank
FROM by_category
ORDER BY risk_rank;


-- 4. 30-day readmission by age band, compared with the overall rate (AVG() OVER)
WITH by_age AS (
    SELECT p.age_band,
           COUNT(*)                   AS encounters,
           SUM(f.readmitted_30d_flag) AS readmitted_30d
    FROM fact_clinical_encounters f
    JOIN dim_patients p ON p.patient_nbr = f.patient_nbr
    GROUP BY p.age_band
)
SELECT age_band, encounters,
       ROUND(100.0 * readmitted_30d / encounters, 2) AS readmission_30d_pct,
       ROUND(100.0 * SUM(readmitted_30d) OVER () / SUM(encounters) OVER (), 2) AS overall_30d_pct,
       ROUND(100.0 * readmitted_30d / encounters
             - 100.0 * SUM(readmitted_30d) OVER () / SUM(encounters) OVER (), 2) AS gap_vs_overall_pts
FROM by_age
ORDER BY age_band;


-- 5. Primary ICD-9 diagnosis groups ranked by 30-day readmission rate (ROW_NUMBER)
WITH by_dx AS (
    SELECT diag_1_category,
           COUNT(*)                       AS encounters,
           AVG(readmitted_30d_flag)       AS rate_30d,
           AVG(time_in_hospital)          AS alos_days
    FROM fact_clinical_encounters
    GROUP BY diag_1_category
)
SELECT ROW_NUMBER() OVER (ORDER BY rate_30d DESC) AS rank_no,
       diag_1_category, encounters,
       ROUND(100 * rate_30d, 2) AS readmission_30d_pct,
       ROUND(alos_days, 2)      AS avg_los_days
FROM by_dx
ORDER BY rank_no;


-- 6. Prior inpatient visits vs 30-day readmission
SELECT CASE WHEN number_inpatient >= 3 THEN '3+'
            ELSE CAST(number_inpatient AS CHAR) END AS prior_inpatient_visits,
       COUNT(*)                                  AS encounters,
       ROUND(100.0 * AVG(readmitted_30d_flag), 2) AS readmission_30d_pct,
       ROUND(100.0 * AVG(readmitted_any_flag), 2) AS readmission_any_pct
FROM fact_clinical_encounters
GROUP BY CASE WHEN number_inpatient >= 3 THEN '3+'
              ELSE CAST(number_inpatient AS CHAR) END
ORDER BY prior_inpatient_visits;


-- 7. HbA1c status vs 30-day readmission
SELECT CASE a1c_result WHEN '>8'   THEN 'Elevated (>8)'
                       WHEN '>7'   THEN 'Elevated (>7)'
                       WHEN 'Norm' THEN 'Normal'
                       ELSE 'Not measured' END AS hba1c_status,
       COUNT(*)                                    AS encounters,
       ROUND(100.0 * AVG(readmitted_30d_flag), 2)  AS readmission_30d_pct
FROM fact_clinical_encounters
GROUP BY CASE a1c_result WHEN '>8'   THEN 'Elevated (>8)'
                         WHEN '>7'   THEN 'Elevated (>7)'
                         WHEN 'Norm' THEN 'Normal'
                         ELSE 'Not measured' END
ORDER BY readmission_30d_pct DESC;


-- 8. High-risk segment: 2+ prior inpatient visits and HbA1c >8
WITH baseline AS (
    SELECT AVG(readmitted_30d_flag) AS base_rate
    FROM fact_clinical_encounters
),
segment AS (
    SELECT COUNT(*) AS seg_encounters,
           AVG(readmitted_30d_flag) AS seg_rate
    FROM fact_clinical_encounters
    WHERE number_inpatient >= 2 AND a1c_result = '>8'
)
SELECT s.seg_encounters,
       ROUND(100 * s.seg_rate, 2)  AS segment_30d_pct,
       ROUND(100 * b.base_rate, 2) AS baseline_30d_pct,
       ROUND(s.seg_rate / b.base_rate, 2) AS relative_risk
FROM segment s CROSS JOIN baseline b;


-- 9. Model risk deciles: lift and cumulative capture of 30-day readmissions (SUM() OVER)
WITH deciles AS (
    SELECT risk_decile,
           COUNT(*)                   AS encounters,
           SUM(readmitted_30d_flag)   AS readmitted_30d,
           AVG(predicted_risk_prob)   AS avg_risk_prob
    FROM fact_clinical_encounters
    GROUP BY risk_decile
)
SELECT risk_decile, encounters, readmitted_30d,
       ROUND(100.0 * readmitted_30d / encounters, 2) AS actual_30d_pct,
       ROUND(100.0 * SUM(readmitted_30d) OVER (ORDER BY risk_decile DESC)
             / SUM(readmitted_30d) OVER (), 1)        AS cumulative_capture_pct
FROM deciles
ORDER BY risk_decile DESC;


-- 10. Top 20% risk cohort (deciles 9 and 10)
SELECT CASE WHEN risk_decile >= 9 THEN 'Top 20% risk cohort' ELSE 'Remaining 80%' END AS cohort,
       COUNT(*)                                     AS encounters,
       SUM(readmitted_30d_flag)                     AS readmitted_30d,
       ROUND(100.0 * AVG(readmitted_30d_flag), 2)   AS readmission_30d_pct,
       ROUND(100.0 * SUM(readmitted_30d_flag)
             / (SELECT SUM(readmitted_30d_flag) FROM fact_clinical_encounters), 1) AS share_of_all_30d_readmissions_pct
FROM fact_clinical_encounters
GROUP BY CASE WHEN risk_decile >= 9 THEN 'Top 20% risk cohort' ELSE 'Remaining 80%' END;


-- 11. Highest-risk diagnosis group within each age band (ROW_NUMBER with PARTITION BY)
WITH age_dx AS (
    SELECT p.age_band, f.diag_1_category,
           COUNT(*)                   AS encounters,
           AVG(f.readmitted_30d_flag) AS rate_30d
    FROM fact_clinical_encounters f
    JOIN dim_patients p ON p.patient_nbr = f.patient_nbr
    GROUP BY p.age_band, f.diag_1_category
    HAVING COUNT(*) >= 100
),
ranked AS (
    SELECT age_band, diag_1_category, encounters, rate_30d,
           ROW_NUMBER() OVER (PARTITION BY age_band ORDER BY rate_30d DESC) AS rn
    FROM age_dx
)
SELECT age_band, diag_1_category, encounters, ROUND(100 * rate_30d, 2) AS readmission_30d_pct
FROM ranked
WHERE rn = 1
ORDER BY age_band;


-- 12. Readmission by patient's number of encounters in the data (first encounter flagged with ROW_NUMBER)
WITH numbered AS (
    SELECT patient_nbr, encounter_id, readmitted_30d_flag,
           ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY encounter_id) AS encounter_seq
    FROM fact_clinical_encounters
)
SELECT CASE WHEN encounter_seq >= 4 THEN '4th or later' ELSE CAST(encounter_seq AS CHAR) END AS encounter_order,
       COUNT(*) AS encounters,
       ROUND(100.0 * AVG(readmitted_30d_flag), 2) AS readmission_30d_pct
FROM numbered
GROUP BY CASE WHEN encounter_seq >= 4 THEN '4th or later' ELSE CAST(encounter_seq AS CHAR) END
ORDER BY encounter_order;
