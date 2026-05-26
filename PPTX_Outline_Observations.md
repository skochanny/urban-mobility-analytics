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
- Net effect — **post-filter final table [confirmed, sql 06]: 69,778,110 rows.**

| trip_type | final rows | share |
|---|---:|---:|
| yellow | 44,178,686 | 63.3% |
| fhv | 25,035,748 | 35.9% |
| green | 563,676 | 0.8% |
| **total** | **69,778,110** | |

- Rows dropped vs raw: yellow 4,543,916 (9.3%, mostly negative-fare voids/adjustments), green 27,699 (4.7%), FHV 11,796 (0.05%) — **6.2% overall.** FHV essentially fully retained, confirming the location-exemption decision.
- Date coverage clean: 2025-01-01 → 2025-12-31, all 12 months present. [06 Q2]
- Final-table NULL pattern [06 Q3/Q4]: `null_distance` = `null_fare` = 25,035,748 = **exactly all FHV** (yellow/green 0 nulls); `null_pickup_borough` 20,566,941 and `null_dropoff_borough` 4,204,507 = FHV rows with missing PU/DO locations; `null_dropoff_ts` = 0; `null_tip_rate` 25,045,429 = all FHV + ~9,681 zero-fare metered trips.
- `tip_rate` caveat: tips recorded for **card only** (`payment_type = 1`); cash shows 0 — restrict tip analysis accordingly.

## Slide 5 — Volume by trip type [confirmed, sql 06]
- **Post-filter shares: yellow 63.3%, FHV 35.9%, green 0.81%** (of 69,778,110 trips).
- Yellow dominates; FHV is over a third of all trips; **green < 1% and nearly vestigial** — a story about the decline of street-hail green cabs.
- FHV's share *rose* after filtering (33.7% → 35.9%) because yellow shed proportionally more rows to data-quality drops — worth a one-line mention.

## Slide 6 — Temporal patterns [confirmed, sql 07 B]
- **Monthly:** yellow ranges 3.18M (Aug, low) → 4.09M (May, high) with a clear **summer slump (Jul–Aug)** and a December bump; FHV is flatter and peaks in **fall (Oct, 2.45M)** with *no* August dip; green flat at ~44–52k/mo. → Yellow and FHV have **opposite seasonality**. (Caveat: FHV April reads oddly low at 1.70M — possible incomplete file, not real demand.)
- **Weekday vs weekend:** weekday avg 197,694 trips/day vs weekend 174,806/day (~13% busier on weekdays — commute-driven). [B3]
- **Day of week:** midweek peak (Wed 10.85M, Thu 10.82M), Sunday lowest (8.48M). [B4]
- **Hour of day** (app demo Q3): trough at 3–4am (~620k), broad **midday/afternoon plateau 12:00–18:00 (~4.0–4.24M, single peak at 2pm)**, tapering overnight. [B5]
- **Weekday vs weekend hourly** (the textbook contrast): weekdays show a sharp **7–9am commute peak**; weekends flatten the morning and instead **spike at 1–3am** (nightlife). [B6]

## Slide 7 — Geographic patterns [confirmed, sql 07 C + E2]
- **Borough with most pickups** (app demo Q1): **Manhattan 39.4M** dominates, then Queens 5.3M (airports), Brooklyn 2.9M, Bronx 0.92M, Staten Island 0.57M. [C1]
- **Top pickup zones** (app Q2): Upper East Side South, Midtown Center, **JFK Airport**, UES North, Penn Station, Midtown East, Times Sq, Lincoln Square, **LaGuardia**, Murray Hill — all Manhattan + the two airports. [C2]
- **Busiest borough pair:** Manhattan→Manhattan = **36.4M (~82% of all borough-pair trips)**; then Queens→Manhattan (airport runs). [C4]
- **Top zone routes** (app Q4): short intra-Manhattan hops — UES South↔UES North (~291k / 248k), Midtown↔UES. [C5]
- **Geographic imbalance (anomaly E2):** dropoff/pickup ratio is huge in (a) **Newark Airport (12.6×) and "Outside NYC" (15.3×)** — drop-off-only zones cabs can't pick up in; (b) **parks & cemeteries** (Highbridge Park 17.9×, Crotona Park, Green-Wood) — destinations, not origins; (c) **Bronx neighborhoods** broadly — yellow drops people there but rarely gets hailed there, and the FHV rides that would balance it are invisible (null locations).
- **State up front:** FHV contributes to geography at only ~18% of its volume (locations missing for 82%), so geographic views are yellow/green-dominated. A documented limitation, not a bug.

## Slide 8 — Trip behavior & cross-type comparison [confirmed, sql 07 D]
- **Use MEDIANS, not means** — green's raw mean distance is **19.91 mi vs a 2.07 mi median** (extreme GPS-glitch outliers; `05` caps only at distance > 0). Yellow is skewed too (mean 6.59 vs median 1.89). Patched D1 now reports median + capped mean + raw mean side-by-side to make this visible. **Headline: both services ≈ 2-mile typical trips.**
- **Green runs slightly longer/slower** (higher median distance, mean duration 21.4 vs yellow 17.6 min) — consistent with outer-borough routes.
- **Yellow is pricier and tips more:** mean fare $20.07 vs green $17.97 (total $28.89 vs $25.24); card tip 25.5% vs 22.5%; ~91–93% of card trips tip. [D1/D2]
- **Fare ∝ distance** is ~linear at ~$3–4/mi; the **JFK flat-fare (~$70) shows as a plateau around the 16–18 mile bins**. [D3]
- **Cross-type story:** yellow 63% / FHV 36% / green <1%; yellow = Manhattan core + airports, green/FHV = outer boroughs (confirm split with new **D4** query); **opposite seasonality** (yellow summer slump vs FHV fall peak); FHV is volume/temporal/geography only (no fare/distance/tip).

## Slide 9 — Anomaly investigation [confirmed, sql 07 E1]
**Headline anomaly: the largest day-over-day volume swings are the 2025 federal-holiday calendar — essentially every top swing is explained.**
- **Troughs on the holiday itself:** Christmas Dec 25 (−32.6%, year's lowest day at 106k), Thanksgiving Nov 27 (−26.1%), Independence Day Jul 4 (−26.0%).
- **Rebounds the day after a Monday holiday:** May 27 (+45%, post-Memorial Day), Jan 21 (+41.6%, post-MLK/Inauguration), Sep 2 (+41.1%, post-Labor Day), Feb 18 (+30.9%, post-Presidents'), Oct 14 (+23.5%, post-Columbus).
- **Long-weekend edges:** May 24 (−22.6%, Saturday exodus), Dec 1 (+27.6%, return-to-work after Thanksgiving).
- **Analytical nuance to call out:** Monday holidays surface as the *Tuesday rebound* (Sundays are already low, so the Monday dip is modest); standalone weekday holidays surface as the negative trough. This explains both signs of the swing.
- Secondary anomaly (geographic dropoff/pickup imbalance, E2) is folded into Slide 7.

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
