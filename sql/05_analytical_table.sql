-- =====================================================================
-- 05_analytical_table.sql  —  The materialized table the app queries
-- =====================================================================
-- Builds trips_analytics: unified trips + zone lookups (pickup & dropoff) +
-- derived time/behavior columns, with data-quality filters applied. This reads
-- the external parquet files ONCE and writes a physical table. Partitioned by
-- pickup_date and clustered by trip_type + pickup zone so the app's per-question
-- queries are cheap.
--
-- FILTERING DECISIONS (justify these in the deck):
--   DROP  - NULL or out-of-2025 pickup timestamp (all trip types)
--   DROP  - metered (yellow/green) rows with NULL pickup OR dropoff location id
--   KEEP  - FHV rows with NULL location ids. Regular FHV is largely
--           base-reported with no zone, so PU/DO location is NULL for a big
--           share of rows. Keeping them preserves FHV VOLUME and TEMPORAL
--           signal; they fall out of geographic queries on their own (the zone
--           join yields NULL borough/zone). Dropping them would erase most FHV.
--   DROP  - rows with a present dropoff that is zero/negative duration or
--           > 24h. FHV rows with a NULL dropoff are kept (duration stays NULL).
--   DROP  - metered trips with distance <= 0, negative fare, or non-positive
--           total   (FHV exempt: it has no fare/distance columns at all)
--   KEEP  - FHV rows with NULL fare/distance/passenger (volume & geography use)
--   KEEP  - passenger_count = 0 (too unreliable to use as a drop criterion)
-- tip_rate caveat: tips are only recorded for CARD payments, so cash trips show
--   tip_rate = 0. Restrict tip analysis to payment_type = 1 in the deck.
-- =====================================================================

CREATE OR REPLACE TABLE `its-a-struggle.nyc_taxi.trips_analytics`
PARTITION BY pickup_date
CLUSTER BY trip_type, pu_location_id
AS
WITH filtered AS (
  SELECT *
  FROM `its-a-struggle.nyc_taxi.unified_trips`
  WHERE
        pickup_datetime IS NOT NULL
    AND pickup_datetime >= TIMESTAMP('2025-01-01')
    AND pickup_datetime <  TIMESTAMP('2026-01-01')
    -- Location ids required for metered trips; FHV exempt (see notes above).
    AND (
          trip_type = 'fhv'
       OR (pu_location_id IS NOT NULL AND do_location_id IS NOT NULL)
        )
    -- Duration sanity only when a dropoff exists: strictly positive (drops the
    -- zero-second and negative glitch rows) and within 24h (86400s).
    AND (
          dropoff_datetime IS NULL
       OR (    TIMESTAMP_DIFF(dropoff_datetime, pickup_datetime, SECOND) > 0
           AND TIMESTAMP_DIFF(dropoff_datetime, pickup_datetime, SECOND) <= 86400)
        )
    -- Fare/distance sanity for metered trips only (FHV has neither).
    AND (
          trip_type = 'fhv'
       OR (trip_distance > 0 AND fare_amount >= 0 AND total_amount > 0)
        )
)
SELECT
  f.*,  -- carry every unified column through

  -- ---- pickup zone enrichment ----
  pu.Borough       AS pickup_borough,
  pu.Zone          AS pickup_zone,
  pu.service_zone  AS pickup_service_zone,

  -- ---- dropoff zone enrichment ----
  do.Borough       AS dropoff_borough,
  do.Zone          AS dropoff_zone,
  do.service_zone  AS dropoff_service_zone,

  -- ---- derived time columns ----
  DATE(f.pickup_datetime)                               AS pickup_date,
  EXTRACT(YEAR    FROM f.pickup_datetime)               AS pickup_year,
  EXTRACT(MONTH   FROM f.pickup_datetime)               AS pickup_month,
  EXTRACT(DAYOFWEEK FROM f.pickup_datetime)             AS pickup_dayofweek, -- 1=Sun .. 7=Sat
  FORMAT_TIMESTAMP('%A', f.pickup_datetime)             AS pickup_dayname,   -- e.g. 'Monday'
  EXTRACT(HOUR    FROM f.pickup_datetime)               AS pickup_hour,
  CASE
    WHEN EXTRACT(DAYOFWEEK FROM f.pickup_datetime) IN (1, 7) THEN 'weekend'
    ELSE 'weekday'
  END                                                   AS day_type,

  -- ---- derived behavior columns ----
  TIMESTAMP_DIFF(f.dropoff_datetime, f.pickup_datetime, SECOND) / 60.0
                                                        AS trip_duration_min,
  SAFE_DIVIDE(f.tip_amount, NULLIF(f.fare_amount, 0))   AS tip_rate
FROM filtered f
LEFT JOIN `its-a-struggle.nyc_taxi.ext_zones` pu
       ON f.pu_location_id = pu.LocationID
LEFT JOIN `its-a-struggle.nyc_taxi.ext_zones` do
       ON f.do_location_id = do.LocationID;
