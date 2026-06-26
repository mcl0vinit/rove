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
vast_machines_json="${tmpdir}/vast-machines.json"
mkdir -p "${fakebin}" "${workdir}" "${home}"

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

cat > "${vast_machines_json}" <<'EOF'
[]
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

if [[ "${1:-}" == "ssh" && "${2:-}" == "console" ]]; then
  exit 0
fi

printf 'unexpected flyctl args: %s\n' "$*" >&2
exit 1
EOF

cat > "${fakebin}/vastai" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

vast_machines_json="${TMP_FAKE_STATE_DIR:?}/vast-machines.json"

if [[ "${1:-}" == "--help" ]]; then
  echo 'vastai smoke help'
  exit 0
fi

if [[ "${1:-}" == "show" && "${2:-}" == "user" ]]; then
  echo '{"id": 1, "balance": 10}'
  exit 0
fi

if [[ "${1:-}" == "search" && "${2:-}" == "offers" ]]; then
  cat <<'JSON'
[
  {
    "id": 9001,
    "gpu_name": "RTX 4090",
    "num_gpus": 1,
    "dph": 0.42,
    "rentable": true
  }
]
JSON
  exit 0
fi

if [[ "${1:-}" == "create" && "${2:-}" == "instance" ]]; then
  offer_id="${3:-}"
  label="rove-gpu-smoke"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label)
        label="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  id="7001"
  jq \
    --arg id "${id}" \
    --arg label "${label}" \
    --arg offer_id "${offer_id}" \
    '. += [{id: ($id | tonumber), label: $label, offer_id: ($offer_id | tonumber), actual_status: "running", cur_state: "running", ssh_host: "ssh.fake.vast.ai", ssh_port: 32022, geolocation: "US", gpu_name: "RTX 4090", num_gpus: 1}]' \
    "${vast_machines_json}" > "${vast_machines_json}.tmp"
  mv "${vast_machines_json}.tmp" "${vast_machines_json}"
  echo '{"success": true, "new_contract": 7001}'
  exit 0
fi

if [[ "${1:-}" == "attach" && "${2:-}" == "ssh" ]]; then
  echo '{"success": true}'
  exit 0
fi

if [[ "${1:-}" == "show" && "${2:-}" == "instance" ]]; then
  instance_id="${3:-}"
  if ! jq -e --argjson id "${instance_id}" '.[] | select(.id == $id)' "${vast_machines_json}" >/dev/null; then
    echo 'instance not found' >&2
    exit 1
  fi
  jq --argjson id "${instance_id}" '{"instances": (.[] | select(.id == $id))}' "${vast_machines_json}"
  exit 0
fi

if [[ "${1:-}" == "destroy" && "${2:-}" == "instance" ]]; then
  instance_id="${3:-}"
  jq --argjson id "${instance_id}" 'map(select(.id != $id))' "${vast_machines_json}" > "${vast_machines_json}.tmp"
  mv "${vast_machines_json}.tmp" "${vast_machines_json}"
  echo '{"success": true}'
  exit 0
fi

printf 'unexpected vastai args: %s\n' "$*" >&2
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

chmod +x "${fakebin}/flyctl" "${fakebin}/vastai" "${fakebin}/ssh" "${fakebin}/scp"

cat > "${workdir}/rove.json" <<EOF
{
  "targets": [
    {
      "name": "devbox",
      "provider": "fly",
      "ssh_user": "rove",
      "startup_script": "${repo_root}/scripts/bootstrap.sh",
      "fly": {
        "app": "fake-devbox",
        "image": "registry.fly.io/fake-devbox:latest@sha256:smoke",
        "vm_size": "shared-cpu-2x"
      }
    },
    {
      "name": "gpu",
      "provider": "vast",
      "ssh_user": "root",
      "vast": {
        "query": "gpu_name=RTX_4090 num_gpus=1 verified=true direct_port_count>=1 rentable=true",
        "image": "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime",
        "disk_gb": 80,
        "order": "dlperf_usd-"
      }
    }
  ]
}
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

assert_json() {
  local json="$1"
  local expr="$2"

  if ! jq -e "${expr}" >/dev/null <<<"${json}"; then
    echo "[error] expected JSON expression to pass: ${expr}" >&2
    echo "[error] actual JSON:" >&2
    printf '%s\n' "${json}" >&2
    exit 1
  fi
}

run_rove up devbox --name smoke >/dev/null
refresh_output="$(run_rove refresh smoke)"
assert_contains "${refresh_output}" $'smoke\tupdated\tready\tstarted'

refresh_json="$(run_rove refresh smoke --json)"
assert_json "${refresh_json}" '.results[0].name == "smoke" and .results[0].result == "updated" and .machines[0].name == "smoke"'

list_output="$(run_rove list)"
assert_contains "${list_output}" $'smoke\tdevbox\tfly\tready'

list_json="$(run_rove list --json)"
assert_json "${list_json}" '.machines[0].name == "smoke" and .machines[0].provider == "fly" and .machines[0].provider_scope == "fake-devbox" and .machines[0].ssh_port == 22 and .machines[0].provider_metadata == null and .machines[0].status == "ready"'

status_output="$(run_rove status smoke)"
assert_contains "${status_output}" $'smoke\tdevbox\tfly\tready'

inspect_json="$(run_rove inspect smoke --json)"
assert_json "${inspect_json}" '.machine.name == "smoke" and .machine.target_name == "devbox" and .machine.ssh_port == 22 and .machine.status == "ready"'

run_rove exec smoke -- true >/dev/null

gpu_up_json="$(run_rove up gpu --name gpu-smoke --json)"
assert_json "${gpu_up_json}" '.machine.name == "gpu-smoke" and .machine.provider == "vast" and .machine.host == "ssh.fake.vast.ai" and .machine.ssh_port == 32022 and .machine.ssh_user == "root" and .machine.status == "ready"'

gpu_inspect_json="$(run_rove inspect gpu-smoke --json)"
assert_json "${gpu_inspect_json}" '.machine.name == "gpu-smoke" and .machine.provider == "vast" and .machine.remote_state == "running" and .machine.ssh_port == 32022'

run_rove exec gpu-smoke -- true >/dev/null

touch "${tmpdir}/hostkey-once"
doctor_output="$(run_rove doctor smoke)"
assert_contains "${doctor_output}" $'ssh\tok\tsmoke: SSH is reachable'

run_rove adopt devbox manual-1 --name adopted >/dev/null
jq 'map(select(.id != "manual-1"))' "${machines_json}" > "${machines_json}.tmp"
mv "${machines_json}.tmp" "${machines_json}"
prune_output="$(run_rove refresh adopted --prune-missing)"
assert_contains "${prune_output}" $'adopted\tpruned\tprovisioned_unreachable\tmissing'

down_json="$(run_rove down smoke --json)"
assert_json "${down_json}" '.destroyed == true and .machine.name == "smoke"'

gpu_down_json="$(run_rove down gpu-smoke --json)"
assert_json "${gpu_down_json}" '.destroyed == true and .machine.name == "gpu-smoke" and .machine.provider == "vast"'

state_json="${home}/.rove/state.json"
if [[ ! -f "${state_json}" ]]; then
  echo "[error] expected state file at ${state_json}" >&2
  exit 1
fi

jq -e '.machines | length == 0' "${state_json}" >/dev/null

echo "[info] integration smoke passed"
