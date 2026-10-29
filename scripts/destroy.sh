#!/usr/bin/env bash
#
# Delete the root stack (and all nested stacks) for one environment.
#
# Usage:
#   scripts/destroy.sh <dev|prod> [--allow-prod]
#
# Always asks for the stack name to be typed as confirmation.
# prod additionally requires --allow-prod.
#
# Resources with DeletionPolicy Retain/Snapshot (S3 buckets, final RDS
# snapshot) survive stack deletion and must be cleaned up manually if they are
# no longer needed - they continue to incur cost.
#
# Not touched: the separate <stack>-ecr (us-east-2) and <stack>-waf (us-east-1)
# stacks. Delete them with `aws cloudformation delete-stack` if needed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-2}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,16p' "$0"; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 2
ENVIRONMENT="$1"; shift
case "$ENVIRONMENT" in
  dev|prod) ;;
  -h|--help) usage 0 ;;
  *) fail "Environment must be 'dev' or 'prod', got '$ENVIRONMENT'." ;;
esac

ALLOW_PROD=false
for arg in "$@"; do
  case "$arg" in
    --allow-prod) ALLOW_PROD=true ;;
    *) fail "Unknown argument: $arg" ;;
  esac
done

if [[ "$ENVIRONMENT" == prod && "$ALLOW_PROD" != true ]]; then
  fail "Refusing to destroy prod without --allow-prod."
fi

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed."
done

PARAMS_FILE="$REPO_ROOT/environments/$ENVIRONMENT/parameters.json"
PROJECT_NAME="$(jq -r '.Parameters.ProjectName' "$PARAMS_FILE")"
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

if ! aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "Stack $STACK_NAME does not exist in $AWS_REGION. Nothing to do."
  exit 0
fi

echo "This permanently deletes stack '$STACK_NAME' in $AWS_REGION and all of its nested stacks."
read -r -p "Type the stack name to confirm: " reply
[[ "$reply" == "$STACK_NAME" ]] || fail "Confirmation did not match. Aborting."

aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$STACK_NAME"
echo "==> Waiting for deletion to complete..."
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$STACK_NAME"
echo "Stack $STACK_NAME deleted. Remember to review retained resources (S3, RDS snapshots)"
echo "and the separate ${STACK_NAME}-ecr and ${STACK_NAME}-waf stacks."
