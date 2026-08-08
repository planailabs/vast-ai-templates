---
name: vastai-image-verify
description: Verify a NixOS CUDA image on a live vast.ai instance — systemd, sshd, nix daemon, driver, and a real GPU inference run with ollama. Use after rolling out an image with vastai-update, or when checking whether a GPU host actually works.
---

# Verifying an image on a live instance

Roll the image out first (see [vastai-update](../vastai-update/SKILL.md)) —
`vastai recycle instance`, not `reboot`. Then connect — **re-read the port every
time**, a recycle or recreate reassigns it:

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

If container logs repeat NixOS stage 2 and end with `could not create symlink
/etc/hostname` or `/etc/hosts`, Vast bind-mounted Docker's runtime files and
NixOS activation is restarting before sshd. Disable those two generated etc
entries in the image; Docker already supplies their contents:

```nix
environment.etc."hostname".enable = false;
environment.etc."hosts".enable = false;
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
that matters: run a real model on the GPU.

**Use the GitHub release artifact, not `nixpkgs#ollama-cuda`.** `ollama-cuda` is
unfree, so nothing caches it — every instance compiles ollama *and* the CUDA
packages from source, which takes tens of minutes and has been killed outright
mid-`nvcc` on vast hosts (`nvcc: Terminated`, `interrupted by the user`) with 19
CPUs and a 181 GB cap free. The vendor tarball runs in seconds and also
exercises `programs.nix-ld`, which is how most people will run vendor binaries
in this image anyway.

Two upstream gotchas, both of which cost a round when wrong: the asset is
`ollama-linux-amd64.tar.zst` (**zstd**, not `.tgz`), and the old
`ollama.com/download/...` URL 404s — fetch from
`github.com/ollama/ollama/releases/latest`.

Run it detached and poll the log; an SSH session that dies takes buffered output
with it:

```bash
ssh ... 'cat > /root/gputest.sh' <<'SH'
#!/usr/bin/env bash
set -x
export NIX_LD_LIBRARY_PATH="/run/current-system/sw/share/nix-ld/lib:/usr/lib/x86_64-linux-gnu:/usr/lib64:/run/opengl-driver/lib"
rm -rf /opt/ollama; mkdir -p /opt/ollama && cd /opt/ollama
curl -fsSL https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst -o o.tar.zst || exit 1
nix shell nixpkgs#zstd --command tar --use-compress-program=unzstd -xf o.tar.zst || exit 1
export PATH=/opt/ollama/bin:$PATH OLLAMA_HOST=127.0.0.1:11434
ollama --version
ollama serve > /tmp/ollama.log 2>&1 &
for i in $(seq 1 90); do curl -sf http://127.0.0.1:11434/ >/dev/null && break; sleep 2; done
echo "=== RUN ==="; ollama run smollm2:135m "Reply with exactly: ok" 2>/dev/null | tr -d '\r'
echo "=== PS ==="; ollama ps
echo "=== LOG ==="; grep -aiE "inference compute|library=cuda|no compatible GPUs" /tmp/ollama.log | tail -4
echo "=== DONE ==="
SH
ssh ... 'chmod +x /root/gputest.sh && setsid nohup /root/gputest.sh > /root/gputest.log 2>&1 </dev/null &'
ssh ... 'sed -n "/=== RUN ===/,/=== DONE ===/p" /root/gputest.log'
```

Poll for `curl:` and `command not found` too — a dead download otherwise looks
exactly like a slow GPU test. `pkill -f gputest` in the same SSH command kills
the shell running it (the pattern matches its own command line); keep them apart.

smollm2:135m is ~270 MB — small enough that a failure is the GPU, not patience.

If you do want the nixpkgs route (`NIXPKGS_ALLOW_UNFREE=1 nix shell --impure
nixpkgs#ollama-cuda`), build it once and pin it in xzar so instances substitute
it instead of compiling.

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

## When a check fails: the loop

Fix in `flake.nix` → build → push a fresh `-$SHA` tag → `vastai recycle
instance` → re-verify. Repeat until layer 3 passes.

```bash
# after editing flake.nix
git commit -am "..." && SHA=$(git rev-parse --short HEAD)
nix build .#cuda13_0 -o ~/.cache/vastai-cuda13_0
skopeo copy --dest-creds "mkg20001:$(glab config get token --host git.plan.ai)" \
  docker-archive:$HOME/.cache/vastai-cuda13_0 \
  docker://registry.plan.ai/plan-ai/vast-ai-templates/nixos-cuda:cuda13_0-$SHA
vastai update instance $ID --image registry.plan.ai/plan-ai/vast-ai-templates/nixos-cuda:cuda13_0-$SHA
vastai recycle instance $ID
```

One round costs ~15–20 min (build + 2 GB push + pull), so **collect every
diagnostic in a single SSH pass** before changing anything — a round spent
learning one fact is a round wasted. Commit each fix separately; the `-$SHA`
tag is what ties a registry image back to the code that produced it.

Do not skip the tag bump: vast.ai will not re-pull a tag it already has, so
re-pushing the same tag makes a fix look like it did nothing.
