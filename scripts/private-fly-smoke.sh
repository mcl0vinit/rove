#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/private-fly-smoke.sh [options]

Launch one private Fly-backed Rove machine, record startup timing phases,
validate private-only exposure, run a Rove exec probe, and destroy it on
success.

Options:
  --target NAME             Rove target to launch. Default: devbox
  --name NAME               Instance name. Default: private-smoke-<timestamp>
  --rove-bin PATH           Rove binary. Default: ./zig-out/bin/rove or rove
  --timeout SECONDS         Poll timeout per phase. Default: 300
  --poll SECONDS            Poll interval. Default: 2
  --jsonl                   Emit machine-readable JSON Lines events
  --destroy-on-failure      Attempt rove down when validation fails
  --keep-on-success         Leave the machine running after successful validation
  -h, --help                Show this help

Environment:
  ROVE_TARGET               Default target name
  ROVE_INSTANCE             Default instance name
  ROVE_BIN                  Default rove binary
  FLY_BIN                   flyctl/fly binary override
  TAILSCALE_BIN             tailscale binary override
  ALLOW_PUBLIC_FLY_IPS=1    Warn instead of failing if the app has public IPs

Run from a directory containing rove.json. The target should use the private
Fly shape: ports=[], inject_authorized_keys=false, ssh_host, and ssh_port.
EOF
}

target="${ROVE_TARGET:-devbox}"
instance="${ROVE_INSTANCE:-private-smoke-$(date -u +%Y%m%d%H%M%S)}"
timeout_seconds=300
poll_seconds=2
jsonl=0
destroy_on_failure=0
keep_on_success=0
rove_bin="${ROVE_BIN:-}"
fly_bin="${FLY_BIN:-}"
tailscale_bin="${TAILSCALE_BIN:-tailscale}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target="${2:?missing target}"
      shift 2
      ;;
    --name)
      instance="${2:?missing name}"
      shift 2
      ;;
    --rove-bin)
      rove_bin="${2:?missing rove binary}"
      shift 2
      ;;
    --timeout)
      timeout_seconds="${2:?missing timeout}"
      shift 2
      ;;
    --poll)
      poll_seconds="${2:?missing poll interval}"
      shift 2
      ;;
    --jsonl)
      jsonl=1
      shift
      ;;
    --destroy-on-failure)
      destroy_on_failure=1
      shift
      ;;
    --keep-on-success)
      keep_on_success=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '[private-smoke:error] unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f rove.json ]]; then
  printf '[private-smoke:error] missing rove.json in %s\n' "$PWD" >&2
  exit 1
fi

if [[ -z "${rove_bin}" ]]; then
  if [[ -x ./zig-out/bin/rove ]]; then
    rove_bin="./zig-out/bin/rove"
  else
    rove_bin="rove"
  fi
fi

if [[ -z "${fly_bin}" ]]; then
  if command -v flyctl >/dev/null 2>&1; then
    fly_bin="flyctl"
  elif command -v fly >/dev/null 2>&1; then
    fly_bin="fly"
  else
    printf '[private-smoke:error] flyctl/fly is not available\n' >&2
    exit 1
  fi
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '[private-smoke:error] required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

require_command jq
require_command nc

target_json="$(jq -c --arg target "$target" '.targets[] | select(.name == $target)' rove.json)"
if [[ -z "${target_json}" ]]; then
  printf '[private-smoke:error] target not found in rove.json: %s\n' "$target" >&2
  exit 1
fi

provider="$(jq -r '.provider // ""' <<<"${target_json}")"
if [[ "${provider}" != "fly" ]]; then
  printf '[private-smoke:error] target %s is provider %s, expected fly\n' "$target" "$provider" >&2
  exit 1
fi

app="$(jq -r '(.fly.app // .app // "")' <<<"${target_json}")"
if [[ -z "${app}" || "${app}" == "null" ]]; then
  printf '[private-smoke:error] target %s does not define a Fly app\n' "$target" >&2
  exit 1
fi

