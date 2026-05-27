"""
Urban Mobility Analytics — natural-language questions over NYC taxi data.

A user types a question in plain English. Gemini (via Vertex AI) returns a JSON
object {sql, explanation} grounded in the trips_analytics schema: a read-only
BigQuery SELECT plus a one-line interpretation. We show the interpretation,
validate the SQL (read-only, single statement, no DDL/DML), run it against
BigQuery, and show the SQL, the result table, and a chart when the shape allows.
If the model declines (empty sql — e.g. a write/DDL request), we show its reason
instead of running anything.

Auth: Application Default Credentials only — on Cloud Run this is the service
account. There are NO API keys or secrets anywhere in this file or its env.
"""

import base64
import json
import os
import re
from pathlib import Path

import pandas as pd
import sqlparse
import streamlit as st
from google import genai
from google.genai import types as genai_types
from google.cloud import bigquery

# --------------------------------------------------------------------------
# Configuration (everything comes from the environment; nothing secret)
# --------------------------------------------------------------------------
PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "its-a-struggle")
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
BQ_DATASET = os.environ.get("BQ_DATASET", "nyc_taxi")
BQ_TABLE = os.environ.get("BQ_TABLE", "trips_analytics")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")

FQ_TABLE = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"

# Cap every query's billing as a safety net (5 GB). The app should never need
# more than this against a clustered/partitioned single table.
MAX_BYTES_BILLED = 5 * 1024 ** 3

# UI accent — kept in sync with primaryColor in .streamlit/config.toml.
TAXI_YELLOW = "#FFC400"

