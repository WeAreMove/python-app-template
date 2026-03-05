#!/usr/bin/env bash

set -e

# Regex definitions
PROJECT_REGEX='^[a-zA-Z0-9_-]+$'
DOMAIN_REGEX='^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$'


# Helpers functions

detect_replacer() {
  if command -v gsed >/dev/null 2>&1; then
    REPLACER="gsed"
  elif command -v perl >/dev/null 2>&1; then
    REPLACER="perl"
  elif command -v sed >/dev/null 2>&1; then
    REPLACER="sed"
  else
    echo "No suitable replacer found (gsed/perl/sed)." >&2
    exit 1
  fi
}

escape_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&@]/\\&/g'
}

replace_in_file() {
  local file="$1"

  local p1 p2 p3 p4
  p1=$(escape_replacement "$PROJECT_NAME")
  p2=$(escape_replacement "$PROD_DOMAIN")
  p3=$(escape_replacement "$STAGE_DOMAIN")
  p4=$(escape_replacement "$CORS_DOMAINS")

  case "$REPLACER" in
    gsed)
      gsed -i \
        "s@_PROJECT_NAME_@$p1@g;
         s@_PROD_DOMAIN_@$p2@g;
         s@_STAGE_DOMAIN_@$p3@g;
         s@_CORS_DOMAINS_@$p4@g" \
        "$file"
      ;;

    sed)
      sed -i '' \
        "s@_PROJECT_NAME_@$p1@g;
         s@_PROD_DOMAIN_@$p2@g;
         s@_STAGE_DOMAIN_@$p3@g;
         s@_CORS_DOMAINS_@$p4@g" \
        "$file"
      ;;

    perl)
      perl -0777 -pi -e "
        s/_PROJECT_NAME_/\Q$PROJECT_NAME\E/g;
        s/_PROD_DOMAIN_/\Q$PROD_DOMAIN\E/g;
        s/_STAGE_DOMAIN_/\Q$STAGE_DOMAIN\E/g;
        s/_CORS_DOMAINS_/\Q$CORS_DOMAINS\E/g;
      " "$file"
      ;;
  esac
}

error() {
  echo "Error: $1" >&2
  exit 1
}

validate_project() {
  [[ "$1" =~ $PROJECT_REGEX ]] || error "Invalid project name."
}

validate_domain() {
  [[ "$1" =~ $DOMAIN_REGEX ]] || error "Invalid domain: $1"
}

normalize_cors() {
  local input="$1"

  # Replace separators (space , ; |) with |
  input=$(echo "$input" | tr ',; ' '|||' | tr -s '|' )

  # Remove leading/trailing |
  input="${input#|}" # before
  input="${input%|}" # after

  IFS='|' read -ra DOMAINS <<< "$input"

  for d in "${DOMAINS[@]}"; do
    validate_domain "$d"
  done

  echo "$input"
}

############################
# Parse CLI parameters
############################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --prod-domain)
      PROD_DOMAIN="$2"
      shift 2
      ;;
    --stage-domain)
      STAGE_DOMAIN="$2"
      shift 2
      ;;
    --cors-domains)
      CORS_DOMAINS_RAW="$2"
      shift 2
      ;;
    *)
      error "Unknown parameter: $1"
      ;;
  esac
done

# Interactive input (if missing)

ask_input() {
  local var_name="$1"
  local label="$2"

  if command -v whiptail >/dev/null 2>&1; then
    value=$(whiptail --inputbox "$label" 10 60 3>&1 1>&2 2>&3)
  else
    read -rp "$label: " value
  fi

  echo "$value"
}

[ -z "$PROJECT_NAME" ] && PROJECT_NAME=$(ask_input "PROJECT_NAME" "Enter project name")
[ -z "$PROD_DOMAIN" ] && PROD_DOMAIN=$(ask_input "PROD_DOMAIN" "Enter production domain")
[ -z "$STAGE_DOMAIN" ] && STAGE_DOMAIN=$(ask_input "STAGE_DOMAIN" "Enter staging domain")
[ -z "$CORS_DOMAINS_RAW" ] && CORS_DOMAINS_RAW=$(ask_input "CORS_DOMAINS" "Enter CORS domains (space , ; | separated)")

# Validation

validate_project "$PROJECT_NAME"
validate_domain "$PROD_DOMAIN"
validate_domain "$STAGE_DOMAIN"

CORS_DOMAINS=$(normalize_cors "$CORS_DOMAINS_RAW")
echo "CORS normalized to: $CORS_DOMAINS"

# Replace placeholders

echo "Detecting replacement engine..."
detect_replacer
echo "Using: $REPLACER"

echo "Replacing placeholders..."

find . -type f -not \( -path "./.git/*" -o -iname 'prepare.sh' \) -print0 |
while IFS= read -r -d '' file; do
  replace_in_file "$file"
done

echo "Done ✅"