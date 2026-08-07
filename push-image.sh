#!/usr/bin/env bash
# Build one CUDA image variant and copy it to the GitLab registry.
# Run via: nix develop -c bash push-image.sh cuda12
set -euxo pipefail

VARIANT="${1:?usage: push-image.sh <cuda11|cuda12|cuda13>}"

if ! command -v skopeo >/dev/null 2>&1; then
  echo "error: skopeo is not available; run via 'nix develop -c bash push-image.sh'" >&2
  exit 127
fi

# skopeo needs a trust policy; CI runners may lack /etc/containers.
POLICY_DIR="/etc/containers"
mkdir -p "$POLICY_DIR" 2>/dev/null || POLICY_DIR="$HOME/.config/containers"
[ -w "$POLICY_DIR" ] || POLICY_DIR="$HOME/.config/containers"
mkdir -p "$POLICY_DIR"
[ -f "$POLICY_DIR/policy.json" ] || echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$POLICY_DIR/policy.json"

# CI sets CI_REGISTRY; the fallback is for local pushes. plan.ai serves the
# registry from registry.plan.ai (git.plan.ai:5050 is closed).
REGISTRY="${CI_REGISTRY:-registry.plan.ai}"
PROJECT="${CI_PROJECT_PATH:-plan-ai/vast-ai-templates}"
SHA="${CI_COMMIT_SHORT_SHA:-latest}"

nix build ".#${VARIANT}" -L
archive="$(readlink -f result)"

copy_image() {
  local xtrace_was_on=0
  case "$-" in *x*) xtrace_was_on=1; set +x ;; esac
  skopeo copy \
    "docker-archive:${archive}" \
    "$1" \
    --dest-creds "${CI_REGISTRY_USER}:${CI_REGISTRY_PASSWORD}"
  [ "$xtrace_was_on" -eq 1 ] && set -x || true
}

copy_image "docker://${REGISTRY}/${PROJECT}/nixos-cuda:${VARIANT}-${SHA}"
copy_image "docker://${REGISTRY}/${PROJECT}/nixos-cuda:${VARIANT}"
