-- =====================================================================
-- 02_inspect_schema.sql  —  VERIFY column names before building the union
-- =====================================================================
-- Run these and eyeball the output. The unified view in 03 assumes specific
-- column names. If any differ (beyond case), edit 03 accordingly. This step
-- costs almost nothing (INFORMATION_SCHEMA is metadata; LIMIT 5 reads 1 file).
-- =====================================================================

-- Column lists for each external table -------------------------------
SELECT 'yellow' AS src, column_name, data_type
FROM `its-a-struggle.nyc_taxi`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'ext_yellow'
ORDER BY ordinal_position;

SELECT 'green' AS src, column_name, data_type
FROM `its-a-struggle.nyc_taxi`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'ext_green'
ORDER BY ordinal_position;

SELECT 'fhv' AS src, column_name, data_type
FROM `its-a-struggle.nyc_taxi`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'ext_fhv'
ORDER BY ordinal_position;

SELECT 'zones' AS src, column_name, data_type
FROM `its-a-struggle.nyc_taxi`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'ext_zones'
ORDER BY ordinal_position;

-- Eyeball a few rows of each (reads a single underlying file) ---------
SELECT * FROM `its-a-struggle.nyc_taxi.ext_yellow` LIMIT 5;
SELECT * FROM `its-a-struggle.nyc_taxi.ext_green`  LIMIT 5;
SELECT * FROM `its-a-struggle.nyc_taxi.ext_fhv`    LIMIT 5;
SELECT * FROM `its-a-struggle.nyc_taxi.ext_zones`  LIMIT 5;
