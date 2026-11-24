# Runbook: build, test and tear down the lab

Short version (see the [README](../README.md)): in Cloud Shell, from `infra-lab/`,
run `./lab.sh up` to build and `./lab.sh down` to destroy. This page is the long version.

## 1. Prerequisites

- A GCP project with **billing enabled** and the **Owner** role for you.
- [Cloud Shell](https://shell.cloud.google.com) (has `gcloud` and `kubectl`).
- A GitHub clone of this repo. Nothing else to install: `./lab.sh up` installs Terraform.

## 2. Set up from scratch

```bash
git clone https://github.com/SINRA12/gcpProject.git
cd gcpProject/infra-lab
gcloud config set project YOUR_PROJECT_ID
./lab.sh up
```

The first `up` runs these steps before touching any infrastructure. Each is skipped
once done:

| Step | Why it is needed |
| --- | --- |
| Install Terraform into `~/bin` | Cloud Shell has only an install stub. `~/bin` is in your home directory, which survives restarts. |
| Write `lab.tfvars` | Project from `gcloud config`, bucket `<project>-tfstate`, `my_ips` = this shell's IP. Never committed. |
| Enable Cloud Resource Manager + Service Usage APIs | Terraform needs them to enable the other APIs. A fresh project has them off, which gives `Error 403 ... Cloud Resource Manager API has not been used`. |
| Create the state bucket | Terraform keeps its record of what exists there (versioned, so a bad apply can be recovered). |

Then it applies the six stages in order (about 25-35 minutes in total). When it finishes it prints
the load balancer IP. Stage 6 (Jenkins and Argo CD) needs a GitHub token and the code on `main`: read
[section 9](#9-deploying-an-application-jenkins-and-argo-cd) before the first `up` that includes it.
`up` also creates the Artifact Registry repository `lab-apps` (once; `down` leaves it).

## 3. Test it

From Cloud Shell:

```bash
./lab.sh test
```

From your own laptop (the load balancer is public, Cloud Armor is off by default):

```bash
curl -s http://LB_IP/flight/cart
curl -s http://LB_IP/flight/checkin
curl -s http://LB_IP/payment
curl -s -o /dev/null -w "%{http_code}\n" http://LB_IP/unknown
```

Expected: the first three return a `whoami` reply (`Name: flight-cart-be`,
`flight-checkin-be`, `payment-be`); `/unknown` returns `404` from HAProxy. To see which
hop handled the request:

```bash
curl -s http://LB_IP/flight/cart | grep -E "Name|Hostname|X-Haproxy-Node|X-Forwarded-For"
```

`Hostname` is the app pod, `X-Haproxy-Node` the HAProxy VM. Both alternate between two.

Find `LB_IP` with `./lab.sh outputs platform` (`lb_ip`). Allow 3-5 minutes after `up`;
earlier requests can return 502.

## 4. See how a request flows

```
You → public IP:80 → Classic ALB → HAProxy VM (private IP)
    → flight/payment ingress IP (internal LB) → ingress-nginx → app pod
```

Follow one request through every hop by sending a recognisable URL:

```bash
curl -s "http://LB_IP/flight/cart?trace=demo1" > /dev/null
```

| Hop | Where to look |
| --- | --- |
| Load balancer | Console → **Logging → Logs Explorer**, query `resource.type="http_load_balancer"` (100% sampled). Shows client IP, URL, status, latency, backend. |
| HAProxy | `gcloud compute instances list --filter="name~haproxy"`, then `gcloud compute ssh NAME --zone ZONE --tunnel-through-iap` and `sudo journalctl -t haproxy -n 30 --no-pager`. Shows which backend (`flight_cluster`, `payment_cluster`) was chosen. |
| ingress-nginx | `gcloud container clusters get-credentials flight-cluster --zone asia-southeast1-a`, then `kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=20` |
| App pod | `kubectl logs -n flight-cart-be-ns -l app=flight-cart-be --tail=20` |

Visual views in the console:

- **Network Intelligence Center → Network Topology**: VPC, load balancer, HAProxy VMs and clusters.
- **Network services → Load balancing**: the external load balancer (frontend, URL map, backend health) and the two internal ones GKE creates for the ingresses.
- **Kubernetes Engine → Workloads / Services & Ingress**: pods, the ingress controller, the Ingress path rules.
- **Network Intelligence Center → Connectivity Tests**: checks a path against routes and firewall rules.

Check HAProxy health as the load balancer sees it:

```bash
gcloud compute backend-services get-health haproxy-backend --global
```

## 5. Explore one stage at a time

```bash
./lab.sh plan platform
./lab.sh up platform
./lab.sh outputs platform
./lab.sh up k8s
./lab.sh up edge
./lab.sh up observability
./lab.sh up delivery
```

After stage 1, compare the Terraform with the console: VPC network → `lab-vpc`, Cloud NAT,
Firewall, Kubernetes Engine clusters, VPC network → IP addresses (two `RESERVED` internal
ingress IPs and the global `lab-lb-ip`). After stage 2:

```bash
kubectl get svc -n ingress-nginx        # EXTERNAL-IP = the reserved ingress IP
kubectl get pods -A
kubectl get ingress -A
```

Ingress IPs are internal, so test a cluster from inside it, or tunnel with
`kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80` and
`curl localhost:8080/flight/cart`.

## 6. Tear down

```bash
./lab.sh down
```

Destroys delivery, observability, edge, k8s, then platform (before platform it waits, up to 5 minutes, until GKE has
removed the internal load balancer pieces it created, so the VPC can be deleted). Check nothing is left:

```bash
./lab.sh status          # every stage should show 0 resources
gcloud container clusters list
gcloud compute instances list
gcloud compute forwarding-rules list
gcloud compute addresses list
```

What stays on purpose: the state bucket, the Artifact Registry repository `lab-apps` with its images (Git
records which tag should run, so the image must outlive the lab), the enabled APIs and Cloud Logging data.
Check Billing → Reports the next day to confirm charges stopped.

## 7. Cloud Armor

Cloud Armor is off by default (`enable_armor = false`). New projects often have a
`SECURITY_POLICIES` quota of 0, and creating the policy fails with
`Quota 'SECURITY_POLICIES' exceeded. Limit: 0.0`. With it off the load balancer accepts
traffic from anywhere, which is acceptable for demo pods, so always run `./lab.sh down`.

To turn it on: request the quota under **IAM & Admin → Quotas & System Limits**
(filter "Security policies"), then set `enable_armor = true` in `lab.tfvars` and run
`./lab.sh up edge`. The policy blocks SQL injection patterns (rule 900), allows `my_ips`
(and Cloudflare's ranges when enabled), and denies everyone else with a 403. If you get
403s later, your IP changed: update `my_ips` and run `./lab.sh up edge`.

## 8. Observability (Prometheus and Grafana)

Stage 5 adds the monitoring a production setup would have. Open Grafana at
`http://LB_IP/grafana/`, user `admin`, and read the password with:

```bash
./lab.sh outputs observability
```

(`terraform output` alone hides it as `<sensitive>`; `lab.sh` prints it on the last line. It is stored in
Terraform's state, so do not paste it into chat or commit it, and a rebuild generates a new one.)

(Or without the public route: `kubectl port-forward -n monitoring svc/kps-grafana 3000:80` against the
flight cluster, then open `http://localhost:3000/grafana/`.) Dashboards are in the **infra-lab** tag:

| Dashboard | What it answers |
| --- | --- |
| Edge: load balancer and HAProxy | Requests, 4xx, 5xx and latency percentiles at the public load balancer and at HAProxy; HAProxy backends up |
| Apps by ingress (rate, errors, duration) | The same per app (`flight-cart-be`, `payment-be`, ...), measured at ingress-nginx. The Cluster selector switches between flight and payment |
| Request path: latency and errors by hop | One graph per signal with the load balancer, HAProxy and ingress-nginx side by side, so you can see where time or errors are added |

The kube-prometheus-stack dashboards for nodes and pods (CPU, memory, restarts) come with it.

### Where the numbers come from

| Hop | Source | How it is collected |
| --- | --- | --- |
| Classic load balancer | Google's `loadbalancing.googleapis.com/https/*` metrics (request count by response code, `total_latencies`, `backend_latencies`) | Already in Cloud Monitoring. Grafana reads them with its Cloud Monitoring data source, using the GKE node's service account. |
| HAProxy VMs | HAProxy's built-in exporter on `:8404/metrics` (`haproxy_frontend_http_responses_total`, `haproxy_backend_response_time_average_seconds`, `haproxy_backend_up`) | The flight cluster's Prometheus finds the VMs through the Compute Engine API and scrapes them over the VPC. |
| ingress-nginx pods | `nginx_ingress_controller_requests` (labelled by status and Ingress) and request/response duration histograms | Each cluster's Prometheus discovers the pods and scrapes port 10254. |
| Nodes and pods | node-exporter, kube-state-metrics, cAdvisor | Installed by kube-prometheus-stack. |

The `whoami` apps expose no metrics of their own, so per-app numbers come from ingress-nginx,
which labels every request with its Ingress. ingress-nginx only counts requests whose `Host` is defined in an
Ingress unless `metrics-per-undefined-host` is on (stage 2 turns it on, because these Ingresses have no host and
clients use the load balancer IP). HAProxy's health checks go to ingress-nginx's `/healthz`, which nginx answers
itself, so they do not appear in the per-app panels.

How the pieces connect: Prometheus runs in both clusters. Grafana runs only in the flight cluster and
queries the payment cluster's Prometheus through an internal load balancer (`payment-prometheus-ip`).
Prometheus keeps 12 hours of data in the pod, with no disk, so history is lost when it restarts.

### Try it

Generate traffic, then watch the dashboards (refresh is 30 seconds):

```bash
while true; do for p in /flight/cart /flight/checkin /payment /unknown; do curl -s -o /dev/null http://LB_IP$p; done; sleep 0.3; done
```

Make a real 5xx appear, then undo it. Point the `flight-checkin-be` Service at a wrong port: the pods stay
Ready, so ingress-nginx keeps sending traffic, the connection is refused and it answers 502 (the nginx log shows
`connect() failed (111: Connection refused)` for each pod). The errors show at the load balancer and HAProxy, and
in the Apps dashboard (Cluster selector on "Prometheus (flight)") once ingress-nginx metrics are on:

```bash
gcloud container clusters get-credentials flight-cluster --zone asia-southeast1-a
kubectl patch svc flight-checkin-be -n flight-checkin-be-ns --type merge -p '{"spec":{"ports":[{"port":80,"targetPort":9999}]}}'
curl -i http://LB_IP/flight/checkin
kubectl patch svc flight-checkin-be -n flight-checkin-be-ns --type merge -p '{"spec":{"ports":[{"port":80,"targetPort":8080}]}}'
```

Scaling the app to zero (`kubectl scale deploy/flight-checkin-be -n flight-checkin-be-ns --replicas=0`) gives a 503
from nginx instead. The load balancer and HAProxy count it. Whether ingress-nginx counts that kind of 503 in its own
metrics has not been confirmed on this lab, so use the port patch above to see errors at every hop. Scale back to 2
afterwards (or the next apply restores it).

For latency, `whoami` can delay its reply: add `?wait=800ms` to a path in the traffic loop
(for example `/flight/cart?wait=800ms`) and watch the latency panels rise at each hop.

### Troubleshooting observability

| Symptom | Cause and fix |
| --- | --- |
| Pods stay `Pending` (`kubectl get pods -A`), events say `Insufficient cpu`; or `up k8s` times out with `context deadline exceeded` on ingress-nginx | The nodes are out of CPU, which happens on `e2-medium` once the monitoring stack is installed. The default is now `e2-standard-2`. If your `lab.tfvars` still sets `node_machine_type = "e2-medium"`, change or remove it, then run `./lab.sh down` and `./lab.sh up` (the clusters are recreated). |
| Load balancer panels are empty | The Cloud Monitoring data source cannot authenticate (check Connections, Data sources, Cloud Monitoring, Save and test), or there has been no traffic yet. Metrics take a minute or two to appear. |
| HAProxy panels are empty | Check Prometheus targets (`kubectl port-forward -n monitoring svc/kps-prometheus 9090:9090`, then Status, Targets, job `haproxy`). If the VMs are not listed, the node service account may lack permission to list instances. If they are down, run `sudo haproxy -vv \| grep PROMEX` on a VM: without it, the HAProxy build has no built-in exporter and the metrics block was skipped. |
| `/grafana/` redirects to a wrong address | `grafana_root_url` does not match how you reach it (for example behind Cloudflare). Set it in `lab.tfvars`. |
| Ingress panels stay empty although `kubectl logs` shows requests | ingress-nginx leaves out metrics for hosts no Ingress defines. These Ingresses have no host and clients use the load balancer IP, so stage 2 sets `metrics-per-undefined-host`. Check that the controller args include it: `kubectl get deploy -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].args}'`. |
| Grafana password shows as `<sensitive>` | `terraform output` hides it. Use `./lab.sh outputs observability` (last line) or `terraform -chdir=5-observability output -raw grafana_admin_password`. |
| Want to see what ingress-nginx records, bypassing Prometheus | `for p in $(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name \| cut -d/ -f2); do kubectl get --raw "/api/v1/namespaces/ingress-nginx/pods/$p:10254/proxy/metrics" \| grep '^nginx_ingress_controller_requests{'; done`, and `kubectl logs -n ingress-nginx` for the access log. (`kubectl run -it` often fails to attach to short-lived pods, so use `get --raw`.) |
| No dashboards | `kubectl get configmap -n monitoring -l grafana_dashboard=1` should list three; Grafana's sidecar loads them within a minute. |

Grafana is public while Cloud Armor is off. It needs the generated password and has sign-up and anonymous
access disabled, but turn Armor on (section 7) or use the port-forward if you leave the lab running.

## 9. Deploying an application (Jenkins and Argo CD)

Stage 6 sets up a delivery pipeline for a sample Java service, `flight-booking-be`. It uses the split many
companies use: **Jenkins is CI** (turns a commit into a tested, scanned image) and **Argo CD is CD** (makes the
cluster match what Git says). The hand-over between them is one commit.

```
push to main
   |
   v
Jenkins (its own VM) looks at Git every 2 minutes
   |  mvn test -> build the image -> Trivy scan -> push to Artifact Registry
   |  last step: commit "gitops: flight-booking-be -> <tag>", which edits
   v
gitops/flight/flight-booking-be/values.yaml   <-- Argo CD (in the flight cluster) checks Git every minute
                                                    |  renders charts/java-service with that file
                                                    v
                                      Deployment, Service, Ingress, PodMonitor, PodDisruptionBudget
browser -> load balancer -> HAProxy -> ingress-nginx -> flight-booking-be pods   (/flight/booking)
```

| Piece | Where | What it does |
| --- | --- | --- |
| Java service | `apps/flight-booking-be/` | Spring Boot 4 on Java 17. `POST /flight/booking/bookings` makes a pretend booking and counts it (`bookings_total{result}`, `booking_amount_total`, `booking_duration_seconds`). Health and metrics are on port 9090, never through the ingress. |
| Pipeline | `apps/flight-booking-be/Jenkinsfile`, `ci/*.sh` | Test, build with Jib (no Docker needed), scan, push, commit the tag. The tag is a fingerprint of the app folder, so identical code gets the identical tag and nothing is committed twice. |
| Chart | `charts/java-service/` | One reusable chart: probes, resources, non-root and read-only filesystem, a rolling update with no gap, replicas kept on different nodes, a PodMonitor for Prometheus, a PodDisruptionBudget. |
| What runs | `gitops/flight/flight-booking-be/values.yaml` | The image tag (written by Jenkins) and the settings. Argo CD watches this file. |
| Jenkins + Argo CD | `6-delivery/` | A Jenkins VM configured entirely as code, Argo CD installed slim in the flight cluster, and the Argo CD Application. |

Jenkins has no access to the cluster: its service account can only write to the registry. Argo CD runs inside
the cluster, so nothing outside needs credentials to deploy.

### Before the first run

1. **Merge to `main` on GitHub.** Jenkins and Argo CD read GitHub's `main` branch, not your laptop or your clone.
   (To try the chart from a branch, set `gitops_revision = "feat/app-delivery"` in `lab.tfvars`; Jenkins only
   records tags on `main`, so the pipeline's last two steps do nothing on a branch.)
2. **Create a GitHub token** so Jenkins can commit the tag: GitHub, Settings, Developer settings, Personal access
   tokens, Fine-grained tokens, Generate new token. Repository access: only `SINRA12/gcpProject`. Permissions:
   Repository permissions, **Contents: Read and write**. Choose a short expiry. Then, in Cloud Shell, paste it at
   the silent prompt (it stays out of your shell history and out of any file):

```bash
read -rs GITHUB_TOKEN && export GITHUB_TOKEN
```

3. Run `./lab.sh up` (or `./lab.sh up delivery` if stages 1, 2 and 5 are already up). The token reaches only
   Terraform's state and the Jenkins VM; never commit it. Without it, stage 6 still builds and pushes images, but
   nothing new is ever deployed.

### What happens after `up`

| About | What |
| --- | --- |
| 0-2 min | Argo CD is installed and syncs the Application. The pods fail with `ImagePullBackOff`, because the tag in Git is still `unset`. That is expected. |
| 3-6 min | The Jenkins VM finishes installing (JDK, Jenkins, plugins, Trivy) and Jenkins starts. |
| +2 min | Jenkins finds the repository (it scans every 2 minutes) and builds `main`. The first build is slow (about 5-8 minutes): Maven and Trivy download what they need. |
| then | Jenkins commits the new tag. Within about a minute Argo CD rolls the pods one at a time. `./lab.sh test` now shows `/flight/booking/` as 200. |

Logins and commands: `./lab.sh outputs delivery` prints both passwords and these commands.

```bash
# From your laptop, both at once (needs gcloud logged in to the lab project, kubectl, gke-gcloud-auth-plugin):
#   LAB_PROJECT=<project id> ./scripts/laptop-access.sh
# Jenkins is then http://localhost:8080, Argo CD http://localhost:8081; the script prints both passwords.
# Sync from the command line instead of the UI (Argo CD CLI, with the script running):
#   argocd login localhost:8081 --plaintext --username admin --password <argo password>
#   argocd app sync flight-booking-be
# Without the CLI: kubectl -n argocd annotate application flight-booking-be argocd.argoproj.io/refresh=hard
# By default both UIs are public, each on its own IP, with HTTPS (self-signed certificates: the browser warns once,
# accept it) and their own logins (user admin). ./lab.sh outputs delivery prints the addresses and passwords:
#   jenkins_url  https://<ip>:8443/        argocd_url  https://<ip>/
# Anyone on the internet can reach the login pages (ui_source_ranges = ["0.0.0.0/0"]); restrict it with CIDRs in
# lab.tfvars, or set ui_source_ranges = [] for no public IPs. Then use the tunnel and port-forward below
# (scripts/laptop-access.sh opens both). Each public UI uses one regional IN_USE_ADDRESSES (4 in a new project).
# Jenkins through the tunnel: run this, leave it open, then open http://localhost:8080 (Cloud Shell: Web Preview,
# change the port to 8080).
gcloud compute ssh jenkins --zone ZONE --project PROJECT --tunnel-through-iap -- -L 8080:localhost:8080

# Argo CD: point kubectl at the flight cluster once, then forward the port and open http://localhost:8081
# (Cloud Shell: Web Preview on port 8081). User admin.
gcloud container clusters get-credentials flight-cluster --zone ZONE --project PROJECT
kubectl port-forward -n argocd svc/argocd-server 8081:80
```

In Jenkins, open `flight-booking-be`, then `main`, then Console Output. **Scan Repository Now** skips the
2-minute wait. In Argo CD, open the `flight-booking-be` application to see the objects and their health.

### Try it

```bash
curl http://LB_IP/flight/booking/                         # which version, on which pod; repeat to see both pods
curl -X POST -H 'Content-Type: application/json' -d '{"flight":"GA123","passengers":2}' \
  http://LB_IP/flight/booking/bookings                    # 201 confirmed, 402 declined (5% of calls) or 500
curl -X POST -H 'Content-Type: application/json' -d '{"flight":"GA123","passengers":2}' \
  'http://LB_IP/flight/booking/bookings?simulate=error&delayMs=300'    # force an outcome and a delay
```

In Grafana, Explore, data source `Prometheus (flight)` (business numbers come from the app itself, section 8 shows
the technical ones):

```
sum by (result) (rate(bookings_total[5m]))
sum(rate(booking_amount_total[5m])) * 60
histogram_quantile(0.95, sum by (le) (rate(booking_duration_seconds_bucket[5m])))
```

The Apps dashboard should also list `flight-booking-be`, from ingress-nginx's own request metrics.

### Exercises

1. **Ship a change.** Change the app (for example a message in `BookingController`), push to `main`. Jenkins builds,
   commits a new tag, and Argo CD rolls the pods. Watch with `kubectl get pods -n flight-booking-be-ns -w`; the new
   version shows in `curl .../flight/booking/`. Then change only `gitops/.../values.yaml` (for example
   `BOOKING_LATENCY_MS: "300"`): Argo CD rolls it, but Jenkins builds nothing, because that commit only touches `gitops/`.
2. **Self-heal.** `kubectl scale deploy flight-booking-be -n flight-booking-be-ns --replicas=5`. Argo CD notices that the
   cluster no longer matches Git and scales it back to 2.
3. **Roll back.** `git revert` the latest `gitops: flight-booking-be -> ...` commit and push. Argo CD redeploys the
   previous tag (its image is still in the registry).
4. **Make a 5xx on purpose.** Set `BOOKING_FAILURE_RATE: "0.3"` in the values file, push, wait for the rollout, then run
   a POST loop and watch the technical panels and `bookings_total{result="error"}` together:

```bash
while true; do curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"flight":"GA123","passengers":2}' http://LB_IP/flight/booking/bookings; sleep 0.5; done
```

5. **Spread.** `kubectl get pods -n flight-booking-be-ns -o wide`: the two replicas are on different nodes (the chart's
   topology spread rule). Cordon one node (`kubectl cordon NODE`) and delete a pod to see the strict rule leave it
   `Pending`; `kubectl uncordon NODE` lets it schedule.

### Troubleshooting delivery

| Symptom | Cause and fix |
| --- | --- |
| `Quota IN_USE_ADDRESSES exceeded` | Public IPs are capped at 4 per region on new projects. Stage 1 now makes the GKE nodes private so they use none. If it still happens, `gcloud compute addresses list` and `gcloud compute instances list` show what holds them. |
| Jenkins or Argo CD URL times out | Wait a few minutes (Argo CD's load balancer takes about 2 minutes, Jenkins' VM about 5). If you narrowed `ui_source_ranges`, your IP may not be in it. Failing that, set it to `[]` and use the tunnel and port-forward. A creation error `IN_USE_ADDRESSES exceeded` means the region's 4 public IPs are used. |
| Cannot reach Jenkins through the tunnel | The VM is still installing. SSH in (`gcloud compute ssh jenkins --zone ZONE --tunnel-through-iap`), then `sudo journalctl -u google-startup-scripts -n 50 --no-pager` for the install, `sudo systemctl status jenkins` and `sudo journalctl -u jenkins -n 50 --no-pager`. |
| `systemctl status jenkins` shows `activating (auto-restart)` again and again | Jenkins is exiting at once. `sudo journalctl -u jenkins -n 15 --no-pager` says why. The message `older than the minimum required version (Java 21)` means the VM has too old a JDK: this Jenkins needs Java 21 or 25, which is why the VM runs Debian 13 with `openjdk-21`. After changing the image or the packages, run `./lab.sh up delivery` (the VM is replaced). |
| The `flight-booking-be` job is missing | The Configuration as Code file failed to load. `sudo journalctl -u jenkins \| grep -i -E 'casc\|configuration'` on the VM; in Jenkins, Manage Jenkins, Configuration as Code shows the same. |
| Job exists but there is no build on `main` | `main` on GitHub does not have `apps/flight-booking-be/Jenkinsfile` yet (not merged), or press Scan Repository Now. |
| Stage "Build image and scan" fails | Either Trivy found a CRITICAL vulnerability with a fix (the log lists it: bump the base image or a dependency), or it could not download its database. For the second, re-run the build. To loosen the gate, edit `--severity` in the `Jenkinsfile`. |
| "Push image" fails with 401 or 403 | The Jenkins service account lacks `roles/artifactregistry.writer` on the repository, or the repository does not exist: `gcloud artifacts repositories list --location REGION`, and run `./lab.sh up delivery` again. |
| "Record new tag in Git" says no token was given | `GITHUB_TOKEN` was not set when stage 6 ran. Export it and run `./lab.sh up delivery` (this updates the VM's metadata), then on the VM `sudo google_metadata_script_runner startup` so Jenkins reads it. |
| The same stage fails with a Git permission error (403) | The token is expired, is for another repository, or lacks Contents: Read and write. If `main` is protected, the push is refused: allow this token to bypass, or leave `gitops/` unprotected in a lab. |
| Application `OutOfSync` or `ComparisonError` in Argo CD | `kubectl describe application -n argocd flight-booking-be`. Usual causes: the repository or path is not on `main` yet, or a chart error (`helm template charts/java-service --set image.repository=x --set image.tag=y` shows it). |
| Pods in `ImagePullBackOff` | The tag in Git is still `unset` (Jenkins has not recorded one: see its build), or the nodes cannot read the registry: `kubectl describe pod -n flight-booking-be-ns` shows the pull error. The nodes use the default compute service account, which stage 6 grants `artifactregistry.reader`. |
| Sync error `no matches for kind "PodMonitor"` | Stage 5 (the monitoring chart installs that CRD) is not applied. |
| A pod stays `Pending` with a topology spread message | One node cannot fit it (CPU) while the rule forbids sharing a node. Free some CPU, add a node, or set `topologySpread.whenUnsatisfiable: ScheduleAnyway` in the values file. |
| Pod `OOMKilled` | Raise `resources.limits.memory` in the values file (the heap is 70% of the limit). |

Lab shortcuts to know about: the Jenkins admin password and the GitHub token travel as instance metadata (a team would
keep them in Secret Manager); Jenkins plugins are installed at their newest compatible version on the first boot, not
pinned (list them afterwards in Manage Jenkins, Plugins, and pin them); both UIs are public by default (`ui_source_ranges`) over HTTPS with self-signed certificates, protected only by their logins; with `ui_source_ranges = []` Jenkins is tunnel-only and Argo CD runs without TLS behind `kubectl port-forward`. Jenkins builds on its own VM.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `terraform` prints an install hint | Cloud Shell's stub is first on `PATH`. Run `export PATH=$HOME/bin:$PATH && hash -r`, or just use `./lab.sh`, which does this itself. |
| `Cloud Resource Manager API has not been used` (403) on apply | `./lab.sh up` enables it and waits 60 seconds. If you hit it anyway: `gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com`, wait a couple of minutes, run again. `plan` on an empty project cannot show this, only `apply` can. |
| `Quota 'SECURITY_POLICIES' exceeded` | See [Cloud Armor](#7-cloud-armor). Keep `enable_armor = false` or request the quota. |
| `Missing newline after argument` in `lab.tfvars` | Stray text on a line, usually pasted into the editor. Each setting must be on its own line. |
| `terraform fmt` differences in `./lab.sh check` | Run `terraform fmt -recursive`. CI fails on them. |
| Google page "Error: Server Error ... try again in 30 seconds" | No healthy HAProxy VM behind the load balancer: they are still starting or were just recreated (about 3 minutes). Check `gcloud compute backend-services get-health haproxy-backend --global`. If they stay unhealthy, SSH in (IAP) and run `sudo systemctl status haproxy` and `sudo haproxy -c -f /etc/haproxy/haproxy.cfg`. |
| Plain "404 Not Found / The resource could not be found" on `/grafana` | That is HAProxy's own 404: the VMs run an older config without the `/grafana` route. Apply stage 4 (`./lab.sh up edge`); the instance group then replaces the VMs by itself (a few minutes, no downtime). |
| `resourceNotReady` creating `haproxy-backend` | Google had not finished creating the health check. Run `./lab.sh up edge` again. |
| 502 right after `up` | HAProxy VMs are still installing (about 2 minutes) or the load balancer is still warming up. Check `get-health` above. |
| 403 from the load balancer | Only with Cloud Armor on: your IP is not in `my_ips`. |
| `down` fails: `network ... is already being used by ... k8s2-...` | GKE left load balancer pieces behind. `down` now waits up to 5 minutes for them to go; if they stay, see [Leftover GKE load balancer pieces](#leftover-gke-load-balancer-pieces). |
| ingress-nginx chart version not found | `helm search repo ingress-nginx/ingress-nginx --versions`, then set `ingress_chart_version` in `2-k8s/modules/cluster-apps/variables.tf`. |
| State lock error | Another run (local or CI) is in progress. Wait; `terraform force-unlock` only if sure nothing is running. |
| Session died during `up` or `down` | Run the same command again; Terraform continues from the saved state. |
| Home directory wiped (Cloud Shell resets after about 120 days idle) | Clone again and run `./lab.sh up`/`down`. The state is in the bucket, so nothing is lost. |

## Leftover GKE load balancer pieces

GKE creates `k8s2-...` forwarding rules, backend services, health checks, network endpoint
groups and firewall rules for each ingress Service and normally removes them itself. If
they survive and block the VPC delete, list them (they are outside Terraform's view):

```bash
gcloud compute forwarding-rules list --filter="name~^k8s2-"
gcloud compute backend-services list --filter="name~^k8s2-"
gcloud compute health-checks list --filter="name~^k8s2-"
gcloud compute network-endpoint-groups list --filter="name~^k8s2-"
gcloud compute firewall-rules list --filter="name~^k8s2-"
```

Delete only names starting with `k8s2-` and containing `ingress-nginx`, in this order
(each blocks the next): forwarding rule, backend service, network endpoint group, health
check, firewall rule. Use `--region` or `--zone` as the list output shows, then run
`./lab.sh down platform` again.

## Known limitations

- **HAProxy checks ingress-nginx, not the apps.** The health check is `GET /healthz` on each ingress, so a broken
  app does not take its backend out of rotation: requests reach ingress-nginx, which answers 5xx (and that is what
  the dashboards measure). HAProxy only marks a backend down when ingress-nginx itself stops answering.
- **Template changes roll out by themselves, slowly.** The HAProxy instance group has an update policy: after
  `./lab.sh up edge` with a changed config it starts up to 3 new VMs, waits until they are healthy, then removes
  the old ones. Watch it with `gcloud compute instance-groups managed list-instances haproxy-mig --region asia-southeast1`.
- **Prometheus data is not kept.** 12 hours, in the pod, no disk.
- **Cloud Armor is off by default**, so the load balancer and Grafana are reachable from the internet (section 7).
- **Delivery reads GitHub, not your machine.** Jenkins and Argo CD follow `main`; Jenkins commits image tags straight
  to `main` with no pull request (fine for a lab, blocked by branch protection). Jenkins polls every 2 minutes and
  Argo CD checks every minute, so a push takes a few minutes to arrive.
- **The first build after `up` is slow and the first sync fails on purpose**: the pods wait in `ImagePullBackOff`
  until Jenkins has recorded a real tag (section 9). Later `up`s deploy the recorded tag at once, because the
  registry keeps the image.
- **Stage 6 has not been confirmed on a live lab yet**: the Jenkins install script, the Job DSL job, the Trivy
  gate and the Jib push to Artifact Registry are untested together.

## Cost

GKE nodes (4 × e2-standard-2), the cluster fee, 2 HAProxy VMs, the Jenkins VM (e2-standard-2 plus a 30 GB disk),
load balancer forwarding rules, Cloud NAT and reserved IPs bill by the hour while the lab is up. The state bucket
and the image registry cost close to nothing. Keep a budget alert on the project.
