-- =====================================================================
-- 00_setup.sql  —  Create the dataset that holds everything
-- Project : its-a-struggle
-- Dataset : nyc_taxi
-- =====================================================================
-- IMPORTANT (location): External tables can only be queried from a dataset
-- whose location matches the GCS bucket's location. The course bucket
-- gs://msca-bdp-data-open is in the US multi-region, so this dataset MUST be
-- 'US'. If you ever see "Not found: Dataset ... in location ..." or a
-- cross-region error, that's almost always this.
--
-- Run order for the whole pipeline:
--   00_setup -> 01_external_tables -> 02_inspect_schema (verify!) ->
--   03_unified_trips -> 04_data_quality (explore) -> 05_analytical_table ->
--   06_dq_report -> 07_analysis
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS `its-a-struggle.nyc_taxi`
OPTIONS (location = 'US');
