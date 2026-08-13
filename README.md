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

**On vast.ai, NVIDIA Vulkan does not work.** The image side is correct — the
manifest the NVIDIA hook writes to `/etc/vulkan/icd.d` is picked up via
`VK_ADD_DRIVER_FILES`, and `libGLX_nvidia.so.0` loads with all its
dependencies — but the driver itself then declines:
`vk_icdNegotiateLoaderICDInterfaceVersion` returns `-3`
(`VK_ERROR_INITIALIZATION_FAILED`) without ever opening `/dev/nvidiactl`.
Reproduced on a Tesla V100 (driver 580.159.03) and a Quadro RTX 8000
(595.71.05); CUDA works on both. `vulkaninfo` then reports only Mesa's
llvmpipe, and `ollama-vulkan` runs at `100% CPU`. Use a CUDA tag on NVIDIA
hosts; the `vulkan` tag is for AMD/Intel GPUs, where Mesa's ICDs come from
the image itself.

## Log web UI

Every image serves a log viewer on TCP 1111 — the port vast's **Open** button
opens, declared on the image so vast maps it, along with `OPEN_BUTTON_PORT`.

It follows whatever the machine is actually doing: a `/proc` scan every few
seconds picks up every process that exports `WEBUI_LOGS`, so a job started long
after boot needs no restart and no recycle.

```bash
WEBUI_LOGS=/root/job.log WEBUI_PROGRESS_PATTERN='step (?P<current>\d+)/(?P<total>\d+)' \
  setsid nohup ./train.sh > /root/job.log 2>&1 < /dev/null &
```

`WEBUI_LOGS` is a file path (`tail -F`, so rotation and truncation are handled)
or a systemd unit name (`journalctl -fu`). Each distinct log becomes its own
tab; two processes naming the same file share one view. `WEBUI_PROGRESS_PATTERN`
is a Python regex whose newest match drives the bar — a named `percent` group,
named `current`/`total`, or the first two numbered groups.

The port lands on a public IP, so `/api/tail` and `/raw` need a token
(`/run/vastai-webui/token`, or set `WEBUI_TOKEN`); the page itself carries no
log content, so the Open button still works and then asks for the token.

```bash
curl -s "localhost:1111/raw?token=$(cat /run/vastai-webui/token)" | tail
WEBUI_LOGS=/tmp/x nix run .#vastai-webui        # same thing, on your laptop
```

## AI guide

`/etc/ai-guide.md` tells an agent that just SSH'd in what this box is: NixOS
(no apt), ephemeral, billed hourly, whose teardown it owes, how to run vendor
binaries and long jobs, and how to drive the web UI. The MOTD is three lines —
the live URL, its token, and a pointer at the guide — regenerated at every boot
from `/proc/1/environ`.

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

`nix flake check` covers the web UI: `webui-selftest` runs the progress-regex,
source-selection and sanitizer asserts, `webui-wiring` is an eval-only check
that the modules are still imported and the port still declared — both need no
KVM, and CI runs them. `webui-vm` boots a slim image under Docker in a VM and
drives the whole thing end to end; it needs `/dev/kvm`, so it stays local.

The build job pins `.#<variant>-toplevel` — the system closure, not the packed
tarball. The image is repacked from that closure at deploy time, so the cache
doesn't hold every byte twice.
