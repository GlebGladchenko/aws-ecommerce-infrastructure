#!/usr/bin/env bash
#
# Check (read-only) that an ECR image reference is a runnable container image
# for the instances' platform, and print its resolved digest.
#
# Usage:
#   scripts/check-image.sh <repository> <tag|sha256:digest>
#
# Fails for references that `docker pull` on the instances cannot run, e.g. a
# tag that points at a BuildKit attestation manifest (an in-toto layer,
# platform unknown/unknown), an index without a linux/amd64 entry, or an
# image built for arm64 on an Apple silicon Mac.
#
# Optional environment variables:
#   AWS_REGION          defaults to us-east-2
#   EXPECTED_PLATFORM   defaults to linux/amd64 (t3 instances, x86_64 AMI)
#
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-2}"
EXPECTED_PLATFORM="${EXPECTED_PLATFORM:-linux/amd64}"
MEDIA_TYPES=(
  application/vnd.oci.image.index.v1+json
  application/vnd.docker.distribution.manifest.list.v2+json
  application/vnd.oci.image.manifest.v1+json
  application/vnd.docker.distribution.manifest.v2+json
)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 2 ]] || { sed -n '3,16p' "$0"; exit 2; }
REPOSITORY="$1"
REFERENCE="$2"
for cmd in aws jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required but not installed."
done

image_id() {
  if [[ "$1" == sha256:* ]]; then echo "imageDigest=$1"; else echo "imageTag=$1"; fi
}

# Sets media_type, digest and manifest for one reference; fails if missing.
get_manifest() {
  local response
  response="$(aws ecr batch-get-image --region "$AWS_REGION" --repository-name "$REPOSITORY" \
    --image-ids "$(image_id "$1")" --accepted-media-types "${MEDIA_TYPES[@]}" --output json)"
  [[ "$(jq '.images | length' <<< "$response")" -gt 0 ]] \
    || fail "$REPOSITORY:$1 not found in ECR ($AWS_REGION)."
  media_type="$(jq -r '.images[0].imageManifestMediaType' <<< "$response")"
  digest="$(jq -r '.images[0].imageId.imageDigest' <<< "$response")"
  manifest="$(jq -r '.images[0].imageManifest' <<< "$response")"
}

get_manifest "$REFERENCE"
resolved_digest="$digest"

# An index (multi-platform image) must have an entry for the instance platform.
if [[ "$media_type" == *index* || "$media_type" == *manifest.list* ]]; then
  os="${EXPECTED_PLATFORM%%/*}"
  arch="${EXPECTED_PLATFORM#*/}"
  child="$(jq -r --arg os "$os" --arg arch "$arch" \
    '[.manifests[] | select(.platform.os == $os and .platform.architecture == $arch)][0].digest // empty' <<< "$manifest")"
  if [[ -z "$child" ]]; then
    platforms="$(jq -r '[.manifests[].platform | "\(.os)/\(.architecture)"] | join(", ")' <<< "$manifest")"
    fail "$REPOSITORY:$REFERENCE is an image index without a $EXPECTED_PLATFORM image (has: $platforms)."
  fi
  get_manifest "$child"
fi

# An attestation manifest has an in-toto layer and no runnable filesystem.
bad_layers="$(jq -r '[.layers[]?.mediaType | select(test("in-toto|attestation|spdx"))] | unique | join(", ")' <<< "$manifest")"
if [[ -n "$bad_layers" ]]; then
  fail "$REPOSITORY:$REFERENCE is not a container image: its manifest has $bad_layers layers (a BuildKit attestation). Rebuild without attestations: scripts/push-image.sh."
fi

config_digest="$(jq -r '.config.digest // empty' <<< "$manifest")"
[[ -n "$config_digest" ]] || fail "$REPOSITORY:$REFERENCE has no image config."
config_url="$(aws ecr get-download-url-for-layer --region "$AWS_REGION" \
  --repository-name "$REPOSITORY" --layer-digest "$config_digest" \
  --query downloadUrl --output text)"
platform="$(curl -sSf "$config_url" | jq -r '"\(.os)/\(.architecture)"')"
[[ "$platform" == "$EXPECTED_PLATFORM" ]] \
  || fail "$REPOSITORY:$REFERENCE is built for $platform, but the instances need $EXPECTED_PLATFORM. Rebuild with scripts/push-image.sh (--platform $EXPECTED_PLATFORM)."

echo "OK  $REPOSITORY:$REFERENCE is a $platform image ($(jq '.layers | length' <<< "$manifest") layers)." >&2
echo "$resolved_digest"