# --------------------------------------------------------------------------
# Schema grounding — this is what makes the generated SQL actually run.
# It documents which columns are NULL for which trip_type (the #1 cause of
# "looks right, returns nothing" queries) and the day-of-week convention.
# --------------------------------------------------------------------------
SCHEMA_PROMPT = f"""
You write BigQuery Standard SQL for ONE table:

  `{FQ_TABLE}`

One row = one taxi trip. Columns:

  trip_type            STRING   'yellow' | 'green' | 'fhv'
  vendor_id            INT64    NULL for fhv
  pickup_datetime      TIMESTAMP
  dropoff_datetime     TIMESTAMP  may be NULL for fhv
  passenger_count      INT64    NULL for fhv
  trip_distance        FLOAT64  miles; NULL for fhv
  pu_location_id       INT64    pickup TLC zone id
  do_location_id       INT64    dropoff TLC zone id
  rate_code_id         INT64    NULL for fhv
  store_and_fwd_flag   STRING   NULL for fhv
  payment_type         INT64    1=card 2=cash 3=no charge 4=dispute; NULL for fhv
  fare_amount          FLOAT64  NULL for fhv
  extra                FLOAT64  NULL for fhv
  mta_tax              FLOAT64  NULL for fhv
  tip_amount           FLOAT64  NULL for fhv; recorded for CARD only
  tolls_amount         FLOAT64  NULL for fhv
  improvement_surcharge FLOAT64 NULL for fhv
  total_amount         FLOAT64  NULL for fhv
  congestion_surcharge FLOAT64  NULL for fhv
  airport_fee          FLOAT64  yellow only
  cbd_congestion_fee   FLOAT64  yellow/green only (2025 congestion pricing)
  ehail_fee            FLOAT64  green only
  sr_flag              INT64    fhv only
  dispatching_base_num STRING   fhv only
  affiliated_base_number STRING fhv only
  pickup_borough       STRING   e.g. 'Manhattan'
  pickup_zone          STRING   e.g. 'JFK Airport'
  pickup_service_zone  STRING
  dropoff_borough      STRING
  dropoff_zone         STRING
  dropoff_service_zone STRING
  pickup_date          DATE
  pickup_year          INT64
  pickup_month         INT64    1-12
  pickup_dayofweek     INT64    1=Sunday .. 7=Saturday
  pickup_dayname       STRING   e.g. 'Monday'
  pickup_hour          INT64    0-23 (NYC local wall-clock)
  day_type             STRING   'weekday' | 'weekend'
  trip_duration_min    FLOAT64  minutes; NULL when dropoff is NULL
  tip_rate             FLOAT64  tip_amount / fare_amount; meaningful for card trips

OUTPUT FORMAT:
- Respond with a single JSON object and NOTHING else (no markdown fences, no prose):
  {{"sql": "<one BigQuery Standard SQL SELECT>", "explanation": "<one sentence>"}}
- "sql": exactly ONE read-only SELECT statement, OR an empty string "" if the
  request cannot be answered with a safe read-only SELECT over this table.
- "explanation": ONE plain-English sentence describing what the query returns. If
  "sql" is empty, put the reason you are declining here instead.
- If the request asks to modify data or schema (INSERT/UPDATE/DELETE/DROP/CREATE/
  ALTER/MERGE/TRUNCATE), or is unrelated to this table, set "sql" to "" and explain
  why in "explanation". Do NOT emit a placeholder query such as `SELECT 1`.

QUERY RULES:
- Read-only. The sql must never INSERT/UPDATE/DELETE/DROP/CREATE/ALTER/MERGE/TRUNCATE.
- Always query the fully-qualified table `{FQ_TABLE}`.
- For fare/distance/tip/passenger questions, filter to trip_type IN ('yellow','green')
  because those columns are NULL for fhv.
- For tip questions, also filter payment_type = 1 (tips only recorded on card).
- For any geographic question that groups by, ranks, or aggregates over a location
  column (pickup_borough, pickup_zone, dropoff_borough, dropoff_zone), you MUST
  exclude rows where that column is NULL — e.g. add `WHERE pickup_zone IS NOT NULL`
  (and the dropoff equivalent for route/dropoff questions). About 82% of fhv trips
  have NULL pickup/dropoff locations; without this filter the NULL bucket dominates
  and shows up as a spurious top result. (The only exception is a question that is
  explicitly *about* missing/NULL locations.)
- For "top N / most common / busiest ... for EACH / per <category>" questions
  (e.g. "top routes for each of yellow and green"), do NOT use one global
  ORDER BY ... LIMIT — the largest group (yellow ≈ 63% of trips) crowds out the
  rest and green (<1%) disappears entirely. Rank WITHIN each group with a window
  function and keep N per group, e.g.:
    SELECT * FROM (
      SELECT trip_type, pickup_zone, dropoff_zone, COUNT(*) AS trip_count,
             ROW_NUMBER() OVER (PARTITION BY trip_type ORDER BY COUNT(*) DESC) AS rn
      FROM `{FQ_TABLE}`
      WHERE trip_type IN ('yellow','green')
        AND pickup_zone IS NOT NULL AND dropoff_zone IS NOT NULL
      GROUP BY trip_type, pickup_zone, dropoff_zone
    ) WHERE rn <= 10 ORDER BY trip_type, trip_count DESC
- Add a sensible LIMIT (e.g. 100) for row-listing questions; never LIMIT pure aggregates.
- pickup_dayofweek is 1=Sunday..7=Saturday; prefer pickup_dayname for readability.
""".strip()

# Keywords that must never appear as a standalone token in generated SQL.
FORBIDDEN = ["INSERT", "UPDATE", "DELETE", "DROP", "CREATE", "ALTER",
             "MERGE", "TRUNCATE", "GRANT", "REVOKE"]


# --------------------------------------------------------------------------
# Clients (cached across reruns)
# --------------------------------------------------------------------------
@st.cache_resource
def get_genai_client() -> genai.Client:
    # vertexai=True -> uses the Cloud Run service account via ADC. No API key.
    return genai.Client(vertexai=True, project=PROJECT_ID, location=LOCATION)


@st.cache_resource
def get_bq_client() -> bigquery.Client:
    return bigquery.Client(project=PROJECT_ID)


# --------------------------------------------------------------------------
# Core steps: generate -> validate -> execute
# --------------------------------------------------------------------------
def strip_fences(text: str) -> str:
    """Remove ```lang ... ``` wrappers (```sql, ```json, or bare ```)."""
    t = text.strip()
    t = re.sub(r"^```[a-zA-Z]*\s*", "", t)
    t = re.sub(r"\s*```$", "", t)
    return t.strip()


