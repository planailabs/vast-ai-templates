---
name: vastai-order-32gb
description: Shortlist and rent a verified single-GPU Vast.ai machine with at least 32 GB VRAM through the private plan-ai-base NixOS CUDA template, with price, disk, network, reliability, and direct-SSH safeguards. Use when work needs a new 32 GB+ Vast.ai training or inference machine, when comparing suitable offers, or when provisioning an ephemeral plan-ai-base instance that must later be torn down.
---

# Order a 32 GB Vast.ai machine

Every invocation needs `VAST_ACCEL` — which GPU API the work needs and the
lowest version that runs it. There is no default: a rental is only useful if
the host can run *your* binaries.

```bash
export VAST_ACCEL="cuda>=13.0"    # filters on Vast's cuda_vers
export VAST_ACCEL="vulkan>=1.3"   # filters on driver_version instead
```

Vast reports no Vulkan version, so the script maps the requested one to the
NVIDIA driver branch that first shipped it in a general release — 1.2 → r440,
1.3 → r510, 1.4 → 550.40.81 — and filters `driver_version` locally. Ask for a
version it has no recorded mapping for and it refuses rather than guessing.

Use `scripts/order.sh list` first. It returns only offers with:

- one GPU and at least 32 GB advertised VRAM;
- the accelerator version from `VAST_ACCEL`;
- a verified host with reliability at least 0.98;
- at least two direct ports, 200 Mbps download, and the requested disk space.

Inspect GPU generation, price including storage, CPU/RAM, bandwidth, location,
and reliability. A cheaper old V100 may be worse value than a newer GPU for a
short run; choose for the workload rather than price alone.

Rent only after the user explicitly asks to provision or run work on Vast.ai:

```bash
export VAST_ACCEL="cuda>=13.0"
export VAST_MAX_DPH=0.75
export VAST_LABEL=<project-specific-name>
export VAST_GPU_NAME="RTX 5090" # optional exact filter
scripts/order.sh create
```

The create command selects a current offer, refuses it if its total hourly
price exceeds `VAST_MAX_DPH`, resolves the current user's exact `plan-ai-base`
template, and creates an on-demand direct instance. Without `VAST_GPU_NAME` it
selects the cheapest qualifying offer.

`VAST_LABEL` is required and has no default: pick a name that identifies the
project the machine is being rented for (3–64 chars of `[A-Za-z0-9_.-]`), so
each rental in `vastai show instances` says which work owns it — and which
agent has to tear it down. A shared fallback label would make every instance
look alike, which is exactly when an idle box gets left running.
It deliberately preserves the template's `args` runtime: passing Vast's `--ssh`
flag replaces PID 1 with Vast's SSH wrapper, which makes this NixOS systemd
image restart forever immediately after `starting systemd`. Port 22 is already
declared by the template. Override `VAST_DISK_GB` only when the workload needs
more or less than the 80 GiB default.

Vast regenerates offer and machine ids between searches. `create` therefore
selects and consumes a current offer in one invocation instead of accepting an
id printed by an earlier `list` call.

Capture and redact the create response. Vast CLI 1.5.2 prints an
instance-scoped API key alongside `new_contract`; only the instance id belongs
in logs or agent transcripts. `scripts/order.sh` emits a sanitized response.

Expect to lose some hosts to problems no filter predicts, and budget a few
minutes per attempt: a stale Docker port allocation leaves the instance stuck
in `created` (`Bind for 0.0.0.0:<port> failed: port is already allocated`), a
cgroup v1 host makes systemd refuse to boot at all, and a datacenter GPU may
have no working Vulkan even on a current driver. Destroy and take the next
offer rather than fighting it — `vastai logs <id>` says which one you hit.

Record the returned instance id immediately. Poll `vastai show instance <id>
--raw` until it is running, then re-read the mapped SSH port. Verify the actual
GPU and VRAM with `nvidia-smi`; an API offer is not proof that the container can
use the device.

The agent that creates an instance owns teardown. Before destruction, follow
the pre-teardown procedure in ai-wasteland's `vast-ai` skill: stop useful work,
push source, export and checksum non-reproducible artifacts, verify them on the
destination, and remove temporary credentials. Then run:

```bash
vastai destroy instance <id>
vastai show instances --raw | jq -e 'all(.[]; .id != <id>)'
```

Never leave an idle instance running because training failed or an SSH session
dropped. An SSH disconnect does not stop remote work; inspect processes first.
