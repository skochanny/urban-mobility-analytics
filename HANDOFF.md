# HANDOFF — BDP Final Project: Urban Mobility Analytics (BigQuery + Gemini)

> Living doc. Update the **Status** and **Open items** sections as work lands.
> Last updated: initial build (SQL pipeline + Streamlit/Gemini app scaffolded).

## 1. Context (don't re-derive this)
- **Course:** Big Data and Computing — final project.
- **Cloud:** Google Cloud Platform.
- **GCP project:** `its-a-struggle`
- **GCS bucket (user's):** `struggle-bucket-33333333` (not strictly needed; data lives in the course bucket below)
- **Source data:** `gs://msca-bdp-data-open/final_project_taxi/` — yellow/green/fhv monthly Parquet + `taxi_zone_lookup.csv`, calendar year **2025**. **Do not download**; register as external tables.
- **BigQuery dataset:** `nyc_taxi` (US multi-region — must match the bucket).
- **Final table the app queries:** `its-a-struggle.nyc_taxi.trips_analytics` (materialized, partitioned by `pickup_date`, clustered by `trip_type, pu_location_id`).
- Sara has been working in BigQuery via a Jupyter notebook instance; the SQL files here are meant to be run top-to-bottom (in the BQ console, `bq query`, or the notebook).

## 2. Deliverables (per the spec PDF)
1. **Zip** containing `sql/`, `app/` (app.py, requirements.txt, Dockerfile, deploy script), `app_url.txt`.
2. **PowerPoint** (.pptx), 10–15 slides — **separate file, built later.**

## 3. What exists now
```
final_project/
├── sql/
│   ├── 00_setup.sql            create dataset (US)
│   ├── 01_external_tables.sql  4 external tables (VERIFY file names first!)
│   ├── 02_inspect_schema.sql   verify actual columns before building union
│   ├── 03_unified_trips.sql    VIEW unifying yellow/green/fhv -> one schema
│   ├── 04_data_quality.sql     bad-row taxonomy (run to justify filters)
│   ├── 05_analytical_table.sql materialized trips_analytics + joins + derived cols
│   ├── 06_dq_report.sql        row/NULL counts on final table (for the deck)
│   └── 07_analysis.sql         every required analysis query, grouped by rubric
├── app/
│   ├── app.py                  Streamlit + Gemini(Vertex) NL->SQL
│   ├── requirements.txt
│   ├── Dockerfile
│   └── deploy.sh               APIs + service account + Cloud Run deploy
├── app_url.txt                 placeholder — fill after deploy
└── HANDOFF.md                  this file
```

## 4. Key design decisions (defend these in the deck)
- **External → unified VIEW → materialized analytical TABLE.** The unified layer is a *view* (free, single readable mapping); only the final table is materialized, per the spec's "must be a table, not a view." Building the table scans the external files exactly once.
- **FHV is kept for volume/geography, excluded from fare/tip/distance.** FHV has no fare/distance/passenger/payment columns → set to NULL in the union. Behavior queries filter `trip_type IN ('yellow','green')`.
- **Filtering (in 05):** drop NULL locations; drop NULL/out-of-2025 pickups; drop trips with a present-but-invalid dropoff (before pickup, or > 24h); drop metered trips with distance ≤ 0 / negative fare / non-positive total. **Keep** FHV rows with NULL dropoff (legit). Keep `passenger_count = 0` (flag, don't cut).
- **Timezone:** TLC timestamps are treated as NYC wall-clock; no tz conversion, so `pickup_hour` is the local hour analysts expect.
- **2025 specifics confirmed:** files include a new `cbd_congestion_fee` column (congestion pricing eff. 2025-01-05) on yellow/green; BigQuery column refs are case-insensitive so FHV casing quirks (PUlocationID/dropOff_datetime) resolve automatically.
- **App security:** SQL validated (SELECT/WITH only, single statement, no DDL/DML); auth via Cloud Run **service account** (ADC) only — no keys/secrets; `maximum_bytes_billed` cap as a cost guard.
- **SDK:** uses `google-genai` with `vertexai=True` (the old `vertexai.generative_models` is deprecated, removal June 2026). Model default `gemini-2.5-flash`.

## 5. How to run (order matters)
**SQL (in BigQuery):**
1. `gcloud storage ls gs://msca-bdp-data-open/final_project_taxi/` → confirm file names, fix URIs in `01` if needed.
2. Run `00` → `01` → `02`. **Read 02's output** and adjust `03` if any column is genuinely missing (not just different case).
3. Run `03` (view) → `04` (explore on one month first to save cost) → `05` (materialize) → `06` (DQ report) → `07` (analysis; copy results into the deck).

**App (deploy):**
1. `cd app && chmod +x deploy.sh && ./deploy.sh`
2. Paste the printed URL into `app_url.txt` and confirm it's live.
3. Demo the four required questions (below).

## 6. The four required app questions (must answer correctly)
1. Which borough has the highest number of trips?
2. What are the top 10 busiest pickup zones?
3. How does trip volume change by hour of day?
4. What are the most common pickup-to-dropoff routes?

## 7. Open items / TODO
- [x] **Verify bucket file naming** — CONFIRMED: files are in `yellow/`, `green/`, `fhv/` subfolders as `<type>_tripdata_2025-01..12.parquet`; CSV at root. URIs in `01` updated.
- [ ] **Run 02 and confirm FHV columns** (esp. `SR_Flag`, `Affiliated_base_number`, `DOLocationID`, `dropOff_datetime`). Drop missing ones to NULL in `03` if creation errors.
- [ ] Run the full pipeline; capture row/NULL counts (06) and analysis outputs (07).
- [ ] Pick the strongest anomaly from `07` section E and write a hypothesis.
- [ ] Deploy app, fill `app_url.txt`, test the 4 questions + a couple that *should* fail validation (e.g. "delete all trips") for the security demo.
- [ ] **Collect 2 concrete Gemini failure cases** (bad/empty/subtly-wrong SQL) for the AI-agent evaluation slide — capture the actual generated SQL.
- [ ] Build the **.pptx** (10–15 slides): methodology, column-mapping, DQ decisions+counts, the 4 analysis sections, anomaly, app demo screenshots, honest Gemini critique, recommendations.
- [ ] Zip `sql/ + app/ + app_url.txt`; submit pptx separately.

## 8. Suggested conversation checkpoints (per Sara's working style)
This is a multi-phase project; start a fresh chat at each phase boundary and bring this file forward:
- **Phase 1 (done here): design + write code.**
- **Phase 2: pipeline execution / schema debugging** — once you're running SQL against real files and adjusting column names. Carry forward: section 4 (decisions), section 7 (open items), and any actual column lists from step 02.
- **Phase 3: Cloud Run deployment + app debugging.** Carry forward: the app/ design notes and the four required questions.
- **Phase 4: presentation build.** Carry forward: the analysis outputs and the Gemini failure cases.