ssh_host_template="$(jq -r '(.fly.ssh_host // empty)' <<<"${target_json}")"
ssh_port="$(jq -r '(.fly.ssh_port // 22)' <<<"${target_json}")"
ports_len="$(jq -r 'if .fly.ports == null then "null" else (.fly.ports | length | tostring) end' <<<"${target_json}")"
if [[ "${ports_len}" != "0" ]]; then
  printf '[private-smoke:error] target %s is not private-only: fly.ports should be []\n' "$target" >&2
  exit 1
fi

start_epoch="$(date +%s)"
tmpdir="$(mktemp -d)"
up_log="${tmpdir}/rove-up.log"
machine_id=""
machine_name=""
ssh_host=""
up_pid=""

cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

elapsed() {
  local now
  now="$(date +%s)"
  printf '%d' "$((now - start_epoch))"
}

event() {
  local phase="$1"
  local status="${2:-ok}"
  local detail="${3:-}"
  local elapsed_seconds
  elapsed_seconds="$(elapsed)"
  if [[ "${jsonl}" -eq 1 ]]; then
    jq -cn \
      --arg phase "${phase}" \
      --arg status "${status}" \
      --arg detail "${detail}" \
      --arg instance "${instance}" \
      --arg target "${target}" \
      --arg app "${app}" \
      --arg machine_id "${machine_id}" \
      --arg machine_name "${machine_name}" \
      --argjson elapsed_seconds "${elapsed_seconds}" \
      '{phase:$phase,status:$status,elapsed_seconds:$elapsed_seconds,target:$target,instance:$instance,app:$app,machine_id:$machine_id,machine_name:$machine_name,detail:$detail}'
  else
    if [[ -n "${detail}" ]]; then
      printf '[private-smoke] t+%ss %-24s %-7s %s\n' "${elapsed_seconds}" "${phase}" "${status}" "${detail}"
    else
      printf '[private-smoke] t+%ss %-24s %s\n' "${elapsed_seconds}" "${phase}" "${status}"
    fi
  fi
}

fail() {
  local message="$1"
  event "failed" "error" "${message}"
  if [[ -n "${up_pid}" ]] && kill -0 "${up_pid}" >/dev/null 2>&1; then
    kill "${up_pid}" >/dev/null 2>&1 || true
    wait "${up_pid}" >/dev/null 2>&1 || true
  fi
  if [[ "${destroy_on_failure}" -eq 1 ]]; then
    "${rove_bin}" down "${instance}" >/dev/null 2>&1 || true
    event "cleanup" "warn" "attempted rove down after failure"
  else
    event "cleanup" "warn" "machine may still be running; inspect with: ${rove_bin} status ${instance}"
  fi
  if [[ -s "${up_log}" ]]; then
    printf '[private-smoke:error] rove up log follows\n' >&2
    sed 's/^/[rove-up] /' "${up_log}" >&2
  fi
  exit 1
}

deadline_reached() {
  local started="$1"
  local now
  now="$(date +%s)"
  [[ "$((now - started))" -ge "${timeout_seconds}" ]]
}

instance_slug() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9._ -]+/-/g; s/[_. ]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

render_template() {
  local template="$1"
  local rendered="${template//\{name\}/${instance}}"
  rendered="${rendered//\{machine_name\}/${machine_name}}"
  rendered="${rendered//\{app\}/${app}}"
  printf '%s' "${rendered}"
}

machine_prefix="rove-$(instance_slug "${instance}")-"
if [[ -n "${ssh_host_template}" ]]; then
  ssh_host="$(render_template "${ssh_host_template}")"
fi

event "launch_requested" "ok" "${rove_bin} up ${target} --name ${instance}"
"${rove_bin}" up "${target}" --name "${instance}" >"${up_log}" 2>&1 &
up_pid="$!"

poll_start="$(date +%s)"
created_recorded=0
started_recorded=0
tailnet_recorded=0
tcp_recorded=0

