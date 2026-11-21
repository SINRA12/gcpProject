#!/usr/bin/env bash
# Build up or tear down the whole lab. Used both locally and by GitHub Actions.
#   ./lab.sh up       create everything (about 15-20 minutes)
#   ./lab.sh down     destroy everything (about 10-15 minutes)
#   ./lab.sh plan     show what would change, stage by stage
#   ./lab.sh check    terraform fmt + validate (no cloud access needed)
#   ./lab.sh status   show how many resources each stage manages
#   ./lab.sh test     curl the load balancer (and Cloudflare URL if enabled)
set -euo pipefail
cd "$(dirname "$0")"

STAGES=(1-platform 2-k8s 3-cloudflare 4-edge)
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
  echo 4-edge
}

case "${1:-}" in
  up)
    need_vars
    if cloudflare_enabled && [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
      echo "enable_cloudflare = true, but CLOUDFLARE_API_TOKEN is not set."; exit 1
    fi
    for s in $(active_stages); do
      init_stage "$s"
      tf "$s" apply -auto-approve -input=false -compact-warnings $COLOR -var-file="$VARS"
    done
    echo -e "\nLab is up. Run ./lab.sh test (the load balancer can take 3-5 minutes to start serving)."
    ;;

  down)
    need_vars
    for s in 4-edge 3-cloudflare 2-k8s 1-platform; do
      has_resources "$s" || { echo "$s: nothing to destroy"; continue; }
      if [[ "$s" == "1-platform" ]]; then
        echo "Waiting 60s for GKE to release the internal load balancers..."
        sleep 60
      fi
      tf "$s" destroy -auto-approve -input=false -compact-warnings $COLOR -var-file="$VARS"
    done
    echo -e "\nLab is down. Check Billing > Reports tomorrow to confirm charges stopped."
    ;;

  plan)
    need_vars
    platform_up=false; has_resources 1-platform && platform_up=true
    for s in $(active_stages); do
      if [[ "$s" != "1-platform" && "$platform_up" == "false" ]]; then
        echo -e "\n=== $s: skipped (lab is down, so its upstream stage has no outputs yet) ==="
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
    echo "=== terraform fmt ==="
    terraform fmt -check -recursive -diff
    for s in "${STAGES[@]}"; do
      terraform -chdir="$s" init -backend=false -input=false $COLOR >/dev/null
      tf "$s" validate $COLOR
    done
    bash -n lab.sh bootstrap/setup-gcp.sh && echo -e "\nShell scripts: syntax OK"
    ;;

  status)
    need_vars
    for s in "${STAGES[@]}"; do
      init_stage "$s"
      echo "$s: $(terraform -chdir="$s" state list 2>/dev/null | wc -l | xargs) resources"
    done
    ;;

  test)
    need_vars
    init_stage 1-platform
    IP=$(terraform -chdir=1-platform output -raw lb_ip)
    echo "--- direct to load balancer ($IP) ---"
    for p in /flight/cart /flight/checkin /payment /unknown; do
      printf '%-16s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "http://$IP$p")"
    done
    curl -s "http://$IP/flight/cart" | grep -E 'Name|Hostname|X-Haproxy-Node|X-Forwarded-For' || true
    if cloudflare_enabled && has_resources 3-cloudflare; then
      URL=$(terraform -chdir=3-cloudflare output -raw url)
      echo "--- through Cloudflare ($URL) ---"
      curl -s "$URL/flight/cart" | grep -E 'Name|Hostname|Cf-Connecting-Ip|X-Forwarded-For' || true
    fi
    ;;

  *)
    echo "Usage: ./lab.sh up | down | plan | check | status | test"; exit 1
    ;;
esac
