#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${1:-${repo_root}/zig-out/bin/rove}"
binary_dir="$(cd "$(dirname "${binary}")" && pwd)"
binary="${binary_dir}/$(basename "${binary}")"

if [[ ! -x "${binary}" ]]; then
  cat >&2 <<EOF
[error] missing rove binary at ${binary}
[hint] run: nix develop -c zig build
EOF
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fakebin="${tmpdir}/bin"
workdir="${tmpdir}/work"
home="${tmpdir}/home"
machines_json="${tmpdir}/machines.json"
mkdir -p "${fakebin}" "${workdir}/.rove" "${home}/.config/gh"

cat > "${machines_json}" <<'EOF'
[
  {
    "id": "manual-1",
    "name": "manual-adopt",
    "state": "started",
    "region": "iad"
  }
]
EOF

cat > "${home}/.config/gh/hosts.yml" <<'EOF'
github.com:
    user: smoke
    oauth_token: smoke-token
    git_protocol: ssh
EOF

cat > "${fakebin}/flyctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

machines_json="${TMP_FAKE_STATE_DIR:?}/machines.json"

if [[ "${1:-}" == "version" ]]; then
  echo 'flyctl v0-smoke'
  exit 0
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "whoami" ]]; then
  echo 'smoke-user'
  exit 0
fi

if [[ "${1:-}" == "machine" && "${2:-}" == "run" ]]; then
  name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        name="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  id="machine-${name}"
  jq --arg id "${id}" --arg name "${name}" '. += [{id: $id, name: $name, state: "started", region: "iad"}]' "${machines_json}" > "${machines_json}.tmp"
  mv "${machines_json}.tmp" "${machines_json}"
  exit 0
fi

if [[ "${1:-}" == "machine" && "${2:-}" == "list" ]]; then
  cat "${machines_json}"
  exit 0
fi

if [[ "${1:-}" == "machine" && "${2:-}" == "destroy" ]]; then
  machine_id="${@: -1}"
  jq --arg machine_id "${machine_id}" 'map(select(.id != $machine_id))' "${machines_json}" > "${machines_json}.tmp"
  mv "${machines_json}.tmp" "${machines_json}"
  exit 0
fi

printf 'unexpected flyctl args: %s\n' "$*" >&2
exit 1
EOF

cat > "${fakebin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

marker="${TMP_FAKE_STATE_DIR:?}/hostkey-once"
if [[ -f "${marker}" ]]; then
  rm -f "${marker}"
  cat >&2 <<'ERR'
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Offending ED25519 key in /tmp/known_hosts:1
Host key verification failed.
ERR
  exit 255
fi

exit 0
EOF

cat > "${fakebin}/scp" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${fakebin}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for arg in "$@"; do
  if [[ "${arg}" == "--dry-run" ]]; then
    exit 0
  fi
done

exit 0
EOF

chmod +x "${fakebin}/flyctl" "${fakebin}/ssh" "${fakebin}/scp" "${fakebin}/rsync"

cat > "${workdir}/rove.json" <<EOF
{
  "targets": [
    {
      "name": "devbox",
      "provider": "fly",
      "app": "fake-devbox",
      "image": "registry.fly.io/fake-devbox:latest@sha256:smoke",
      "vm_size": "shared-cpu-2x",
      "ssh_user": "rove",
      "startup_script": "${repo_root}/scripts/bootstrap.sh"
    }
  ]
}
EOF

cat > "${workdir}/.rove/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "workspace bootstrap"
EOF

run_rove() {
  (
    cd "${workdir}"
    HOME="${home}" PATH="${fakebin}:$PATH" TMP_FAKE_STATE_DIR="${tmpdir}" "${binary}" "$@"
  )
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "[error] expected output to contain: ${needle}" >&2
    echo "[error] actual output:" >&2
    printf '%s\n' "${haystack}" >&2
    exit 1
  fi
}

run_rove run devbox --name smoke >/dev/null
refresh_output="$(run_rove refresh smoke)"
assert_contains "${refresh_output}" $'smoke\tupdated\tready\tstarted'

sync_output="$(run_rove sync smoke)"
assert_contains "${sync_output}" "workspace synced"

workspaces_output="$(run_rove workspaces smoke)"
assert_contains "${workspaces_output}" $'1\t*'

pull_output="$(run_rove pull smoke --workspace 1 --preview)"
assert_contains "${pull_output}" "no remote changes detected"

auth_output="$(run_rove auth smoke)"
assert_contains "${auth_output}" "installed Git auth material"

touch "${tmpdir}/hostkey-once"
doctor_output="$(run_rove doctor smoke)"
assert_contains "${doctor_output}" $'ssh\tok\tsmoke: SSH is reachable'

run_rove adopt devbox manual-1 --name adopted >/dev/null
jq 'map(select(.id != "manual-1"))' "${machines_json}" > "${machines_json}.tmp"
mv "${machines_json}.tmp" "${machines_json}"
prune_output="$(run_rove refresh adopted --prune-missing)"
assert_contains "${prune_output}" $'adopted\tpruned\tprovisioned_unreachable\tmissing'

run_rove down smoke >/dev/null

state_json="${home}/.rove/state.json"
if [[ ! -f "${state_json}" ]]; then
  echo "[error] expected state file at ${state_json}" >&2
  exit 1
fi

jq -e '.machines | length == 0' "${state_json}" >/dev/null

echo "[info] integration smoke passed"