def format_sql(sql: str) -> str:
    """Pretty-print SQL multi-line for display, regardless of how the model
    formatted it. Display-only — the raw SQL is what gets validated and run.
    Falls back to the original string if sqlparse can't handle it."""
    try:
        pretty = sqlparse.format(sql, reindent=True, keyword_case="upper").strip()
        return pretty or sql
    except Exception:  # noqa: BLE001
        return sql


def parse_model_json(raw: str) -> tuple[str, str]:
    """Parse Gemini's JSON reply into (sql, explanation), defensively.

    Falls back to treating the whole reply as SQL if it isn't valid JSON, so the
    pipeline still works if the model ever ignores the JSON contract. An empty
    sql string is a deliberate signal that the model declined (see UI handling).
    """
    cleaned = strip_fences(raw)
    try:
        obj = json.loads(cleaned)
        sql = strip_fences(str(obj.get("sql") or "")).strip()
        explanation = str(obj.get("explanation") or "").strip()
        return sql, explanation
    except (json.JSONDecodeError, TypeError, AttributeError):
        # Not JSON — treat the raw text as the SQL; no explanation available.
        return cleaned, ""


def generate_sql(question: str) -> tuple[str, str]:
    """Ask Gemini for {sql, explanation}; returns (sql, explanation).

    sql == "" means the model declined (e.g. a write/DDL or off-topic request);
    the caller shows `explanation` as the reason instead of running anything.
    """
    client = get_genai_client()
    resp = client.models.generate_content(
        model=GEMINI_MODEL,
        contents=question,
        config=genai_types.GenerateContentConfig(
            system_instruction=SCHEMA_PROMPT,
            temperature=0.0,
            response_mime_type="application/json",
        ),
    )
    return parse_model_json(resp.text or "")


def validate_sql(sql: str) -> tuple[bool, str]:
    """Return (is_valid, reason). Reason is shown to the user on rejection."""
    if not sql:
        return False, "Model returned an empty query."

    # Single statement only — no stacked queries.
    stripped = sql.strip().rstrip(";")
    if ";" in stripped:
        return False, "Multiple statements are not allowed (found a ';')."

    # Must be a read-only query: first keyword SELECT or WITH (CTE).
    first_kw = re.match(r"\s*([A-Za-z]+)", stripped)
    if not first_kw or first_kw.group(1).upper() not in ("SELECT", "WITH"):
        return False, "Only SELECT queries are allowed (must start with SELECT or WITH)."

    # No DDL/DML keywords anywhere (word-boundary match, case-insensitive).
    upper = stripped.upper()
    for kw in FORBIDDEN:
        if re.search(rf"\b{kw}\b", upper):
            return False, f"Query contains a forbidden keyword: {kw}."

    return True, "OK"


def run_query(sql: str) -> pd.DataFrame:
    client = get_bq_client()
    job_config = bigquery.QueryJobConfig(
        maximum_bytes_billed=MAX_BYTES_BILLED,
        use_query_cache=True,
    )
    return client.query(sql, job_config=job_config).result().to_dataframe()


def maybe_chart(df: pd.DataFrame) -> None:
    """Draw a chart only for aggregated results.

    "Aggregated" heuristic: a single label column with one row per distinct value
    (as GROUP BY produces) and a modest number of rows. Raw row listings (e.g. a
    LIMIT 100 dump) tend to have a repeated first column or too many rows, so they
    are left as just a table.
    """
    if df.empty or df.shape[1] < 2:
        return
    numeric_cols = df.select_dtypes(include="number").columns.tolist()
    if not numeric_cols:
        return

    label_col = df.columns[0]
    value_col = numeric_cols[-1]
    # Don't chart if the label column is itself the only numeric column.
    if label_col == value_col and len(numeric_cols) == 1:
        return

    # Aggregated-only guard: one row per label, and few enough rows to read as a
    # chart. Duplicated labels or a long result => looks like raw rows, not a
    # group-by, so skip charting and just show the table.
    if df[label_col].duplicated().any() or len(df) > 50:
        return

    chart_df = df.set_index(label_col)[[value_col]]
    # Time-ish first column -> line; otherwise -> bar. Keep it simple.
    if re.search(r"hour|date|month|year|dayofweek", str(label_col), re.IGNORECASE):
        st.line_chart(chart_df, color=TAXI_YELLOW)
    else:
        st.bar_chart(chart_df, color=TAXI_YELLOW)


