# Rove

Rove is a personal CLI for bringing up a remote devbox, syncing a workspace into it, handing off tmux state, and pulling work back down later.

V1 is intentionally narrow:
- Fly Machines only
- CPU devboxes only
- one baked devbox image
- local JSON state in `~/.rove/state.json`
- repo sync with `rsync`
- tmux handoff with either plain layout restore or your dotfiles-aware hook
- locked-down SSH with no agent or port forwarding

## Current command set

```bash
rove run <target> [--name <name>]
rove status
rove refresh [name] [--prune-missing]
rove doctor [name]
rove auth <name> [--copy-gh]
rove sync <name> [--preview] [--delete]
rove workspaces <name>
rove offload <name> [--workspace <selector>]
rove ssh <name> [--workspace <selector>]
rove pull <name> [--workspace <selector>] [--preview] [--force]
rove adopt <target> <machine-id> [--name <name>]
rove down <name>
```

Workspace selectors accepted by `pull`, `ssh`, and `offload`:
- `active`
- a workspace index from `rove workspaces <name>`
- a workspace label
- a full local path
- a full remote path

## Requirements

- Nix with flakes enabled
- Fly CLI authenticated for the target app
- `jq`
- local `ssh-keygen`

The repo flake already gives you the normal dev shell:

```bash
nix develop
```

## First-time setup

1. Build and test the CLI:

```bash
nix develop -c zig build test
nix develop -c zig build integration
```

2. Set up the Fly app and base image using [`infra/fly/devbox/README.md`](infra/fly/devbox/README.md).

3. Confirm `rove.json` points at a pinned image ref, not plain `:latest`.

The repo currently ships with a pinned working image ref in [`rove.json`](rove.json) and [`rove.example.json`](rove.example.json).

## Publishing and pinning the devbox image

Rebuild and publish the base image from `infra/fly/devbox/`:

```bash
cd infra/fly/devbox
fly deploy --push --app mcl0vinit-devbox
```

After you know the new full image ref, update the target config with:

```bash
./scripts/pin-image-ref.sh devbox 'registry.fly.io/mcl0vinit-devbox:latest@sha256:<digest>'
```

That updates both [`rove.json`](rove.json) and [`rove.example.json`](rove.example.json).

## Normal workflow

Create a machine:

```bash
nix run . -- run devbox --name sam-east
```

Sync the current repo:

```bash
nix run . -- sync sam-east
```

Move your tmux workspace up and attach:

```bash
nix run . -- offload sam-east
```

Reconnect later:

```bash
nix run . -- ssh sam-east
```

Preview or pull changes back:

```bash
nix run . -- pull sam-east --preview
nix run . -- pull sam-east
```

Tear the box down:

```bash
nix run . -- down sam-east
```

## Remote auth story

V1 is opinionated:
- no SSH agent forwarding
- no SSH port forwarding through the devbox
- Git SSH access uses a dedicated Rove-managed Git key, not the machine access key
- local `gh` auth is opt-in and is only copied when you pass `--copy-gh`

Run:

```bash
nix run . -- auth sam-east
```

That does two things by default:
- uploads the dedicated Git auth key to `~/.ssh/rove_git_ed25519` on the remote box
- installs a managed GitHub block in `~/.ssh/config`

If you explicitly want your local GitHub CLI auth copied to the box too:

```bash
nix run . -- auth sam-east --copy-gh
```

If private SSH Git remotes still fail, add the printed `rove-github` public key to GitHub once and rerun `rove auth <name>`.

## Recovery workflow

Refresh local state from Fly:

```bash
nix run . -- refresh
nix run . -- refresh sam-east
```

Prune machines that were deleted outside Rove:

```bash
nix run . -- refresh --prune-missing
```

Import an existing machine:

```bash
nix run . -- adopt devbox <machine-id> --name sam-east
```

Run a full health check:

```bash
nix run . -- doctor
nix run . -- doctor sam-east
```

`doctor` checks:
- Fly CLI presence and auth
- config loading
- pinned image refs
- managed SSH keys
- local GitHub auth availability
- tracked machine reachability
- stale SSH host keys, with automatic cleanup and retry

## Testing

Unit tests:

```bash
nix develop -c zig build test
```

Scripted fake-provider smoke test:

```bash
nix develop -c zig build
./scripts/integration-smoke.sh
```

Or via Zig:

```bash
nix develop -c zig build integration
```

## Explicit V1 non-goals

- GPU providers
- multiple providers
- volume-backed roaming state
- live process migration
- editor buffer migration
- multi-user orchestration
