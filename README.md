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

The provider can be Fly, Vast.ai, or a future backend. Rove keeps the same lifecycle and SSH experience while provider-specific details stay in local config.

## What Rove Owns

Rove owns:
- machine lifecycle: create, inspect, refresh, adopt, destroy
- SSH reachability: managed keys, isolated known hosts, `ssh`, `exec`, file upload for bootstrap
- optional bootstrap scripts after SSH becomes reachable
- optional generic readiness commands after SSH/bootstrap
- local machine state in `~/.rove/state.json`
- provider reconciliation through `rove refresh` and `rove doctor`
- script-friendly JSON output and launch progress events

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

- `target`: a named machine definition in Rove config, such as `devbox` or `gpu-4090`
- `name`: a tracked machine instance name, such as `work`, `train`, or `gpu-east`
- `provider`: the backend used by a target
- `machine record`: the normalized state Rove stores locally and prints as JSON

Targets are reusable definitions. Names are individual machine instances created from those targets.

## Quick Start

Copy the example config into either a repo-local config or your user config and
edit the provider settings:

```bash
mkdir -p ~/.config/rove
cp rove.example.json ~/.config/rove/rove.json
rove doctor
rove up devbox --name work
rove ssh work
```

Rove looks for config in this order: `ROVE_CONFIG`, `./rove.json`, then
`~/.config/rove/rove.json`. Real config files are local state and should not be
tracked; `rove.example.json` is the public template.

If a machine needs bootstrapping after SSH becomes reachable, set
`startup_script` in your local config. Keep personal paths out of tracked
templates.

```json
"startup_script": "/path/to/bootstrap-remote"
```

If a machine should not be marked ready until a generic remote check succeeds,
set `readiness_command`. Rove runs it over SSH after SSH is reachable and after
`startup_script`, if one is configured. The command is polled until it exits 0
or the timeout expires.

```json
"readiness_command": "test -f /tmp/app-ready",
"readiness_timeout_ms": 60000,
"readiness_poll_interval_ms": 1000
```

Use `startup_script` for setup work. Use `readiness_command` for a readiness
gate that should hold the machine in a non-ready state until the target image or
application reports it is usable. Rove does not print readiness command output
by default.

## Commands

```bash
rove up <target> [--name <name>] [--json] [--progress-jsonl]
rove run <target> [--name <name>] [--json] [--progress-jsonl]
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

For baked devbox images, repository ownership is intentionally split:

- The image repo owns the Dockerfile, build inputs, publish wrapper, and image boot behavior.
- Rove owns machine launch, local machine state, and SSH reachability.
- Higher-level tools own control plane behavior, session state, and developer UX.

Rove should receive an immutable image ref from the image publish process and
pin that exact ref in your local Rove config. Do not put Fly
tokens, Tailscale auth keys, SSH private keys, or secret values in tracked files.
Run the publish wrapper from the image repo, then pass its
`registry.fly.io/<fly-app>:<tag>@sha256:<digest>` output to Rove:

```bash
./scripts/pin-image-ref.sh devbox 'registry.fly.io/<fly-app>:<tag>@sha256:<digest>'
```

Private Fly devboxes should use Fly secrets as the source of truth for SSH keys
and Tailscale auth. Set the secrets out of band and store only their names in
documentation:

```bash
flyctl secrets set --app <fly-app> \
  AUTHORIZED_KEYS='<public ssh keys only>' \
  MESH_TAILSCALE_AUTHKEY='<tailscale auth key>'
