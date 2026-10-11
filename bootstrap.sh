#!/usr/bin/env bash
#
# Provision the AWS + GitHub prerequisites for a project created from this template:
#
#   1. ECR repository            app/<project>
#   2. S3 buckets (optional)     <prefix>-<project>-stage / -prod  (private, encrypted, versioned)
#   3. Deploy key                ed25519 key pair; public half added to the GitHub repo (read-only)
#   4. Secrets Manager           move-infra/kubernetes/{stage,prod}/<project>
#   5. GitHub variables          ACCOUNTID, DEPLOYMENT, OWNER_NAME, REGION, REPO
#
# Idempotent: existing resources are kept, and secret keys that already have a
# value are never overwritten — re-running only fills in what is missing.
#
# Run it once from the project root after ./prepare.sh, with AWS credentials
# allowed to create these resources and `gh` logged in with repo admin access.
#
# Shared secret values are read from the environment when set (otherwise they
# are created empty and listed at the end so you can fill them in):
#   APP_AWS_ACCESS_KEY_ID, APP_AWS_SECRET_ACCESS_KEY,
#   NEW_RELIC_LICENSE_KEY, NEW_RELIC_ACCOUNT, NEW_RELIC_API_KEY

set -euo pipefail

REGION="eu-central-1"
OWNER_NAME="move-infra"
BUCKET_PREFIX="move-k8s"
WITH_S3=true
WITH_GITHUB=true
DRY_RUN=false
PROJECT_NAME=""
GITHUB_REPO=""

usage() {
  cat <<EOF
Usage: ./bootstrap.sh [options]

  --project-name NAME   Project name (default: read from kubernetes/base/deployment.yml)
  --github-repo O/R     GitHub repo (default: from the git 'origin' remote)
  --region REGION       AWS region (default: $REGION)
  --bucket-prefix P     S3 bucket name prefix (default: $BUCKET_PREFIX)
  --no-s3               Don't create S3 buckets
  --no-github           Don't touch GitHub (deploy key / variables)
  --dry-run             Show what would be created, change nothing
EOF
}

error() { echo "Error: $1" >&2; exit 1; }
info()  { echo "==> $*"; }
skip()  { echo "    ✓ $*"; }
did()   { if $DRY_RUN; then echo "    + (would be) $*"; else echo "    + $*"; fi; }

# Run a mutating command, or just print it in --dry-run mode (to stderr, so
# callers' >/dev/null doesn't hide it).
# Secret values passed via --secret-string are never printed.
run() {
  if $DRY_RUN; then
    local out=() redact=false a
    for a in "$@"; do
      if $redact; then out+=("<redacted>"); redact=false; else out+=("$a"); fi
      [[ "$a" == "--secret-string" ]] && redact=true
    done
    echo "    [dry-run] ${out[*]}" >&2
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)  PROJECT_NAME="$2"; shift 2 ;;
    --github-repo)   GITHUB_REPO="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --bucket-prefix) BUCKET_PREFIX="$2"; shift 2 ;;
    --no-s3)         WITH_S3=false; shift ;;
    --no-github)     WITH_GITHUB=false; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage; error "Unknown parameter: $1" ;;
  esac
done

############################
# Pre-flight
############################

for cmd in aws jq ssh-keygen base64; do
  command -v "$cmd" >/dev/null 2>&1 || error "'$cmd' is required."
done
$WITH_GITHUB && { command -v gh >/dev/null 2>&1 || error "'gh' is required (or pass --no-github)."; }

if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME=$(awk '/^metadata:/{m=1} m && /^  name:/{print $2; exit}' kubernetes/base/deployment.yml 2>/dev/null || true)
fi
[[ -n "$PROJECT_NAME" && "$PROJECT_NAME" != "_PROJECT_NAME_" ]] \
  || error "Project name unknown — run ./prepare.sh first or pass --project-name."
[[ "$PROJECT_NAME" =~ ^[a-z0-9-]+$ ]] \
  || error "Project name must be lowercase a-z, 0-9 and '-' (ECR/S3 naming rules)."

if $WITH_GITHUB && [[ -z "$GITHUB_REPO" ]]; then
  GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)
  [[ -n "$GITHUB_REPO" ]] || error "Could not detect the GitHub repo — pass --github-repo owner/repo."
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) \
  || error "AWS credentials not working (aws sts get-caller-identity failed)."
ECR_REPO="app/${PROJECT_NAME}"
export AWS_DEFAULT_REGION="$REGION"

echo "Project:  $PROJECT_NAME"
echo "Account:  $ACCOUNT_ID ($REGION)"
$WITH_GITHUB && echo "GitHub:   $GITHUB_REPO"
$DRY_RUN && echo "Mode:     DRY RUN — nothing will be changed"
echo

############################
# 1. ECR
############################

info "ECR repository $ECR_REPO"
if aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  skip "exists"
else
  run aws ecr create-repository --repository-name "$ECR_REPO" \
    --image-tag-mutability MUTABLE >/dev/null
  did "created"
fi

############################
# 2. S3
############################

# Bucket name for an env ("" with --no-s3). Plain function: macOS ships bash 3.2 (no assoc arrays).
bucket_for() { $WITH_S3 && echo "${BUCKET_PREFIX}-${PROJECT_NAME}-$1" || echo ""; }

if $WITH_S3; then
  for env in stage prod; do
    bucket=$(bucket_for "$env")
    info "S3 bucket $bucket"
    if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
      skip "exists"
      continue
    fi
    run aws s3api create-bucket --bucket "$bucket" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    run aws s3api put-public-access-block --bucket "$bucket" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    run aws s3api put-bucket-encryption --bucket "$bucket" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    run aws s3api put-bucket-versioning --bucket "$bucket" \
      --versioning-configuration Status=Enabled
    did "created (private, encrypted, versioned)"
  done
