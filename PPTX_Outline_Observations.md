# PPTX Outline & Observations — Urban Mobility Analytics

Running notes for the 10–15 slide deck, organized as a slide skeleton. Each
finding tags the SQL that backs it (rubric: *every claim must be backed by a
query result*). **[confirmed]** = from real query output; **[PENDING]** = awaits
a run. Update as `06`, `07`, and the app deployment land.

Scope: full-year 2025 — NYC Yellow / Green / FHV. Project `its-a-struggle`,
dataset `nyc_taxi`, final table `trips_analytics`.

---

## Slide 1 — Executive summary (write last)
- End-to-end BigQuery pipeline + deployed Gemini NL→SQL app over **74.4M raw 2025 trips**; what the data says, and where LLM-generated SQL can / can't be trusted.
- Drop in headline numbers once `06`/`07` are final.

## Slide 2 — Methodology / pipeline architecture
- Layered: **external tables** (Parquet/CSV in GCS, queried in place — no data downloaded) → **`unified_trips` VIEW** (one schema, `trip_type` discriminator) → **`trips_analytics` materialized TABLE** (filtered, zone-joined, derived columns). [sql 00–05]
- Final table partitioned by `pickup_date`, clustered by `trip_type, pu_location_id` → the app never pays for a multi-table join per question.
- Cost discipline: external tables re-scan files on every query, so exploration ran against the view; the full-year scan was paid once to materialize the table.

## Slide 3 — Column mapping / unification decisions [02, 03]
- Datetimes unified: yellow `tpep_*`, green `lpep_*`, FHV `pickup_datetime`/`dropOff_datetime` → `pickup_datetime`/`dropoff_datetime`.
- Green's **own** `trip_type` column (1=street-hail, 2=dispatch) was **dropped** to avoid clashing with our source discriminator.
- Source-specific fields kept as NULL where absent: `airport_fee` (yellow only), `ehail_fee` (green only), `cbd_congestion_fee` (yellow/green only — new 2025 congestion-pricing field, effective Jan 5 2025), and `sr_flag` / `dispatching_base_num` / `affiliated_base_number` (FHV only).
- BigQuery column references are **case-insensitive**, so FHV's `PUlocationID`/`DOlocationID`/`dropOff_datetime` and yellow's `Airport_fee` resolved with no edits.
- Timestamps are true `TIMESTAMP` holding NYC wall-clock; **no timezone conversion** applied, so `pickup_hour` is the local hour analysts expect.

## Slide 4 — Data quality: decisions + counts

Pre-filter raw counts (unified view) **[confirmed, sql 04]**:

| trip_type | raw rows | share |
|---|---:|---:|
| yellow | 48,722,602 | 65.5% |
| fhv | 25,047,544 | 33.7% |
| green | 591,375 | 0.8% |
| **total** | **74,361,521** | |

Problems quantified **[confirmed, sql 04]**:
- **FHV null PU/DO location: 20,591,758 (82.2% of FHV).** Only ~4,455,786 FHV rows (17.8%) have *both* locations (DO-null = 4,207,921; PU-null is the dominant driver). FHV dropoff timestamp is never null (0).
- Yellow: negative fare 2,848,620 (5.85%); zero/neg distance 1,402,958 (2.88%); non-positive total 980,522 (2.01%); passenger=0 260,062 (0.53%); distance >100mi 2,870.
- Green: zero/neg distance 24,438 (4.13%); negative fare 1,736 (0.29%); non-positive total 2,706; passenger=0 8,255; distance >100mi 209.
- Noise-level: pickup outside 2025 (29 yellow, 21 green, 0 fhv); dropoff-before-pickup (2,235 yellow, 1,344 green, 292 fhv); duration >24h (351 yellow, 2 green, 11,447 fhv).