```

Example private target:

```json
{
  "name": "devbox",
  "provider": "fly",
  "ssh_user": "rove",
  "ssh_resolver": "tailscale",
  "require_private_ssh": true,
  "fly": {
    "app": "your-fly-app",
    "image": "registry.fly.io/your-fly-app:deployment-<id>@sha256:<digest>",
    "vm_size": "shared-cpu-2x",
    "ports": [],
    "inject_authorized_keys": false,
    "ssh_host": "private-{name}",
    "ssh_port": 2222,
    "env": {
      "TAILSCALE_HOSTNAME": "private-{name}",
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
- `ports`: optional Fly public port mappings. If omitted or set to `[]`, Rove opens no public Fly service ports.
- `allow_public_ports`: defaults to `false`; must be `true` before any non-empty `ports` list is accepted.
- `env`: optional launch-time environment variables. String values support `{name}`, `{machine_name}`, and `{app}` templates.
- `inject_authorized_keys`: defaults to `true`; set to `false` when the image/provider already receives authorized keys from app secrets.
- `ssh_host`: optional SSH host template stored in Rove state after launch.
- `ssh_port`: optional SSH port stored in Rove state after launch.

Target fields:
- `ssh_identity_file`: optional private key path for Rove's SSH operations. Omit it to use Rove's managed key; if `inject_authorized_keys` is `false`, make sure the `AUTHORIZED_KEYS` Fly secret contains the matching public key.
- `ssh_resolver`: optional SSH host resolver. Defaults to `system`, which preserves normal OpenSSH/provider behavior. Set to `tailscale` to resolve `ssh_host` with `tailscale ip -4 <host>` before SSH operations. `none` records that no resolver policy is being used.
- `require_private_ssh`: optional guardrail, default `false`. When `true`, Rove requires a private resolver such as `tailscale` and fails closed instead of falling back to public/system SSH.
- `startup_script`: optional post-SSH bootstrap script path.
- `readiness_command`: optional generic post-SSH command that must exit 0 before Rove marks the machine ready.
- `readiness_timeout_ms`: optional readiness command timeout, default 180000.
- `readiness_poll_interval_ms`: optional readiness command poll interval, default 2000.

Legacy top-level Fly fields are still accepted for older configs, but new configs should use the nested `fly` block.

### Private Mesh Devbox Loop

After publishing and pinning the image, launch through Rove:

```bash
rove doctor
rove up devbox --name work
rove inspect work --json
```

Verify that Rove reaches the machine over the private resolver path, not public
Fly ingress:

```bash
tailscale ip -4 private-work
rove exec work -- hostname
flyctl machine list --app <fly-app>
flyctl ips list --app <fly-app>
```

For private-only targets, the machine should have no Fly services from Rove's
launch args and the app should not need public ingress IPs for Rove SSH. Mesh
validation happens from the Mesh repo or CLI after Rove can inspect and SSH to
the machine.

Public Fly service ports are intentionally a two-step opt-in. A non-empty
`ports` list without `"allow_public_ports": true` is rejected before launch.

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

Troubleshooting:
- Missing secrets: confirm `flyctl secrets list --app <fly-app>` includes `AUTHORIZED_KEYS` and `MESH_TAILSCALE_AUTHKEY`; do not print secret values.
- No Tailscale IP or DNS name: check the image boot logs from Fly, confirm the auth key is valid, and verify `TAILSCALE_HOSTNAME` rendered to the expected private hostname.
- Rove cannot SSH: confirm `tailscale ip -4 <ssh-host>` succeeds, the resolved IP accepts TCP on the configured SSH port, and the `AUTHORIZED_KEYS` secret includes Rove's public key.
- Wrong image ref: run `rove doctor` and inspect the target image; repin to the digest emitted by the dotfiles publish wrapper.
- Public ports accidentally configured: set `"ports": []` in the target and relaunch. Non-empty `ports` require `"allow_public_ports": true`.
- Higher-level peer validation fails: first prove `rove exec <name> -- hostname` works, then use that tool's diagnostics to inspect runtime state and peer health.

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
  "startup_script": "/path/to/bootstrap-remote",
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

`rove up <target> --progress-jsonl` writes launch progress events as JSON Lines
to stderr. This keeps stdout compatible with the existing human output and final
`--json` machine document. Events use provider-neutral lifecycle phases:
`launch`, `provider_create`, `ssh_wait`, `endpoint_resolution`, `ssh`,
`bootstrap`, `readiness_command`, and `ready`.

Each progress event includes stable fields:
- `type`
- `phase`
- `status`
- `elapsed_ms`
- `instance_name`
- `target_name`
- `provider`
- `machine_id`
- `machine_name`
- `ssh_configured_host`
- `ssh_resolved_host`
- `ssh_endpoint_host`
- `ssh_port`

The stable normalized SSH endpoint is:
- `ssh_user`
- `host`
- `ssh_configured_host`
- `ssh_resolved_host`
- `ssh_endpoint_host`
- `ssh_port`
- `ssh_resolver`
- `require_private_ssh`

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
  "ssh_configured_host": "ssh5.vast.ai",
  "ssh_resolved_host": null,
  "ssh_endpoint_host": "ssh5.vast.ai",
  "ssh_port": 32022,
  "ssh_resolver": "system",
  "require_private_ssh": false,
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
      "ssh_configured_host": "your-fly-app.fly.dev",
      "ssh_resolved_host": null,
      "ssh_endpoint_host": "your-fly-app.fly.dev",
      "ssh_port": 22,
      "ssh_resolver": "system",
      "require_private_ssh": false,
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
    "ssh_configured_host": "your-fly-app.fly.dev",
    "ssh_resolved_host": null,
    "ssh_endpoint_host": "your-fly-app.fly.dev",
    "ssh_port": 22,
    "ssh_resolver": "system",
    "require_private_ssh": false,
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
