#!/usr/bin/env bash
# =====================================================================
# deploy.sh — build & deploy the app to Cloud Run with a locked-down
#             service account. Run from inside the app/ directory.
#
#   chmod +x deploy.sh && ./deploy.sh
#
# Security model (graded): the app authenticates to BigQuery and Vertex AI
# ONLY through this service account. No keys are baked into the image or env.
# =====================================================================
set -euo pipefail

# ---- Config — edit these two if needed ------------------------------
PROJECT_ID="its-a-struggle"
REGION="us-central1"          # Cloud Run + Vertex AI region (keep them equal)
# ---------------------------------------------------------------------

SERVICE="urban-mobility-app"
SA_NAME="mobility-app-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BQ_DATASET="nyc_taxi"
BQ_TABLE="trips_analytics"
GEMINI_MODEL="gemini-2.5-flash"

gcloud config set project "${PROJECT_ID}"

echo ">> Enabling required APIs…"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  bigquery.googleapis.com \
  aiplatform.googleapis.com

echo ">> Creating service account (ignore error if it already exists)…"
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Urban Mobility App SA" || true

echo ">> Granting least-privilege roles to the service account…"
for ROLE in roles/bigquery.dataViewer roles/bigquery.jobUser roles/aiplatform.user; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

echo ">> Deploying to Cloud Run (builds from the Dockerfile in this dir)…"
gcloud run deploy "${SERVICE}" \
  --source . \
  --region="${REGION}" \
  --service-account="${SA_EMAIL}" \
  --allow-unauthenticated \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=${REGION},GOOGLE_GENAI_USE_VERTEXAI=true,BQ_DATASET=${BQ_DATASET},BQ_TABLE=${BQ_TABLE},GEMINI_MODEL=${GEMINI_MODEL}"

echo ">> Done. URL below — paste it into app_url.txt:"
gcloud run services describe "${SERVICE}" --region="${REGION}" \
  --format='value(status.url)'
