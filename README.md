# vast.ai NixOS CUDA template

Full NixOS Docker image — systemd as PID 1, sshd, working nix daemon, CUDA
toolkit — built with [nixos2docker](https://git.plan.ai/plan-ai/nixos2docker).

```bash
nix build .#
docker load < result

docker run -d --gpus all -p 2222:22 \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  vastai-nixos-cuda:latest

ssh -p 2222 root@localhost
```

No `--privileged`, no `--cap-add`. The NVIDIA container runtime injects the
host driver (`libcuda.so`, `nvidia-smi`); `LD_LIBRARY_PATH` and `PATH` already
point at the injection paths.

Root login is key-only — edit the key in `flake.nix` before building for
someone else.
