#!/usr/bin/env bash
#
# Validate the infrastructure code locally or in CI. Makes no changes to AWS.
#
# Usage:
#   scripts/validate.sh          # offline checks: cfn-lint, parameter files, shellcheck
#   scripts/validate.sh --aws    # also run read-only `aws cloudformation validate-template`
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN_DIR="$REPO_ROOT/cloudformation"
ENV_DIR="$REPO_ROOT/environments"
AWS_REGION="${AWS_REGION:-us-east-2}"

RUN_AWS_CHECKS=false
case "${1:-}" in
  "") ;;
  --aws) RUN_AWS_CHECKS=true ;;
  -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not installed."; }

cd "$REPO_ROOT"

log "Linting CloudFormation templates (cfn-lint)"
require cfn-lint
find "$CFN_DIR" -name '*.yml' -print0 | xargs -0 cfn-lint --
echo "cfn-lint passed."

log "Validating environment parameter files"
require jq
for params in "$ENV_DIR"/*/parameters.json; do
  env_name="$(basename "$(dirname "$params")")"
  jq -e . "$params" >/dev/null || fail "$params is not valid JSON."
  jq -e '.Parameters | type == "object"' "$params" >/dev/null \
    || fail "$params must contain a .Parameters object."
  jq -e '.Tags | type == "object"' "$params" >/dev/null \
    || fail "$params must contain a .Tags object."
  declared_env="$(jq -r '.Parameters.Environment // empty' "$params")"
  [[ "$declared_env" == "$env_name" ]] \
    || fail "$params sets Environment='$declared_env' but lives in '$env_name/'."
  for tag in Project Environment Owner CostCenter ManagedBy; do
    jq -e --arg t "$tag" '.Tags[$t] // empty' "$params" >/dev/null \
      || fail "$params is missing required tag '$tag'."
  done
  echo "OK  $params"
done

log "Linting shell scripts (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REPO_ROOT"/scripts/*.sh
  echo "shellcheck passed."
else
  echo "SKIP shellcheck not installed (it runs in CI)."
fi

log "Implementation status"
placeholders="$(grep -rlE '^[[:space:]]*ImplementationStatus:[[:space:]]*PLACEHOLDER' "$CFN_DIR" || true)"
if [[ -n "$placeholders" ]]; then
  echo "Templates still marked PLACEHOLDER (not deployable):"
  echo "${placeholders//$REPO_ROOT\//  - }"
else
  echo "All templates are marked IMPLEMENTED."
fi

if [[ "$RUN_AWS_CHECKS" == true ]]; then
  log "Validating templates with the CloudFormation API (read-only)"
  require aws
  find "$CFN_DIR" -name '*.yml' | sort | while read -r template; do
    aws cloudformation validate-template \
      --region "$AWS_REGION" \
      --template-body "file://$template" >/dev/null
    echo "OK  ${template#"$REPO_ROOT"/}"
  done
fi

log "Validation complete"
