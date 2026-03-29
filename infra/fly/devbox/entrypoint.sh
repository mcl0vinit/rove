#!/usr/bin/env bash
set -euo pipefail

export PATH="/home/rove/.local/share/rove/devbox-profile/bin:/home/rove/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

persist_dir="${ROVE_PERSIST_DIR:-/persist}"
host_key_dir="${persist_dir}/ssh"
workspace_dir="${ROVE_WORKSPACE_DIR:-/workspace}"
login_user="${ROVE_LOGIN_USER:-rove}"
login_group="${ROVE_LOGIN_GROUP:-${login_user}}"
login_home="${ROVE_LOGIN_HOME:-/home/${login_user}}"
authorized_keys_file="${login_home}/.ssh/authorized_keys"
persist_work_dir="${persist_dir}/work"

mkdir -p "${login_home}/.ssh" /etc/ssh /var/run/sshd /var/empty "${host_key_dir}" "${persist_work_dir}" "${workspace_dir}"
chmod 700 "${login_home}/.ssh"
chmod 755 /var/empty
chown -R "${login_user}:${login_group}" "${login_home}" "${persist_work_dir}" "${workspace_dir}"

if command -v passwd >/dev/null 2>&1; then
  passwd -d "${login_user}" >/dev/null 2>&1 || true
fi

if [[ -f "${persist_dir}/authorized_keys" ]]; then
  cp "${persist_dir}/authorized_keys" "${authorized_keys_file}"
elif [[ -n "${ROVE_AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "${ROVE_AUTHORIZED_KEYS}" > "${authorized_keys_file}"
elif [[ -n "${AUTHORIZED_KEYS:-}" ]]; then
  printf '%s\n' "${AUTHORIZED_KEYS}" > "${authorized_keys_file}"
fi

if [[ ! -f "${authorized_keys_file}" ]]; then
  cat >&2 <<'EOF'
[error] no authorized SSH keys found
[hint] set AUTHORIZED_KEYS as a Fly secret or place /persist/authorized_keys on a mounted volume
EOF
  exit 1
fi

chown "${login_user}:${login_group}" "${authorized_keys_file}"
chmod 600 "${authorized_keys_file}"

for key_type in ed25519 rsa; do
  key_path="${host_key_dir}/ssh_host_${key_type}_key"
  if [[ ! -f "${key_path}" ]]; then
    ssh-keygen -q -N "" -t "${key_type}" -f "${key_path}"
  fi
done

cp "${host_key_dir}"/ssh_host_* /etc/ssh/
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/ssh/ssh_host_*_key.pub

sshd_bin="$(command -v sshd)"
if [[ -z "${sshd_bin}" ]]; then
  cat >&2 <<'EOF'
[error] sshd not found in PATH
EOF
  exit 1
fi

exec "${sshd_bin}" -D -e -f /etc/ssh/sshd_config
