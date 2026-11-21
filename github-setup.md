# Putting the lab on GitHub

Follow these once. Afterwards you can build and destroy the lab from the
GitHub Actions tab, from Cloud Shell, or by asking Claude Code.

## 1. Create the repository and push

On your machine (or Cloud Shell), from the unzipped `infra-lab` folder:

```bash
git init -b main
git add .
git status        # confirm: no *.tfstate, no lab.tfvars, no .terraform/
git commit -m "Initial infra lab"
```

Create an empty repository on github.com (no README, so there's nothing to merge),
then:

```bash
git remote add origin https://github.com/<you>/infra-lab.git
git push -u origin main
```

Or with the GitHub CLI: `gh repo create infra-lab --private --source=. --push`.

In the repo's **Settings → Code security**, turn on secret scanning and push protection.

## 2. Bootstrap the GCP project (once)

In Cloud Shell, logged in as the project owner:

```bash
./bootstrap/setup-gcp.sh <project-id> <you>/infra-lab
```

It creates the state bucket, the `terraform-ci` service account, and the Workload
Identity Federation that lets only this repository's workflows act as that account.
No key file is created anywhere. It prints the values for the next step.

## 3. Add repository variables

**Settings → Secrets and variables → Actions → Variables**: add each value the
bootstrap script printed (`GCP_PROJECT_ID`, `GCP_REGION`, `GCP_ZONE`,
`TF_STATE_BUCKET`, `GCP_WIF_PROVIDER`, `GCP_SA_EMAIL`, `LAB_MY_IPS`,
`ENABLE_CLOUDFLARE`). For Cloudflare, also `CF_DOMAIN`, `CF_ZONE_ID` and the
**secret** `CLOUDFLARE_API_TOKEN`.

These are variables rather than secrets because none of them grants access by itself.

## 4. Protect main

**Settings → Branches → Add rule** for `main`: require a pull request before merging,
and require the `check` status check to pass. Now every change goes through review
and CI, as in a real team.

## 5. Run it

- **Actions → Lab → Run workflow → up**: builds the lab (about 20 minutes).
- **Actions → Lab → Run workflow → down**: destroys it.
- The same workflow runs `down` every night at 17:00 UTC; edit the cron in
  `.github/workflows/lab.yml` to change or remove it.
- Every pull request runs `check`, and `plan` once the variables exist; the plan
  appears in the run's summary page.

Local runs keep working too: put the same values in `lab.tfvars` and use `./lab.sh`.
Both share the GCS state, and Terraform's state lock stops them from colliding.

## 6. Continue with Claude Code

```bash
cd infra-lab
claude
```

Claude Code reads `CLAUDE.md` automatically, so it knows the architecture, the
commands, and the rule never to apply or destroy without your say-so. Good first
prompts: "run ./lab.sh check and fix anything that fails", or "add Prometheus and
Grafana to the flight cluster on a new branch and open a PR".
