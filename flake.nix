{
  description = "CUDA NixOS Docker image (systemd PID 1, sshd, nix daemon) for vast.ai";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos2docker = {
      url = "git+https://git.plan.ai/plan-ai/nixos2docker";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos2docker, ... }:
    let
      system = "x86_64-linux";

      # NVIDIA container runtime injects the host driver (libcuda.so,
      # libnvidia-ml.so, nvidia-smi) into these paths at `docker run --gpus`
      # time — the image itself must not ship a driver.
      driverLibs = "/usr/lib64:/usr/lib/x86_64-linux-gnu:/run/opengl-driver/lib";
    in
    {
      nixosConfigurations.vastai = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos2docker.nixosModules.default
          ({ pkgs, lib, ... }: {
            nixpkgs.config.allowUnfree = true; # cudatoolkit

            virtualisation.dockerImage = {
              name = "vastai-nixos-cuda";
              tag = "latest";
              includeNixDB = true; # working nix / nix-daemon inside the image
            };

            # ── CUDA ────────────────────────────────────────────────
            environment.systemPackages = with pkgs; [
              cudaPackages.cudatoolkit
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
      };

      # nix build .# && docker load < result
      # docker run -d --gpus all -p 2222:22 \
      #   --tmpfs /run --tmpfs /run/lock --tmpfs /tmp vastai-nixos-cuda:latest
      packages.${system}.default =
        self.nixosConfigurations.vastai.config.system.build.dockerImage;
    };
}