fi

############################
# 3 + 4. Deploy key + Secrets Manager
############################

secret_name() { echo "${OWNER_NAME}/kubernetes/$1/${PROJECT_NAME}"; }

# Existing secret JSON for an env ("{}" when the secret doesn't exist yet).
existing_secret() {
  aws secretsmanager get-secret-value --secret-id "$(secret_name "$1")" \
    --query SecretString --output text 2>/dev/null || echo "{}"
}

# The same deploy key is used by both environments; reuse it if either secret has one.
GH_SSH_KEY=""
for env in stage prod; do
  GH_SSH_KEY=$(existing_secret "$env" | jq -r '.GH_SSH_KEY // empty')
  [[ -n "$GH_SSH_KEY" ]] && break
done

info "Deploy key"
if [[ -n "$GH_SSH_KEY" ]]; then
  skip "already in Secrets Manager (GH_SSH_KEY)"
else
  KEY_DIR=$(mktemp -d)
  trap 'rm -rf "$KEY_DIR"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "${PROJECT_NAME}-k8s-pull" -f "$KEY_DIR/key"
  GH_SSH_KEY=$(base64 < "$KEY_DIR/key" | tr -d '\n')
  if $WITH_GITHUB; then
    run gh repo deploy-key add "$KEY_DIR/key.pub" --repo "$GITHUB_REPO" \
      --title "${PROJECT_NAME}-k8s-pull" >/dev/null
    did "generated, public key added to $GITHUB_REPO (read-only)"
  else
    did "generated — add this public key to the repo's Deploy Keys yourself:"
    cat "$KEY_DIR/key.pub"
  fi
fi

MISSING=()
for env in stage prod; do
  name=$(secret_name "$env")
  info "Secret $name"
  [[ "$env" == "prod" ]] && app_env="production" || app_env="dev"

  # Values we can provide. Empty strings are placeholders to fill in later.
  wanted=$(jq -n \
    --arg app_env "$app_env" \
    --arg gh_ssh_key "$GH_SSH_KEY" \
    --arg aws_key "${APP_AWS_ACCESS_KEY_ID:-}" \
    --arg aws_secret "${APP_AWS_SECRET_ACCESS_KEY:-}" \
    --arg nr_license "${NEW_RELIC_LICENSE_KEY:-}" \
    --arg nr_account "${NEW_RELIC_ACCOUNT:-}" \
    --arg nr_api "${NEW_RELIC_API_KEY:-}" \
    --arg bucket "$(bucket_for "$env")" \
    '{
      APP_ENV: $app_env,
      GH_SSH_KEY: $gh_ssh_key,
      AWS_ACCESS_KEY_ID: $aws_key,
      AWS_SECRET_ACCESS_KEY: $aws_secret,
      NEW_RELIC_LICENSE_KEY: $nr_license,
      NEW_RELIC_ACCOUNT: $nr_account,
      NEW_RELIC_API_KEY: $nr_api
    } + (if $bucket != "" then {S3_BUCKET: $bucket} else {} end)')

  current=$(existing_secret "$env")
  # Keep every existing key; only fill keys that are missing or still empty.
  merged=$(jq -n --argjson cur "$current" --argjson new "$wanted" \
    '$cur + $new + ($cur | with_entries(select(.value != "")))')

  if [[ "$(jq -S . <<<"$merged")" == "$(jq -S . <<<"$current")" ]]; then
    skip "up to date"
  elif aws secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1; then
    run aws secretsmanager put-secret-value --secret-id "$name" --secret-string "$merged" >/dev/null
    did "updated (added: $(jq -rn --argjson cur "$current" --argjson m "$merged" \
      '[$m | to_entries[] | select(($cur[.key] // "") != .value) | .key] | join(", ")'))"
  else
    run aws secretsmanager create-secret --name "$name" --secret-string "$merged" >/dev/null
    did "created"
  fi

  while IFS= read -r k; do MISSING+=("$name → $k"); done \
    < <(jq -r 'to_entries[] | select(.value == "") | .key' <<<"$merged")
done

############################
# 5. GitHub variables
############################

if $WITH_GITHUB; then
  info "GitHub variables on $GITHUB_REPO"
  for kv in "ACCOUNTID=$ACCOUNT_ID" "DEPLOYMENT=$PROJECT_NAME" "OWNER_NAME=$OWNER_NAME" \
            "REGION=$REGION" "REPO=$ECR_REPO"; do
    run gh variable set "${kv%%=*}" --repo "$GITHUB_REPO" --body "${kv#*=}"
    did "${kv%%=*}=${kv#*=}"
  done
fi

############################
# Summary
############################

echo
echo "Done ✅"
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo
  echo "These secret keys are still empty — set them in AWS Secrets Manager"
  echo "(or re-run with the matching env vars exported):"
  printf '  - %s\n' "${MISSING[@]}"
fi
if $WITH_S3; then
  echo
  echo "The app's runtime AWS key (AWS_ACCESS_KEY_ID in the secret) needs access to the buckets:"
  for env in stage prod; do
    echo "  s3:GetObject, s3:PutObject, s3:DeleteObject on arn:aws:s3:::$(bucket_for "$env")/*"
    echo "  s3:ListBucket                           on arn:aws:s3:::$(bucket_for "$env")"
  done
fi
if $WITH_GITHUB; then
  echo
  echo "Still required on GitHub (not handled here): repository secrets"
  echo "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (CI) and optionally SLACK_WEBHOOK_URL / SLACK_WEBHOOK_CHANNEL,"
  echo "unless they are already provided as organization secrets."
fi
