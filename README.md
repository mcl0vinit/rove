# Rove

Rove provisions and tracks disposable remote machines.

Rove owns machine lifecycle, SSH reachability, bootstrap, provider reconciliation, and teardown. It deliberately does not own workspace sync, terminal session state, distributed search, or higher-level control-plane UX.

The current V1 is narrow on purpose:
- Fly Machines for CPU devboxes
- Vast.ai instances for GPU workloads
- pinned image refs
- local JSON state in `~/.rove/state.json`
- managed SSH keys and isolated known hosts
- optional target bootstrap script

## Core Workflow

```bash
rove up devbox --name work
rove status work
rove inspect work --json
rove ssh work
rove exec work -- uname -a
rove down work
```

`rove run` remains an alias for `rove up`.

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
- `name`: a tracked machine instance name such as `work` or `gpu-east`
- `provider`: the machine backend; currently `fly` and `vast`

## Quick Start

1. Set up a Fly app and publish the base image from [`infra/fly/devbox/`](infra/fly/devbox/README.md).
2. Copy [`rove.example.json`](rove.example.json) to `rove.json`.
3. Replace the example `app` and `image` values with your own Fly app and pinned image digest.
4. Run `rove doctor` to verify local prerequisites.
5. Start a machine.

Example:

```bash
cp rove.example.json rove.json
rove doctor
rove up devbox --name work
rove ssh work
```

## Fly Example Config

```json
{
  "targets": [
    {
      "name": "devbox",
      "provider": "fly",
      "ssh_user": "rove",
      "startup_script": "./scripts/bootstrap.sh",
      "fly": {
        "app": "your-fly-app",
        "image": "registry.fly.io/your-fly-app:latest@sha256:<digest>",
        "vm_size": "shared-cpu-2x"
      }
    }
  ]
}
```

`startup_script` is optional. If present, Rove uploads and runs it after SSH becomes reachable. Provider settings live under a provider-named block such as `fly`; legacy top-level Fly fields are still accepted for old configs.

The checked-in `rove.json` in this repo is a working repo-local config for development. Treat `rove.example.json` as the public template.

## Vast.ai Example Config

Install and authenticate the Vast.ai CLI first:

```bash
pip install vastai
vastai set api-key <your-api-key>
```

Then add a GPU target:

```json
{
  "targets": [
    {
      "name": "gpu-4090",
      "provider": "vast",
      "ssh_user": "root",
      "startup_script": "./scripts/bootstrap-gpu.sh",
      "vast": {
        "query": "gpu_name=RTX_4090 num_gpus=1 verified=true direct_port_count>=1 rentable=true",
        "image": "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime",
        "disk_gb": 80,
        "order": "dlperf_usd-"
      }
    }
  ]
}
```

Rove searches offers with the query, rents the first result, launches it as an SSH/direct instance, attaches Rove's managed SSH key, records the returned `ssh_host` and `ssh_port`, then runs the normal SSH/bootstrap flow.

Use `offer_id` instead of `query` when you want to rent a specific offer:

```json
{
  "name": "gpu-fixed",
  "provider": "vast",
  "ssh_user": "root",
  "vast": {
    "offer_id": 9001,
    "image": "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime",
    "disk_gb": 80
  }
}
```

## Command Overview

```bash
rove up <target> [--name <name>] [--json]
rove run <target> [--name <name>] [--json]
rove list [--json]
rove status [name] [--json]
rove inspect <name> [--json]
rove refresh [name] [--prune-missing] [--json]
rove doctor [name]
rove adopt <target> <machine-id> [--name <name>] [--json]
rove ssh <name>
rove exec <name> -- <command> [args...]
rove down <name> [--json]
```

## Script Contract

Rove's script-facing API is JSON on stdout and errors/warnings on stderr. The normalized SSH endpoint is `ssh_user`, `host`, and `ssh_port`; provider-specific details can live in `provider_metadata`.

Machine-list commands return:

```json
{
  "machines": [
    {
      "name": "work",
      "target_name": "devbox",
      "provider": "fly",
      "id": "machine-id",
      "machine_name": "rove-work-abcd",
      "provider_scope": "your-fly-app",
      "app": "your-fly-app",
      "host": "your-fly-app.fly.dev",
      "ssh_port": 22,
      "region": "iad",
      "remote_state": "started",
      "ssh_user": "rove",
      "status": "ready",
      "provider_metadata": null
    }
  ]
}
```

Single-machine commands return:

```json
{
  "machine": {
    "name": "work",
    "target_name": "devbox",
    "provider": "fly",
    "id": "machine-id",
    "machine_name": "rove-work-abcd",
    "provider_scope": "your-fly-app",
    "app": "your-fly-app",
    "host": "your-fly-app.fly.dev",
    "ssh_port": 22,
    "region": "iad",
    "remote_state": "started",
    "ssh_user": "rove",
    "status": "ready",
    "provider_metadata": null
  }
}
```

Prefer `rove inspect <name> --json` for scripts and higher-level automation.

## Security Model

Rove is designed for personal remote machine provisioning, not as a hardened bastion host.

Current defaults:
- SSH is key-only
- root login is disabled in the provided devbox image
- SSH agent forwarding is disabled
- TCP, stream-local, and tunnel forwarding are disabled
- plain authorized keys are rewritten to `restrict,pty` in the provided devbox image
- SSH known-host entries are isolated under `~/.rove/known_hosts`

Important limitation:
- if someone gets shell access to the box, anything you intentionally put there is exposed

## Recovery

Refresh local state from the provider:

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
- configured provider CLI presence and auth
- config loading
- pinned image refs
- managed SSH keys
- tracked machine reachability
- stale SSH host keys, with automatic cleanup and retry

## Boundaries

Rove should stay the provider-backed machine launcher.

Rove should not own:
- terminal session control
- repo, port, or pane indexing
- distributed grep/search
- workspace sync or pull flows
- public UI or cockpit behavior

Higher-level tools should treat Rove as a backend: create or adopt a machine, inspect its machine record, then decide what to do with it.

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
