# Rove

Rove is a personal CLI for launching, tracking, reaching, and destroying disposable remote machines through provider backends.

The important part is the stable interface:

```bash
rove up <target> --name <name>
rove inspect <name> --json
rove ssh <name>
rove exec <name> -- <command>
rove down <name>
```

The provider can be Fly, Vast.ai, or a future backend. Rove keeps the same lifecycle and SSH experience while provider-specific details stay in `rove.json`.

## What Rove Owns

Rove owns:
- machine lifecycle: create, inspect, refresh, adopt, destroy
- SSH reachability: managed keys, isolated known hosts, `ssh`, `exec`, file upload for bootstrap
- optional bootstrap scripts after SSH becomes reachable
- local machine state in `~/.rove/state.json`
- provider reconciliation through `rove refresh` and `rove doctor`
- script-friendly JSON output

Rove does not own:
- terminal session state
- tmux layout, bindings, capture, or orchestration
- repo, pane, port, or process indexing
- distributed search
- workspace sync or pull flows
- public UI or cockpit behavior

Higher-level tools should treat Rove as the machine backend: create or adopt a machine, inspect the normalized machine record, then decide what to do with it.

## Providers

Current providers:
- `fly`: Fly Machines for CPU devboxes
- `vast`: Vast.ai instances for GPU workloads

Provider-specific CLIs are called directly. Rove does not reimplement each provider API yet.

Provider prerequisites:
- Fly targets require `flyctl` and Fly auth.
- Vast targets require `vastai` and a configured Vast.ai API key.

`rove doctor` checks only the providers present in your config.

## Install

Install Rove with Nix:

```bash
nix profile add github:mcl0vinit/rove
rove help
```

From a checkout:

```bash
nix develop
nix develop -c zig build test
```

## Core Concepts

- `target`: a named machine definition in `rove.json`, such as `devbox` or `gpu-4090`
- `name`: a tracked machine instance name, such as `work`, `train`, or `gpu-east`
- `provider`: the backend used by a target
- `machine record`: the normalized state Rove stores locally and prints as JSON

Targets are reusable definitions. Names are individual machine instances created from those targets.

## Quick Start

Copy the example config and edit the provider settings:

```bash
cp rove.example.json rove.json
rove doctor
rove up devbox --name work
rove ssh work
```

The checked-in `rove.json` is a repo-local development config. Treat `rove.example.json` as the public template.

For personal machines, point `startup_script` at your dotfiles remote bootstrap. In this checkout layout that is:

```json
"startup_script": "../dotfiles/bin/bootstrap-remote"
```

## Commands

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

`rove run` is an alias for `rove up`.

## Fly Targets

Fly targets are useful for CPU devboxes and long-lived base images.

Rove does not own the devbox image build or publish path. Build and publish the
image from the dotfiles-owned image project, for example:

- `~/Documents/Code/dotfiles/images/mesh-devbox`
- `~/Documents/Code/dotfiles/deploy/fly/mesh-devbox`

Then pin the resulting image digest in the Rove target config:

```bash
./scripts/pin-image-ref.sh devbox 'registry.fly.io/your-fly-app:latest@sha256:<digest>'
```

Example target:

```json
{
  "name": "devbox",
  "provider": "fly",
  "ssh_user": "rove",
  "startup_script": "../dotfiles/bin/bootstrap-remote",
  "fly": {
    "app": "your-fly-app",
    "image": "registry.fly.io/your-fly-app:latest@sha256:<digest>",
    "vm_size": "shared-cpu-2x",
    "ports": [],
    "inject_authorized_keys": false,
    "ssh_host": "mesh-{name}",
    "ssh_port": 2222,
    "env": {
      "TAILSCALE_HOSTNAME": "mesh-{name}",
      "TAILSCALE_SERVE_SSH": "1"
    }
  }
}
```

Fly fields:
- `app`: Fly app name
- `image`: image ref to run, preferably pinned by digest
- `vm_size`: Fly machine size
- `region`: optional fixed region
- `region_preference`: optional ordered list of preferred regions
- `ports`: optional Fly public port mappings. If omitted, Rove preserves the old default `22:2222/tcp`; use `[]` for no public Fly service.
- `env`: optional launch-time environment variables. String values support `{name}`, `{machine_name}`, and `{app}` templates.
- `inject_authorized_keys`: defaults to `true`; set to `false` when the image/provider already receives authorized keys from app secrets.
- `ssh_host`: optional SSH host template stored in Rove state after launch.
- `ssh_port`: optional SSH port stored in Rove state after launch.

Target fields:
- `ssh_identity_file`: optional private key path for Rove's SSH operations. Omit it to use Rove's managed key; if `inject_authorized_keys` is `false`, make sure the provider/app secret contains the matching public key.

