# Urban Mobility Analytics — BigQuery + Gemini

End-to-end analytical pipeline on Google Cloud over NYC's 2025 Yellow Taxi,
Green Taxi, and For-Hire Vehicle (FHV) trip records, plus a deployed Streamlit
app that answers plain-English questions by generating BigQuery SQL with Gemini.

## Structure
```
sql/   BigQuery pipeline, runnable top-to-bottom (00 -> 07)
app/   Streamlit + Gemini (Vertex AI) app: app.py, requirements.txt, Dockerfile, deploy.sh
```
`HANDOFF.md` has the full run order, design decisions, and data-quality notes.

## Pipeline (run in order)
`00_setup` -> `01_external_tables` -> `02_inspect_schema` -> `03_unified_trips`
-> `04_data_quality` -> `05_analytical_table` -> `06_dq_report` -> `07_analysis`

External tables sit over Parquet/CSV in GCS; a unified view maps all three trip
types to one schema; the materialized `trips_analytics` table (what the app
queries) adds zone joins and derived time/behavior columns.

## App
Natural-language question -> Gemini-generated BigQuery SQL -> validated
(SELECT-only, no DDL/DML) -> executed -> shown as SQL + table + chart.
Auth is via the Cloud Run service account (no API keys or secrets in code).
Deploy with `app/deploy.sh`.

## Data
NYC TLC 2025 trip records (`gs://msca-bdp-data-open/final_project_taxi/`),
registered as BigQuery external tables — not stored in this repo.
