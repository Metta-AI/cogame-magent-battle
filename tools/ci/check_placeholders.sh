#!/usr/bin/env bash
# Fails if any coworld-builder scaffold placeholder survived substitution.
#
# The pattern is ASSEMBLED FROM PARTS on purpose: written out literally, this
# script would match itself, and so would the workflow step that inlined the
# same grep -- which is exactly how the gate first went red on its own text.
set -euo pipefail

open="<"
close=">"
pattern="${open}slug${close}\|${open}IMAGE${close}\|${open}SEATS${close}"

targets=(
  .github/workflows/ci.yml
  .github/workflows/coworld-release.yml
  .github/workflows/coworld-submit.yml
  tools/ci/docker_smoke.sh
  tools/ci/policies.json
  coworld_manifest_template.json
  compose.yaml
  Dockerfile
  Dockerfile.replay-viewer
)

status=0
for target in "${targets[@]}"; do
  if grep -n "${pattern}" "${target}"; then
    echo "::error::${target} still carries an unsubstituted scaffold placeholder"
    status=1
  fi
done
if [[ "${status}" -eq 0 ]]; then
  echo "no scaffold placeholders in ${#targets[@]} files"
fi
exit "${status}"
