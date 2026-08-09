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

      # One image per CUDA release nixpkgs still carries. vast.ai hosts run a
      # wide range of driver versions; pick the tag that matches what the
      # machine reports, or a major alias to track the newest of a series.
      # Everything up to 12.5 (and all of 11.x) was dropped from nixpkgs as
      # unmaintained upstream — those attrs exist but throw on eval.
      # Keep this list in sync with the matrix in .gitlab-ci.yml.
      cudaVersions = {
        cuda12 = "cudaPackages_12"; # alias, currently 12.9
        cuda13 = "cudaPackages_13"; # alias, currently 13.2

        cuda12_6 = "cudaPackages_12_6";
        cuda12_8 = "cudaPackages_12_8";
        cuda12_9 = "cudaPackages_12_9";
        cuda13_0 = "cudaPackages_13_0";
        cuda13_1 = "cudaPackages_13_1";
        cuda13_2 = "cudaPackages_13_2";
        cuda13_3 = "cudaPackages_13_3";
      };

      # `cudaAttr = null` builds the Vulkan-only variant: same driver stack,
      # no CUDA toolkit.  Vulkan and CUDA are two APIs onto the same NVIDIA
      # driver, so every CUDA image below speaks Vulkan too — the separate
      # `vulkan` tag exists to skip the ~4 GB toolkit closure, and to run on
      # AMD/Intel hosts where CUDA is not an option at all.
      mkSystem = tag: cudaAttr: (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos2docker.nixosModules.default
          ({ pkgs, lib, ... }:
          let
            cudaToolkit = if cudaAttr == null then null else pkgs.${cudaAttr}.cudatoolkit;
            withCuda = cudaToolkit != null;
            # The host-injected libGLX_nvidia.so.0 — which is also the Vulkan
            # ICD — links against libX11 and libXext. Nothing else in the image
            # pulls them in, and without them the loader gets as far as reading
            # the ICD manifest and then fails to dlopen the driver.
            icdDeps = lib.makeLibraryPath [ pkgs.xorg.libX11 pkgs.xorg.libXext ];
            runtimeLibraryPath = lib.concatStringsSep ":" (
              lib.optional withCuda "${cudaToolkit}/lib" ++ [ driverLibs icdDeps ]);
          in {
            nixpkgs.config.allowUnfree = true; # cudatoolkit, nvidia_x11

            virtualisation.dockerImage = {
              name = "vastai-nixos-cuda";
              inherit tag;
              includeNixDB = true; # working nix / nix-daemon inside the image
              # Read by the NVIDIA container runtime hook *before* the container
              # starts.  Its default is compute,utility, which injects libcuda
              # and nvidia-smi but none of the GL/Vulkan libraries — and the
              # image's own copy of those is useless, because it has to match
              # the host's kernel module exactly.
              extraEnv.NVIDIA_DRIVER_CAPABILITIES = "all";
            };

            # ── GPU ─────────────────────────────────────────────────
            environment.systemPackages = with pkgs; [
              (pkgs.python3Packages.callPackage ./nix/vastai.nix { })
              pkgs.linuxPackages.nvidia_x11.bin # nvidia-smi, nvidia-debugdump
              vulkan-loader
              vulkan-tools # vulkaninfo, vkcube — how you tell a broken ICD apart
              git
              curl
              wget
              openssl
              htop
              tmux
              rsync
              python3
            ] ++ lib.optional withCuda cudaToolkit;

            # Ship the full NVIDIA userspace driver and let hardware.graphics
            # populate /run/opengl-driver (GL/GLX/EGL + the Vulkan ICD, libcuda,
            # libnvidia-ml). Note the userspace version has to match the host's
            # kernel module — pin pkgs.linuxPackages.nvidiaPackages.* here when
            # the host runs a different branch than nixpkgs' default.
            hardware.graphics = {
              enable = true;
              extraPackages = [ pkgs.linuxPackages.nvidia_x11 ];
            };

            environment.variables = {
              LD_LIBRARY_PATH = runtimeLibraryPath;
              # The NVIDIA hook drops its Vulkan ICD in the FHS location,
              # /etc/vulkan/icd.d — which nixpkgs' loader does not search (it
              # is patched to look in /run/opengl-driver/share/vulkan/icd.d).
              # ADD rather than replace, so Mesa's ICDs survive: they are the
              # only ones that work on an AMD or Intel host.
              VK_ADD_DRIVER_FILES = "/etc/vulkan/icd.d/nvidia_icd.json";
            } // lib.optionalAttrs withCuda { CUDA_PATH = "${cudaToolkit}"; };
            # ...and for services, not just login shells.
            virtualisation.dockerVariant.systemd.settings.Manager.DefaultEnvironment =
              lib.mkForce (lib.concatStringsSep " " ([ "SYSTEMD_SECCOMP=0" ]
                ++ lib.optional withCuda "CUDA_PATH=${cudaToolkit}"
                ++ [
                  "LD_LIBRARY_PATH=${runtimeLibraryPath}"
                  "VK_ADD_DRIVER_FILES=/etc/vulkan/icd.d/nvidia_icd.json"
                ]));
            # nvidia-smi lands in /usr/bin, which NixOS' profile PATH drops.
            environment.extraInit = ''export PATH="$PATH:/usr/bin"'';
            # Build tools such as Forge provisioners download auxiliary JDKs
            # with the conventional glibc interpreter path.
            programs.nix-ld.enable = true;

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
            # Vast bind-mounts Docker's runtime-owned hostname and hosts files.
            # setup-etc cannot replace bind mounts with NixOS symlinks and PID
            # 1 otherwise restarts forever before sshd is reached.
            environment.etc."hostname".enable = false;
            environment.etc."hosts".enable = false;
            time.timeZone = "UTC";
            i18n.defaultLocale = "en_US.UTF-8";

            # Required for the base eval; the Docker variant overrides both.
            fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
            boot.loader.grub.enable = false;

            system.stateVersion = "25.11";
          })
        ];
      });

      cudaSystems = lib.mapAttrs mkSystem (cudaVersions // { vulkan = null; });
    in
    {
      packages.${system} = lib.mapAttrs (_: s: s.config.system.build.dockerImage) cudaSystems
      # `.#cuda12-toplevel` is what CI pins in xzar: the system closure the
      # image is packed from. Caching the tarball instead would store every
      # byte twice, and it repacks from the closure in seconds anyway.
      // lib.mapAttrs' (n: s: lib.nameValuePair "${n}-toplevel"
           s.config.virtualisation.dockerVariant.system.build.toplevel) cudaSystems
      // {
        # 12.x is what most frameworks (torch, jax) ship wheels against.
        default = self.packages.${system}.cuda12;

        # The vast.ai CLI — shipped in every image, also usable standalone
        # (`nix run .#vastai -- show instances`).
        vastai = pkgs.python3Packages.callPackage ./nix/vastai.nix { };

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