Legacy top-level Fly fields are still accepted for older configs, but new configs should use the nested `fly` block.

### Private Fly Smoke Test

For private-only Fly targets, use the smoke helper after publishing and pinning
a new image:

```bash
nix develop -c zig build
nix develop -c scripts/private-fly-smoke.sh --target devbox
```

The helper launches a uniquely named machine, records phase timings, checks that
the machine has no Fly services, checks that the app has no public ingress IPs,
waits for private SSH, runs `rove exec`, and destroys the machine on success.
Use `--jsonl` for machine-readable event output.

The default private path expects these app secrets by name:

- `AUTHORIZED_KEYS`: public keys only. Include `~/.rove/id_ed25519.pub` for
  Rove automation.
- `MESH_TAILSCALE_AUTHKEY`: runtime Tailscale auth key.

Keep `ssh_identity_file` unset unless you know the private key can sign in
batch mode. Passphrase-protected personal keys can be accepted by the server but
still fail noninteractive Rove SSH.

Fly may report app secrets as `Staged` when using `fly machine run` without an
app release. A newly created Machine still receives staged secrets at boot; use
the smoke helper to prove the actual runtime path.

If `mesh-{name}` does not resolve locally, confirm the node appears in
`tailscale status` and retry from the same shell used for Rove. You can also use
the full tailnet DNS name from `tailscale status` while debugging.

## Vast.ai Targets

Vast targets are useful for short-lived GPU machines. Rove searches offers, rents an instance, requests direct SSH, attaches Rove's managed SSH public key, records the returned `ssh_host` and `ssh_port`, then uses the normal Rove SSH/bootstrap flow.

Install and authenticate the Vast CLI:

```bash
pip install vastai
vastai set api-key <your-api-key>
```

Example target using marketplace search:

```json
{
  "name": "gpu-4090",
  "provider": "vast",
  "ssh_user": "root",
  "startup_script": "../dotfiles/bin/bootstrap-remote",
  "vast": {
    "query": "gpu_name=RTX_4090 num_gpus=1 verified=true direct_port_count>=1 rentable=true",
    "image": "pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime",
    "disk_gb": 80,
    "order": "dlperf_usd-"
  }
}
```

Example target using a specific offer:

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

Vast fields:
- `query`: Vast offer query; required unless `offer_id` is set
- `offer_id`: specific offer to rent; skips search
- `image`: Docker image; required unless `template_hash` is set
- `template_hash`: Vast template hash; alternative to `image`
- `disk_gb`: disk size in GB, default `40`
- `order`: offer ordering, default `dlperf_usd-`
- `search_type`: Vast search type, default `on-demand`
- `direct`: request direct SSH, default `true`
- `cancel_unavail`: cancel unavailable offers, default `true`
- `bid_price`: optional interruptible bid price
- `env`: optional Vast env string
- `onstart_cmd`: optional Vast on-start command

## Script Contract

Rove's script-facing API is JSON on stdout and errors or warnings on stderr.

The stable normalized SSH endpoint is:
- `ssh_user`
- `host`
- `ssh_port`

Common machine fields:

```json
{
  "name": "train",
  "target_name": "gpu-4090",
  "provider": "vast",
  "id": "7001",
  "machine_name": "rove-train",
  "provider_scope": null,
  "app": null,
  "host": "ssh5.vast.ai",
  "ssh_port": 32022,
  "region": "US",
  "remote_state": "running",
  "ssh_user": "root",
  "status": "ready",
  "provider_metadata": null
}
```

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

## Recovery

Refresh local state from the provider:

```bash
rove refresh
rove refresh work
```

Prune machines deleted outside Rove:

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
rove adopt gpu-4090 <vast-instance-id> --name recovered-gpu
```

`doctor` checks:
- configured provider CLI presence and auth
- config loading
- image digest pinning where the target has an image field
- managed SSH keys
- tracked machine reachability
- stale SSH host keys, with automatic cleanup and retry

## Security Model

Rove is designed for personal remote machine provisioning, not as a hardened bastion host.

Current defaults:
- SSH is key-only.
- SSH agent forwarding is disabled by Rove's client invocation.
- TCP, stream-local, and tunnel forwarding are disabled by Rove's client invocation.
- SSH known-host entries are isolated under `~/.rove/known_hosts`.
- Fly targets can opt out of public Fly services with `ports: []` and use a private-network `ssh_host` instead.
- The externally published Fly devbox image is expected to disable root login and restrict authorized keys; Rove only pins and launches that image.
- Vast instances run whatever image/template you choose; validate image defaults yourself.

Important limitation:
- if someone gets shell access to a machine, anything you intentionally put there is exposed

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

Build the CLI:

```bash
nix develop -c zig build --summary all
```
