#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  cat >&2 <<'EOF'
usage: scripts/pin-image-ref.sh <target-name> <full-image-ref> [config-file...]

example:
  scripts/pin-image-ref.sh devbox registry.fly.io/mcl0vinit-devbox:latest@sha256:deadbeef rove.json rove.example.json
EOF
  exit 1
fi

target_name="$1"
image_ref="$2"
shift 2

if [[ $# -eq 0 ]]; then
  set -- rove.json rove.example.json
fi

for config_path in "$@"; do
  tmp_path="$(mktemp)"
  jq \
    --arg target_name "${target_name}" \
    --arg image_ref "${image_ref}" \
    '
      .targets = (
        .targets | map(
          if .name == $target_name then
            .image = $image_ref
          else
            .
          end
        )
      )
    ' "${config_path}" > "${tmp_path}"
  mv "${tmp_path}" "${config_path}"
done
