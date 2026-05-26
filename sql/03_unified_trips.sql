-- =====================================================================
-- 03_unified_trips.sql  —  One schema to rule all three trip types
-- =====================================================================
-- DESIGN DECISION (document in the deck): unified_trips is a VIEW, not a
-- materialized table. The view is the canonical column-mapping layer; the
-- FINAL analytical table (05) is what gets materialized and what the app hits.
-- Building the analytical table reads the external files exactly once, so a
-- view here costs nothing extra and keeps the mapping in one readable place.
-- If your grader insists on a physical unified table, change "VIEW" to
-- "TABLE" and "CREATE OR REPLACE VIEW" to "CREATE OR REPLACE TABLE".
--
-- COLUMN-MAPPING NOTES (also for the deck):
--  * Yellow uses tpep_* datetimes; Green uses lpep_*; FHV uses pickup_datetime
--    / dropOff_datetime (case-insensitive match -> dropoff_datetime).
--  * Green has its OWN `trip_type` column (1=Street-hail, 2=Dispatch). We do
--    NOT carry it through, because we reuse `trip_type` as the source
--    discriminator ('yellow'/'green'/'fhv'). The green meaning is dropped.
--  * FHV is sparse: NO fare/distance/passenger_count/payment/rate columns.
--    Those are set to NULL so the union lines up.
--  * Yellow has airport_fee; Green does not -> NULL for green.
--  * 2025 files add cbd_congestion_fee (congestion pricing, eff. 2025-01-05)
--    to yellow & green; FHV does not have it -> NULL.
--  * Datetimes are SAFE_CAST to TIMESTAMP for a uniform type. We treat the
--    stored value as NYC wall-clock and do NOT apply a timezone conversion,
--    so EXTRACT(HOUR ...) gives the local hour analysts expect.
--  * Everything is SAFE_CAST so per-file type drift (INT64 vs FLOAT64 in
--    different monthly parquets) and stray bad values won't fail the union.
-- =====================================================================

CREATE OR REPLACE VIEW `its-a-struggle.nyc_taxi.unified_trips` AS

-- ---- YELLOW ---------------------------------------------------------
SELECT
  'yellow'                                        AS trip_type,
  SAFE_CAST(VendorID            AS INT64)         AS vendor_id,
  SAFE_CAST(tpep_pickup_datetime  AS TIMESTAMP)   AS pickup_datetime,
  SAFE_CAST(tpep_dropoff_datetime AS TIMESTAMP)   AS dropoff_datetime,
  SAFE_CAST(passenger_count     AS INT64)         AS passenger_count,
  SAFE_CAST(trip_distance       AS FLOAT64)       AS trip_distance,
  SAFE_CAST(PULocationID        AS INT64)         AS pu_location_id,
  SAFE_CAST(DOLocationID        AS INT64)         AS do_location_id,
  SAFE_CAST(RatecodeID          AS INT64)         AS rate_code_id,
  SAFE_CAST(store_and_fwd_flag  AS STRING)        AS store_and_fwd_flag,
  SAFE_CAST(payment_type        AS INT64)         AS payment_type,
  SAFE_CAST(fare_amount         AS FLOAT64)       AS fare_amount,
  SAFE_CAST(extra               AS FLOAT64)       AS extra,
  SAFE_CAST(mta_tax             AS FLOAT64)       AS mta_tax,
  SAFE_CAST(tip_amount          AS FLOAT64)       AS tip_amount,
  SAFE_CAST(tolls_amount        AS FLOAT64)       AS tolls_amount,
  SAFE_CAST(improvement_surcharge AS FLOAT64)     AS improvement_surcharge,
  SAFE_CAST(total_amount        AS FLOAT64)       AS total_amount,
  SAFE_CAST(congestion_surcharge AS FLOAT64)      AS congestion_surcharge,
  SAFE_CAST(airport_fee         AS FLOAT64)       AS airport_fee,
  SAFE_CAST(cbd_congestion_fee  AS FLOAT64)       AS cbd_congestion_fee,
  CAST(NULL AS FLOAT64)                           AS ehail_fee,
  CAST(NULL AS INT64)                             AS sr_flag,
  CAST(NULL AS STRING)                            AS dispatching_base_num,
  CAST(NULL AS STRING)                            AS affiliated_base_number
FROM `its-a-struggle.nyc_taxi.ext_yellow`

UNION ALL

