{
  pkgs,
  module,
  plugin,
}:
pkgs.testers.runNixOSTest {
  name = "nix-extras-scryer-options";
  nodes.server = { lib, pkgs, ... }: {
    imports = [ module ];
    services.scryer = {
      enable = true;
      supplementaryGroups = [ "downloads" ];
      umask = "0027";
      readOnlyPaths = [ "/srv/archive" ];
      writablePaths = [
        "/srv/media"
        "/srv/downloads"
      ];
      adminPasswordFile = "/run/scryer-admin-password";
      adminUsername = "operator";
      environmentFile = "/run/scryer-options.env";
      settings.SCRYER_AUTH_ENABLED = "true";
      environment.SCRYER_LOG_FORMAT = "text";
      waitForReady = true;
    };
    users.groups.downloads = { };
    systemd.tmpfiles.rules = [
      "d /srv/archive 0770 scryer scryer -"
      "d /srv/media 0770 scryer scryer -"
      "d /srv/downloads 2770 root downloads -"
    ];
    systemd.services.scryer = {
      wantedBy = lib.mkForce [ ];
      serviceConfig.ExecStartPost = lib.mkAfter [
        (pkgs.writeShellScript "scryer-options-probe" ''
          set -euo pipefail
          test ! -r /run/scryer-admin-password
          touch /srv/media/umask-probe
          touch /srv/downloads/group-probe
          if touch /srv/archive/read-only-probe; then
            echo 'readOnlyPaths was writable' >&2
            exit 1
          fi
        '')
      ];
    };
    systemd.services.scryer-dependent = {
      requires = [ "scryer.service" ];
      after = [ "scryer.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -o pipefail
        ${pkgs.curl}/bin/curl --fail --silent http://127.0.0.1:8080/health/ready \
          | ${pkgs.jq}/bin/jq -e '.ready == true'
        touch /run/scryer-dependent-ready
      '';
    };
    environment.systemPackages = [
      pkgs.python3
      pkgs.curl
      pkgs.jq
    ];
    virtualisation.memorySize = 3072;
  };
  testScript = ''
    start_all()
    server.succeed("python3 ${./scryer-options.py} prepare")
    server.succeed("systemctl start scryer-dependent", timeout=200)
    server.wait_for_unit("scryer.service")
    server.succeed("test -f /run/scryer-dependent-ready")
    server.succeed("curl -fsS http://127.0.0.1:8080/health/ready | jq -e '.ready == true'")
    server.succeed("test $(stat -c %a /srv/media/umask-probe) = 640")
    server.succeed("test $(stat -c %G /srv/downloads/group-probe) = downloads")
    server.succeed("test ! -e /srv/archive/read-only-probe")
    server.succeed("grep -E '^Umask:[[:space:]]+0027$' /proc/$(systemctl show -p MainPID --value scryer)/status")
    server.succeed("grep -E '^Groups:.*\\b'$(getent group downloads | cut -d: -f3)'\\b' /proc/$(systemctl show -p MainPID --value scryer)/status")
    server.succeed("python3 ${./scryer-options.py} verify ${plugin}/share/scryer/plugins/transmission/plugin-v3.wasm.zst", timeout=240)
    server.succeed("systemctl restart scryer", timeout=200)
    server.succeed("curl -fsS http://127.0.0.1:8080/health/ready | jq -e '.ready == true'")
    server.succeed("python3 ${./scryer-options.py} verify-restart")
  '';
}
