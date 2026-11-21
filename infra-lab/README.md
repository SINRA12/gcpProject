# Infra lab as code

A learning lab that rebuilds an enterprise request path on Google Cloud with Terraform:

```
User → Cloudflare (optional) → Google Classic Application Load Balancer (+ Cloud Armor, optional)
     → HAProxy (managed instance group) → ingress-nginx (flight / payment GKE clusters)
     → demo services in their own namespaces
```

Build it at the start of a session, destroy it at the end, and pay only for the hours
it exists.

## Quick start (Google Cloud Shell)

Everything runs in [Cloud Shell](https://shell.cloud.google.com): no local installs.
You need a GCP project with billing enabled and the Owner role on it.

**First time only**, clone the repo and pick your project:

```bash
git clone https://github.com/tiketRakesh/gcpSetUp.git
cd gcpSetUp/infra-lab
gcloud config set project YOUR_PROJECT_ID
```

(Until the feature branches are merged into `main`, clone the branch that has everything:
`git clone --branch feat/observability https://github.com/tiketRakesh/gcpSetUp.git`.)

**Then, every session, two commands:**

```bash
./lab.sh up      # build everything, about 20-30 minutes
./lab.sh down    # destroy everything, about 10-15 minutes. Always run this when you finish.
```

On the very first `up`, the script also does the one-time setup by itself, so there is
nothing to prepare by hand:

- installs `terraform` into `~/bin` (Cloud Shell only ships an install stub),
- writes `lab.tfvars` from your gcloud project and this shell's public IP,
- enables the Cloud Resource Manager and Service Usage APIs,
- creates the versioned state bucket `<project>-tfstate`.

Every one of those steps is skipped when it is already done, so later runs go straight to
building. Keep the Cloud Shell tab open while `up` or `down` runs; a closed or idle
session stops Terraform half way (it is safe to run the command again).

When `up` finishes it prints the load balancer IP. Give it 3-5 minutes, then:

```bash
./lab.sh test                          # curls the load balancer on every route
curl http://LB_IP/flight/cart          # or from your own laptop, using the printed IP
```

Grafana is at `http://LB_IP/grafana/` (user `admin`; `./lab.sh outputs observability` prints
the generated password). It shows 4xx, 5xx and response time at the load balancer,
HAProxy and ingress-nginx. See the observability section of the runbook.

The full walkthrough, with testing, logs and troubleshooting, is in
[docs/runbook.md](docs/runbook.md).

> Run commands from `infra-lab/`. The copies of `lab.sh`, `lab.yml`, `pr.yml` and
> `setup-gcp.sh` at the top of the repository are old duplicates; ignore them.

## Settings (lab.tfvars)

`lab.tfvars` is created for you and is never committed. Edit it to change a default:

| Setting | Default | Meaning |
| --- | --- | --- |
| `project_id`, `state_bucket` | from gcloud / `<project>-tfstate` | Where the lab runs and keeps Terraform state |
| `region`, `zone` | `asia-southeast1`, `asia-southeast1-a` | Set `LAB_REGION` before the first `up` to change the generated file |
| `my_ips` | this Cloud Shell's IP | CIDRs Cloud Armor lets through (only used when `enable_armor = true`) |
| `node_machine_type` | `e2-standard-2` | GKE node size. `e2-medium` is cheaper but runs out of CPU with the monitoring stack (changing it recreates the clusters) |
| `enable_armor` | `false` | Cloud Armor needs a quota that new projects often lack, see the runbook |
| `enable_cloudflare` | `false` | Optional stage 3, see below |

## Stages

| Stage | Creates | Reads from |
| --- | --- | --- |
| `1-platform` | VPC, subnet, Cloud NAT, firewall rules, `flight` and `payment` GKE clusters, reserved internal ingress IPs, global load balancer IP | — |
| `2-k8s` | ingress-nginx (2 replicas, internal LB on the reserved IP) and demo `whoami` services, in both clusters | 1 |
| `3-cloudflare` (optional) | Proxied DNS record to the load balancer IP, Cloudflare Origin CA certificate | 1 |
| `4-edge` | HAProxy instance template + regional MIG, health check, load balancer chain, Cloud Armor (when enabled), HTTPS when Cloudflare is on | 1, 3 |
| `5-observability` | Prometheus in both clusters, Grafana at `/grafana` on the public IP, dashboards as code | 1, 2 |

Each stage is its own Terraform root, because the Kubernetes and Helm providers need
the clusters to exist before they can be configured. State lives in a GCS bucket
(`infra-lab/<stage>`), with locking and versioning, so local runs and GitHub Actions
share it safely.

## Running one stage at a time

Handy for learning: apply a stage, inspect it in the GCP console or with `gcloud`,
then move on. A stage can be `1`-`5` or `platform`, `k8s`, `cloudflare`, `edge`, `observability`.

```bash
./lab.sh plan platform     # preview stage 1 only (read-only)
./lab.sh up platform       # create VPC, NAT, firewall, 2 GKE clusters, reserved IPs
./lab.sh outputs platform  # see what stage 1 publishes for later stages
# ...explore in the console, then continue:
./lab.sh up k8s            # ingress-nginx + demo apps
./lab.sh up edge           # HAProxy and the load balancer
./lab.sh up observability  # Prometheus + Grafana + dashboards
./lab.sh down observability  # tear down in reverse order, one stage at a time
```

A stage refuses to run if the stage it reads from has not been applied, and
`down <stage>` refuses while a later stage still depends on it. Other commands:
`./lab.sh check` (fmt + validate, no cloud access), `./lab.sh status`, `./lab.sh test`.

## Enabling Cloudflare

One-time, in the Cloudflare dashboard (persists for free between sessions):

1. Add your domain (Free plan) and switch the registrar's nameservers to Cloudflare's.
2. **SSL/TLS → Overview**: **Full (strict)**.
3. **SSL/TLS → Edge Certificates**: **Always Use HTTPS**, minimum TLS 1.2.
4. Create an API token with **Zone → DNS → Edit** and **Zone → SSL and Certificates → Edit**.

Then set `enable_cloudflare = true`, `domain`, `cloudflare_zone_id` and `my_ips = []`
in `lab.tfvars` (or the matching GitHub variables), export `CLOUDFLARE_API_TOKEN`
(or add it as a GitHub secret), and run `up`. The DNS record follows the load
balancer IP automatically on every rebuild.

## GitHub Actions (optional)

The `PR` workflow runs checks and a plan on pull requests; the `Lab` workflow can build or
destroy the lab from the Actions tab and destroys it every night. Setup is in
[docs/github-setup.md](docs/github-setup.md). CI does its own setup, so the first-run
steps in `lab.sh` are skipped there.

## Cost

GKE nodes and cluster fees, VMs, load balancer forwarding rules and NAT all bill by
the hour. `./lab.sh down` removes everything. Keep a budget alert on the project. The
state bucket stays and costs close to nothing.

## Troubleshooting

See [docs/runbook.md](docs/runbook.md#troubleshooting) for the errors seen so far
(API not enabled, Cloud Armor quota, stray text in `lab.tfvars`, destroy ordering, 502s).

ingress-nginx was retired upstream in March 2026. It is kept to mirror the real setup;
migrating to Gateway API is a good follow-up exercise. See `CLAUDE.md` for working on this
repo with Claude Code.
