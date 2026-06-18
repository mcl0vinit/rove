#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$HOME/work" "$HOME/.cache/rove"

if [[ -d /persist ]]; then
  if [[ -d /persist/work ]] || mkdir -p /persist/work 2>/dev/null; then
    ln -sfn /persist/work "$HOME/work/persist"
  fi
fi

bashrc="$HOME/.bashrc"
if [[ ! -e "$bashrc" ]]; then
  cat >"$bashrc" <<'EOF'
# >>> rove >>>
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/usr/local/bin:$PATH"
# <<< rove <<<
EOF
elif [[ -w "$bashrc" ]] && ! grep -q '>>> rove >>>' "$bashrc" 2>/dev/null; then
  cat >>"$bashrc" <<'EOF'
# >>> rove >>>
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/usr/local/bin:$PATH"
# <<< rove <<<
EOF
fi

touch "$HOME/.rove-ready"
