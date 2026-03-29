#!/usr/bin/env bash
set -euo pipefail

export PATH="/nix/var/nix/profiles/default/bin:/root/.nix-profile/bin:${PATH}"

persist_dir="${ROVE_PERSIST_DIR:-/persist}"
host_key_dir="${persist_dir}/ssh"
authorized_keys_file="/root/.ssh/authorized_keys"

mkdir -p /root/.ssh /etc/ssh /var/run/sshd
chmod 700 /root/.ssh

if [[ -f "${persist_dir}/authorized_keys" ]]; then
  cp "${persist_dir}/authorized_keys" "${authorized_keys_file}"
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

chmod 600 "${authorized_keys_file}"

mkdir -p "${host_key_dir}"

for key_type in ed25519 rsa; do
  key_path="${host_key_dir}/ssh_host_${key_type}_key"
  if [[ ! -f "${key_path}" ]]; then
    ssh-keygen -q -N "" -t "${key_type}" -f "${key_path}"
  fi
done

cp "${host_key_dir}"/ssh_host_* /etc/ssh/
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/ssh/ssh_host_*_key.pub

exec sshd -D -e -f /etc/ssh/sshd_config
