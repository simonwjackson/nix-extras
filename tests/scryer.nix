{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "nix-extras-scryer";
  nodes = {
    server = { config, pkgs, ... }: {
      imports = [ module ];
      services.scryer.enable = true;
      environment.systemPackages = [
        pkgs.curl
        pkgs.sqlite
        config.services.scryer.package
      ];
      virtualisation.memorySize = 3072;
      specialisation.lan-closed.configuration.services.scryer.listenAddress = pkgs.lib.mkForce "0.0.0.0";
      specialisation.disabled.configuration.services.scryer.enable = pkgs.lib.mkForce false;
    };
    peer = { pkgs, lib, ... }: {
      imports = [ module ];
      users.users.media-worker = {
        isSystemUser = true;
        group = "media";
      };
      services.scryer = {
        enable = true;
        user = "media-worker";
        group = "media";
        stateDir = "/srv/scryer-state";
        listenAddress = "0.0.0.0";
        port = 19092;
        openFirewall = true;
        environmentFile = "/run/scryer-test.env";
        writablePaths = [ "/srv/media" ];
      };
      systemd.tmpfiles.rules = [
        "d /srv/media 2770 media-worker media -"
        "d /srv/not-granted 2770 media-worker media -"
      ];
      systemd.services.scryer.wantedBy = lib.mkForce [ ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.sqlite
        pkgs.util-linux
      ];
      virtualisation.memorySize = 3072;
    };
  };
  testScript = ''
    start_all()
    server.wait_for_unit("scryer.service")
    server.succeed("scryer --version | grep -Fx 'scryer 0.21.15'")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health/ready", timeout=180)
    server.succeed("curl -fsS http://127.0.0.1:8080/ | grep -i scryer")
    server.succeed("ss -lnt | grep '127.0.0.1:8080'")
    peer.fail("curl -fsS --connect-timeout 3 http://server:8080/health/ready")
    server.succeed("test $(stat -c %U:%a /var/lib/scryer) = scryer:700")
    server.succeed("test $(stat -c %U /var/lib/scryer/scryer.db) = scryer")
    server.succeed("test $(stat -c %a /var/lib/scryer/encryption.key) = 600")
    server.succeed("test $(ps -o user= -p $(systemctl show -p MainPID --value scryer)) = scryer")
    key = server.succeed("cat /var/lib/scryer/encryption.key").strip()
    assert key
    server.succeed("sqlite3 /var/lib/scryer/scryer.db \"CREATE TABLE nix_extras_persistence (value TEXT); INSERT INTO nix_extras_persistence VALUES ('kept');\"")
    server.succeed("systemctl restart scryer")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health/ready", timeout=180)
    assert server.succeed("cat /var/lib/scryer/encryption.key").strip() == key
    assert server.succeed("sqlite3 /var/lib/scryer/scryer.db 'SELECT value FROM nix_extras_persistence;'").strip() == "kept"
    assert server.succeed("sqlite3 /var/lib/scryer/scryer.db 'PRAGMA integrity_check;'").strip() == "ok"

    server.succeed("/run/current-system/specialisation/lan-closed/bin/switch-to-configuration test")
    server.wait_until_succeeds("ss -lnt | grep '0.0.0.0:8080'")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:8080/health/ready", timeout=180)
    peer.fail("curl -fsS --connect-timeout 3 http://server:8080/health/ready")

    # This fixture is not a real secret. Runtime overrides must not defeat the
    # module's bind address or re-enable an application-managed binary upgrade.
    peer.succeed("printf 'SCRYER_BIND=127.0.0.1:19999\\nSCRYER_DISABLE_SELF_UPGRADE=0\\nSCRYER_LOG_FORMAT=text\\n' > /run/scryer-test.env; chmod 600 /run/scryer-test.env")
    peer.succeed("systemctl start scryer")
    peer.wait_for_unit("scryer.service")
    server.wait_until_succeeds("curl -fsS http://peer:19092/health/ready", timeout=180)
    peer.succeed("curl -fsS http://127.0.0.1:19092/ | grep -i scryer")
    peer.succeed("test $(stat -c %U:%G:%a /srv/scryer-state) = media-worker:media:700")
    peer.succeed("test $(ps -o user= -p $(systemctl show -p MainPID --value scryer)) = media-worker")
    peer.succeed("tr '\\0' '\\n' < /proc/$(systemctl show -p MainPID --value scryer)/environ | grep -Fx SCRYER_DISABLE_SELF_UPGRADE=1")
    peer.succeed("nsenter -t $(systemctl show -p MainPID --value scryer) -m -- runuser -u media-worker -- sh -c 'touch /srv/media/service-probe && ! touch /srv/not-granted/service-probe'")
    peer.succeed("systemctl restart scryer")
    server.wait_until_succeeds("curl -fsS http://peer:19092/health/ready", timeout=180)
    server.succeed("/run/booted-system/specialisation/disabled/bin/switch-to-configuration test")
    server.fail("systemctl is-active scryer")
    assert server.succeed("cat /var/lib/scryer/encryption.key").strip() == key
    assert server.succeed("sqlite3 /var/lib/scryer/scryer.db 'SELECT value FROM nix_extras_persistence;'").strip() == "kept"
  '';
}
