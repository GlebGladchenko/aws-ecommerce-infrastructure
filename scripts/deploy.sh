#!/usr/bin/env bash
#
# Package the nested templates and deploy the root stack for one environment.
#
# Usage:
#   scripts/deploy.sh <dev|prod> [--stage network|compute|full]
#                     [--image <digest-or-tag>] [--ami <ami-id>|latest]
#                     [--param KEY=VALUE ...] [--allow-shrink]
#                     [--allow-network-changes] [--execute] [--yes]
#
#   --stage     network = VPC and security groups only; compute = network +
#               VPC endpoints, IAM, ALB, launch template, Auto Scaling group;
#               full = every stack (default: full)
#   --image     app image in the <project>-<env>-api ECR repository: a digest
#               (sha256:...) or tag. Required for compute/full unless the stack
#               already has one, which is then reused.
#   --ami       AMI for the app instances. Without it the deployed AMI is
#               reused; a new stack (or `latest`) resolves AMI_SSM_PARAMETER.
#               A changed image or AMI rolls all instances (instance refresh).
#   --param     override one root stack parameter for this run (repeatable),
#               e.g. --param AlbTestIngressCidr=203.0.113.10/32. Also the only
#               way to change a protected network parameter (see Safety).
#   --allow-shrink  allow moving to a smaller stage, e.g. compute -> network
#               to stop hourly compute charges while keeping the VPC. The
#               nested stacks of the larger stage are deleted.
#   --allow-network-changes  execute even if the change set removes or
#               replaces resources in NetworkStack or security groups.
#   (default)   create and review a change set, but do not execute it
#   --execute   execute the change set after creating and reviewing it
#   --yes       skip the interactive prod confirmation (CI, behind a GitHub
#               Environment approval)
#
# Required environment variables:
#   CFN_ARTIFACT_BUCKET   existing S3 bucket for packaged nested templates
# Optional:
#   AWS_REGION            defaults to us-east-2
#   AMI_SSM_PARAMETER     SSM parameter resolved by --ami latest; defaults to
#                         the public AL2023 x86_64 parameter
#
# Safety:
#   - refuses a stage that includes a template marked
#     `ImplementationStatus: PLACEHOLDER`;
#   - refuses to move a stack to a smaller stage unless --allow-shrink is given
#     (never for a full-stage stack);
#   - refuses to change a protected network parameter (NatGatewayMode, VpcCidr,
#     AvailabilityZoneA/B) of a deployed stack unless it is passed explicitly
#     with --param, so a parameter file can never silently delete or create a
#     NAT Gateway or replace the VPC or subnets;
#   - refuses to create the root stack when a VPC with its name already exists
#     (a standalone network stack), which would add a second VPC;
#   - creates the change set with nested stacks included, prints every change,
#     and refuses to execute one that removes or replaces resources in
#     NetworkStack or replaces a security group, unless --allow-network-changes.
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
AMI_SSM_PARAMETER="${AMI_SSM_PARAMETER:-/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}"

# Templates the network stage creates; keep in sync with the stacks in
# cloudformation/main.yml that have no `Condition`.
NETWORK_STAGE_TEMPLATES=(
  network/vpc.yml
  network/security-groups.yml
)
# Templates the compute stage adds; keep in sync with the stacks in main.yml
# that have `Condition: HasCompute`.
COMPUTE_STAGE_TEMPLATES=(
  network/endpoints.yml
  security/iam.yml
  compute/alb.yml
  compute/ec2.yml
  compute/autoscaling.yml
)
# Changing any of these replaces the VPC or subnets, or creates/deletes NAT
# Gateways and the app tier's default routes.
PROTECTED_PARAMS=(NatGatewayMode VpcCidr AvailabilityZoneA AvailabilityZoneB)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,57p' "$0"; exit "${1:-0}"; }
stage_rank() {
  case "$1" in
    network) echo 1 ;;
    compute) echo 2 ;;
    full) echo 3 ;;
    *) echo 0 ;;
  esac
}

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
ALLOW_SHRINK=false
ALLOW_NETWORK_CHANGES=false
APP_IMAGE=""
APP_AMI=""
EXTRA_PARAMS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      [[ $# -ge 2 ]] || fail "--stage needs a value: network, compute or full."
      STAGE="$2"; shift ;;
    --stage=*) STAGE="${1#--stage=}" ;;
    --image)
      [[ $# -ge 2 ]] || fail "--image needs a digest (sha256:...) or tag."
      APP_IMAGE="$2"; shift ;;
    --image=*) APP_IMAGE="${1#--image=}" ;;
    --ami)
      [[ $# -ge 2 ]] || fail "--ami needs an AMI ID or 'latest'."
      APP_AMI="$2"; shift ;;
    --ami=*) APP_AMI="${1#--ami=}" ;;
    --param)
      [[ $# -ge 2 && "$2" == ?*=* ]] || fail "--param needs KEY=VALUE."
      EXTRA_PARAMS+=("$2"); shift ;;
    --allow-shrink) ALLOW_SHRINK=true ;;
    --allow-network-changes) ALLOW_NETWORK_CHANGES=true ;;
    --execute) EXECUTE=true ;;
    --yes) ASSUME_YES=true ;;
    *) fail "Unknown argument: $1" ;;
  esac
  shift
