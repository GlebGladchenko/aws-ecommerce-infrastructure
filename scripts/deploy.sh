#!/usr/bin/env bash
#
# Package the nested templates and deploy the root stack for one environment.
#
# Usage:
#   scripts/deploy.sh <dev|prod> [--execute] [--yes]
#
#   (default)   create a change set for review, but do not execute it
#   --execute   execute the change set after creating it
#   --yes       skip the interactive prod confirmation (CI, behind a GitHub
#               Environment approval)
#
# Required environment variables:
#   CFN_ARTIFACT_BUCKET   existing S3 bucket for packaged nested templates
# Optional:
#   AWS_REGION            defaults to us-east-2
#
# Safety: refuses to run while any template is marked
# `ImplementationStatus: PLACEHOLDER`.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN_DIR="$REPO_ROOT/cloudformation"
BUILD_DIR="$REPO_ROOT/.build"
AWS_REGION="${AWS_REGION:-us-east-2}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,20p' "$0"; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 2
ENVIRONMENT="$1"; shift
case "$ENVIRONMENT" in
  dev|prod) ;;
  -h|--help) usage 0 ;;
  *) fail "Environment must be 'dev' or 'prod', got '$ENVIRONMENT'." ;;
esac

EXECUTE=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --execute) EXECUTE=true ;;
    --yes) ASSUME_YES=true ;;
    *) fail "Unknown argument: $arg" ;;
  esac
done

PARAMS_FILE="$REPO_ROOT/environments/$ENVIRONMENT/parameters.json"
[[ -f "$PARAMS_FILE" ]] || fail "Parameter file not found: $PARAMS_FILE"

# --- Guard: never deploy scaffolding -----------------------------------------
placeholders="$(grep -rlE '^[[:space:]]*ImplementationStatus:[[:space:]]*PLACEHOLDER' "$CFN_DIR" || true)"
if [[ -n "$placeholders" ]]; then
  echo "Refusing to deploy: these templates are still placeholders:" >&2
  echo "$placeholders" | sed "s|$REPO_ROOT/|  - |" >&2
  exit 1
fi

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed."
done
[[ -n "${CFN_ARTIFACT_BUCKET:-}" ]] || fail "CFN_ARTIFACT_BUCKET must be set."

PROJECT_NAME="$(jq -r '.Parameters.ProjectName' "$PARAMS_FILE")"
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

"$REPO_ROOT/scripts/validate.sh"

if [[ "$ENVIRONMENT" == prod && "$ASSUME_YES" != true ]]; then
  read -r -p "Type the stack name ($STACK_NAME) to continue with a PROD deployment: " reply
  [[ "$reply" == "$STACK_NAME" ]] || fail "Confirmation did not match. Aborting."
fi

# bash 3.2 compatible (macOS default): no mapfile
PARAM_OVERRIDES=()
while IFS= read -r line; do PARAM_OVERRIDES+=("$line"); done \
  < <(jq -r '.Parameters | to_entries[] | "\(.key)=\(.value)"' "$PARAMS_FILE")
TAGS=()
while IFS= read -r line; do TAGS+=("$line"); done \
  < <(jq -r '.Tags | to_entries[] | "\(.key)=\(.value)"' "$PARAMS_FILE")

mkdir -p "$BUILD_DIR"
PACKAGED_TEMPLATE="$BUILD_DIR/main.$ENVIRONMENT.packaged.yml"

echo "==> Packaging nested templates to s3://$CFN_ARTIFACT_BUCKET/$STACK_NAME/"
aws cloudformation package \
  --region "$AWS_REGION" \
  --template-file "$CFN_DIR/main.yml" \
  --s3-bucket "$CFN_ARTIFACT_BUCKET" \
  --s3-prefix "$STACK_NAME" \
  --output-template-file "$PACKAGED_TEMPLATE"

DEPLOY_ARGS=(
  --region "$AWS_REGION"
  --stack-name "$STACK_NAME"
  --template-file "$PACKAGED_TEMPLATE"
  --s3-bucket "$CFN_ARTIFACT_BUCKET"
  --s3-prefix "$STACK_NAME"
  --capabilities CAPABILITY_IAM
  --parameter-overrides "${PARAM_OVERRIDES[@]}"
  --tags "${TAGS[@]}"
  --no-fail-on-empty-changeset
)
if [[ "$EXECUTE" != true ]]; then
  DEPLOY_ARGS+=(--no-execute-changeset)
fi

echo "==> Deploying stack $STACK_NAME in $AWS_REGION (execute=$EXECUTE)"
aws cloudformation deploy "${DEPLOY_ARGS[@]}"

if [[ "$EXECUTE" != true ]]; then
  echo "Change set created but not executed. Review it in the CloudFormation console,"
  echo "then re-run with --execute."
fi
