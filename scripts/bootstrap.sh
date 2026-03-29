#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME/work" "$HOME/.cache/rove"

if [[ -d /persist ]]; then
  mkdir -p /persist/work
  ln -sfn /persist/work "$HOME/work/persist"
fi

bashrc="$HOME/.bashrc"
if ! grep -q '>>> rove >>>' "$bashrc" 2>/dev/null; then
  cat >>"$bashrc" <<'EOF'
# >>> rove >>>
export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook bash)"
fi
# <<< rove <<<
EOF
fi

tmux has-session -t main 2>/dev/null || tmux new-session -d -s main -c "$HOME/work"

touch "$HOME/.rove-ready"