done
case "$STAGE" in
  network|compute|full) ;;
  *) fail "Stage must be 'network', 'compute' or 'full', got '$STAGE'." ;;
esac

PARAMS_FILE="$REPO_ROOT/environments/$ENVIRONMENT/parameters.json"
[[ -f "$PARAMS_FILE" ]] || fail "Parameter file not found: $PARAMS_FILE"

# --- Guard: never deploy scaffolding -----------------------------------------
# The network and compute stages check only the templates they create; the
# full stage checks every template, including main.yml.
if [[ "$STAGE" != full ]]; then
  stage_templates=()
  for t in "${NETWORK_STAGE_TEMPLATES[@]}"; do stage_templates+=("$CFN_DIR/$t"); done
  if [[ "$STAGE" == compute ]]; then
    for t in "${COMPUTE_STAGE_TEMPLATES[@]}"; do stage_templates+=("$CFN_DIR/$t"); done
  fi
  placeholders="$(grep -lE '^[[:space:]]*ImplementationStatus:[[:space:]]*PLACEHOLDER' "${stage_templates[@]}" || true)"
else
  placeholders="$(grep -rlE '^[[:space:]]*ImplementationStatus:[[:space:]]*PLACEHOLDER' "$CFN_DIR" || true)"
fi
if [[ -n "$placeholders" ]]; then
  echo "Refusing to deploy the $STAGE stage: these templates are still placeholders:" >&2
  echo "${placeholders//$REPO_ROOT\//  - }" >&2
  [[ "$STAGE" == full ]] && echo "Use --stage network or --stage compute to deploy only the implemented stacks." >&2
  exit 1
fi

for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed."
done
[[ -n "${CFN_ARTIFACT_BUCKET:-}" ]] || fail "CFN_ARTIFACT_BUCKET must be set."

PROJECT_NAME="$(jq -r '.Parameters.ProjectName' "$PARAMS_FILE")"
STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
WAF_STACK_NAME="${STACK_NAME}-waf"

# Read-only lookups on the deployed root stack ("" if it does not exist).
STACK_STATUS="$(aws cloudformation describe-stacks \
  --region "$AWS_REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].StackStatus" --output text 2>/dev/null || true)"
current_param() {
  local value
  [[ -n "$STACK_STATUS" ]] || return 0
  value="$(aws cloudformation describe-stacks \
    --region "$AWS_REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue | [0]" \
    --output text 2>/dev/null || true)"
  [[ "$value" == None ]] && value=""
  echo "$value"
}
case "$STACK_STATUS" in
  ROLLBACK_COMPLETE)
    fail "$STACK_NAME is in ROLLBACK_COMPLETE (its creation failed and every resource was deleted). CloudFormation cannot update it: delete it with scripts/destroy.sh $ENVIRONMENT, then deploy again." ;;
  ""|*_COMPLETE|REVIEW_IN_PROGRESS) ;;
  *) fail "$STACK_NAME is in state $STACK_STATUS; wait for it to finish (or fix it) before deploying." ;;
esac

