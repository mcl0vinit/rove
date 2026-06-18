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

chmod +x "${fakebin}/flyctl" "${fakebin}/ssh" "${fakebin}/scp"

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
assert_json "${list_json}" '.machines[0].name == "smoke" and .machines[0].provider == "fly" and .machines[0].provider_scope == "fake-devbox" and .machines[0].status == "ready"'

status_output="$(run_rove status smoke)"
assert_contains "${status_output}" $'smoke\tdevbox\tfly\tready'

inspect_json="$(run_rove inspect smoke --json)"
assert_json "${inspect_json}" '.machine.name == "smoke" and .machine.target_name == "devbox" and .machine.status == "ready"'

run_rove exec smoke -- true >/dev/null

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

state_json="${home}/.rove/state.json"
if [[ ! -f "${state_json}" ]]; then
  echo "[error] expected state file at ${state_json}" >&2
  exit 1
fi

jq -e '.machines | length == 0' "${state_json}" >/dev/null

echo "[info] integration smoke passed"
