---
name: vastai-image-verify
description: Verify a NixOS CUDA image on a live vast.ai instance — systemd, sshd, nix daemon, driver, and a real GPU inference run with ollama. Use after rolling out an image with vastai-update, or when checking whether a GPU host actually works.
---

# Verifying an image on a live instance

Roll the image out first (see [vastai-update](../vastai-update/SKILL.md)) —
`vastai recycle instance`, not `reboot`. Then connect:

```bash
ID=47107605
read IP PORT < <(vastai show instance $ID --raw \
  | jq -r '"\(.public_ipaddr) \(.ports."22/tcp"[0].HostPort)"')
ssh -i ~/.ssh/id_ed25519 -p $PORT root@$IP
```

## Layer 1 — the system booted

```bash
systemctl is-system-running     # "running"; "degraded" → systemctl --failed
readlink -f /run/current-system  # must equal the closure you built
nix-store --version              # nix daemon + store DB survived the image build
vastai --version
```

`readlink -f /run/current-system` is the only trustworthy check that the new
image is live. The API's `status_msg` lags and keeps naming the previous tag.

## Layer 2 — the GPU is reachable

```bash
cat /proc/driver/nvidia/version           # host kernel module version
ls /usr/bin/nvidia* /usr/lib/x86_64-linux-gnu/libnvidia* 2>/dev/null  # what the runtime injected
ls -d /run/opengl-driver                  # present when hardware.graphics is on
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
```

Two failures to tell apart:

- `Could not start dynamically linked executable` — PATH found the injected
  `/usr/bin/nvidia-smi`, a glibc binary NixOS cannot exec.
- `Driver/library version mismatch` — the image's userspace driver differs from
  `/proc/driver/nvidia/version`. Pin `linuxPackages.nvidiaPackages.*` to the
  host's branch.

## Layer 3 — real inference (the actual pass/fail)

Everything above can look fine while CUDA still can't allocate. This is the test
that matters: pull a model over the network, build a CUDA-enabled runtime through
the in-image nix daemon, and run it on the GPU.

```bash
export NIXPKGS_ALLOW_UNFREE=1   # ollama-cuda is unfree
nix shell --impure nixpkgs#ollama-cuda --command bash -c '
  ollama serve > /tmp/ollama.log 2>&1 &
  until curl -sf http://127.0.0.1:11434/ >/dev/null; do sleep 1; done
  ollama run smollm2:135m "Reply with exactly: ok"
  ollama ps
  grep -iE "inference compute|library=cuda|no compatible GPUs" /tmp/ollama.log
'
```

smollm2:135m is ~270 MB — small enough that a failure is the GPU, not patience.

Pass criteria:

- the model answers,
- `ollama ps` shows `100% GPU` in the PROCESSOR column,
- the log has `inference compute ... library=cuda` and **not**
  `no compatible GPUs were discovered`.

If it answers but `ollama ps` says `100% CPU`, the runtime never found
`libcuda.so.1` — check `LD_LIBRARY_PATH` and that the injected driver libs are
where the image expects them (`/usr/lib64`, `/usr/lib/x86_64-linux-gnu`,
`/run/opengl-driver/lib`).

This exercise doubles as a check on the nix daemon: it only works if the store
DB was registered at image build time (`virtualisation.dockerImage.includeNixDB`)
and `nix.settings.sandbox = false` (no CAP_SYS_ADMIN in the container).
