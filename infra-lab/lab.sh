#!/usr/bin/env bash
# Build up or tear down the whole lab. Used both locally (Cloud Shell) and by GitHub Actions.
# Day to day you only need two commands:
#   ./lab.sh up       set everything up (first run also installs terraform, enables
#                     APIs, creates the state bucket and writes lab.tfvars)
#   ./lab.sh down     tear everything down
# Everything else below is for exploring one stage at a time.
#   ./lab.sh up [stage]       create everything, or just one stage (about 15-20 min in total)
#   ./lab.sh down [stage]     destroy everything, or just one stage (about 10-15 min in total)
#   ./lab.sh plan [stage]     show what would change, for all stages or just one
#   ./lab.sh outputs [stage]  print a stage's outputs (default: 1-platform)
#   ./lab.sh check    terraform fmt + validate (no cloud access needed)
#   ./lab.sh status   show how many resources each stage manages
#   ./lab.sh test     curl the load balancer (and Cloudflare URL if enabled)
# A stage can be given as 1-5, or by name: platform, k8s, cloudflare, edge, observability
# (the full directory name such as 1-platform also works).
set -euo pipefail
cd "$(dirname "$0")"

STAGES=(1-platform 2-k8s 3-cloudflare 4-edge 5-observability)
VARS="$PWD/lab.tfvars"
COLOR=""; [[ -n "${CI:-}" ]] && COLOR="-no-color"

need_vars() {
  [[ -f "$VARS" ]] || { echo "Missing lab.tfvars. Copy lab.tfvars.example and fill it in."; exit 1; }
}

# Read a simple value from lab.tfvars, e.g. tfvar state_bucket
tfvar() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$VARS" | head -1 | xargs
}

cloudflare_enabled() { [[ "$(tfvar enable_cloudflare)" == "true" ]]; }

# ---------- First-run setup (local / Cloud Shell only; CI does this itself) ----------

LOCAL=true; [[ -n "${CI:-}" ]] && LOCAL=false
$LOCAL && export PATH="$HOME/bin:$PATH"  # where install-terraform-cloudshell.sh puts terraform

ensure_terraform() {
  $LOCAL || return 0
  terraform version >/dev/null 2>&1 && return 0
  echo "terraform not found: installing it into ~/bin ..."
  ./scripts/install-terraform-cloudshell.sh
  hash -r
  terraform version >/dev/null 2>&1 || { echo "terraform is still not usable. See docs/runbook.md."; exit 1; }
}

# Write lab.tfvars from your gcloud settings the first time
ensure_tfvars() {
  $LOCAL || return 0
  [[ -f "$VARS" ]] && return 0
  command -v gcloud >/dev/null || { echo "gcloud not found. Use Cloud Shell, or install the gcloud CLI."; exit 1; }
  local project region ip ips=""
  project=$(gcloud config get-value project 2>/dev/null || true)
  [[ -n "$project" ]] || { echo "No project selected. Run: gcloud config set project YOUR_PROJECT_ID"; exit 1; }
  region="${LAB_REGION:-asia-southeast1}"
  ip=$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
  [[ -n "$ip" ]] && ips="\"$ip/32\""
  cat > "$VARS" <<TFVARS
project_id        = "$project"
region            = "$region"
zone              = "${region}-a"
state_bucket      = "${project}-tfstate"
my_ips            = [$ips]
enable_armor      = false
enable_cloudflare = false
TFVARS
  echo "Wrote $VARS for project $project (this shell's IP: ${ip:-unknown}). Edit it to change anything."
}

# Base APIs Terraform itself needs, plus the state bucket (both are no-ops once done)
ensure_gcp() {
  $LOCAL || return 0
  local project bucket region enabled
  project=$(tfvar project_id); bucket=$(tfvar state_bucket); region=$(tfvar region)
  enabled=$(gcloud services list --enabled --project "$project" --format='value(config.name)')
  if ! grep -qx cloudresourcemanager.googleapis.com <<<"$enabled"; then
    echo "Enabling Cloud Resource Manager + Service Usage APIs (waiting 60s to take effect) ..."
    gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com --project "$project"
    sleep 60
  fi
  if ! gcloud storage buckets describe "gs://$bucket" >/dev/null 2>&1; then
    echo "Creating state bucket gs://$bucket ..."
    gcloud storage buckets create "gs://$bucket" --project "$project" --location "$region" \
      --uniform-bucket-level-access --public-access-prevention
    gcloud storage buckets update "gs://$bucket" --versioning
  fi
}

tf() {  # tf <stage> <args...>
  local stage=$1; shift
  echo -e "\n=== $stage: terraform $1 ==="
  terraform -chdir="$stage" "$@"
}

init_stage() {
  terraform -chdir="$1" init -input=false -reconfigure $COLOR \
    -backend-config="bucket=$(tfvar state_bucket)" \
    -backend-config="prefix=infra-lab/$1" >/dev/null
}

has_resources() {  # true if the stage currently manages any resources
  init_stage "$1"
  [[ -n "$(terraform -chdir="$1" state list 2>/dev/null)" ]]
}

