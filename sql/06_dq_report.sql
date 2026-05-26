-- =====================================================================
-- 06_dq_report.sql  —  Post-build verification (row & NULL counts)
-- =====================================================================
-- Run AFTER 05. Numbers here go straight into the "Data Quality" slide.
-- All queries hit the materialized table, so they are cheap.
-- =====================================================================

-- 1) Row counts by trip type + share --------------------------------
SELECT
  trip_type,
  COUNT(*)                                              AS num_rows,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)      AS pct_of_total
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY trip_type
ORDER BY num_rows DESC;

-- 2) Date coverage sanity (should be fully inside 2025) -------------
SELECT
  MIN(pickup_date) AS min_pickup_date,
  MAX(pickup_date) AS max_pickup_date,
  COUNT(DISTINCT pickup_month) AS distinct_months
FROM `its-a-struggle.nyc_taxi.trips_analytics`;

-- 3) NULL counts on key columns -------------------------------------
SELECT
  COUNT(*)                                       AS rows_total,
  COUNTIF(pickup_borough  IS NULL)               AS null_pickup_borough,
  COUNTIF(dropoff_borough IS NULL)               AS null_dropoff_borough,
  COUNTIF(trip_distance   IS NULL)               AS null_distance,   -- expect ~ all FHV
  COUNTIF(fare_amount     IS NULL)               AS null_fare,       -- expect ~ all FHV
  COUNTIF(dropoff_datetime IS NULL)              AS null_dropoff_ts,
  COUNTIF(tip_rate        IS NULL)               AS null_tip_rate
FROM `its-a-struggle.nyc_taxi.trips_analytics`;

-- 4) NULL distance/fare broken out by trip type (proves FHV is the source) -
SELECT
  trip_type,
  COUNTIF(trip_distance IS NULL) AS null_distance,
  COUNTIF(fare_amount   IS NULL) AS null_fare
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY trip_type
ORDER BY trip_type;
