{
  description = "CUDA NixOS Docker images (systemd PID 1, sshd, nix daemon) for vast.ai";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos2docker = {
      url = "git+https://git.plan.ai/plan-ai/nixos2docker";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    gitlab-incus-image.url = "git+https://git.mkg20001.io/mkg20001/gitlab-incus-image.git";
    xzar.url = "github:mkg20001/xzar";
    xzar.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixos2docker, gitlab-incus-image, xzar, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ xzar.overlays.default ]; # xzar-client, for the CI cache job
      };

      # NVIDIA's container runtime injects the host driver (libcuda.so,
      # libnvidia-ml.so, nvidia-smi) into these paths at `docker run --gpus`
      # time — the image must not ship a driver of its own.
      driverLibs = "/usr/lib64:/usr/lib/x86_64-linux-gnu:/run/opengl-driver/lib";

      # One image per major CUDA release. vast.ai hosts run a wide range of
      # driver versions; pick the tag that matches what the machine reports.
      # CUDA 11 is gone from nixpkgs (unmaintained upstream, needs unsupported
      # compilers). Add a minor here — e.g. cuda12_4 = "cudaPackages_12_4" —
      # when a framework pins one.
      cudaMajors = {
        cuda12 = "cudaPackages_12";
        cuda13 = "cudaPackages_13";
      };

      mkImage = tag: cudaAttr: (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos2docker.nixosModules.default
          ({ pkgs, lib, ... }: {
            nixpkgs.config.allowUnfree = true; # cudatoolkit

            virtualisation.dockerImage = {
              name = "vastai-nixos-cuda";
              inherit tag;
              includeNixDB = true; # working nix / nix-daemon inside the image
            };

            # ── CUDA ────────────────────────────────────────────────
            environment.systemPackages = with pkgs; [
              pkgs.${cudaAttr}.cudatoolkit
              git
              curl
              wget
              htop
              tmux
              rsync
              python3
            ];

            environment.variables.LD_LIBRARY_PATH = driverLibs;
            # ...and for services, not just login shells.
            virtualisation.dockerVariant.systemd.settings.Manager.DefaultEnvironment =
              lib.mkForce "SYSTEMD_SECCOMP=0 LD_LIBRARY_PATH=${driverLibs}";
            # nvidia-smi lands in /usr/bin, which NixOS' profile PATH drops.
            environment.extraInit = ''export PATH="$PATH:/usr/bin"'';

            # ── SSH ─────────────────────────────────────────────────
            services.openssh = {
              enable = true;
              settings.PermitRootLogin = "prohibit-password";
            };
            users.users.root.openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIBBEhZ7sLQCNZXBunHMxEDS2Niy3wpnHgUPDBCNeKew maciej@mkg-razer"
            ];

            # ── Nix daemon ──────────────────────────────────────────
            nix.settings = {
              experimental-features = [ "nix-command" "flakes" ];
              sandbox = false; # no CAP_SYS_ADMIN in the container
            };

            networking.hostName = "vastai";
            time.timeZone = "UTC";
            i18n.defaultLocale = "en_US.UTF-8";

            # Required for the base eval; the Docker variant overrides both.
            fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
            boot.loader.grub.enable = false;

            system.stateVersion = "25.11";
          })
        ];
      }).config.system.build.dockerImage;
    in
    {
      packages.${system} = lib.mapAttrs mkImage cudaMajors // {
        # 12.x is what most frameworks (torch, jax) ship wheels against.
        default = self.packages.${system}.cuda12;

        # NixOS-in-Incus image for the GitLab CI runners that build the above.
        # Must be named `image` — that's the attribute the runner infra builds.
        image = gitlab-incus-image.lib.mkImage {
          inherit system nixpkgs;
          modules = [
            ({ pkgs, ... }: {
              nixpkgs.overlays = [ xzar.overlays.default ];

              environment.systemPackages = with pkgs; [
                openssh
                rsync
                skopeo
                pixz
                pkgs.xzar-client
              ];

              programs.git.config.advice.detachedHead = false;
              system.stateVersion = "26.11";

              nix.settings = {
                substituters = [ "https://xzar.plan.ai" ];
                trusted-public-keys = [
                  "xzar.plan.ai:KUE66pjr6UX5HHCn9kedN1DJ2J5nSlBrKmE7tUjXewE="
                ];
              };
            })
          ];
        };
      };

      # `nix develop` — what push-image.sh and the CI cache job need.
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.skopeo pkgs.jq pkgs.xzar-client ];
      };
    };
}
