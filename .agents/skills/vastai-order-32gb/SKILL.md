---
name: vastai-order-32gb
description: Shortlist and rent a verified single-GPU Vast.ai machine with at least 32 GB VRAM through the private plan-ai-base NixOS CUDA template, with price, disk, network, reliability, and direct-SSH safeguards. Use when work needs a new 32 GB+ Vast.ai training or inference machine, when comparing suitable offers, or when provisioning an ephemeral plan-ai-base instance that must later be torn down.
---

# Order a 32 GB Vast.ai machine

Use `scripts/order.sh list` first. It returns only offers with:

- one GPU and at least 32 GB advertised VRAM;
- CUDA 13 compatibility;
- a verified host with reliability at least 0.98;
- at least two direct ports, 200 Mbps download, and the requested disk space.

Inspect GPU generation, price including storage, CPU/RAM, bandwidth, location,
and reliability. A cheaper old V100 may be worse value than a newer GPU for a
short run; choose for the workload rather than price alone.

Rent only after the user explicitly asks to provision or run work on Vast.ai:

```bash
export VAST_MAX_DPH=0.75
scripts/order.sh create <offer-id>
```

The create command re-fetches that exact offer, refuses it if any constraint
drifted or its total hourly price exceeds `VAST_MAX_DPH`, resolves the current
user's exact `plan-ai-base` template, and creates an on-demand direct-SSH
instance. Override `VAST_DISK_GB` only when the workload needs more or less than
the 80 GiB default.

Do not revalidate with a server-side `id=<offer-id>` search. Vast CLI 1.5.2
accepts that filter but returns an empty set for a freshly listed offer. Re-run
the constrained shortlist and match `.id` locally, as `scripts/order.sh` does.

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
