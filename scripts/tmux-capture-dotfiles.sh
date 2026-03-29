#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2129
set -euo pipefail

local_root="${1:?usage: tmux-capture-dotfiles.sh <local-root> <current-dir> <remote-root> <remote-current-dir>}"
current_dir="${2:?usage: tmux-capture-dotfiles.sh <local-root> <current-dir> <remote-root> <remote-current-dir>}"
remote_root="${3:?usage: tmux-capture-dotfiles.sh <local-root> <current-dir> <remote-root> <remote-current-dir>}"
remote_current_dir="${4:?usage: tmux-capture-dotfiles.sh <local-root> <current-dir> <remote-root> <remote-current-dir>}"

command -v tmux >/dev/null 2>&1 || exit 1
[ -n "${TMUX:-}" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1

single_quote() {
  local raw="$1"
  printf "'%s'" "${raw//\'/\'\"\'\"\'}"
}

escape_double_quoted() {
  local raw="$1"
  raw="${raw//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  raw="${raw//\$/\\$}"
  raw="${raw//\`/\\\`}"
  printf '%s' "$raw"
}

quote_remote_path() {
  local raw="$1"
  local rest

  if [[ "$raw" == \$HOME* ]]; then
    rest="${raw#\$HOME}"
    printf '"$HOME%s"' "$(escape_double_quoted "$rest")"
    return
  fi

  printf '"%s"' "$(escape_double_quoted "$raw")"
}

map_local_path() {
  local local_path="$1"

  if [ "$local_path" = "$local_root" ]; then
    printf '%s\n' "$remote_root"
    return
  fi

  if [[ "$local_path" == "$local_root/"* ]]; then
    printf '%s%s\n' "$remote_root" "${local_path#"$local_root"}"
    return
  fi

  if [ "$local_path" = "$current_dir" ]; then
    printf '%s\n' "$remote_current_dir"
    return
  fi

  printf '%s\n' "$remote_root"
}

base_session_name() {
  case "$1" in
    act-*)
      printf '%s\n' "${1#act-}"
      ;;
    arc-*)
      printf '%s\n' "${1#arc-}"
      ;;
    tmp-*)
      printf '%s\n' "${1#tmp-}"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

session="$(tmux display-message -p '#S')"
[ -n "$session" ] || exit 1

remote_script_file="$(mktemp)"
trap 'rm -f "$remote_script_file"' EXIT

{
  printf 'set -euo pipefail\n'
  printf 'session=%s\n' "$(single_quote "$session")"
  printf 'active_window_id=\n'
  printf 'if tmux has-session -t "$session" 2>/dev/null; then\n'
  printf '  tmux kill-session -t "$session"\n'
  printf 'fi\n'
} >"$remote_script_file"

window_lines="$(tmux list-windows -t "$session" -F '#{window_id}|#{window_name}|#{window_layout}|#{window_active}')"
[ -n "$window_lines" ] || exit 1

window_number=0
while IFS='|' read -r window_id window_name window_layout window_active; do
  [ -n "$window_id" ] || continue
  window_number=$((window_number + 1))

  pane_number=0
  active_pane_number=1
  pane_remote_paths=()
  pane_lines="$(tmux list-panes -t "$window_id" -F '#{pane_current_path}|#{pane_active}')"

  while IFS='|' read -r pane_cwd pane_active; do
    [ -n "$pane_cwd" ] || continue
    pane_number=$((pane_number + 1))
    mapped_remote="$(map_local_path "$pane_cwd")"
    pane_remote_paths+=("$mapped_remote")

    if [ "$pane_active" = "1" ]; then
      active_pane_number="$pane_number"
    fi
  done <<EOF
$pane_lines
EOF

  first_pane_remote="${pane_remote_paths[0]:-}"
  [ -n "$first_pane_remote" ] || exit 1

  if [ "$window_number" -eq 1 ]; then
    printf 'remote_window_id=$(tmux new-session -d -P -F '"'"'#{window_id}'"'"' -s "$session" -n %s -c %s)\n' \
      "$(single_quote "$window_name")" \
      "$(quote_remote_path "$first_pane_remote")" >>"$remote_script_file"
  else
    printf 'remote_window_id=$(tmux new-window -P -F '"'"'#{window_id}'"'"' -d -t "$session" -n %s -c %s)\n' \
      "$(single_quote "$window_name")" \
      "$(quote_remote_path "$first_pane_remote")" >>"$remote_script_file"
  fi

  if [ "${#pane_remote_paths[@]}" -gt 1 ]; then
    for ((pane_index = 1; pane_index < ${#pane_remote_paths[@]}; pane_index++)); do
      printf 'tmux split-window -d -t "$remote_window_id" -c %s\n' \
        "$(quote_remote_path "${pane_remote_paths[$pane_index]}")" >>"$remote_script_file"
    done
  fi

  printf 'tmux select-layout -t "$remote_window_id" %s >/dev/null\n' "$(single_quote "$window_layout")" >>"$remote_script_file"
  printf 'active_pane_id=$(tmux list-panes -t "$remote_window_id" -F '"'"'#{pane_id}'"'"' | sed -n '"'"'%sp'"'"')\n' "$active_pane_number" >>"$remote_script_file"
  printf 'if [ -n "$active_pane_id" ]; then\n' >>"$remote_script_file"
  printf '  tmux select-pane -t "$active_pane_id"\n' >>"$remote_script_file"
  printf 'fi\n' >>"$remote_script_file"

  if [ "$window_active" = "1" ]; then
    printf 'active_window_id="$remote_window_id"\n' >>"$remote_script_file"
  fi
done <<EOF
$window_lines
EOF

printf 'if [ -n "$active_window_id" ]; then\n' >>"$remote_script_file"
printf '  tmux select-window -t "$active_window_id"\n' >>"$remote_script_file"
printf 'fi\n' >>"$remote_script_file"

if command -v tmx-session-scratchpad >/dev/null 2>&1; then
  scratchpad_path="$(tmx-session-scratchpad path "$session" 2>/dev/null || true)"
  if [ -n "$scratchpad_path" ] && [ -f "$scratchpad_path" ]; then
    scratchpad_base64="$(base64 <"$scratchpad_path" | tr -d '\n')"
    scratchpad_name="$(base_session_name "$session").md"

    printf 'scratchpad_dir="${XDG_STATE_HOME:-$HOME/.local/state}/tmux-scratchpads"\n' >>"$remote_script_file"
    printf 'mkdir -p "$scratchpad_dir"\n' >>"$remote_script_file"
    printf 'scratchpad_file="$scratchpad_dir"/%s\n' "$(single_quote "$scratchpad_name")" >>"$remote_script_file"
    printf 'cat <<'"'"'__ROVE_SCRATCHPAD__'"'"' | base64 -d > "$scratchpad_file"\n' >>"$remote_script_file"
    printf '%s\n' "$scratchpad_base64" >>"$remote_script_file"
    printf '__ROVE_SCRATCHPAD__\n' >>"$remote_script_file"
  fi
fi

attach_command="tmux attach-session -t $(single_quote "$session")"

jq -n \
  --arg session_name "$session" \
  --rawfile remote_script "$remote_script_file" \
  --arg attach_command "$attach_command" \
  '{
    session_name: $session_name,
    remote_script: $remote_script,
    attach_command: $attach_command
  }'