# --------------------------------------------------------------------------
# Presentation: dimmed B&W background + transit-poster hero banner.
# Colors come from .streamlit/config.toml; this layers the image, fonts, and
# the taxi-yellow accents on top via injected CSS.
# --------------------------------------------------------------------------
@st.cache_data
def _bg_data_uri() -> str:
    """Base64 data-URI for the background image. Empty string if missing
    (app still works, just falls back to the flat dark theme)."""
    path = Path(__file__).parent / "assets" / "bg.jpg"
    try:
        return "data:image/jpeg;base64," + base64.b64encode(path.read_bytes()).decode()
    except FileNotFoundError:
        return ""


def inject_css() -> None:
    bg = _bg_data_uri()
    # Dark gradient over the photo: a touch lighter behind the hero, dimmer
    # behind the data below so tables stay readable. User wants it subtle.
    if bg:
        app_bg = (
            "linear-gradient(180deg, rgba(10,10,12,0.84) 0%, "
            "rgba(10,10,12,0.93) 55%, rgba(10,10,12,0.97) 100%), "
            f'url("{bg}") center/cover fixed no-repeat'
        )
    else:
        app_bg = "#0d0d0f"

    st.markdown(
        f"""
        <style>
        @import url('https://fonts.googleapis.com/css2?family=Anton&family=DM+Sans:wght@400;500;700&display=swap');

        .stApp {{ background: {app_bg}; }}
        .stApp, .stApp p, .stApp li, .stApp label {{
            font-family: 'DM Sans', sans-serif;
        }}
        .stApp h1, .stApp h2, .stApp h3 {{
            font-family: 'DM Sans', sans-serif; letter-spacing: -0.01em;
        }}

        /* Hero banner ------------------------------------------------------ */
        .hero {{
            position: relative;
            background: rgba(18,18,21,0.72);
            border: 1px solid rgba(255,196,0,0.25);
            border-radius: 14px;
            padding: 30px 34px 26px;
            margin: 4px 0 26px;
            backdrop-filter: blur(3px);
            box-shadow: 0 18px 50px rgba(0,0,0,0.55);
            overflow: hidden;
        }}
        /* Black-and-yellow taxi checker stripe across the top */
        .hero::before {{
            content: ""; position: absolute; top: 0; left: 0; right: 0; height: 10px;
            background-color: #0d0d0f;
            background-image:
                linear-gradient(45deg, {TAXI_YELLOW} 25%, transparent 25%),
                linear-gradient(-45deg, {TAXI_YELLOW} 25%, transparent 25%),
                linear-gradient(45deg, transparent 75%, {TAXI_YELLOW} 75%),
                linear-gradient(-45deg, transparent 75%, {TAXI_YELLOW} 75%);
            background-size: 20px 20px;
            background-position: 0 0, 0 10px, 10px -10px, -10px 0;
        }}
        .hero-kicker {{
            font-family: 'DM Sans', sans-serif; font-weight: 700;
            letter-spacing: 0.32em; text-transform: uppercase;
            font-size: 0.72rem; color: {TAXI_YELLOW}; margin: 8px 0 6px;
        }}
        .hero-title {{
            font-family: 'Anton', sans-serif; font-weight: 400;
            font-size: clamp(2.4rem, 5.5vw, 4rem); line-height: 0.98;
            letter-spacing: 0.01em; text-transform: uppercase;
            color: #ffffff; margin: 0 0 12px;
        }}
        .hero-title .spark {{ color: {TAXI_YELLOW}; }}
        .hero-sub {{
            font-size: 1.05rem; line-height: 1.5; color: #d6d6d8;
            max-width: 70ch; margin: 0;
        }}
        .hero-sub code {{
            color: {TAXI_YELLOW}; background: rgba(255,196,0,0.08);
            padding: 1px 6px; border-radius: 5px; font-size: 0.92em;
        }}

        /* Accents on Streamlit chrome ------------------------------------- */
        .stButton > button {{
            font-family: 'DM Sans', sans-serif; font-weight: 700;
            letter-spacing: 0.04em; border-radius: 9px;
        }}
        .stButton > button[kind="primary"],
        .stButton > button[data-testid*="primary"] {{
            color: #141414 !important;
        }}
        .stApp [data-testid="stExpander"] {{
            border: 1px solid rgba(255,196,0,0.18); border-radius: 10px;
        }}
        .stApp strong {{ color: {TAXI_YELLOW}; }}
        </style>
        """,
        unsafe_allow_html=True,
    )