# --- Guard: never shrink a stack ---------------------------------------------
# Moving DeploymentStage to a smaller stage would make CloudFormation delete
# every nested stack of the larger one (load balancer, instances, database...).
current_stage="$(current_param DeploymentStage)"
if [[ -n "$current_stage" && "$(stage_rank "$STAGE")" -lt "$(stage_rank "$current_stage")" ]]; then
  if [[ "$ALLOW_SHRINK" == true && "$current_stage" != full ]]; then
    echo "WARNING: moving $STACK_NAME from the $current_stage to the $STAGE stage deletes its $current_stage-stage nested stacks." >&2
  else
    fail "$STACK_NAME is deployed with DeploymentStage=$current_stage; deploying the $STAGE stage would delete its nested stacks. Use --allow-shrink (not for full), or scripts/destroy.sh to tear it down."
  fi
fi

# --- Application image and AMI (compute and full stages) ---------------------
# Both are pinned: the deployed values are reused unless --image / --ami is
# given, because a change rolls every instance through an instance refresh.
if [[ "$STAGE" != network ]]; then
  deployed_image="$(current_param AppImageReference)"
  [[ -n "$APP_IMAGE" ]] || APP_IMAGE="$deployed_image"
  [[ -n "$APP_IMAGE" ]] || fail "The $STAGE stage needs --image <digest-or-tag> (an image in the ${STACK_NAME}-api ECR repository)."
  # Read-only: the reference must be a runnable linux/amd64 image, not e.g. a
  # BuildKit attestation manifest or an arm64 build (see scripts/check-image.sh).
  AWS_REGION="$AWS_REGION" "$REPO_ROOT/scripts/check-image.sh" "${STACK_NAME}-api" "$APP_IMAGE" >/dev/null \
    || fail "Image $APP_IMAGE in ${STACK_NAME}-api cannot run on the instances (see above)."
  EXTRA_PARAMS+=("AppImageReference=$APP_IMAGE")

  deployed_ami="$(current_param AppAmiId)"
  [[ -n "$APP_AMI" ]] || APP_AMI="$deployed_ami"
  if [[ -z "$APP_AMI" || "$APP_AMI" == latest ]]; then
    APP_AMI="$(aws ssm get-parameter --region "$AWS_REGION" --name "$AMI_SSM_PARAMETER" \
      --query Parameter.Value --output text)" \
      || fail "Could not resolve the AMI from SSM parameter $AMI_SSM_PARAMETER."
    echo "AMI resolved from $AMI_SSM_PARAMETER: $APP_AMI"
  fi
  [[ "$APP_AMI" =~ ^ami-[0-9a-f]{8,17}$ ]] || fail "Not an AMI ID: $APP_AMI"
  EXTRA_PARAMS+=("AppAmiId=$APP_AMI")

  if [[ -n "$deployed_image" && ( "$deployed_image" != "$APP_IMAGE" || "$deployed_ami" != "$APP_AMI" ) ]]; then
    echo "NOTE: image/AMI change ($deployed_image, $deployed_ami -> $APP_IMAGE, $APP_AMI):"
    echo "      executing this change set replaces every instance through an instance refresh."
  fi
fi

"$REPO_ROOT/scripts/validate.sh"

if [[ "$ENVIRONMENT" == prod && "$ASSUME_YES" != true ]]; then
  read -r -p "Type the stack name ($STACK_NAME) to continue with a PROD $STAGE-stage deployment: " reply
  [[ "$reply" == "$STACK_NAME" ]] || fail "Confirmation did not match. Aborting."
fi

# --- Parameters --------------------------------------------------------------
# bash 3.2 compatible (macOS default): no mapfile or associative arrays.
PARAM_OVERRIDES=()
while IFS= read -r line; do PARAM_OVERRIDES+=("$line"); done \
  < <(jq -r '.Parameters | to_entries[] | "\(.key)=\(.value)"' "$PARAMS_FILE")
PARAM_OVERRIDES+=("DeploymentStage=$STAGE")
set_param() {
  local key="${1%%=*}" existing merged=()
  for existing in "${PARAM_OVERRIDES[@]}"; do
    [[ "${existing%%=*}" == "$key" ]] || merged+=("$existing")
  done
  PARAM_OVERRIDES=("${merged[@]}" "$1")
}
param_value() {
  local entry
  for entry in "${PARAM_OVERRIDES[@]}"; do
    [[ "${entry%%=*}" == "$1" ]] && { echo "${entry#*=}"; return 0; }
  done
  return 0
}
explicit_param() {
  local entry
  for entry in ${EXTRA_PARAMS[@]+"${EXTRA_PARAMS[@]}"}; do
    [[ "${entry%%=*}" == "$1" ]] && return 0
  done
  return 1
}
# --param, --image and --ami values replace the same key from the file.
for extra in ${EXTRA_PARAMS[@]+"${EXTRA_PARAMS[@]}"}; do set_param "$extra"; done

