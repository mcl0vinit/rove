# Rove

Rove is an opinionated remote development loop.

It does more than boot a machine and hand you a shell. It brings up a pinned devbox, syncs a repo into it, restores tmux context, reconnects you to work that already feels in-progress, and gives you recovery commands when local state and cloud state drift apart.

The current V1 is narrow on purpose:
- Fly Machines only
- CPU devboxes only
- one baked devbox image
- local JSON state in `~/.rove/state.json`
- repo sync with `rsync`
- tmux handoff with either plain layout restore or a custom capture hook
- locked-down SSH with no agent or port forwarding

## Why It Feels Different

- the remote machine is a real devbox, not a blank cloud instance
- the image is pinned, so bring-up is reproducible
- your shell/tmux workflow is part of the product, not an afterthought
- `offload` is about moving working context, not just copying files
- `doctor`, `refresh`, and `adopt` exist because remote development gets messy in practice
- the security model is opinionated: locked-down SSH, separate Git auth, and opt-in `gh` auth sync

## The Loop

This is the core workflow:

```bash
rove run devbox --name work
rove auth work
rove sync work
rove offload work
```

Later:

```bash
rove ssh work
rove pull work
rove down work
```

That is the point of Rove: bring a box up fast, move into it with context, reconnect cleanly, and tear it down without losing track of what happened.

## Install

Install from GitHub with Nix:

```bash
nix profile add github:mcl0vinit/rove
rove help
```

If you are working from a checkout:

```bash
nix develop
nix develop -c zig build test
```

## Core Concepts

- `target`: a named machine definition in `rove.json`
- `name`: a tracked machine instance name such as `work` or `sam-east`
- `workspace`: a repo synced to that machine

## Quick Start

1. Set up a Fly app and publish the base image from [`infra/fly/devbox/`](infra/fly/devbox/README.md).
2. Copy [`rove.example.json`](rove.example.json) to `rove.json`.
3. Replace the example `app` and `image` values with your own Fly app and pinned image digest.
4. Run `rove doctor` to verify local prerequisites.
5. Start a machine, sync your repo, and offload your tmux session.

Example:

```bash
cp rove.example.json rove.json
rove doctor
rove run devbox --name work
rove auth work
rove sync work
rove offload work
```

If you explicitly want local GitHub CLI auth copied to the remote box too:

```bash
rove auth work --copy-gh
```

## Example Config

Use [`rove.example.json`](rove.example.json) as a starting point:

```json
{
  "targets": [
    {
      "name": "devbox",
      "provider": "fly",
      "app": "your-fly-app",
      "image": "registry.fly.io/your-fly-app:latest@sha256:<digest>",
      "vm_size": "shared-cpu-2x",
      "ssh_user": "rove",
      "startup_script": "./scripts/bootstrap.sh",
      "tmux": {
        "backend": "shape"
      }
    }
  ]
}
```

The checked-in `rove.json` in this repo is a working repo-local config for development. Treat `rove.example.json` as the public template.

## Command Overview

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

Common workflow:

```bash
rove run devbox --name work
rove auth work
rove sync work
rove offload work
```

Reconnect later:

```bash
rove ssh work
```

Preview or pull changes back:

```bash
rove pull work --preview
rove pull work
```

Destroy the machine:

```bash
rove down work
```

Workspace selectors accepted by `pull`, `ssh`, and `offload`:
- `active`
- a workspace index from `rove workspaces <name>`
- a workspace label
- a full local path
- a full remote path

## Security Model

Rove is designed for personal remote development, not as a hardened bastion host.

Current defaults:
- SSH is key-only
- root login is disabled
- SSH agent forwarding is disabled
- TCP, stream-local, and tunnel forwarding are disabled
- plain authorized keys are rewritten to `restrict,pty`
- `rove auth` installs a separate Git SSH key, not your normal machine SSH key
- GitHub CLI auth is opt-in and only copied with `--copy-gh`

Important limitation:
- if someone gets shell access to the box, anything you intentionally copied there is exposed

So the safe default is:
- use `rove auth <name>` for SSH Git access
- only use `rove auth <name> --copy-gh` if you explicitly want GitHub CLI auth on that box

## Recovery

Refresh local state from Fly:

```bash
rove refresh
rove refresh work
```

Prune machines that were deleted outside Rove:

```bash
rove refresh --prune-missing
```

Run a health check:

```bash
rove doctor
rove doctor work
```

Adopt an existing machine:

```bash
rove adopt devbox <machine-id> --name recovered
```

`doctor` checks:
- Fly CLI presence and auth
- config loading
- pinned image refs
- managed SSH keys
- optional local GitHub auth availability
- tracked machine reachability
- stale SSH host keys, with automatic cleanup and retry

## Building The Devbox Image

The Fly image scaffold lives in [`infra/fly/devbox/`](infra/fly/devbox/README.md).

After publishing a new image, pin its digest into your config:

```bash
./scripts/pin-image-ref.sh devbox 'registry.fly.io/your-fly-app:latest@sha256:<digest>'
```

## Development

Run tests:

```bash
nix develop -c zig build test
nix develop -c zig build integration
```

Run the fake-provider smoke test directly:

```bash
nix develop -c zig build
./scripts/integration-smoke.sh
```

## V1 Non-Goals

- GPU providers
- multiple providers
- volume-backed roaming state
- live process migration
- editor buffer migration
- multi-user orchestration
