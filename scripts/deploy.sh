#!/usr/bin/env bash
#
# Package the nested templates and deploy the root stack for one environment.
#
# Usage:
#   scripts/deploy.sh <dev|prod> [--stage network|full] [--execute] [--yes]
#
#   --stage     network = VPC and security groups only; full = every stack
#               (default: full)
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
# Safety: refuses to deploy a stage that includes a template marked
# `ImplementationStatus: PLACEHOLDER`, and refuses to move a full stack back
# to the network stage (that would delete every non-network nested stack).
#
# The full stage also deploys networking/waf.yml as <stack>-waf in us-east-1,
# because a CloudFront-scoped WAF web ACL can only be created there, and
# passes its WebAclArn output to the root stack.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN_DIR="$REPO_ROOT/cloudformation"
BUILD_DIR="$REPO_ROOT/.build"
AWS_REGION="${AWS_REGION:-us-east-2}"
WAF_REGION="us-east-1" # fixed by AWS for Scope: CLOUDFRONT web ACLs

# Templates the network stage creates; keep in sync with the stacks in
# cloudformation/main.yml that have no `Condition: IsFullDeployment`.
NETWORK_STAGE_TEMPLATES=(
  network/vpc.yml
  network/security-groups.yml
)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,27p' "$0"; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 2
ENVIRONMENT="$1"; shift
case "$ENVIRONMENT" in
  dev|prod) ;;
  -h|--help) usage 0 ;;
  *) fail "Environment must be 'dev' or 'prod', got '$ENVIRONMENT'." ;;
esac

STAGE=full
EXECUTE=false
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      [[ $# -ge 2 ]] || fail "--stage needs a value: network or full."
      STAGE="$2"; shift ;;
    --stage=*) STAGE="${1#--stage=}" ;;
    --execute) EXECUTE=true ;;
    --yes) ASSUME_YES=true ;;
    *) fail "Unknown argument: $1" ;;
  esac
  shift
done
case "$STAGE" in
  network|full) ;;
  *) fail "Stage must be 'network' or 'full', got '$STAGE'." ;;
esac

PARAMS_FILE="$REPO_ROOT/environments/$ENVIRONMENT/parameters.json"
[[ -f "$PARAMS_FILE" ]] || fail "Parameter file not found: $PARAMS_FILE"

# --- Guard: never deploy scaffolding -----------------------------------------
# The network stage checks only the templates it creates; the full stage checks
# every template, including main.yml.
if [[ "$STAGE" == network ]]; then
  stage_templates=()
  for t in "${NETWORK_STAGE_TEMPLATES[@]}"; do stage_templates+=("$CFN_DIR/$t"); done
  placeholders="$(grep -lE '^[[:space:]]*ImplementationStatus:[[:space:]]*PLACEHOLDER' "${stage_templates[@]}" || true)"
else
  placeholders="$(grep -rlE '^[[:space:]]*ImplementationStatus:[[:space:]]*PLACEHOLDER' "$CFN_DIR" || true)"
fi
if [[ -n "$placeholders" ]]; then
  echo "Refusing to deploy the $STAGE stage: these templates are still placeholders:" >&2
  echo "$placeholders" | sed "s|$REPO_ROOT/|  - |" >&2
  [[ "$STAGE" == full ]] && echo "Use --stage network to deploy only the implemented network stacks." >&2
  exit 1
fi

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed."
done
[[ -n "${CFN_ARTIFACT_BUCKET:-}" ]] || fail "CFN_ARTIFACT_BUCKET must be set."

PROJECT_NAME="$(jq -r '.Parameters.ProjectName' "$PARAMS_FILE")"
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
WAF_STACK_NAME="${STACK_NAME}-waf"

# --- Guard: never shrink a full stack ----------------------------------------
# Switching DeploymentStage from full to network would make CloudFormation
# delete the database, load balancer and every other full-stage stack.
current_stage="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Parameters[?ParameterKey=='DeploymentStage'].ParameterValue | [0]" \
  --output text 2>/dev/null || true)"
if [[ "$STAGE" == network && "$current_stage" == full ]]; then
  fail "$STACK_NAME is deployed with DeploymentStage=full; deploying the network stage would delete every non-network stack. Use scripts/destroy.sh to tear it down instead."
fi

"$REPO_ROOT/scripts/validate.sh"

if [[ "$ENVIRONMENT" == prod && "$ASSUME_YES" != true ]]; then
  read -r -p "Type the stack name ($STACK_NAME) to continue with a PROD $STAGE-stage deployment: " reply
  [[ "$reply" == "$STACK_NAME" ]] || fail "Confirmation did not match. Aborting."
fi

# bash 3.2 compatible (macOS default): no mapfile
PARAM_OVERRIDES=()
while IFS= read -r line; do PARAM_OVERRIDES+=("$line"); done \
  < <(jq -r '.Parameters | to_entries[] | "\(.key)=\(.value)"' "$PARAMS_FILE")
PARAM_OVERRIDES+=("DeploymentStage=$STAGE")
TAGS=()
while IFS= read -r line; do TAGS+=("$line"); done \
  < <(jq -r '.Tags | to_entries[] | "\(.key)=\(.value)"' "$PARAMS_FILE")

# --- WAF (full stage only, us-east-1) ----------------------------------------
if [[ "$STAGE" == full ]]; then
  WAF_DEPLOY_ARGS=(
    --region "$WAF_REGION"
    --stack-name "$WAF_STACK_NAME"
    --template-file "$CFN_DIR/networking/waf.yml"
    --parameter-overrides
      "ProjectName=$PROJECT_NAME"
      "Environment=$ENVIRONMENT"
      "LogRetentionDays=$(jq -r '.Parameters.LogRetentionDays' "$PARAMS_FILE")"
    --tags "${TAGS[@]}" "Component=waf"
    --no-fail-on-empty-changeset
  )
  if [[ "$EXECUTE" != true ]]; then
    WAF_DEPLOY_ARGS+=(--no-execute-changeset)
  fi

  echo "==> Deploying WAF stack $WAF_STACK_NAME in $WAF_REGION (execute=$EXECUTE)"
  aws cloudformation deploy "${WAF_DEPLOY_ARGS[@]}"

  web_acl_arn="$(aws cloudformation describe-stacks \
    --region "$WAF_REGION" --stack-name "$WAF_STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='WebAclArn'].OutputValue | [0]" \
    --output text 2>/dev/null || true)"
  if [[ -z "$web_acl_arn" || "$web_acl_arn" == None ]]; then
    fail "$WAF_STACK_NAME has no WebAclArn output yet, so the root stack change set cannot be created. Execute the WAF change set (or re-run with --execute) first."
  fi
  PARAM_OVERRIDES+=("WebAclArn=$web_acl_arn")
fi

# --- Root stack (AWS_REGION) -------------------------------------------------
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

echo "==> Deploying stack $STACK_NAME ($STAGE stage) in $AWS_REGION (execute=$EXECUTE)"
aws cloudformation deploy "${DEPLOY_ARGS[@]}"

if [[ "$EXECUTE" != true ]]; then
  echo "Change set created but not executed. Review it in the CloudFormation console,"
  echo "then re-run with --execute."
fi