# --- Guard: protected network parameters -------------------------------------
# The deployed value wins over the parameter file. A different value is only
# used when passed explicitly with --param, and the change set review below
# still shows (and blocks) what it would remove or replace.
for key in "${PROTECTED_PARAMS[@]}"; do
  deployed="$(current_param "$key")"
  wanted="$(param_value "$key")"
  [[ -n "$deployed" && "$deployed" != "$wanted" ]] || continue
  if explicit_param "$key"; then
    echo "WARNING: changing $key of $STACK_NAME from '$deployed' to '$wanted' (explicit --param)." >&2
  else
    fail "$STACK_NAME is deployed with $key=$deployed, but $PARAMS_FILE has '$wanted'. Keep it with --param $key=$deployed, or change it deliberately with --param $key=$wanted."
  fi
done

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
  set_param "WebAclArn=$web_acl_arn"
fi

# --- Root stack (AWS_REGION) -------------------------------------------------
mkdir -p "$BUILD_DIR"
PACKAGED_TEMPLATE="$BUILD_DIR/main.$ENVIRONMENT.packaged.yml"
PARAMS_JSON="$BUILD_DIR/main.$ENVIRONMENT.parameters.json"
TAGS_JSON="$BUILD_DIR/main.$ENVIRONMENT.tags.json"

echo "==> Packaging nested templates to s3://$CFN_ARTIFACT_BUCKET/$STACK_NAME/"
aws cloudformation package \
  --region "$AWS_REGION" \
  --template-file "$CFN_DIR/main.yml" \
  --s3-bucket "$CFN_ARTIFACT_BUCKET" \
  --s3-prefix "$STACK_NAME" \
  --output-template-file "$PACKAGED_TEMPLATE"

# Parameters not listed here take their template defaults (e.g. an
# AlbTestIngressCidr from an earlier run is removed unless passed again).
printf '%s\n' "${PARAM_OVERRIDES[@]}" | jq -R -s \
  'split("\n") | map(select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$")
   | {ParameterKey: .k, ParameterValue: .v})' > "$PARAMS_JSON"
printf '%s\n' "${TAGS[@]}" | jq -R -s \
  'split("\n") | map(select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$")
   | {Key: .k, Value: .v})' > "$TAGS_JSON"

if [[ -z "$STACK_STATUS" || "$STACK_STATUS" == REVIEW_IN_PROGRESS ]]; then
  change_set_type=CREATE
  # A new root stack always creates a VPC. Refuse if one with this stack's
  # name already exists (e.g. vpc.yml deployed as a standalone stack).
  existing_vpcs="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${STACK_NAME}-vpc" --query 'Vpcs[].VpcId' --output text)"
  if [[ -n "$existing_vpcs" && "$existing_vpcs" != None && "$ALLOW_NETWORK_CHANGES" != true ]]; then
    fail "Root stack $STACK_NAME does not exist, but VPC(s) named ${STACK_NAME}-vpc do: $existing_vpcs. Creating the stack would add a second VPC. Delete or import the existing network stack first (or pass --allow-network-changes)."
  fi
else
  change_set_type=UPDATE
fi
if [[ "$(wc -c < "$PACKAGED_TEMPLATE")" -le 51200 ]]; then
  template_args=(--template-body "file://$PACKAGED_TEMPLATE")
else
  template_key="$STACK_NAME/main.$ENVIRONMENT.packaged.yml"
  aws s3 cp --region "$AWS_REGION" "$PACKAGED_TEMPLATE" "s3://$CFN_ARTIFACT_BUCKET/$template_key" >/dev/null
  template_args=(--template-url "https://$CFN_ARTIFACT_BUCKET.s3.$AWS_REGION.amazonaws.com/$template_key")
fi

