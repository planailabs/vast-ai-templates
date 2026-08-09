# vast.ai NixOS CUDA templates

Full NixOS Docker images — systemd as PID 1, sshd, working nix daemon, CUDA
toolkit — built with [nixos2docker](https://git.plan.ai/plan-ai/nixos2docker).

One image per CUDA release nixpkgs still carries:

| variant | CUDA |
|---|---|
| `cuda12` | alias for the newest 12.x (12.9 today) |
| `cuda13` | alias for the newest 13.x (13.2 today) |
| `cuda12_6` `cuda12_8` `cuda12_9` | 12.6, 12.8, 12.9 |
| `cuda13_0` `cuda13_1` `cuda13_2` `cuda13_3` | 13.0 – 13.3 |
| `vulkan` | none — Vulkan only |

12.5 and older (and all of 11.x) were removed from nixpkgs as unmaintained
upstream. The aliases share their closure with the minor they point at, so they
cost one extra tarball, not an extra build.

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
point at the injection paths. `CUDA_PATH` points at the image's matching Nix
toolkit closure, so runtimes that compile kernels through NVRTC can find its
headers and libraries. Port 22 is declared on the image, so `-P` works.

Root login is key-only — edit the key in `flake.nix` before building for
someone else.

## Vulkan

Vulkan and CUDA are two APIs onto the same NVIDIA driver, so **every image
here speaks both** — `hardware.graphics` puts the ICD in
`/run/opengl-driver/share/vulkan/icd.d`, and `vulkan-loader` and
`vulkan-tools` are installed. The separate `vulkan` tag is the same image
without the CUDA toolkit: a few GB smaller, and it is the one that makes sense
on AMD or Intel hosts, where CUDA is not an option.

The images set `NVIDIA_DRIVER_CAPABILITIES=all` in the OCI `Env`. Without it
the NVIDIA container runtime defaults to `compute,utility` and injects
`libcuda` and `nvidia-smi` but none of the GL/Vulkan libraries — and the
image's own copies cannot stand in, because that userspace has to match the
host's kernel module exactly. The variable has to be in the image config: the
runtime hook reads it before the container exists, so no in-container setting
can substitute.

```bash
vulkaninfo --summary          # driverName should be "NVIDIA"
nix run nixpkgs#ollama-vulkan -- serve
```

`ollama-vulkan` is in nixpkgs and, unlike `ollama-cuda`, is free software —
so it substitutes from the binary cache in seconds instead of compiling.

## vastai CLI

The [`vastai`](https://pypi.org/project/vastai/) CLI/SDK isn't in nixpkgs, so
it's packaged here (`nix/vastai.nix`) and installed in every image:

```bash
nix run .#vastai -- show instances
```

`borb` is dropped from its dependencies — nixpkgs ships 3.x, upstream imports
the 2.1 API, and only the deprecated PDF-invoice shim touches it (behind a
`try/except ImportError`). Everything else is relaxed off upstream's exact
pins onto nixpkgs' versions.

## CI

`.gitlab-ci.yml` runs on the `nix-image` runner tag: build the matrix, then
push each variant to the GitLab registry as
`$CI_REGISTRY/$CI_PROJECT_PATH/nixos-cuda:<variant>`.

The runner image itself comes from this flake — `nix build .#image` builds a
NixOS-in-Incus image with `xzar.plan.ai` configured as a substituter. The
`cache-devshell` job pins the devshell closure in xzar (needs `XZAR_TOKEN`), so
later pipelines fetch skopeo & co instead of rebuilding them.

The build job pins `.#<variant>-toplevel` — the system closure, not the packed
tarball. The image is repacked from that closure at deploy time, so the cache
doesn't hold every byte twice.