while true; do
  if [[ "${created_recorded}" -eq 0 || "${started_recorded}" -eq 0 ]]; then
    list_json="$("${fly_bin}" machine list --app "${app}" --json 2>/dev/null || printf '[]')"
    row="$(jq -r --arg prefix "${machine_prefix}" '.[] | select(.name | startswith($prefix)) | [.id, .name, (.state // "")] | @tsv' <<<"${list_json}" | head -n 1)"
    if [[ -n "${row}" ]]; then
      IFS=$'\t' read -r machine_id machine_name machine_state <<<"${row}"
      if [[ "${created_recorded}" -eq 0 ]]; then
        created_recorded=1
        if [[ -z "${ssh_host}" && -n "${ssh_host_template}" ]]; then
          ssh_host="$(render_template "${ssh_host_template}")"
        fi
        event "fly_machine_created" "ok" "${machine_id} ${machine_name}"
      fi
      if [[ "${started_recorded}" -eq 0 && "${machine_state}" == "started" ]]; then
        started_recorded=1
        event "fly_machine_started" "ok" "${machine_id}"
      fi
    fi
  fi

  if [[ "${tailnet_recorded}" -eq 0 && -n "${ssh_host}" ]] && command -v "${tailscale_bin}" >/dev/null 2>&1; then
    if "${tailscale_bin}" status 2>/dev/null | awk '{print $2}' | grep -Fx "${ssh_host}" >/dev/null 2>&1; then
      tailnet_recorded=1
      event "tailscale_visible" "ok" "${ssh_host}"
    fi
  fi

  if [[ "${tcp_recorded}" -eq 0 && -n "${ssh_host}" ]]; then
    if nc -z -w 3 "${ssh_host}" "${ssh_port}" >/dev/null 2>&1; then
      tcp_recorded=1
      event "tailnet_tcp_open" "ok" "${ssh_host}:${ssh_port}"
    fi
  fi

  if ! kill -0 "${up_pid}" >/dev/null 2>&1; then
    break
  fi

  if deadline_reached "${poll_start}"; then
    fail "timed out waiting for ${instance} startup phases"
  fi

  sleep "${poll_seconds}"
done

if ! wait "${up_pid}"; then
  fail "rove up failed"
fi
up_pid=""
event "ssh_ready" "ok" "rove up completed"

status_json="$("${rove_bin}" status "${instance}" --json)"
machine_id="$(jq -r '.machine.id // empty' <<<"${status_json}")"
machine_name="$(jq -r '.machine.machine_name // empty' <<<"${status_json}")"
ssh_host="$(jq -r '.machine.host // empty' <<<"${status_json}")"
ssh_port="$(jq -r '.machine.ssh_port // empty' <<<"${status_json}")"

if [[ -z "${machine_id}" || -z "${ssh_host}" ]]; then
  fail "rove status did not return machine id and host"
fi

config_json="$("${fly_bin}" machine status "${machine_id}" --app "${app}" --display-config 2>/dev/null | awk '
  BEGIN { started=0; depth=0 }
  /^[[:space:]]*[{[]/ { started=1 }
  started {
    print
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      if (c == "}") depth--
    }
    if (started && depth == 0) exit
  }
')"

services_count="$(jq '(.services // []) | length' <<<"${config_json}")"
if [[ "${services_count}" != "0" ]]; then
  fail "machine ${machine_id} has ${services_count} Fly service entries"
fi
event "fly_services_check" "ok" "no machine services"

ips_output="$("${fly_bin}" ips list --app "${app}" 2>/dev/null || true)"
if grep -i 'public ingress' <<<"${ips_output}" >/dev/null 2>&1; then
  if [[ "${ALLOW_PUBLIC_FLY_IPS:-0}" == "1" ]]; then
    event "fly_public_ips_check" "warn" "public ingress IPs exist for ${app}"
  else
    fail "app ${app} has public ingress IPs"
  fi
else
  event "fly_public_ips_check" "ok" "no public ingress IPs"
fi

exec_output="$("${rove_bin}" exec "${instance}" -- hostname 2>"${tmpdir}/rove-exec.err")" || {
  sed 's/^/[rove-exec] /' "${tmpdir}/rove-exec.err" >&2 || true
  fail "rove exec failed"
}
event "rove_exec_ok" "ok" "${exec_output}"

if [[ "${keep_on_success}" -eq 1 ]]; then
  event "cleanup" "warn" "kept ${instance} running by request"
else
  "${rove_bin}" down "${instance}" >/dev/null
  event "cleanup" "ok" "destroyed ${instance}"
fi

event "summary" "ok" "private smoke completed"