CHANGE_SET_NAME="deploy-$STAGE-$(date -u +%Y%m%d%H%M%S)"
echo "==> Creating change set $CHANGE_SET_NAME ($change_set_type, $STAGE stage) for $STACK_NAME in $AWS_REGION"
CHANGE_SET_ID="$(aws cloudformation create-change-set \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET_NAME" \
  --change-set-type "$change_set_type" \
  "${template_args[@]}" \
  --parameters "file://$PARAMS_JSON" \
  --tags "file://$TAGS_JSON" \
  --capabilities CAPABILITY_IAM \
  --include-nested-stacks \
  --description "scripts/deploy.sh $ENVIRONMENT --stage $STAGE" \
  --query Id --output text)"

if ! aws cloudformation wait change-set-create-complete \
  --region "$AWS_REGION" --change-set-name "$CHANGE_SET_ID"; then
  reason="$(aws cloudformation describe-change-set --region "$AWS_REGION" \
    --change-set-name "$CHANGE_SET_ID" --query StatusReason --output text)"
  if [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]]; then
    aws cloudformation delete-change-set --region "$AWS_REGION" --change-set-name "$CHANGE_SET_ID"
    echo "No changes to deploy."
    exit 0
  fi
  fail "Change set $CHANGE_SET_NAME failed: $reason"
fi

# --- Review the change set, nested stacks included ---------------------------
# Prints one line per resource change. Blocks execution when the network
# foundation would lose or replace resources: anything in NetworkStack (VPC,
# subnets, NAT Gateways, routes, S3 endpoint), removal of either network-stage
# stack, or replacement of a security group (new group IDs).
BLOCKERS=()
review_change_set() {
  local change_set="$1" stack="$2" action logical type replacement nested
  while IFS=$'\t' read -r action logical type replacement nested; do
    printf '  %-22s %-8s %-34s %-42s replacement=%s\n' "$stack" "$action" "$logical" "$type" "$replacement"
    if [[ "$stack" == NetworkStack && ( "$action" == Remove || "$replacement" == True || "$replacement" == Conditional ) ]]; then
      BLOCKERS+=("$stack/$logical ($type): $action, replacement=$replacement")
    elif [[ "$stack" == root && "$action" == Remove && ( "$logical" == NetworkStack || "$logical" == SecurityGroupsStack ) ]]; then
      BLOCKERS+=("$logical: $action")
    elif [[ "$type" == AWS::EC2::SecurityGroup && ( "$action" == Remove || "$replacement" == True ) ]]; then
      BLOCKERS+=("$stack/$logical ($type): $action, replacement=$replacement")
    fi
    if [[ -n "$nested" && "$nested" != None && "$nested" != null ]]; then
      review_change_set "$nested" "$logical"
    fi
  done < <(aws cloudformation describe-change-set --region "$AWS_REGION" \
    --change-set-name "$change_set" --output json \
    | jq -r '.Changes[].ResourceChange
             | [.Action, .LogicalResourceId, .ResourceType, (.Replacement // "-"), (.ChangeSetId // "")]
             | @tsv')
}

echo "==> Changes (stack, action, resource, type, replacement):"
review_change_set "$CHANGE_SET_ID" root

if [[ ${#BLOCKERS[@]} -gt 0 ]]; then
  echo "BLOCKED: this change set removes or replaces network foundation resources:" >&2
  printf '  - %s\n' "${BLOCKERS[@]}" >&2
  if [[ "$ALLOW_NETWORK_CHANGES" != true ]]; then
    echo "Not executing. If this is intended, re-run with --allow-network-changes." >&2
    exit 1
  fi
  echo "Proceeding because --allow-network-changes was given." >&2
fi

if [[ "$EXECUTE" != true ]]; then
  echo
  echo "Change set created but not executed: $CHANGE_SET_ID"
  echo "Execute this reviewed change set with:"
  echo "  aws cloudformation execute-change-set --region $AWS_REGION --change-set-name '$CHANGE_SET_ID'"
  exit 0
fi

echo "==> Executing change set $CHANGE_SET_NAME"
aws cloudformation execute-change-set --region "$AWS_REGION" --change-set-name "$CHANGE_SET_ID"
if [[ "$change_set_type" == CREATE ]]; then
  aws cloudformation wait stack-create-complete --region "$AWS_REGION" --stack-name "$STACK_NAME"
else
  aws cloudformation wait stack-update-complete --region "$AWS_REGION" --stack-name "$STACK_NAME"
fi
echo "Stack $STACK_NAME is $(aws cloudformation describe-stacks --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text)."
