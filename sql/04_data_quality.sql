-- =====================================================================
-- 04_data_quality.sql  —  Quantify the dirt BEFORE deciding what to drop
-- =====================================================================
-- These queries count problem rows by category so the filtering decisions in
-- 05 are defensible (and quotable in the deck). They scan the external files
-- via the view, so to keep cost down run them on ONE month first by
-- uncommenting the month filter, then once on the full year for the deck.
-- =====================================================================

-- Optional: restrict to a single month while iterating (uncomment).
-- Put `AND pickup_datetime >= '2025-01-01' AND pickup_datetime < '2025-02-01'`
-- into each WHERE below, or just trust the small LIMIT-free aggregates.

-- 1) Bad-row taxonomy across ALL trip types --------------------------
SELECT
  trip_type,
  COUNT(*)                                                         AS rows_total,
  COUNTIF(pu_location_id IS NULL OR do_location_id IS NULL)        AS null_location,
  COUNTIF(pickup_datetime IS NULL)                                 AS null_pickup_ts,
  COUNTIF(pickup_datetime <  TIMESTAMP('2025-01-01')
       OR pickup_datetime >= TIMESTAMP('2026-01-01'))              AS pickup_outside_2025,
  COUNTIF(dropoff_datetime IS NOT NULL
          AND dropoff_datetime < pickup_datetime)                  AS dropoff_before_pickup,
  COUNTIF(dropoff_datetime IS NOT NULL
          AND TIMESTAMP_DIFF(dropoff_datetime, pickup_datetime, MINUTE) > 1440)
                                                                   AS duration_over_24h
FROM `its-a-struggle.nyc_taxi.unified_trips`
GROUP BY trip_type
ORDER BY trip_type;

-- 2) Fare/distance problems — metered trips only (yellow/green) ------
SELECT
  trip_type,
  COUNT(*)                                  AS rows_total,
  COUNTIF(trip_distance <= 0)               AS distance_zero_or_neg,
  COUNTIF(trip_distance > 100)              AS distance_over_100mi,
  COUNTIF(fare_amount < 0)                  AS fare_negative,
  COUNTIF(total_amount <= 0)               AS total_zero_or_neg,
  COUNTIF(passenger_count = 0)             AS passenger_zero
FROM `its-a-struggle.nyc_taxi.unified_trips`
WHERE trip_type IN ('yellow','green')
GROUP BY trip_type
ORDER BY trip_type;

-- 3) How much of FHV would we lose if we required a dropoff timestamp? -
-- (Informs whether duration filters should be conditional on dropoff present.)
SELECT
  COUNT(*)                                  AS fhv_rows,
  COUNTIF(dropoff_datetime IS NULL)         AS fhv_null_dropoff,
  COUNTIF(do_location_id IS NULL)           AS fhv_null_dolocation
FROM `its-a-struggle.nyc_taxi.unified_trips`
WHERE trip_type = 'fhv';
