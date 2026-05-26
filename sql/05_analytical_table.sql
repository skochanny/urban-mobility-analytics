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
--   DROP  - rows with NULL pickup OR dropoff location id
--   DROP  - rows with NULL or out-of-2025 pickup timestamp
--   DROP  - rows where a dropoff IS present but is before pickup or implies
--           a > 24h (1440 min) trip   (kept if dropoff is simply absent, which
--           is common & legitimate for FHV)
--   DROP  - metered (yellow/green) trips with distance <= 0, negative fare,
--           or non-positive total   (FHV exempt: it has no fare/distance)
--   KEEP  - FHV rows with NULL fare/distance/passenger (used for volume &
--           geography only, by design)
--   KEEP  - passenger_count = 0 (not reliable enough to drop; flagged, not cut)
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
        pu_location_id IS NOT NULL
    AND do_location_id IS NOT NULL
    AND pickup_datetime IS NOT NULL
    AND pickup_datetime >= TIMESTAMP('2025-01-01')
    AND pickup_datetime <  TIMESTAMP('2026-01-01')
    AND (
          dropoff_datetime IS NULL
       OR (    dropoff_datetime >= pickup_datetime
           AND TIMESTAMP_DIFF(dropoff_datetime, pickup_datetime, MINUTE) <= 1440)
        )
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
