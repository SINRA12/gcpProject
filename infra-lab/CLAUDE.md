# CLAUDE.md

Context for Claude Code working in this repository.

## What this is

A personal learning lab that rebuilds a typical enterprise request path on Google Cloud,
mirroring a company setup ("GK" test environment) the owner works with:

User → Cloudflare (optional) → Google Classic Application Load Balancer + Cloud Armor
→ HAProxy (regional managed instance group, private IPs) → ingress-nginx in one of two
GKE clusters (`flight`, `payment`, via internal load balancers on reserved IPs)
→ demo `traefik/whoami` services in per-service namespaces (`flight-cart-be-ns`, ...).

The owner is learning infrastructure concepts. When making changes, explain the
"why" in plain language, not only the code.

## Layout

| Path | Purpose |
| --- | --- |
| `1-platform/` | VPC, subnet, Cloud NAT, firewall, 2 GKE clusters, reserved IPs |
| `2-k8s/` | ingress-nginx + demo apps per cluster (`modules/cluster-apps`) |
| `3-cloudflare/` | Optional: DNS record + Origin CA cert |
| `4-edge/` | HAProxy MIG, health check, LB chain, Cloud Armor (optional, `enable_armor`), HTTPS |
| `5-observability/` | Prometheus (both clusters), Grafana at `/grafana`, dashboards as JSON in `dashboards/`, Helm values in `values/` |
| `bootstrap/setup-gcp.sh` | One-time: state bucket, CI service account, Workload Identity Federation |
| `lab.sh` | Entry point: `up`, `down`, `plan`, `outputs`, `check`, `status`, `test` (`up`/`down`/`plan` take an optional stage) |
| `scripts/install-terraform-cloudshell.sh` | Installs terraform into `~/bin` on Cloud Shell; `lab.sh` calls it when needed |
| `docs/runbook.md` | Full walkthrough: setup, testing, logs, teardown, troubleshooting |
| `scripts/ci-write-tfvars.sh` | Builds `lab.tfvars` from env vars in CI |
| `.github/workflows/` | `pr.yml` (check + plan), `lab.yml` (manual up/down, nightly down) |

Stages are separate Terraform roots with state in GCS under `infra-lab/<stage>`.
Later stages read earlier ones through `terraform_remote_state`. Changing or removing
an output in one stage means updating every stage that reads it.

## Commands

The owner's workflow is two commands in Google Cloud Shell, from `infra-lab/`:
`./lab.sh up` and `./lab.sh down`. On a local run (not CI), `up` first does the one-time
setup itself: installs terraform, writes `lab.tfvars` from gcloud, enables the Cloud Resource
Manager and Service Usage APIs, creates the `<project>-tfstate` bucket. Keep that automatic.

- `./lab.sh check` — fmt + validate, no cloud access. Run before every commit.
- `./lab.sh plan [stage]` — read-only against the real project.
- `./lab.sh up [stage]` / `./lab.sh down [stage]` — create / destroy everything, or one
  stage (`1`-`5`, `platform`, `k8s`, `cloudflare`, `edge`, `observability`). Stages refuse to run out of order.
- `./lab.sh outputs [stage]` — print a stage's outputs.

## Rules

- **Never run `./lab.sh up`, `./lab.sh down`, `terraform apply` or `terraform destroy`
  without the owner explicitly asking in this session.** They cost money or delete things.
- Never commit `*.tfstate`, `lab.tfvars`, `.terraform/`, keys or tokens (see `.gitignore`).
  Secrets come from environment variables or GitHub secrets only.
- Keep `terraform fmt` clean; CI fails otherwise.
- Make changes on a branch and open a pull request; `pr.yml` runs checks and a plan.
- Keep provider versions pinned in each stage's `required_providers`; bump deliberately.
- Keep every resource destroyable by `./lab.sh down` (no `prevent_destroy`, no deletion protection).

## Known state

- The lab has been applied end to end in Cloud Shell (stages 1, 2, 4 and 5, Cloudflare off).
- `enable_armor` defaults to `false`: new projects often have a `SECURITY_POLICIES` quota of 0,
  so the Cloud Armor policy cannot be created until the quota is raised.
- Stage 5 (observability) is applied and Grafana loads. Lessons so far: nodes default to e2-standard-2
  (on e2-medium the monitoring stack leaves no CPU for rolling updates: `Insufficient cpu`, Helm
  `context deadline exceeded`); ingress-nginx needs `metrics-per-undefined-host` or requests to the LB IP are
  not counted. Not yet confirmed on a live lab: the Cloud Monitoring panels, HAProxy scraping, and whether
  ingress-nginx counts the 503 it returns for a Service with no pods.
- HAProxy health-checks ingress-nginx's `/healthz` (not the apps) with a proper Host, and the instance group has a
  PROACTIVE update policy (surge 3, no unavailable) so template changes roll out by themselves. Neither has been
  confirmed on a live lab yet. Before this, the check was a bare `GET /flight/cart` that got a 308 and never failed.
- Stray duplicate copies of `lab.sh`, `lab.yml`, `pr.yml`, `setup-gcp.sh`, `github-setup.md`
  and two zips sit at the repository root; the real files are under `infra-lab/`.
- ingress-nginx was retired upstream in March 2026; it is kept here only to mirror the
  real setup. Migrating to a Gateway API implementation is a planned exercise.
- Cloudflare zone settings (SSL Full (strict), Always Use HTTPS) are set manually in
  the dashboard, not by Terraform.

## Ideas backlog

- Migrate ingress-nginx to Gateway API (e.g. Envoy Gateway) in one cluster, compare.
- Add alert rules (5xx ratio, p95 latency, unhealthy HAProxy, crash loops) to stage 5.
- Cloud Armor rate limiting keyed on `CF-Connecting-IP`.
- Manage Cloudflare zone settings and WAF rules in Terraform.
- Post the plan as a pull request comment instead of the job summary.
- Tighten the CI service account's IAM roles.
