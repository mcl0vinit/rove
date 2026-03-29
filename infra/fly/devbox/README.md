# Fly Devbox

This directory defines the first Fly-based Rove substrate: a small CPU devbox image with Nix, SSH, and your baked-in `portable-linux` dotfiles baseline.

## What this image is for

- boot a ready-to-use remote machine quickly
- let project-specific flakes define language runtimes and app dependencies
- keep your portable shell, tmux, and editor defaults in the image instead of replaying Home Manager on every boot
- keep the base image focused on remote-dev primitives:
  - `nix`
  - `git`
  - `tmux`
  - `openssh`
  - `rsync`
  - `ripgrep`
  - `fd`
  - `jq`
  - `curl`
  - `direnv`
  - `nix-direnv`

## Why it looks like this

This image is intentionally not a general workstation snapshot.

The base layer should only cover:
- shell access
- repo transfer
- bootstrap scripts
- common terminal tooling
- smooth `nix develop` / project flake usage

Language runtimes should come from each project's own flake.

## Files

- `flake.nix`: declarative package set for the base image
- `Dockerfile`: builds on Debian, layers a single-user Nix install on top, and applies the pinned dotfiles baseline during image build
- `entrypoint.sh`: prepares SSH keys and starts `sshd`
- `sshd_config`: raw SSH service on internal port `2222`
- `fly.toml`: starter app config for a CPU-only Fly app

## Initial setup

1. The app name in `fly.toml` is already set to `mcl0vinit-devbox`.
2. Create the app:

```bash
fly apps create mcl0vinit-devbox
```

3. Set your SSH public key as a secret:

```bash
fly secrets set AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" --app mcl0vinit-devbox
```

4. If you want normal public `ssh` / `scp` / `rsync`, allocate a dedicated IPv4:

```bash
fly ips allocate-v4 --app mcl0vinit-devbox
```

5. Deploy the image.

If you want the first manually deployed Machine close to where you are right now, pass a region explicitly at deploy time:

```bash
fly deploy --region <closest-region>
```

6. Optional: create a volume only if you want region stickiness more than roaming placement:

```bash
fly volumes create data --app mcl0vinit-devbox --region <your-region> --size 20
```

7. If you create that volume, uncomment the mount in `fly.toml`.

## Region strategy

For your use case, the right default is:
- no fixed `primary_region` in `fly.toml`
- no fixed `region` in `rove.json` unless you want one
- no volume by default

That lets future `rove run` calls create Machines near wherever you are when you run the command.

The tradeoff is persistence:
- Fly volumes are tied to one region
- a Machine that needs a volume cannot roam freely between regions

So there are really two modes:
- roaming mode: nearest region, ephemeral machine, no volume
- sticky mode: fixed region, optional volume, better persistence

For Rove V1, roaming mode is the cleaner default.

## Deploying the image
You can still use plain deploy for image iteration:

```bash
fly deploy
```

The image is pinned to a specific dotfiles commit in `Dockerfile` via `DOTFILES_REF`. When you want a newer baseline baked in, update that ref and rebuild the image.

## Access modes

### Normal SSH

If you allocated a dedicated IPv4, you can connect with:

```bash
ssh rove@mcl0vinit-devbox.fly.dev
```

### Fly console / Fly SSH

If you skip public raw SSH for now, Fly's own access path still works:

```bash
fly ssh console --app mcl0vinit-devbox
```

## Notes

- Fly's SSH-server guide recommends running your own `sshd` on internal port `2222`, not `22`.
- Raw public SSH is a non-HTTP TCP service. Fly documents dedicated IPv4 as the normal option unless every client will use IPv6.
- The volume mount is optional. If present, the entrypoint will reuse SSH host keys from `/persist/ssh`, but that also makes the box region-bound.
- The login user is `rove`, with passwordless `sudo`, while the entrypoint stays root-owned so it can manage host keys and `sshd`.

## Likely Rove target shape later

The default `devbox` target now assumes dotfiles are already in the image, so it stays lean:

```json
{
  "name": "devbox",
  "provider": "fly",
  "app": "mcl0vinit-devbox",
  "image": "registry.fly.io/mcl0vinit-devbox:deployment-<id>",
  "vm_size": "shared-cpu-2x",
  "ssh_user": "rove",
  "startup_script": "./scripts/bootstrap.sh"
}
```
