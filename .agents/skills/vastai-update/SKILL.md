---
name: vastai-update
description: Build, push, and roll out a new NixOS CUDA image to a vast.ai instance. Use when a change to flake.nix must reach a running instance, or when a pushed image does not seem to take effect.
---

# Rolling a new image onto a vast.ai instance

Four steps: build → push → point the instance at the new tag → **recycle**.
Skipping the recycle is the usual reason "the push didn't work".

## 1. Build with a GC root

```bash
nix build .#cuda13_0 -o ~/.cache/vastai-cuda13_0
```

Use `-o`, not `--no-link`. The host runs near-full; nix's auto-GC deletes
unrooted results, and a 2 GB image tarball disappears between build and push.

## 2. Push, tagged with the commit sha

```bash
export CI_REGISTRY_PASSWORD=$(glab config get token --host git.plan.ai)
SHA=$(git rev-parse --short HEAD)
IMG=registry.plan.ai/plan-ai/vast-ai-templates/nixos-cuda
for tag in cuda13_0 "cuda13_0-$SHA"; do
  skopeo copy --dest-creds "mkg20001:$CI_REGISTRY_PASSWORD" \
    docker-archive:$HOME/.cache/vastai-cuda13_0 "docker://$IMG:$tag"
done
```

The registry is `registry.plan.ai` (not `git.plan.ai:5050` — that port is
closed). The `glab` token needs `write_registry`; re-auth with
`glab auth login --hostname git.plan.ai` if the API returns 401.

**Always push a `-$SHA` tag and roll that out.** vast.ai will not re-pull a tag
it already has cached, so overwriting `cuda13_0` alone changes nothing.

## 3. Point the instance at it, then recycle

```bash
ID=47107605
vastai update instance $ID --image $IMG:cuda13_0-$SHA
vastai recycle instance $ID
```

What each command actually does — measured, not documented:

| command | effect |
|---|---|
| `update instance --image` | sets `image_uuid`; container keeps running the old image |
| `reboot instance` | stop/start of the **existing** container — no pull |
| `recycle instance` | destroys and recreates the container, pulls the image ✅ |
| `update instance --template_hash_id` | reported success, container unchanged |
| `update template <hash> --image_tag` | 400 Bad Request |

`recycle` wipes the container filesystem. Anything worth keeping must live on a
volume first.

Watch it land (`status_msg` shows the pull, then the new tag):

```bash
vastai show instance $ID --raw | jq -r '"\(.actual_status) \(.status_msg)"'
```

## 4. Verify over SSH

Root login uses the key baked into `flake.nix`. Host/port come from the
instance:

```bash
vastai show instance $ID --raw | jq -r '"\(.public_ipaddr) \(.ports."22/tcp"[0].HostPort)"'
ssh -i ~/.ssh/id_ed25519 -p <port> root@<ip> '
  systemctl is-system-running          # running, no failed units
  readlink -f /run/current-system      # closure hash = the build you pushed
  ls -d /run/opengl-driver             # exists once hardware.graphics is on
  nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  nvcc --version | tail -1
  nix-store --version
  vastai --version
'
```

`readlink -f /run/current-system` is the reliable check that the new image is
live — `status_msg` lags and keeps showing the previous tag.

Failure modes worth recognising:

- `Could not start dynamically linked executable: nvidia-smi` — PATH resolved
  the host-injected `/usr/bin/nvidia-smi` (a glibc binary NixOS can't exec).
  The image must ship `linuxPackages.nvidia_x11.bin`.
- `Driver/library version mismatch` — the image's driver (595.84 from nixpkgs)
  differs from the host's kernel module. Pin
  `linuxPackages.nvidiaPackages.*` to the host's branch.
