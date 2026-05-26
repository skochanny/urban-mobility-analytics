-- =====================================================================
-- 07_analysis.sql  —  Every claim in the deck traces back to one of these
-- =====================================================================
-- All queries hit the materialized trips_analytics table (cheap, fast).
-- Grouped by the rubric's required analysis sections.
-- =====================================================================

-- =========================================================
-- A. VOLUME BY TRIP TYPE
-- =========================================================
-- A1: total volume + share by type
SELECT
  trip_type,
  COUNT(*) AS trips,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY trip_type
ORDER BY trips DESC;

-- =========================================================
-- B. TEMPORAL PATTERNS
-- =========================================================
-- B1: monthly volume by trip type
SELECT pickup_month, trip_type, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY pickup_month, trip_type
ORDER BY pickup_month, trip_type;

-- B2: daily volume (whole year) — feeds the anomaly hunt in section E
SELECT pickup_date, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY pickup_date
ORDER BY pickup_date;

-- B3: weekday vs weekend (per-day average so it's a fair comparison)
SELECT
  day_type,
  COUNT(*)                                  AS trips,
  COUNT(DISTINCT pickup_date)               AS num_days,
  ROUND(COUNT(*) / COUNT(DISTINCT pickup_date)) AS avg_trips_per_day
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY day_type;

-- B4: day-of-week demand
SELECT pickup_dayofweek, ANY_VALUE(pickup_dayname) AS dayname, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY pickup_dayofweek
ORDER BY pickup_dayofweek;

-- B5: hour-of-day demand curve (one of the four app questions)
SELECT pickup_hour, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY pickup_hour
ORDER BY pickup_hour;

-- B6: hour-of-day split weekday vs weekend (richer curve for the deck)
SELECT pickup_hour, day_type, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
GROUP BY pickup_hour, day_type
ORDER BY pickup_hour, day_type;

-- =========================================================
-- C. GEOGRAPHIC PATTERNS
-- =========================================================
-- C1: borough with the most pickups (one of the four app questions)
SELECT pickup_borough, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE pickup_borough IS NOT NULL
GROUP BY pickup_borough
ORDER BY trips DESC;

-- C2: top 10 busiest pickup zones (one of the four app questions)
SELECT pickup_zone, pickup_borough, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE pickup_zone IS NOT NULL
GROUP BY pickup_zone, pickup_borough
ORDER BY trips DESC
LIMIT 10;

-- C3: top 10 busiest dropoff zones
SELECT dropoff_zone, dropoff_borough, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE dropoff_zone IS NOT NULL
GROUP BY dropoff_zone, dropoff_borough
ORDER BY trips DESC
LIMIT 10;

-- C4: busiest borough pairs (pickup -> dropoff)
SELECT pickup_borough, dropoff_borough, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE pickup_borough IS NOT NULL AND dropoff_borough IS NOT NULL
GROUP BY pickup_borough, dropoff_borough
ORDER BY trips DESC
LIMIT 15;

-- C5: most common pickup->dropoff ZONE routes (one of the four app questions)
SELECT pickup_zone, dropoff_zone, COUNT(*) AS trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE pickup_zone IS NOT NULL AND dropoff_zone IS NOT NULL
GROUP BY pickup_zone, dropoff_zone
ORDER BY trips DESC
LIMIT 10;

-- =========================================================
-- D. TRIP BEHAVIOR  (yellow/green only — FHV has no fare/distance)
-- =========================================================
-- D1: distance / duration / fare summary by type
SELECT
  trip_type,
  ROUND(AVG(trip_distance), 2)      AS avg_distance_mi,
  ROUND(AVG(trip_duration_min), 1)  AS avg_duration_min,
  ROUND(AVG(fare_amount), 2)        AS avg_fare,
  ROUND(AVG(total_amount), 2)       AS avg_total,
  APPROX_QUANTILES(trip_distance, 100)[OFFSET(50)] AS median_distance_mi
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE trip_type IN ('yellow','green')
GROUP BY trip_type;

-- D2: tip behavior — CARD payments only (payment_type = 1), where tips exist
SELECT
  trip_type,
  ROUND(AVG(tip_amount), 2)        AS avg_tip,
  ROUND(100 * AVG(tip_rate), 2)    AS avg_tip_pct_of_fare,
  COUNTIF(tip_amount > 0)          AS trips_with_tip,
  COUNT(*)                         AS card_trips
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE trip_type IN ('yellow','green') AND payment_type = 1
GROUP BY trip_type;

-- D3: fare vs distance relationship (binned), for a scatter/line in the deck
SELECT
  CAST(FLOOR(trip_distance) AS INT64) AS distance_mi_bin,
  COUNT(*)                  AS trips,
  ROUND(AVG(fare_amount),2) AS avg_fare
FROM `its-a-struggle.nyc_taxi.trips_analytics`
WHERE trip_type IN ('yellow','green') AND trip_distance BETWEEN 0 AND 30
GROUP BY distance_mi_bin
ORDER BY distance_mi_bin;

-- =========================================================
-- E. ANOMALY INVESTIGATION  (pick the strongest one for the deck)
-- =========================================================
-- E1: day-over-day swings — flag the biggest jumps/drops (spikes & dead days)
WITH daily AS (
  SELECT pickup_date, COUNT(*) AS trips
  FROM `its-a-struggle.nyc_taxi.trips_analytics`
  GROUP BY pickup_date
)
SELECT
  pickup_date,
  trips,
  LAG(trips) OVER (ORDER BY pickup_date)                              AS prev_day_trips,
  ROUND(100 * SAFE_DIVIDE(trips - LAG(trips) OVER (ORDER BY pickup_date),
                          LAG(trips) OVER (ORDER BY pickup_date)), 1) AS pct_change
FROM daily
ORDER BY ABS(
  SAFE_DIVIDE(trips - LAG(trips) OVER (ORDER BY pickup_date),
              LAG(trips) OVER (ORDER BY pickup_date))
) DESC
LIMIT 20;

-- E2: candidate "dead zones" — zones with pickups but almost no dropoffs
--     (or vice versa); a geographic imbalance worth a hypothesis.
WITH pu AS (
  SELECT pu_location_id AS loc, COUNT(*) AS pickups
  FROM `its-a-struggle.nyc_taxi.trips_analytics` GROUP BY loc
),
do AS (
  SELECT do_location_id AS loc, COUNT(*) AS dropoffs
  FROM `its-a-struggle.nyc_taxi.trips_analytics` GROUP BY loc
)
SELECT
  z.Zone, z.Borough,
  IFNULL(pu.pickups, 0)   AS pickups,
  IFNULL(do.dropoffs, 0)  AS dropoffs,
  ROUND(SAFE_DIVIDE(IFNULL(do.dropoffs,0), IFNULL(pu.pickups,0)), 2) AS dropoff_to_pickup_ratio
FROM `its-a-struggle.nyc_taxi.ext_zones` z
LEFT JOIN pu ON z.LocationID = pu.loc
LEFT JOIN do ON z.LocationID = do.loc
WHERE IFNULL(pu.pickups,0) + IFNULL(do.dropoffs,0) > 0
ORDER BY dropoff_to_pickup_ratio DESC
LIMIT 25;

-- E3: hourly volume on the single biggest-anomaly day (fill date from E1)
-- SELECT pickup_hour, trip_type, COUNT(*) AS trips
-- FROM `its-a-struggle.nyc_taxi.trips_analytics`
-- WHERE pickup_date = DATE '2025-MM-DD'
-- GROUP BY pickup_hour, trip_type
-- ORDER BY pickup_hour, trip_type;
