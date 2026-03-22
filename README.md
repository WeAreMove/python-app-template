# `python-app-template`

A bootstrap template for deploying Python applications to our Kubernetes cluster on AWS. This guide walks you through every step — from cloning the template to having your app live.

---

## Overview

The deployment flow works like this:

```
1. Clone template → 2. Run prepare.sh → 3. Configure GitHub → 4. Configure AWS → 5. Push code → 6. Auto-deploys to K8s
```

Each push to GitHub triggers a GitHub Actions pipeline that:
- Builds a Docker image and pushes it to Amazon ECR
- Determines the target environment based on the branch
- Deploys to the Kubernetes cluster using Kustomize

---

## Prerequisites

Before you begin, make sure you have:

- `bash` (required)
- `gsed` / `perl` — for placeholder replacement (see [Install Dependencies](#install-dependencies))
- `whiptail` — optional, provides a nicer interactive setup UI
- Access to the AWS account and ECR repository
- GitHub repository admin access (to configure secrets/variables)

### Install Dependencies

**macOS:**
```bash
brew install gnu-sed whiptail
```

**Ubuntu / Debian:**
```bash
sudo apt install whiptail perl
```
> GNU sed is the default on Linux — no extra install needed.

---

## Step 1 — Bootstrap the Project

Clone this template repository and run the setup script. It will replace all `_PLACEHOLDER_` values across every file in the repo.

### Interactive mode (recommended)
```bash
./prepare.sh
```
Uses `whiptail` if installed, otherwise prompts via `read`.

### CLI mode
```bash
./prepare.sh \
  --project-name my-app \
  --prod-domain example.com \
  --stage-domain stage.example.com \
  --cors-domains "example.com api.example.com"
```

The script collects, validates, and replaces these four values everywhere:

| Placeholder | Description | Example |
|---|---|---|
| `_PROJECT_NAME_` | Your app's name (`a-zA-Z0-9_-` only) | `my-app` |
| `_PROD_DOMAIN_` | Production domain | `example.com` |
| `_STAGE_DOMAIN_` | Staging domain | `stage.example.com` |
| `_CORS_DOMAINS_` | Allowed CORS origins (space/comma/semicolon/pipe separated) | `example.com api.example.com` |

CORS domains are normalized automatically into `domain1.com|domain2.com` format.

> **Important:** Commit your repo before running the script. `.git/` and `prepare.sh` itself are excluded from replacements.

---

## Step 2 — Configure the GitHub Repository

Go to your repository on GitHub: **Settings → Secrets and variables → Actions**

### Repository Variables

**Settings → Secrets and variables → Actions → Variables**

| Variable | Description |
|---|---|
| `ACCOUNTID` | AWS Account ID |
| `DEPLOYMENT` | Project name — must match `_PROJECT_NAME_` |
| `OWNER_NAME` | Cluster owner, must be `move-infra` |
| `REGION` | AWS region (e.g. `eu-central-1`) |
| `REPO` | ECR repository name (e.g. `app/_PROJECT_NAME_`) |

### Repository Secrets

**Settings → Secrets and variables → Actions → Secrets**

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key for CI |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key for CI |
| `SLACK_WEBHOOK_URL` | Slack webhook URL for deploy notifications (optional) |
| `SLACK_WEBHOOK_CHANNEL` | Slack channel for notifications (optional) |

### Deploy Keys

The cluster uses an SSH key to `git pull` your repository during deployment. You need to generate a key pair, add the public half to GitHub, and store the private half in AWS (covered in Step 4).

**1. Generate the key pair** (run this once on your machine):
```bash
ssh-keygen -t ed25519 -f ~/.ssh/my-app-k8s-pull.key
```
This creates two files:
- `~/.ssh/my-app-k8s-pull.key` — private key (goes to AWS Secrets Manager)
- `~/.ssh/my-app-k8s-pull.key.pub` — public key (goes to GitHub)

**2. Copy the public key:**
```bash
cat ~/.ssh/my-app-k8s-pull.key.pub
```

**3. Add it to GitHub:** go to **Settings → Deploy Keys → Add deploy key**, paste the public key, enable **Allow read access**, and save.

---

## Step 3 — Create the ECR Repository

The pipeline pushes Docker images to Amazon ECR. The repository must exist before the first deployment.

1. Go to **AWS Console → ECR → Repositories → Create repository**
2. Set the name to match your `REPO` GitHub variable exactly (e.g. `app/my-app`)
3. Keep it **Private** and create it

> If your team manages infrastructure via Terraform or a shared infra repo, check there first — the repository may need to be provisioned that way instead.

---

## Step 4 — Configure AWS Secrets Manager

The Kubernetes cluster reads your app's runtime secrets from AWS Secrets Manager. You must create secrets for each environment **before** running your first deployment.

Create two secrets, one per environment:

```
move-infra/kubernetes/prod/_PROJECT_NAME_
move-infra/kubernetes/stage/_PROJECT_NAME_
```

Each secret must contain the following keys:

| Key | Description |
|---|---|
| `APP_ENV` | `production` or `dev` |
| `AWS_ACCESS_KEY_ID` | AWS key for your app's runtime use |
| `AWS_SECRET_ACCESS_KEY` | AWS secret for your app's runtime use |
| `NEW_RELIC_LICENSE_KEY` | New Relic license key |
| `NEW_RELIC_ACCOUNT` | New Relic account ID |
| `NEW_RELIC_API_KEY` | New Relic API key |
| `GH_SSH_KEY` | Base64-encoded private SSH deploy key (see below) |

### `GH_SSH_KEY` — the private deploy key

This is the private key you generated in the Deploy Keys step above. Run this to get the value to paste into Secrets Manager:

```bash
cat ~/.ssh/my-app-k8s-pull.key | base64 | tr -d '\n'
```

The value must be a single line with no line breaks.

---

## Step 5 — Deploy

Once everything above is configured, deployment is **fully automatic on every push**.

### Branch → Environment Mapping

| Branch | Environment | Cluster | Kubernetes Namespace |
|---|---|---|---|
| `release` | Production | `prod` | `_PROJECT_NAME_` |
| `main` / `master` | Staging | `stage` | `_PROJECT_NAME_-stage` |
| Any other branch | Dev (dynamic) | `stage` | `_PROJECT_NAME_-<branch-name>` |

> Feature branches get their own isolated namespace on the staging cluster automatically.

### What happens on each push

1. **Build** — Docker image is built and pushed to ECR with tags: `<branch>`, `<git-sha>`, and `<branch>-<git-sha>`
2. **Choose target** — The pipeline determines which overlay and cluster to deploy to based on the branch name
3. **Deploy** — Kustomize applies the appropriate overlay to the target namespace; kubectl waits for the rollout
4. **Notify** — A Slack message is sent with the deployment status and live URLs (if Slack is configured)

You can also trigger a deployment manually from **Actions → _PROJECT_NAME_ - Deploy → Run workflow**.

---

## Repository Structure

```
.
├── prepare.sh              # Bootstrap script — run once to initialize the project
├── Dockerfile              # Python 3.12 Alpine image with Supervisor, New Relic, ZSH
├── entrypoint.sh           # Container entrypoint
├── supervisord.conf        # Supervisor process config
├── docker_build/           # Dotfiles and configs copied into the container
├── kubernetes/
│   ├── base/               # Base Kubernetes manifests (Deployment, Service, Ingress, etc.)
│   └── overlays/
│       ├── dev/            # Overlay for feature branch deployments
│       ├── staging/        # Overlay for main/master branch
│       └── release/        # Overlay for production (release branch)
└── .github/
    └── workflows/
        ├── build-and-deploy.yaml   # Main pipeline: build image + choose target + deploy
        ├── build-image.yaml        # Standalone image build (no deploy)
        └── run-deploy.yaml         # Reusable deploy workflow called by build-and-deploy
```
