# vast.ai NixOS CUDA templates

Full NixOS Docker images — systemd as PID 1, sshd, working nix daemon, CUDA
toolkit — built with [nixos2docker](https://git.plan.ai/plan-ai/nixos2docker).

One image per major CUDA release (`cuda12`, `cuda13`; CUDA 11 is gone from
nixpkgs). Add a minor in `flake.nix`'s `cudaMajors` when a framework pins one.

```bash
nix build .#cuda12        # or .#cuda13, .# for the default (cuda12)
docker load < result

docker run -d --gpus all -p 2222:22 \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  vastai-nixos-cuda:cuda12

ssh -p 2222 root@localhost
```

No `--privileged`, no `--cap-add`. The NVIDIA container runtime injects the
host driver (`libcuda.so`, `nvidia-smi`); `LD_LIBRARY_PATH` and `PATH` already
point at the injection paths. Port 22 is declared on the image, so `-P` works.

Root login is key-only — edit the key in `flake.nix` before building for
someone else.

## CI

`.gitlab-ci.yml` runs on the `nix-image` runner tag: build the matrix, then
push each variant to the GitLab registry as
`$CI_REGISTRY/$CI_PROJECT_PATH/nixos-cuda:<variant>`.

The runner image itself comes from this flake — `nix build .#ci-image` builds a
NixOS-in-Incus image with `xzar.plan.ai` configured as a substituter. The
`cache-devshell` job pins the devshell closure in xzar (needs `XZAR_TOKEN`), so
later pipelines fetch skopeo & co instead of rebuilding them.