def render_hero() -> None:
    st.markdown(
        f"""
        <div class="hero">
          <div class="hero-kicker">NYC&nbsp;·&nbsp;Yellow&nbsp;·&nbsp;Green&nbsp;·&nbsp;FHV&nbsp;·&nbsp;2025</div>
          <h1 class="hero-title">🚕 Urban Mobility <span class="spark">Analytics</span></h1>
          <p class="hero-sub">
            Ask New York's streets a question — in plain English. Our Gemini-powered
            engine turns it into live BigQuery SQL against
            <code>{FQ_TABLE}</code>, runs it, and brings the answer straight back.
            All your mobility data, no query language required.
          </p>
        </div>
        """,
        unsafe_allow_html=True,
    )


# --------------------------------------------------------------------------
# UI
# --------------------------------------------------------------------------
st.set_page_config(page_title="Urban Mobility Analytics", page_icon="🚕", layout="wide")
inject_css()
render_hero()

with st.expander("Example questions"):
    st.markdown(
        "- Which borough has the highest number of trips?\n"
        "- What are the top 10 busiest pickup zones?\n"
        "- How does trip volume change by hour of day?\n"
        "- What are the most common pickup-to-dropoff routes?"
    )

question = st.text_input(
    "Your question",
    placeholder="e.g. Which borough has the highest number of trips?",
)

if st.button("Ask", type="primary") and question.strip():
    with st.spinner("Asking Gemini…"):
        try:
            sql, explanation = generate_sql(question.strip())
        except Exception as e:  # noqa: BLE001
            st.error(f"Gemini call failed: {e}")
            st.stop()

    # Model declined (empty sql — e.g. a write/DDL or off-topic request):
    # show its reason and run nothing. No SELECT 1 no-op.
    if not sql:
        st.warning(
            "Gemini didn't produce a query for this request. "
            f"Reason: {explanation or 'no explanation provided.'}"
        )
        st.stop()

    if explanation:
        st.markdown(f"**Interpretation:** {explanation}")

    st.subheader("Generated SQL")
    st.code(format_sql(sql), language="sql")

    ok, reason = validate_sql(sql)
    if not ok:
        st.error(f"Query rejected by the safety validator: {reason}")
        st.stop()

    with st.spinner("Running query in BigQuery…"):
        try:
            df = run_query(sql)
        except Exception as e:  # noqa: BLE001
            st.error(f"Query execution failed: {e}")
            st.stop()

    st.subheader(f"Result ({len(df):,} rows)")
    if df.empty:
        st.info("The query ran but returned no rows.")
    elif "trip_type" in df.columns and df["trip_type"].nunique() > 1 \
            and len(df) > df["trip_type"].nunique():
        # Per-type listing (e.g. "top routes for each of yellow and green"):
        # one table per trip_type so a small group (green) isn't buried under a
        # large one (yellow). A 1-row-per-type comparison falls through to the
        # single combined table below instead.
        for ttype, group in df.groupby("trip_type", sort=False):
            st.markdown(f"**{str(ttype).title()}** ({len(group):,} rows)")
            st.dataframe(
                group.drop(columns=["trip_type"]).reset_index(drop=True),
                use_container_width=True,
            )
    else:
        st.dataframe(df, use_container_width=True)
        maybe_chart(df)
