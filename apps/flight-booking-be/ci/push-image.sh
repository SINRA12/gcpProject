#!/usr/bin/env bash
# Pushes the image to Artifact Registry. Run by the Jenkinsfile on the Jenkins VM.
#
# The VM has a service account that may only write to the registry. A short-lived access token
# for it comes from the metadata server (no key file anywhere) and goes to Jib as the registry
# password. The token is expanded inside this script, so it never appears in the build log.
#
# Needs: IMAGE_REPO (registry path without the tag) and TAG.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${IMAGE_REPO:?IMAGE_REPO is not set}"
: "${TAG:?TAG is not set}"

TOKEN=$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

./mvnw -B -q jib:build \
  -Dimage.repo="$IMAGE_REPO" -Dimage.tag="$TAG" \
  -Djib.to.auth.username=oauth2accesstoken -Djib.to.auth.password="$TOKEN"

echo "Pushed $IMAGE_REPO:$TAG"
