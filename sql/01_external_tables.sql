-- =====================================================================
-- 01_external_tables.sql  —  Register raw GCS files as BigQuery external tables
-- =====================================================================
-- We DO NOT download the data. We register it in place and query it.
--
-- File layout CONFIRMED: files live in per-type subfolders, e.g.
--   gs://.../final_project_taxi/yellow/yellow_tripdata_2025-01..12.parquet
--   (same pattern for green/ and fhv/); taxi_zone_lookup.csv is at the root.
-- The wildcards below match all 12 monthly files in each subfolder.
--
-- COST WARNING: every query against an external table re-scans the underlying
-- files in GCS. Do your exploration on ONE month first (see 04), and only
-- materialize the full year once (see 05). Never point the Streamlit app at
-- these external tables — it queries the materialized trips_analytics table.
--
-- NOTE on column names: BigQuery column references are CASE-INSENSITIVE, so the
-- historical FHV casing quirks (PUlocationID vs PULocationID, dropOff_datetime
-- vs dropoff_datetime) resolve fine. The only thing that breaks is a column
-- that is genuinely absent — that's what step 02 is for.
-- =====================================================================

-- ---- Yellow Taxi ----------------------------------------------------
CREATE OR REPLACE EXTERNAL TABLE `its-a-struggle.nyc_taxi.ext_yellow`
OPTIONS (
  format = 'PARQUET',
  uris = ['gs://msca-bdp-data-open/final_project_taxi/yellow/yellow_tripdata_2025-*.parquet']
);

-- ---- Green Taxi -----------------------------------------------------
CREATE OR REPLACE EXTERNAL TABLE `its-a-struggle.nyc_taxi.ext_green`
OPTIONS (
  format = 'PARQUET',
  uris = ['gs://msca-bdp-data-open/final_project_taxi/green/green_tripdata_2025-*.parquet']
);

-- ---- For-Hire Vehicles (sparse schema) ------------------------------
CREATE OR REPLACE EXTERNAL TABLE `its-a-struggle.nyc_taxi.ext_fhv`
OPTIONS (
  format = 'PARQUET',
  uris = ['gs://msca-bdp-data-open/final_project_taxi/fhv/fhv_tripdata_2025-*.parquet']
);

-- ---- Taxi Zone Lookup (CSV) -----------------------------------------
-- Schema is given explicitly because CSV external tables don't autodetect
-- reliably from DDL. Columns per the TLC taxi_zone_lookup.csv header:
--   LocationID, Borough, Zone, service_zone
CREATE OR REPLACE EXTERNAL TABLE `its-a-struggle.nyc_taxi.ext_zones` (
  LocationID  INT64,
  Borough     STRING,
  Zone        STRING,
  service_zone STRING
)
OPTIONS (
  format = 'CSV',
  uris = ['gs://msca-bdp-data-open/final_project_taxi/taxi_zone_lookup.csv'],
  skip_leading_rows = 1
);
