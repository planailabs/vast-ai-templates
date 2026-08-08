# AGENTS.md

NixOS CUDA Docker images for vast.ai. See `README.md` for what the flake builds.

## Skills

- [vastai-update](.agents/skills/vastai-update/SKILL.md) — build, push, and roll
  an image out to a running vast.ai instance (the rollout needs
  `vastai recycle instance`, not `reboot`).
- [vastai-image-verify](.agents/skills/vastai-image-verify/SKILL.md) — check a
  rolled-out image on the instance, ending in a real GPU inference run
  (`ollama` + `smollm2:135m` through the in-image nix daemon).
- [vastai-order-32gb](.agents/skills/vastai-order-32gb/SKILL.md) — shortlist
  and safely rent a verified direct-SSH `plan-ai-base` machine with at least
  32 GB VRAM, an explicit hourly price cap, and mandatory teardown ownership.

## Notes

- `nix build` on this host: always use `-o <link>`; the disk runs near-full and
  auto-GC eats unrooted results.
- The registry is `registry.plan.ai`; credentials come from the `glab` token for
  `git.plan.ai` (`write_registry` scope).
