# AGENTS.md

NixOS CUDA Docker images for vast.ai. See `README.md` for what the flake builds.

## Skills

- [vastai-update](.agents/skills/vastai-update/SKILL.md) — build, push, and roll
  an image out to a running vast.ai instance (the rollout needs
  `vastai recycle instance`, not `reboot`).

## Notes

- `nix build` on this host: always use `-o <link>`; the disk runs near-full and
  auto-GC eats unrooted results.
- The registry is `registry.plan.ai`; credentials come from the `glab` token for
  `git.plan.ai` (`write_registry` scope).