-- ---- GREEN ----------------------------------------------------------
SELECT
  'green'                                         AS trip_type,
  SAFE_CAST(VendorID            AS INT64)         AS vendor_id,
  SAFE_CAST(lpep_pickup_datetime  AS TIMESTAMP)   AS pickup_datetime,
  SAFE_CAST(lpep_dropoff_datetime AS TIMESTAMP)   AS dropoff_datetime,
  SAFE_CAST(passenger_count     AS INT64)         AS passenger_count,
  SAFE_CAST(trip_distance       AS FLOAT64)       AS trip_distance,
  SAFE_CAST(PULocationID        AS INT64)         AS pu_location_id,
  SAFE_CAST(DOLocationID        AS INT64)         AS do_location_id,
  SAFE_CAST(RatecodeID          AS INT64)         AS rate_code_id,
  SAFE_CAST(store_and_fwd_flag  AS STRING)        AS store_and_fwd_flag,
  SAFE_CAST(payment_type        AS INT64)         AS payment_type,
  SAFE_CAST(fare_amount         AS FLOAT64)       AS fare_amount,
  SAFE_CAST(extra               AS FLOAT64)       AS extra,
  SAFE_CAST(mta_tax             AS FLOAT64)       AS mta_tax,
  SAFE_CAST(tip_amount          AS FLOAT64)       AS tip_amount,
  SAFE_CAST(tolls_amount        AS FLOAT64)       AS tolls_amount,
  SAFE_CAST(improvement_surcharge AS FLOAT64)     AS improvement_surcharge,
  SAFE_CAST(total_amount        AS FLOAT64)       AS total_amount,
  SAFE_CAST(congestion_surcharge AS FLOAT64)      AS congestion_surcharge,
  CAST(NULL AS FLOAT64)                           AS airport_fee,
  SAFE_CAST(cbd_congestion_fee  AS FLOAT64)       AS cbd_congestion_fee,
  SAFE_CAST(ehail_fee           AS FLOAT64)       AS ehail_fee,
  CAST(NULL AS INT64)                             AS sr_flag,
  CAST(NULL AS STRING)                            AS dispatching_base_num,
  CAST(NULL AS STRING)                            AS affiliated_base_number
FROM `its-a-struggle.nyc_taxi.ext_green`

UNION ALL

-- ---- FHV (sparse) ---------------------------------------------------
-- If this branch errors on a missing column, the likely culprits are
-- SR_Flag or Affiliated_base_number — comment those two lines out (set NULL)
-- and re-run. pickup/dropoff/PULocationID/DOLocationID/dispatching_base_num
-- should always be present in 2025 FHV.
SELECT
  'fhv'                                           AS trip_type,
  CAST(NULL AS INT64)                             AS vendor_id,
  SAFE_CAST(pickup_datetime     AS TIMESTAMP)     AS pickup_datetime,
  SAFE_CAST(dropoff_datetime    AS TIMESTAMP)     AS dropoff_datetime,  -- matches dropOff_datetime
  CAST(NULL AS INT64)                             AS passenger_count,
  CAST(NULL AS FLOAT64)                           AS trip_distance,
  SAFE_CAST(PULocationID        AS INT64)         AS pu_location_id,     -- matches PUlocationID
  SAFE_CAST(DOLocationID        AS INT64)         AS do_location_id,     -- matches DOlocationID
  CAST(NULL AS INT64)                             AS rate_code_id,
  CAST(NULL AS STRING)                            AS store_and_fwd_flag,
  CAST(NULL AS INT64)                             AS payment_type,
  CAST(NULL AS FLOAT64)                           AS fare_amount,
  CAST(NULL AS FLOAT64)                           AS extra,
  CAST(NULL AS FLOAT64)                           AS mta_tax,
  CAST(NULL AS FLOAT64)                           AS tip_amount,
  CAST(NULL AS FLOAT64)                           AS tolls_amount,
  CAST(NULL AS FLOAT64)                           AS improvement_surcharge,
  CAST(NULL AS FLOAT64)                           AS total_amount,
  CAST(NULL AS FLOAT64)                           AS congestion_surcharge,
  CAST(NULL AS FLOAT64)                           AS airport_fee,
  CAST(NULL AS FLOAT64)                           AS cbd_congestion_fee,
  CAST(NULL AS FLOAT64)                           AS ehail_fee,
  SAFE_CAST(SR_Flag             AS INT64)         AS sr_flag,
  SAFE_CAST(dispatching_base_num AS STRING)       AS dispatching_base_num,
  SAFE_CAST(Affiliated_base_number AS STRING)     AS affiliated_base_number
FROM `its-a-struggle.nyc_taxi.ext_fhv`;
