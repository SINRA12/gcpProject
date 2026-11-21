#!/usr/bin/env bash
# One-time setup, run once per GCP project (from Cloud Shell, as project owner):
#   1. a versioned GCS bucket for Terraform state
#   2. a service account Terraform runs as in GitHub Actions
#   3. Workload Identity Federation so GitHub Actions can act as that
#      service account without any stored key
#
# Usage: ./bootstrap/setup-gcp.sh <project-id> <github-owner/repo> [region]
set -euo pipefail

PROJECT_ID=${1:?project id required}
REPO=${2:?github repo required, e.g. myname/infra-lab}
REGION=${3:-asia-southeast1}

BUCKET="${PROJECT_ID}-tfstate"
SA_NAME="terraform-ci"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL="github"
PROVIDER="github-provider"

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

echo "== Enabling APIs"
gcloud services enable \
  compute.googleapis.com container.googleapis.com storage.googleapis.com \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com

echo "== State bucket gs://$BUCKET"
if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BUCKET" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
# Versioning keeps old state files, so a bad apply can be recovered
gcloud storage buckets update "gs://$BUCKET" --versioning

echo "== Service account $SA_EMAIL"
gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$SA_NAME" --display-name="Terraform (GitHub Actions)"

# Broad enough to build and destroy this lab. Fine for a personal lab project;
# a real team would scope these much more tightly.
for ROLE in roles/compute.admin roles/container.admin \
            roles/iam.serviceAccountUser roles/serviceusage.serviceUsageAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role="$ROLE" --condition=None >/dev/null
done
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$SA_EMAIL" --role=roles/storage.objectAdmin >/dev/null

echo "== Workload Identity Federation for $REPO"
gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$POOL" --location=global \
    --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --location=global --workload-identity-pool="$POOL" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --location=global --workload-identity-pool="$POOL" \
    --display-name="GitHub" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository=='${REPO}'"

# Only workflows from this exact repository may act as the service account
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}" >/dev/null

cat <<OUT

Done. Add these as GitHub repository VARIABLES
(Settings -> Secrets and variables -> Actions -> Variables):

  GCP_PROJECT_ID    = ${PROJECT_ID}
  GCP_REGION        = ${REGION}
  GCP_ZONE          = ${REGION}-a
  TF_STATE_BUCKET   = ${BUCKET}
  GCP_WIF_PROVIDER  = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}
  GCP_SA_EMAIL      = ${SA_EMAIL}
  LAB_MY_IPS        = ["<your-ip>/32"]
  ENABLE_CLOUDFLARE = false

Optional, for Cloudflare: variables CF_DOMAIN and CF_ZONE_ID,
and the SECRET CLOUDFLARE_API_TOKEN.

For local runs, put state_bucket = "${BUCKET}" in lab.tfvars.
OUT
