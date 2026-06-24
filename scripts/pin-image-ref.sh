#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  cat >&2 <<'EOF'
usage: scripts/pin-image-ref.sh <target-name> <full-image-ref> [config-file...]

example:
  scripts/pin-image-ref.sh devbox registry.fly.io/your-fly-app:latest@sha256:deadbeef
EOF
  exit 1
fi

target_name="$1"
image_ref="$2"
shift 2

if [[ $# -eq 0 ]]; then
  if [[ -n "${ROVE_CONFIG:-}" ]]; then
    set -- "${ROVE_CONFIG}"
  elif [[ -f rove.json ]]; then
    set -- rove.json
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    set -- "${XDG_CONFIG_HOME}/rove/rove.json"
  else
    set -- "${HOME}/.config/rove/rove.json"
  fi
fi

for config_path in "$@"; do
  if [[ ! -f "${config_path}" ]]; then
    printf 'pin-image-ref: missing config file: %s\n' "${config_path}" >&2
    exit 1
  fi

  tmp_path="$(mktemp)"
  jq \
    --arg target_name "${target_name}" \
    --arg image_ref "${image_ref}" \
    '
      .targets = (
        .targets | map(
          if .name == $target_name then
            if has("fly") then
              .fly.image = $image_ref
            else
              .image = $image_ref
            end
          else
            .
          end
        )
      )
    ' "${config_path}" > "${tmp_path}"
  mv "${tmp_path}" "${config_path}"
done
