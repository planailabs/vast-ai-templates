# A guide for whoever -- usually an agent -- just logged into a rented box.
#
# The guide itself is a file (/etc/ai-guide.md) so it can be long enough to be
# useful; the MOTD stays three lines and only carries what cannot be baked into
# the image: the live web UI URL and its token.
{ pkgs, ... }:

let
  guide = pkgs.writeText "ai-guide.md" ''
    # This box, in one page

    A rented vast.ai GPU machine running a NixOS image (systemd is PID 1,
    inside Docker). Read this before installing anything.

    ## It is ephemeral, and it bills by the hour

    Everything here disappears when the instance is destroyed or recycled --
    including /root. Push source, and export and checksum artifacts to a place
    that outlives the box, then verify them there before tearing it down.
    Whoever rented this machine owns its teardown; do not leave it idle. An SSH
    disconnect does not stop remote work: check the processes first.

    ## Installing software

    There is no apt, dnf or yum. Use nix:

        nix shell nixpkgs#ffmpeg -c ffmpeg -i in.mp4 out.mkv   # once
        nix profile install nixpkgs#ripgrep                    # permanently

    Downloaded (non-Nix) binaries run through nix-ld:

        export NIX_LD_LIBRARY_PATH="/run/current-system/sw/share/nix-ld/lib:/usr/lib/x86_64-linux-gnu:/usr/lib64:/run/opengl-driver/lib"

    ## GPU

    `nvidia-smi` comes from the host driver injected into /usr/bin. CUDA_PATH
    and LD_LIBRARY_PATH are already set -- extend them, never replace them.
    Vulkan on NVIDIA does not work on vast (the driver refuses to initialise);
    use CUDA. For a quick inference check use the ollama release tarball
    (ollama-linux-amd64.tar.zst, zstd), not nixpkgs#ollama-cuda: that one is
    unfree, so nothing caches it and it compiles for tens of minutes.

    ## Run long jobs detached, and log to a file

        WEBUI_LOGS=/root/job.log WEBUI_PROGRESS_PATTERN='step (\d+)/(\d+)' \
          setsid nohup ./train.sh > /root/job.log 2>&1 < /dev/null &

    Anything you start in an SSH session dies with it. `tmux new -d` works too.

    ## Watching a run from the browser

    Any process that sets WEBUI_LOGS is picked up within a few seconds -- no
    restart, no recycle. WEBUI_PROGRESS_PATTERN is a Python regex matched
    against each line; the newest match drives the progress bar:

        (?P<percent>\d+(\.\d+)?)%      -- one named group with a percentage
        step (?P<current>\d+)/(?P<total>\d+)
        step (\d+)/(\d+)               -- unnamed: first group / second group

    Several logs at once are fine: each distinct path gets its own entry in the
    UI's picker, and two processes naming the same file share one view. From the shell:

        curl -s "localhost:1111/raw?token=$(cat /run/vastai-webui/token)" | tail

    The port is published on a public IP, so the log must not contain secrets.

    ## Reading the container's own environment

    Variables set at rental time are not in your shell -- they live on PID 1:

        tr '\0' '\n' < /proc/1/environ

    Worth knowing: PUBLIC_IPADDR, VAST_TCP_PORT_22, VAST_TCP_PORT_1111,
    VAST_CONTAINERLABEL, CONTAINER_ID.

    ## When something looks wrong

        systemctl --failed          # nothing should be listed
        journalctl -u <unit> -b
        readlink -f /run/current-system   # the only honest image identity
        df -h /                     # a full disk looks like every other bug

    Changing the image means rebuild, push a new tag, and `vastai recycle
    instance` from outside -- never `reboot`.
  '';

  render = pkgs.writeShellScript "render-motd" ''
    set -u
    export PATH=${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.gnused ]}:/run/current-system/sw/bin:/usr/bin

    from_pid1() { tr '\0' '\n' < /proc/1/environ | sed -n "s/^$1=//p" | head -1; }

    label=$(from_pid1 VAST_CONTAINERLABEL)
    instance=$(from_pid1 CONTAINER_ID)
    ip=$(from_pid1 PUBLIC_IPADDR)
    port=$(from_pid1 VAST_TCP_PORT_1111)
    [ -n "$ip" ] || ip=127.0.0.1
    [ -n "$port" ] || port=1111
    gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd, - || true)

    # The web UI writes its token at startup; give it a moment before giving up.
    token=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      token=$(cat /run/vastai-webui/token 2>/dev/null || true)
      [ -z "$token" ] || break
      sleep 0.5
    done

    {
      printf 'vast.ai NixOS box'
      [ -z "$label" ]    || printf ' - %s' "$label"
      [ -z "$instance" ] || printf ' (instance %s)' "$instance"
      [ -z "$gpu" ]      || printf ' - %s' "$gpu"
      printf '\n'
      printf 'Log UI  http://%s:%s/?token=%s\n' "$ip" "$port" "$token"
      printf 'Read /etc/ai-guide.md first - NixOS (no apt), ephemeral, teardown is owed.\n'
    } > /run/motd.tmp
    # A login mid-render must never read half a file.
    mv /run/motd.tmp /run/motd
  '';
in
{
  environment.etc."ai-guide.md".source = guide;

  # pam_motd re-reads the path on every login, so it may be generated at boot.
  # (Mutually exclusive with users.motd; services.openssh already turns showMotd on.)
  users.motdFile = "/run/motd";

  systemd.services.ai-guide-motd = {
    description = "Render the login guide shown on ssh";
    wantedBy = [ "multi-user.target" ];
    after = [ "vastai-webui.service" ];
    before = [ "sshd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = render;
    };
  };
}
