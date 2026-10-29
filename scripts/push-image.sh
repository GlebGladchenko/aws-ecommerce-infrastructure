#!/usr/bin/env bash
#
# Build the app image for the EC2 instances and push it to the environment's
# ECR repository, then verify the pushed image and print its digest.
#
# Usage:
#   scripts/push-image.sh <dev|prod> [--tag <tag>]
#
#   --tag   image tag (default: the current git commit SHA). Tags in the
#           repository are immutable, so an existing tag is refused.
#
# The image is built for linux/amd64 (t3 instances, x86_64 AMI), also on an
# Apple silicon Mac, and without BuildKit provenance/SBOM attestations. With
# attestations, a push to an IMMUTABLE ECR repository can leave the tag on the
# attestation manifest (an in-toto layer, platform unknown/unknown) instead of
# the image, and `docker pull` on the instances fails with
# "unsupported media type application/vnd.in-toto+json".
#
# Optional environment variables:
#   AWS_REGION   defaults to us-east-2
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-2}"
PLATFORM=linux/amd64

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,21p' "$0"; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 2
ENVIRONMENT="$1"; shift
case "$ENVIRONMENT" in
  dev|prod) ;;
  -h|--help) usage 0 ;;
  *) fail "Environment must be 'dev' or 'prod', got '$ENVIRONMENT'." ;;
esac

TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || fail "--tag needs a value."
      TAG="$2"; shift ;;
    --tag=*) TAG="${1#--tag=}" ;;
    *) fail "Unknown argument: $1" ;;
  esac
  shift
done

for cmd in aws docker git jq; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed."
done
docker buildx version >/dev/null 2>&1 || fail "docker buildx is required."

# The tag must identify the code in the image: refuse uncommitted app changes.
if [[ -z "$TAG" ]]; then
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain -- app)" ]] \
    || fail "app/ has uncommitted changes; commit them or pass --tag explicitly."
  TAG="$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

PROJECT_NAME="$(jq -r '.Parameters.ProjectName' "$REPO_ROOT/environments/$ENVIRONMENT/parameters.json")"
REPOSITORY="${PROJECT_NAME}-${ENVIRONMENT}-api"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

if aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPOSITORY" \
  --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  fail "$REPOSITORY:$TAG already exists and tags are immutable. Use another --tag, or delete the old image first."
fi

echo "==> Logging in to $REGISTRY"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "==> Building and pushing $REPOSITORY:$TAG ($PLATFORM, no attestations)"
docker buildx build "$REPO_ROOT/app" \
  --platform "$PLATFORM" \
  --provenance=false \
  --sbom=false \
  --tag "$REGISTRY/$REPOSITORY:$TAG" \
  --push

echo "==> Verifying the pushed image"
DIGEST="$(AWS_REGION="$AWS_REGION" EXPECTED_PLATFORM="$PLATFORM" \
  "$REPO_ROOT/scripts/check-image.sh" "$REPOSITORY" "$TAG")"

echo
echo "Pushed $REPOSITORY:$TAG"
echo "Digest: $DIGEST"
echo "Deploy it with:"
echo "  scripts/deploy.sh $ENVIRONMENT --stage compute --image $DIGEST"
