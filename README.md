
# `python-app-template`

Project bootstrap for python apps in kubernetes.

Leverages `prepare.sh` placeholder replacement to kickstart your project.

----------

## What It Does

`prepare.sh`:

1.  Collects required project values:
    
    -   `_PROJECT_NAME_`
    -   `_PROD_DOMAIN_`
    -   `_STAGE_DOMAIN_`
    -   `_CORS_DOMAINS_`
2.  Validates:
    
    -   Project name (`a-zA-Z0-9_-`)
    -   Domains / subdomains
    -   CORS domains list
3.  Normalizes CORS domains into:
    

```basic
domain1.com|domain2.com|domain3.com

```

4.  Recursively replaces placeholders in all files in the current directory  
    (excluding `.git/`)

----------

## Usage

### Interactive

bash

```bash
./prepare.sh

```

Uses `whiptail` if installed, otherwise falls back to `read`.

----------

### CLI

bash

```bash
./prepare.sh \
  --project-name my-app \
  --prod-domain example.com \
  --stage-domain stage.example.com \
  --cors-domains "example.com api.example.com"

```

----------

## Placeholders Replaced

Placeholder

Replaced With

`_PROJECT_NAME_`

Project name

`_PROD_DOMAIN_`

Production domain

`_STAGE_DOMAIN_`

Stage domain

`_CORS_DOMAINS_`

`domain1

----------

# Requirements

## Required

-   `bash`

## Optional (Recommended)

-   `whiptail` (UI prompts)
-   `gsed` (GNU sed — recommended on macOS)
-   `perl` (fallback replacement engine)

----------

## Install Dependencies

### macOS

bash

```bash
brew install gnu-sed whiptail

```

### Ubuntu / Debian

bash

```bash
sudo apt install whiptail perl

```

GNU sed is default on Linux.

----------

# GitHub Repository Configuration

Go to:

```armasm
Settings → Secrets and variables → Actions

```

----------

## 1️⃣ Repository Variables

Location:

```gams
Settings → Secrets and variables → Actions → Variables

```

Variable

Description

`ACCOUNTID`

AWS Account ID

`DEPLOYMENT`

Project name (should match `_PROJECT_NAME_`)

`OWNER_NAME`

Used in cluster settings during deploy

`REGION`

AWS region (e.g. `eu-west-1`)

`REPO`

ECR repository name

----------

## 2️⃣ Repository Secrets

Location:

```gams
Settings → Secrets and variables → Actions → Secrets

```

Secret

Description

`AWS_ACCESS_KEY_ID`

AWS access key

`AWS_SECRET_ACCESS_KEY`

AWS secret key

`SLACK_WEBHOOK_CHANNEL`

Slack channel

`SLACK_WEBHOOK_URL`

Slack webhook URL

----------

## 3️⃣ Deploy Keys

Location:

```mathematica
Settings → Deploy Keys

```

Add:

-   Public key corresponding to `GH_SSH_KEY`
-   Enable **Read access**
-   Used for `git pull` during deployment

----------

# AWS Secrets Manager Configuration

Secrets must exist under:

```awk
kubernetes/prod/_PROJECT_NAME_
kubernetes/stage/_PROJECT_NAME_

```

Replace `_PROJECT_NAME_` with your actual project name.

----------

## Required Secret Keys

Key

Description

`APP_ENV`

`prod` or `stage`

`AWS_ACCESS_KEY_ID`

AWS key

`AWS_SECRET_ACCESS_KEY`

AWS secret

`NEW_RELIC_LICENSE_KEY`

New Relic license

`NEW_RELIC_ACCOUNT`

New Relic account ID

`NEW_RELIC_API_KEY`

New Relic API key

`GH_SSH_KEY`

Base64 encoded public GitHub deploy key

----------

## GH_SSH_KEY Format

Must be:

-   Public key
-   Base64 encoded
-   Single line
-   No line breaks

Generate:

bash

```bash
cat id_rsa.pub | base64 | tr -d '\n'
```

----------

# Important Notes

-   `.git/` is automatically excluded from replacements.
-   Commit your repository before running the script.
-   Ensure AWS Secrets exist before running deployment workflows.