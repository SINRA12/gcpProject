# Runbook: build, test and tear down the lab

Short version (see the [README](../README.md)): in Cloud Shell, from `infra-lab/`,
run `./lab.sh up` to build and `./lab.sh down` to destroy. This page is the long version.

## 1. Prerequisites

- A GCP project with **billing enabled** and the **Owner** role for you.
- [Cloud Shell](https://shell.cloud.google.com) (has `gcloud` and `kubectl`).
- A GitHub clone of this repo. Nothing else to install: `./lab.sh up` installs Terraform.

## 2. Set up from scratch

```bash
git clone https://github.com/tiketRakesh/gcpSetUp.git
cd gcpSetUp/infra-lab
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

Then it applies the five stages in order (about 20-30 minutes in total). When it finishes it prints
the load balancer IP.

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

Destroys observability, edge, k8s, then platform (before platform it waits, up to 5 minutes, until GKE has
removed the internal load balancer pieces it created, so the VPC can be deleted). Check nothing is left:

```bash
./lab.sh status          # every stage should show 0 resources
gcloud container clusters list
gcloud compute instances list
gcloud compute forwarding-rules list
gcloud compute addresses list
```

What stays on purpose: the state bucket, the enabled APIs and Cloud Logging data.
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

## Cost

GKE nodes (4 × e2-standard-2), the cluster fee, 2 HAProxy VMs, load balancer forwarding rules,
Cloud NAT and reserved IPs bill by the hour while the lab is up. The state bucket costs
close to nothing. Keep a budget alert on the project.
