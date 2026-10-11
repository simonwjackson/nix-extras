{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "nix-extras-nzbfast";
  nodes = {
    server =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      {
        imports = [ module ];
        services.nzbfast.enable = true;
        systemd.services.nzbfast = lib.mkIf config.services.nzbfast.enable {
          environment.NZBFAST_NO_ENRICH = "1";
        };
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
          config.services.nzbfast.package
        ];
        virtualisation.memorySize = 1536;
        specialisation.lan-closed.configuration.services.nzbfast.listenAddress = pkgs.lib.mkForce "0.0.0.0";
        specialisation.disabled.configuration.services.nzbfast.enable = pkgs.lib.mkForce false;
      };
    peer = { pkgs, lib, ... }: {
      imports = [ module ];
      users.users.download-worker = {
        isSystemUser = true;
        group = "media";
      };
      services.nzbfast = {
        enable = true;
        user = "download-worker";
        group = "media";
        stateDir = "/srv/nzbfast-state";
        downloadDir = "/srv/downloads/usenet";
        listenAddress = "0.0.0.0";
        port = 19091;
        openFirewall = true;
        environmentFile = "/run/nzbfast-test.env";
      };
      systemd.services.nzbfast.wantedBy = lib.mkForce [ ];
      systemd.tmpfiles.rules = [ "d /srv/not-granted 2770 download-worker media -" ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
        pkgs.util-linux
      ];
      virtualisation.memorySize = 1536;
    };
  };
  testScript = ''
    import json

    start_all()
    server.wait_for_unit("nzbfast.service")
    server.succeed("nzbfast --version | grep -F 1.7.1")
    server.wait_until_succeeds("curl -fsS http://127.0.0.1:6789/ | grep -i nzbfast")
    server.succeed("ss -lnt | grep '127.0.0.1:6789'")
    peer.fail("curl -fsS --connect-timeout 3 http://server:6789/")
    server.succeed("test $(stat -c %a /var/lib/nzbfast) = 700")
    server.succeed("test $(stat -c %U /var/lib/nzbfast/apikey) = nzbfast")
    server.succeed("test $(stat -c %a /var/lib/nzbfast/apikey) = 600")
    server.succeed("test $(ps -o user= -p $(systemctl show -p MainPID --value nzbfast)) = nzbfast")
    key = server.succeed("cat /var/lib/nzbfast/apikey").strip()
    assert len(key) >= 16
    status = server.succeed("curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:6789/api?mode=queue&output=json'").strip()
    assert status in ("401", "403"), status

    # A synthetic NZB stays queued because the fixture has no NNTP providers.
    server.succeed("printf '%s' '<nzb xmlns=\"http://www.newzbin.com/DTD/2003/nzb\"><file poster=\"test\" date=\"0\" subject=\"&quot;fixture.bin&quot; yEnc (1/1)\"><groups><group>alt.test</group></groups><segments><segment bytes=\"10\" number=\"1\">nix-extras-fixture@invalid</segment></segments></file></nzb>' > /tmp/fixture.nzb")
    response = json.loads(server.succeed(f"curl -fsS -F name=@/tmp/fixture.nzb 'http://127.0.0.1:6789/api?mode=addfile&output=json&apikey={key}'"))
    assert response["status"] is True, response
    job = response["nzo_ids"][0]
    queue_command = f"curl -fsS 'http://127.0.0.1:6789/api?mode=queue&output=json&apikey={key}'"
    server.wait_until_succeeds(queue_command + f" | jq -e '.queue.slots | map(.nzo_id) | index(\"{job}\") != null'")

    # Saved GUI values must not defeat the service's address or paths.
    server.succeed("systemctl stop nzbfast")
    server.succeed("printf '%s' '{\"bind\":\"0.0.0.0\",\"port\":19999,\"out_dir\":\"/tmp/wrong\",\"speedlimit\":1234}' > /var/lib/nzbfast/settings.json; chown nzbfast:nzbfast /var/lib/nzbfast/settings.json")
    server.succeed("systemctl start nzbfast")
    server.wait_until_succeeds(queue_command)
    assert server.succeed("cat /var/lib/nzbfast/apikey").strip() == key
    slots = json.loads(server.succeed(queue_command))["queue"]["slots"]
    assert job in [slot["nzo_id"] for slot in slots], slots
    server.succeed("ss -lnt | grep '127.0.0.1:6789'")
    server.succeed("jq -e '.bind == \"127.0.0.1\" and .port == 6789 and .out_dir == \"/var/lib/nzbfast/downloads\" and .speedlimit == 1234' /var/lib/nzbfast/settings.json")

    # Invalid saved settings fail without replacing the original file.
    server.succeed("systemctl stop nzbfast; cp -p /var/lib/nzbfast/settings.json /var/lib/nzbfast/settings.backup; printf '%s' '{broken' > /var/lib/nzbfast/settings.json")
    server.fail("systemctl start nzbfast")
    assert server.succeed("cat /var/lib/nzbfast/settings.json").strip() == "{broken"
    server.succeed("truncate -s 0 /var/lib/nzbfast/settings.json; systemctl reset-failed nzbfast")
    server.fail("systemctl start nzbfast")
    server.succeed("test ! -s /var/lib/nzbfast/settings.json; mv /var/lib/nzbfast/settings.backup /var/lib/nzbfast/settings.json; systemctl reset-failed nzbfast; systemctl start nzbfast")
    server.wait_until_succeeds(queue_command)

    # A non-loopback listener still stays unreachable with the firewall closed.
    server.succeed("/run/current-system/specialisation/lan-closed/bin/switch-to-configuration test")
    server.wait_until_succeeds("ss -lnt | grep '0.0.0.0:6789'")
    server.succeed("curl -fsS http://127.0.0.1:6789/ > /dev/null")
    peer.fail("curl -fsS --connect-timeout 3 http://server:6789/")

    # The runtime environment file is created outside the store before startup.
    peer.succeed("printf '%s' 'NZBFAST_NO_ENRICH=1' > /run/nzbfast-test.env; chmod 600 /run/nzbfast-test.env")
    peer.succeed("systemctl start nzbfast")
    peer.wait_for_unit("nzbfast.service")
    server.wait_until_succeeds("curl -fsS http://peer:19091/ | grep -i nzbfast")
    peer.succeed("test $(stat -c %U:%G:%a /srv/nzbfast-state) = download-worker:media:700")
    peer.succeed("test $(stat -c %U:%G:%a /srv/downloads/usenet) = download-worker:media:2770")
    peer.succeed("test $(ps -o user= -p $(systemctl show -p MainPID --value nzbfast)) = download-worker")
    peer.succeed("nsenter -t $(systemctl show -p MainPID --value nzbfast) -m -- runuser -u download-worker -- sh -c 'touch /srv/downloads/usenet/service-probe && ! touch /srv/not-granted/service-probe'")
    peer.succeed("systemctl restart nzbfast")
    server.wait_until_succeeds("curl -fsS http://peer:19091/ > /dev/null")
    server.succeed("touch /var/lib/nzbfast/downloads/keep.txt")
    server.succeed("/run/booted-system/specialisation/disabled/bin/switch-to-configuration test")
    server.fail("systemctl is-active nzbfast")
    assert server.succeed("cat /var/lib/nzbfast/apikey").strip() == key
    server.succeed("test -f /var/lib/nzbfast/downloads/keep.txt; test -d /var/lib/nzbfast/.spool")
  '';
}
