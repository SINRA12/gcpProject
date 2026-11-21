#!/usr/bin/env bash
# Generates lab.tfvars in CI from environment variables
# (which the workflows fill from GitHub repository variables).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GCP_PROJECT_ID:?set the GCP_PROJECT_ID repository variable}"
: "${TF_STATE_BUCKET:?set the TF_STATE_BUCKET repository variable}"

cat > lab.tfvars <<TFVARS
project_id         = "${GCP_PROJECT_ID}"
region             = "${GCP_REGION:-asia-southeast1}"
zone               = "${GCP_ZONE:-asia-southeast1-a}"
state_bucket       = "${TF_STATE_BUCKET}"
my_ips             = ${LAB_MY_IPS:-[]}
enable_armor       = ${ENABLE_ARMOR:-false}
enable_cloudflare  = ${ENABLE_CLOUDFLARE:-false}
domain             = "${CF_DOMAIN:-example.com}"
cloudflare_zone_id = "${CF_ZONE_ID:-none}"
record_name        = "lab"
TFVARS
echo "lab.tfvars written for project ${GCP_PROJECT_ID}"
