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
| `6-delivery/` | Jenkins VM (config as code, plugin list and startup script in `jenkins/`), Argo CD (slim, Helm) and its Application for `flight-booking-be` |
| `../apps/flight-booking-be/` | Sample Spring Boot service (Java 17, Maven, Jib) with its `Jenkinsfile` and `ci/` scripts. At the repository root, outside `infra-lab/` |
| `../charts/java-service/` | Reusable Helm chart that Argo CD renders |
| `../gitops/flight/flight-booking-be/values.yaml` | What Argo CD deploys. Jenkins edits `image.tag` here, one commit per build |
| `bootstrap/setup-gcp.sh` | One-time: state bucket, Artifact Registry repo, CI service account, Workload Identity Federation |
| `lab.sh` | Entry point: `up`, `down`, `plan`, `outputs`, `check`, `status`, `test` (`up`/`down`/`plan` take an optional stage) |
| `scripts/install-terraform-cloudshell.sh` | Installs terraform into `~/bin` on Cloud Shell; `lab.sh` calls it when needed |
| `docs/runbook.md` | Full walkthrough: setup, testing, logs, teardown, troubleshooting |
| `scripts/laptop-access.sh` | Opens Jenkins (IAP tunnel, :8080) and Argo CD (port-forward, :8081) on the laptop |
| `scripts/ci-write-tfvars.sh` | Builds `lab.tfvars` from env vars in CI |
| `.github/workflows/` | `pr.yml` (check + plan), `lab.yml` (manual up/down, nightly down) |

Stages are separate Terraform roots with state in GCS under `infra-lab/<stage>`.
Later stages read earlier ones through `terraform_remote_state`. Changing or removing
an output in one stage means updating every stage that reads it.

## Commands

The owner's workflow is two commands in Google Cloud Shell, from `infra-lab/`:
`./lab.sh up` and `./lab.sh down`. On a local run (not CI), `up` first does the one-time
setup itself: installs terraform, writes `lab.tfvars` from gcloud, enables the Cloud Resource
Manager and Service Usage APIs, creates the `<project>-tfstate` bucket, and (full `up` or stage 6) creates the
`lab-apps` Artifact Registry repository. Keep that automatic.

- `./lab.sh check` — fmt + validate, no cloud access. Run before every commit.
- `./lab.sh plan [stage]` — read-only against the real project.
- `./lab.sh up [stage]` / `./lab.sh down [stage]` — create / destroy everything, or one
  stage (`1`-`6`, `platform`, `k8s`, `cloudflare`, `edge`, `observability`, `delivery`). Stages refuse to run out of order.
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
  One deliberate exception: the Artifact Registry repository is created by `lab.sh`/`bootstrap`, not Terraform, so
  `down` leaves it. Git records the image tag that should run, so the image has to outlive the lab.
- The GitHub token Jenkins uses to commit image tags comes from the `GITHUB_TOKEN` environment variable only
  (`lab.sh` turns it into `TF_VAR_github_token`). Never write it to a file, a tfvars file or a commit.

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
- Stage 6 (delivery) is written and its pieces are tested separately (the app's unit tests and metrics, a Jib
  tarball build, the tag-bump script against a scratch repo, the Argo CD chart value names), but Terraform has not
  been run on it and it has not been applied on a live lab. Unconfirmed: the Jenkins startup script, the Job DSL
  job, the Trivy gate, the Jib push to Artifact Registry, Argo CD syncing the chart.
- Delivery design: Jenkins is CI only (no cluster access; its service account can only write to the registry).
  Its last step commits `image.tag` to `gitops/flight/flight-booking-be/values.yaml` on `main`; Argo CD (auto-sync,
  self-heal, prune) deploys. The tag is the git tree id of `apps/flight-booking-be`, so identical code gets the same
  tag and `bump-tag.sh` commits nothing twice; a gitops-only commit does not trigger a build. The image repository
  is passed to Argo CD by Terraform, so the project id stays out of Git. The tag starts as `unset`, so the pods sit
  in `ImagePullBackOff` until the first Jenkins build. The service is Java 17 (the
  owner's Mac JDK, `distroless/java17`); bump `java.version` and the Jib base image together to move to 21 or 25.
  The Jenkins VM is Debian 13 with JDK 21, because Jenkins 2.580 refuses to start on Java 17 (found live: the first
  `up` used Debian 12 and JDK 17, and the service restarted in a loop). Maven compiles the app there with
  `--release 17`; not yet confirmed on a live lab.
  Jenkins is reached through the IAP tunnel and has no public IP by default (found live: a public IP hit the regional
  `IN_USE_ADDRESSES` quota of 4). Setting `jenkins_ui_ips` adds a static IP, a firewall rule for those CIDRs and HTTPS
  8443 with a self-signed certificate; unconfirmed live.
- GKE nodes are private (no public IPs; they use Cloud NAT) because public nodes used the whole regional `IN_USE_ADDRESSES`
  quota of 4 and blocked Jenkins' public IP. The control plane stays public (/28 per cluster in `1-platform`), and the
  `lab-allow-gke-master-webhooks` firewall rule lets it reach webhooks on 8443/9443. Written but not yet applied on a
  live lab; if Helm installs time out on admission webhooks, check that rule first.
- GitHub only runs workflows from the repository root's `.github/workflows/`, but ours sit in
  `infra-lab/.github/workflows/` (the repo root is the folder above `infra-lab/`), so `pr.yml` and `lab.yml` probably
  never run. Unverified; check the Actions tab. The repository is `SINRA12/gcpProject`, with no `tiketRakesh/gcpSetUp` references left in the docs.
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
- Argo Rollouts canary (10%, 50%, 100%) for `flight-booking-be`, judged by a Prometheus analysis on the nginx 5xx
  ratio and p95, with automatic rollback.
- A second environment (the payment cluster as "prod") with promotion by pull request, and Argo CD registering it.
- Move the Jenkins and GitHub secrets to Secret Manager; Workload Identity for pods; pin the Jenkins plugin versions.
- A GitHub webhook instead of Jenkins polling; Jenkins build agents as Kubernetes pods.
