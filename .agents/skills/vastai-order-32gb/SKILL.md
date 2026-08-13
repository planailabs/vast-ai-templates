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
GPUs that are not NVIDIA skip that check: their `driver_version` is not an
NVIDIA branch number, and they are the hosts a Vulkan rental actually wants.

`VAST_ACCEL` also picks the template: `cuda` rents through `plan-ai-base`
(CUDA toolkit included), `vulkan` through `plan-ai-vulkan` (the `vulkan` image
tag, no toolkit). `VAST_TEMPLATE` overrides both.

**NVIDIA Vulkan does not work on Vast.** Measured on two unrelated hosts — a
Tesla V100 on driver 580.159.03 and a Quadro RTX 8000 on 595.71.05 — the
injected ICD loads and then the driver refuses:
`vk_icdNegotiateLoaderICDInterfaceVersion` returns `-3`
(`VK_ERROR_INITIALIZATION_FAILED`) before it even opens `/dev/nvidiactl`, and
`vulkaninfo` falls back to Mesa's llvmpipe. CUDA on the same hosts is fine.
So `plan-ai-vulkan` is for AMD or Intel GPUs, where Mesa's ICDs ship in the
image and nothing has to be injected — and Vast currently lists none of those
(75 distinct models across 2000 rentable offers, all NVIDIA). Until that
changes, rent with `cuda>=…`.

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
`create` passes its own `--env`, which *replaces* the template's docker-options
string — hence `-p 22:22` being repeated there alongside the web UI's port.
It deliberately preserves the template's `args` runtime: passing Vast's `--ssh`
flag replaces PID 1 with Vast's SSH wrapper, which makes this NixOS systemd
image restart forever immediately after `starting systemd`. Port 22 is already
declared by the template. Override `VAST_DISK_GB` only when the workload needs
more or less than the 80 GiB default.

## Watching the run from a browser

Every image serves a log viewer on port 1111 — the port vast's **Open** button
opens. It follows whatever any process in the container declares:

```bash
export VAST_WEBUI_LOGS=/root/job.log
export VAST_WEBUI_PROGRESS_PATTERN='step\s(?P<current>[0-9]+)/(?P<total>[0-9]+)'
```

Both are optional at rental time — a process started later can export the same
two variables and the UI picks it up within seconds, no recycle. Setting them
here just means the page is useful from the first boot.

**No whitespace in either value.** Measured on a live rental: vast stores a
value containing a space in the instance's `extra_env` and then never passes it
to the container — quoting does not help, and nothing reports the loss. Write
`\s` in the regex; `order.sh` refuses whitespace and quotes rather than hand
you a bar that silently never moves.

Both templates declare `-p 1111:1111 -e OPEN_BUTTON_PORT=1111`, so renting from
the vast console works the same way.

After `create`, the URL and its token:

```bash
vastai show instance <id> --raw | jq -r '"http://\(.public_ipaddr):\(.ports."1111/tcp"[0].HostPort)/"'
ssh -p <port> root@<ip> cat /run/vastai-webui/token
```

The token is also printed in the login MOTD. **That port is on a public IP** —
the log must not contain credentials.

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