active_stages() {
  echo 1-platform 2-k8s
  if cloudflare_enabled; then echo 3-cloudflare; fi
  echo 4-edge 5-observability
}

# Turn "1", "platform" or "1-platform" into the stage directory name
resolve_stage() {
  local in=$1 s
  for s in "${STAGES[@]}"; do
    if [[ "$s" == "$in" || "${s%%-*}" == "$in" || "${s#*-}" == "$in" ]]; then
      echo "$s"; return
    fi
  done
  echo "Unknown stage '$in'. Use one of: ${STAGES[*]} (or just 1-5, platform, k8s, cloudflare, edge, observability)." >&2
  exit 1
}

# Stages that must already be applied before <stage> can run (they provide its inputs)
upstream_of() {
  case "$1" in
    1-platform) ;;
    2-k8s|3-cloudflare) echo 1-platform ;;
    4-edge) echo 1-platform; if cloudflare_enabled; then echo 3-cloudflare; fi ;;
    5-observability) echo 1-platform 2-k8s ;;
  esac
}

require_upstream() {
  local u
  for u in $(upstream_of "$1"); do
    has_resources "$u" || { echo "$1 needs $u first. Run: ./lab.sh up $u"; exit 1; }
  done
}

# Stages that read <stage>'s outputs, so destroying <stage> first would break them
downstream_of() {
  case "$1" in
    1-platform) echo 2-k8s 3-cloudflare 4-edge 5-observability ;;
    2-k8s) echo 5-observability ;;
    3-cloudflare) echo 4-edge ;;
  esac
}

require_enabled() {
  if [[ "$1" == "3-cloudflare" ]] && ! cloudflare_enabled; then
    echo "3-cloudflare is disabled (enable_cloudflare is not true in lab.tfvars)."; exit 1
  fi
}

apply_stage() {
  require_enabled "$1"
  init_stage "$1"
  tf "$1" apply -auto-approve -input=false -compact-warnings $COLOR -var-file="$VARS"
}

# Names of load balancer pieces GKE created for the ingress Services (all prefixed k8s2-)
gke_lb_leftovers() {
  local project; project=$(tfvar project_id)
  {
    gcloud compute forwarding-rules list --project "$project" --filter="name~^k8s2-" --format='value(name)'
    gcloud compute backend-services list --project "$project" --filter="name~^k8s2-" --format='value(name)'
    gcloud compute network-endpoint-groups list --project "$project" --filter="name~^k8s2-" --format='value(name)'
  } 2>/dev/null || true
}

# GKE removes those pieces asynchronously after the ingress Service is deleted. Destroying
# the VPC before that finishes fails with "network is already being used by ...".
wait_for_gke_lb_cleanup() {
  if ! command -v gcloud >/dev/null; then
    echo "gcloud not found, waiting 60s for GKE to release the internal load balancers..."
    sleep 60; return
  fi
  local left tries=0
  echo "Waiting for GKE to release its internal load balancers (up to 5 minutes)..."
  while (( tries < 30 )); do
    left=$(gke_lb_leftovers)
    if [[ -z "$left" ]]; then echo "GKE load balancer resources are gone."; return; fi
    sleep 10; tries=$((tries + 1))
  done
  echo "Still present after 5 minutes:"; echo "$left"
  echo "Continuing anyway. If deleting the VPC fails, remove them by hand (docs/runbook.md, Troubleshooting)."
}

destroy_stage() {
  has_resources "$1" || { echo "$1: nothing to destroy"; return; }
  if [[ "$1" == "1-platform" ]]; then
    wait_for_gke_lb_cleanup
  fi
  if ! tf "$1" destroy -auto-approve -input=false -compact-warnings $COLOR -var-file="$VARS"; then
    if [[ "$1" == "1-platform" ]]; then
      echo -e "\nIf the error says the network is 'already being used by' a k8s2-... resource,"
      echo "GKE left load balancer pieces behind. Delete them (docs/runbook.md, Troubleshooting),"
      echo "then run ./lab.sh down platform again."
    fi
    exit 1
  fi
}

STAGE_ARG="${2:-}"

