#!/usr/bin/env bash
# Opens Jenkins and Argo CD on your laptop, no public IPs involved:
#   Jenkins  -> http://localhost:8080   (IAP tunnel to the VM)
#   Argo CD  -> http://localhost:8081   (kubectl port-forward to the flight cluster)
# Leave it running; Ctrl+C closes both. Needs gcloud (logged in as the account that owns the lab project),
# kubectl and gke-gcloud-auth-plugin:  gcloud components install kubectl gke-gcloud-auth-plugin
#
# Usage: LAB_PROJECT=my-project ./scripts/laptop-access.sh      (LAB_ZONE defaults to asia-southeast1-a)
# Tip: if your gcloud is logged in to another account (work), make a separate profile first:
#   gcloud config configurations create lab && gcloud auth login && gcloud config set project <lab project>
set -euo pipefail

PROJECT="${LAB_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${LAB_ZONE:-asia-southeast1-a}"
[[ -n "$PROJECT" ]] || { echo "Set LAB_PROJECT=<lab project id>"; exit 1; }
for c in gcloud kubectl gke-gcloud-auth-plugin; do
  command -v "$c" >/dev/null || { echo "Missing $c. Install: gcloud components install kubectl gke-gcloud-auth-plugin"; exit 1; }
done
echo "Project: $PROJECT, zone: $ZONE, account: $(gcloud config get-value account 2>/dev/null)"

gcloud container clusters get-credentials flight-cluster --zone "$ZONE" --project "$PROJECT" >/dev/null
ctx="gke_${PROJECT}_${ZONE}_flight-cluster"

jenkins_pw=$(gcloud compute instances describe jenkins --zone "$ZONE" --project "$PROJECT" \
  --format='value(metadata.items.jenkins-admin-password)' 2>/dev/null || true)
argo_pw=$(kubectl --context "$ctx" -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || true)

pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT INT TERM

gcloud compute start-iap-tunnel jenkins 8080 --local-host-port=localhost:8080 --zone "$ZONE" --project "$PROJECT" &
pids+=($!)
kubectl --context "$ctx" -n argocd port-forward svc/argocd-server 8081:80 &
pids+=($!)

cat <<MSG

  Jenkins  http://localhost:8080   user admin   password ${jenkins_pw:-<not found: is the VM up?>}
  Argo CD  http://localhost:8081   user admin   password ${argo_pw:-<not found: is Argo CD installed?>}

  Build:  Jenkins -> flight-booking-be -> main -> Build Now
  Sync:   Argo CD UI -> flight-booking-be -> Refresh, Sync   (or the argocd CLI, see docs/runbook.md)
  Ctrl+C to close both tunnels.
MSG
wait
