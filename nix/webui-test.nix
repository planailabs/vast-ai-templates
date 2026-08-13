# NixOS VM test for the log web UI and the login guide.
#
# It builds a *slim* image (just the two modules, no CUDA) and drives it through
# Docker, because that is the only way to exercise the real path: env vars
# arriving via `docker run -e` land on PID 1, the ExposedPorts come from the
# image, and the /proc scan has actual processes to find.
{ pkgs, lib, nixos2docker }:

let
  image = (lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      nixos2docker.nixosModules.default
      ./webui.nix
      ./ai-guide.nix
      ({ ... }: {
        virtualisation.dockerImage = { name = "webui-test"; tag = "latest"; };
        services.openssh.enable = true;
        networking.hostName = "webui";
        environment.etc."hostname".enable = false;
        environment.etc."hosts".enable = false;
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        boot.loader.grub.enable = false;
        system.stateVersion = "25.11";
      })
    ];
  }).config.system.build.dockerImage;

  # docker exec doesn't inherit the image's ENV, so spell out PATH.
  path = "/run/current-system/sw/bin";
  exec = "docker exec -e PATH=${path} webui";
  api = "curl -sf 'http://localhost:8080/api/tail?token=testtoken";
in
{
  name = "webui";
  meta.maintainers = [ ];

  nodes.machine = { pkgs, ... }: {
    # python3 for the assertions below; the image under test ships none.
    environment.systemPackages = [ pkgs.python3 ];
    virtualisation = {
      docker.enable = true;
      memorySize = 2048;
      diskSize = 8192;
      cores = 2;
    };
  };

  testScript = ''
    import shlex

    def job(name, log, pattern):
        """A detached process that declares WEBUI_LOGS, like a real training run."""
        machine.succeed(
            f"docker exec -d webui ${path}/env WEBUI_LOGS={log} "
            f"'WEBUI_PROGRESS_PATTERN={pattern}' ${path}/sleep 600"
        )

    def write(log, text):
        """Append to a log inside the container. %b so the escapes below are
        real bytes, and shlex so nothing here reaches sh half-quoted."""
        inner = f"printf %b {shlex.quote(text)} >> {log}"
        machine.succeed("${exec} sh -c " + shlex.quote(inner))

    machine.wait_for_unit("docker.service")
    machine.succeed("docker load < ${image}")

    # The image itself must advertise the port and the Open button, or vast
    # never maps it.
    machine.succeed(
        "docker inspect webui-test:latest --format '{{json .Config.ExposedPorts}}'"
        " | grep -q '1111/tcp'"
    )
    machine.succeed(
        "docker inspect webui-test:latest --format '{{json .Config.Env}}'"
        " | grep -q 'OPEN_BUTTON_PORT=1111'"
    )

    machine.succeed(
        "docker run -d --name webui "
        "--tmpfs /run --tmpfs /run/lock --tmpfs /tmp "
        "--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw "
        "-p 8080:1111 -e WEBUI_TOKEN=testtoken "
        "webui-test:latest"
    )
    machine.wait_until_succeeds(
        "${exec} systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'",
        timeout=90,
    )

    with subtest("idle is a normal state, not a crash loop"):
        machine.succeed("${exec} systemctl is-active vastai-webui.service")
        machine.succeed("${exec} systemctl --failed --no-legend | wc -l | grep -q '^0$'")
        machine.wait_until_succeeds("curl -sf http://localhost:8080/healthz | grep -q ok", timeout=30)
        machine.succeed("curl -sf http://localhost:8080/ | grep -q '<progress'")
        machine.succeed(
            "test $(curl -s -o /dev/null -w '%{http_code}' "
            "http://localhost:8080/api/tail) = 401"
        )

    with subtest("a job started long after boot is picked up"):
        job("a", "/tmp/a.log", "step ([0-9]+)/([0-9]+)")
        write("/tmp/a.log", "step 5/10\n")
        machine.wait_until_succeeds("${api}' | grep -q '/tmp/a.log'", timeout=30)
        machine.wait_until_succeeds("${api}' | grep -q '\"percent\": 50.0'", timeout=30)

    with subtest("two processes on one file are one source"):
        job("a2", "/tmp/a.log", "step ([0-9]+)/([0-9]+)")
        machine.wait_until_succeeds(
            "${api}' | python3 -c \"import json,sys; d=json.load(sys.stdin);"
            " sys.exit(0 if len(d['sources']) == 1 and len(d['sources'][0]['procs']) == 2 else 1)\"",
            timeout=30,
        )

    with subtest("a second log gets its own source and becomes the default"):
        job("b", "/tmp/b.log", "(?P<percent>[0-9]+)%")
        write("/tmp/b.log", "building 55% done\n")
        machine.wait_until_succeeds(
            "${api}' | python3 -c \"import json,sys; d=json.load(sys.stdin);"
            " sys.exit(0 if len(d['sources']) == 2 and d['default'] == '/tmp/b.log'"
            " and d['tail']['key'] == '/tmp/b.log' else 1)\"",
            timeout=30,
        )
        machine.succeed("${api}&source=/tmp/a.log' | grep -q '\"percent\": 50.0'")

    with subtest("truncation and rotation do not stall the tail"):
        machine.succeed("${exec} sh -c ': > /tmp/a.log'")
        write("/tmp/a.log", "step 6/10\n")
        machine.wait_until_succeeds(
            "${api}&source=/tmp/a.log' | grep -q '\"percent\": 60.0'", timeout=30)
        machine.succeed("${exec} sh -c 'mv /tmp/a.log /tmp/a.log.1'")
        write("/tmp/a.log", "step 10/10\n")
        machine.wait_until_succeeds(
            "${api}&source=/tmp/a.log' | grep -q '\"percent\": 100.0'", timeout=30)

    with subtest("ANSI is stripped and a \\r-only line still counts"):
        write("/tmp/a.log", "\\033[32mstep 7/10\\033[0m\\r")
        machine.wait_until_succeeds(
            "${api}&source=/tmp/a.log' | grep -q '\"percent\": 70.0'", timeout=30)
        machine.fail("curl -sf 'http://localhost:8080/raw?token=testtoken&source=/tmp/a.log'"
                     " | grep -q $'\\033'")
        machine.succeed("curl -sf 'http://localhost:8080/raw?token=testtoken&source=/tmp/a.log'"
                        " | grep -q 'step 10/10'")

    with subtest("a finished run keeps its output and its last percent"):
        machine.succeed("${exec} pkill -f 'WEBUI_LOGS=/tmp/b.log' || true")
        machine.wait_until_succeeds(
            "${api}' | python3 -c \"import json,sys; d=json.load(sys.stdin);"
            " s=[x for x in d['sources'] if x['key']=='/tmp/b.log'][0];"
            " sys.exit(0 if s['state']=='orphaned' and s['progress']['percent']==55.0 else 1)\"",
            timeout=30,
        )

    with subtest("the guide is a file and the motd only points at it"):
        machine.succeed("${exec} grep -q WEBUI_LOGS /etc/ai-guide.md")
        machine.succeed("${exec} test $(wc -l < /run/motd) -le 5")
        machine.succeed("${exec} grep -q '/etc/ai-guide.md' /run/motd")
        machine.succeed("${exec} grep -q 'token=testtoken' /run/motd")
        machine.fail("${exec} grep -q 'apt, dnf or yum' /run/motd")

    with subtest("WEBUI_LOGS passed at rental time is followed from boot"):
        machine.succeed(
            "docker run -d --name preset "
            "--tmpfs /run --tmpfs /run/lock --tmpfs /tmp "
            "--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw "
            "-p 8081:1111 -e WEBUI_TOKEN=testtoken -e WEBUI_LOGS=/tmp/c.log "
            "-e 'WEBUI_PROGRESS_PATTERN=step ([0-9]+)/([0-9]+)' "
            "webui-test:latest"
        )
        machine.wait_until_succeeds(
            "docker exec -e PATH=${path} preset sh -c 'echo \"step 9/10\" >> /tmp/c.log'",
            timeout=90,
        )
        machine.wait_until_succeeds(
            "curl -sf 'http://localhost:8081/api/tail?token=testtoken' | grep -q '\"percent\": 90.0'",
            timeout=60,
        )

    with subtest("nothing broke on the way out"):
        machine.succeed("${exec} systemctl --failed --no-legend | wc -l | grep -q '^0$'")
        machine.succeed("docker stop -t 30 webui preset")
        machine.succeed("docker inspect webui --format='{{.State.ExitCode}}' | grep -q '^0$'")
  '';
}