case "${1:-}" in
  up)
    ensure_terraform; ensure_tfvars; need_vars; ensure_gcp
    if [[ -n "$STAGE_ARG" ]]; then
      s=$(resolve_stage "$STAGE_ARG")
      if [[ "$s" == "3-cloudflare" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        echo "CLOUDFLARE_API_TOKEN is not set."; exit 1
      fi
      require_upstream "$s"
      apply_stage "$s"
      echo -e "\n$s is up. Next: ./lab.sh outputs $s"
      exit 0
    fi
    if cloudflare_enabled && [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      echo "enable_cloudflare = true, but CLOUDFLARE_API_TOKEN is not set."; exit 1
    fi
    for s in $(active_stages); do
      apply_stage "$s"
    done
    LB_IP=$(terraform -chdir=1-platform output -raw lb_ip 2>/dev/null || true)
    echo -e "\nLab is up. Load balancer IP: ${LB_IP:-unknown}"
    echo "It can take 3-5 minutes to start serving. Then try:  ./lab.sh test"
    echo "or from anywhere:  curl http://${LB_IP:-LB_IP}/flight/cart"
    echo "When you finish:   ./lab.sh down"
    ;;

  down)
    ensure_terraform; ensure_tfvars; need_vars
    if $LOCAL && command -v gcloud >/dev/null && ! gcloud storage buckets describe "gs://$(tfvar state_bucket)" >/dev/null 2>&1; then
      echo "State bucket gs://$(tfvar state_bucket) does not exist, so there is nothing to destroy."; exit 0
    fi
    if [[ -n "$STAGE_ARG" ]]; then
      s=$(resolve_stage "$STAGE_ARG")
      for d in $(downstream_of "$s"); do
        if has_resources "$d"; then
          echo "$d still depends on $s. Destroy it first: ./lab.sh down $d"; exit 1
        fi
      done
      destroy_stage "$s"
      echo -e "\n$s is down."
      exit 0
    fi
    for s in 5-observability 4-edge 3-cloudflare 2-k8s 1-platform; do
      destroy_stage "$s"
    done
    echo -e "\nLab is down. Check Billing > Reports tomorrow to confirm charges stopped."
    ;;

  plan)
    ensure_terraform; ensure_tfvars; need_vars
    if $LOCAL && command -v gcloud >/dev/null && ! gcloud storage buckets describe "gs://$(tfvar state_bucket)" >/dev/null 2>&1; then
      echo "State bucket gs://$(tfvar state_bucket) does not exist yet. Run ./lab.sh up once: it creates the bucket."; exit 1
    fi
    if [[ -n "$STAGE_ARG" ]]; then
      s=$(resolve_stage "$STAGE_ARG")
      require_enabled "$s"
      require_upstream "$s"
      init_stage "$s"
      tf "$s" plan -input=false -compact-warnings $COLOR -var-file="$VARS"
      exit 0
    fi
    platform_up=false; has_resources 1-platform && platform_up=true
    for s in $(active_stages); do
      if [[ "$s" != "1-platform" && "$platform_up" == "false" ]]; then
        echo -e "\n=== $s: skipped (lab is down, so its upstream stage has no outputs yet) ==="
        continue
      fi
      if [[ "$s" == "5-observability" ]] && ! has_resources 2-k8s; then
        echo -e "\n=== $s: skipped (2-k8s not applied yet) ==="
        continue
      fi
      if [[ "$s" == "4-edge" ]] && cloudflare_enabled && ! has_resources 3-cloudflare; then
        echo -e "\n=== $s: skipped (3-cloudflare not applied yet) ==="
        continue
      fi
      init_stage "$s"
      tf "$s" plan -input=false -compact-warnings $COLOR -var-file="$VARS"
    done
    ;;

  check)
    ensure_terraform
    echo "=== terraform fmt ==="
    terraform fmt -check -recursive -diff
    for s in "${STAGES[@]}"; do
      terraform -chdir="$s" init -backend=false -input=false $COLOR >/dev/null
      tf "$s" validate $COLOR
    done
    bash -n lab.sh bootstrap/setup-gcp.sh && echo -e "\nShell scripts: syntax OK"
    ;;

  status)
    ensure_terraform; need_vars
    for s in "${STAGES[@]}"; do
      init_stage "$s"
      echo "$s: $(terraform -chdir="$s" state list 2>/dev/null | wc -l | xargs) resources"
    done
    ;;

  outputs)
    ensure_terraform; need_vars
    s=$(resolve_stage "${STAGE_ARG:-1-platform}")
    init_stage "$s"
    terraform -chdir="$s" output
    if [[ "$s" == "5-observability" ]]; then
      # terraform hides sensitive outputs in the list above, so print the Grafana password too
      echo "grafana_admin_password = $(terraform -chdir="$s" output -raw grafana_admin_password 2>/dev/null || echo '(not available yet)')"
    fi
    ;;

  test)
    ensure_terraform; need_vars
    init_stage 1-platform
    IP=$(terraform -chdir=1-platform output -raw lb_ip)
    echo "--- direct to load balancer ($IP) ---"
    for p in /flight/cart /flight/checkin /payment /unknown; do
      printf '%-16s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP$p")"
    done
    curl -s "http://$IP/flight/cart" | grep -E 'Name|Hostname|X-Haproxy-Node|X-Forwarded-For' || true
    if has_resources 5-observability; then
      printf '%-16s %s\n' /grafana/api/health "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP/grafana/api/health")"
      echo "Grafana: http://$IP/grafana/  (user admin, password: ./lab.sh outputs observability)"
    fi
    if cloudflare_enabled && has_resources 3-cloudflare; then
      URL=$(terraform -chdir=3-cloudflare output -raw url)
      echo "--- through Cloudflare ($URL) ---"
      curl -s "$URL/flight/cart" | grep -E 'Name|Hostname|Cf-Connecting-Ip|X-Forwarded-For' || true
    fi
    ;;

  *)
    echo "Usage: ./lab.sh up|down|plan [stage] | outputs [stage] | check | status | test"; exit 1
    ;;
esac
