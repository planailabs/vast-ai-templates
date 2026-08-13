# A log viewer on vast's "Open" button port.
#
# It follows every log declared by a WEBUI_LOGS environment variable anywhere in
# the container -- PID 1 (what `vastai create instance --env` passed) or any job
# an agent starts later -- and infers a progress bar from WEBUI_PROGRESS_PATTERN.
{ config, pkgs, ... }:

let
  port = 1111; # what vast's own images use, and where "Open" points by default

  # writePython3Bin byte-compiles and lints at build time, so a typo fails
  # `nix build` instead of the rented machine.
  webui = pkgs.writers.writePython3Bin "vastai-webui" {
    flakeIgnore = [ "E501" ]; # the embedded HTML/CSS/JS is not 79 columns
  } (builtins.readFile ./webui.py);
in
{
  # `nix run .#vastai-webui`, and the selftest check in flake.nix.
  system.build.vastai-webui = webui;

  systemd.services.vastai-webui = {
    description = "Log tail and progress web UI";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    # `tail` for files, `journalctl` for units.
    path = [ pkgs.coreutils config.systemd.package ];
    serviceConfig = {
      ExecStart = "${webui}/bin/vastai-webui";
      RuntimeDirectory = "vastai-webui"; # /run/vastai-webui/token
      Restart = "always";
      RestartSec = 2;
    };
    # No Protect*/sandboxing: the logs it follows are arbitrary root-owned paths
    # and the scan reads every /proc/<pid>/environ.
  };

  # nixos2docker derives the image's OCI ExposedPorts from this list, and vast
  # maps whatever the image exposes.  The firewall itself is off in containers.
  networking.firewall.allowedTCPPorts = [ port ];
  # Points vast's console "Open" button at the UI instead of nothing.
  virtualisation.dockerImage.extraEnv.OPEN_BUTTON_PORT = toString port;

  environment.systemPackages = [ webui ];
}