Filtering decisions:
- **DROP** — null/out-of-2025 pickup; metered (yellow/green) null locations; present-but-invalid duration (zero/negative or >24h); metered distance ≤ 0 / negative fare / non-positive total.
- **KEEP** — FHV rows with null locations (preserves volume + temporal signal; they self-exclude from geographic queries since their zone join is NULL); FHV null fare/distance/passenger; `passenger_count = 0` (too unreliable to use as a drop rule).
- Net effect: ~6% of yellow removed (mostly negative-fare voids/adjustments); FHV essentially fully retained for volume. Post-filter counts **[PENDING sql 06]**, expected ≈ 70.6M total (≈ 45M yellow, ~25M fhv, ~0.56M green).
- `tip_rate` caveat: tips recorded for **card only** (`payment_type = 1`); cash shows 0 — restrict tip analysis accordingly.

## Slide 5 — Volume by trip type [04 Q1 → 06 Q1]
- Yellow dominates (~66%), FHV ~34%, **green < 1% and nearly vestigial** — a story about the decline of street-hail green cabs.
- Use post-filter numbers from `06` for the final figure.

## Slide 6 — Temporal patterns [PENDING sql 07 B]
- Monthly trend by type; daily series; weekday vs weekend (per-day average for a fair comparison); day-of-week; **hour-of-day demand curve** (also app demo Q3); weekday-vs-weekend hourly split.
- Watch for: any congestion-pricing-era shift across the 2025 months.

## Slide 7 — Geographic patterns [PENDING sql 07 C]
- **Borough with most pickups** (app demo Q1); **top 10 pickup zones** (app Q2); top dropoff zones; busiest borough pairs; **top pickup→dropoff routes** (app Q4).
- **State up front:** FHV contributes to geography at only ~18% of its volume (locations missing for 82%), so geographic views are yellow/green-dominated. This is a documented limitation, not a bug.

## Slide 8 — Trip behavior [PENDING sql 07 D]
- Distance / duration / fare summaries by type (yellow vs green; FHV excluded — no fare/distance columns).
- Tip behavior on card trips; tip % of fare; fare-vs-distance relationship (binned).

## Slide 9 — Anomaly investigation [PENDING sql 07 E]
- Candidate 1: biggest day-over-day volume swings (holidays, storms, events).
- Candidate 2: "dead zone" geographic imbalance — zones with pickups but ~no dropoffs (or vice versa).
- Pick one, show the query result, give a concrete hypothesis.

## Slides 10–11 — Streamlit + Gemini app [PENDING deploy]
- Architecture: text question → Gemini (Vertex AI, `google-genai` SDK) generates BigQuery SQL grounded in the schema (with NULL-by-`trip_type` notes) → validate → execute → display SQL + table + chart.
- Demo the four required questions (Q1–Q4 above).
- Security: SELECT/WITH-only validation, DDL/DML rejection with the reason shown, markdown-fence stripping, **service-account auth (no API keys/secrets)**, `maximum_bytes_billed` cap.

## Slide 12 — AI-agent evaluation [PENDING testing]
- Where Gemini worked well vs failed.
- **Need ≥ 2 concrete failure cases** with the actual bad SQL it generated — capture these during app testing.
- What schema/prompt/guardrail choices improved accuracy. Biggest lever: the NULL-by-`trip_type` schema notes — without them the model writes queries that look right and return nothing (e.g. asking FHV for fares).
- For which business users / question classes this is appropriate, and where you would *not* deploy it.

## Slide 13 — Recommendations / conclusions [PENDING]
- Tie findings to action; state the honest scope of the NL→SQL tool.

---

## Cross-cutting caveats to weave through the deck
- **FHV**: huge by volume, sparse by geography (82% null locations); no fare/distance/passenger at all.
- **Yellow voids/adjustments**: ~6% negative fare, ~3% zero distance — dropped as data-quality, not real completed trips.
- **Green sample is small** (591k/yr) — avoid over-strong per-zone conclusions for green alone.
- **`tip_rate`** only meaningful for card payments.
