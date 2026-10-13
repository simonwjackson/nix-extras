{
  pkgs,
  nixpkgs,
  modules,
  packages,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  evaluate =
    extra:
    (nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        modules.nzbfast
        modules.scryer
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
        }
        extra
      ];
    }).config;
  disabled = evaluate { };
  defaults = evaluate {
    services.nzbfast.enable = true;
    services.scryer.enable = true;
  };
  customized = evaluate {
    services.nzbfast = {
      enable = true;
      user = "worker";
      group = "media";
      port = 12345;
      stateDir = "/srv/state";
      downloadDir = "/srv/downloads";
      openFirewall = true;
      package = pkgs.hello;
    };
    services.scryer = {
      enable = true;
      listenAddress = "::1";
      port = 12346;
      environmentFile = "/run/secrets/scryer.env";
      writablePaths = [ "/srv/media" ];
      supplementaryGroups = [ "downloads" ];
      umask = "0027";
      readOnlyPaths = [ "/srv/archive" ];
      adminPasswordFile = "/run/secrets/scryer-password";
      adminUsername = "operator";
      settings.SCRYER_AUTH_ENABLED = "true";
      environment.SCRYER_LOG_FORMAT = "text";
      waitForReady = true;
    };
    users.users.worker = {
      isSystemUser = true;
      group = "media";
    };
  };
  root = evaluate {
    services.scryer = {
      enable = true;
      user = "root";
    };
    services.nzbfast = {
      enable = true;
      group = "root";
    };
  };
  enabledThenDisabled = evaluate {
    services.nzbfast.enable = lib.mkForce false;
    services.scryer.enable = lib.mkForce false;
  };
  sameDirectory = evaluate {
    services.nzbfast = {
      enable = true;
      stateDir = "/srv/all";
      downloadDir = "/srv/all";
    };
  };
  overlapping = evaluate {
    services.scryer = {
      enable = true;
      readOnlyPaths = [ "/srv/media" ];
      writablePaths = [ "/srv/archive/../media/downloads" ];
    };
  };
  storedPassword = evaluate {
    services.scryer = {
      enable = true;
      adminPasswordFile = "/run/../nix/store/example-password";
    };
  };
  invalidUmask = evaluate {
    services.scryer = {
      enable = true;
      umask = "0088";
    };
  };
  rejected = config: message: lib.any (a: a.message == message && !a.assertion) config.assertions;
in
assert !(disabled.systemd.services ? nzbfast);
assert !(disabled.systemd.services ? scryer);
assert !(enabledThenDisabled.users.users ? nzbfast);
assert !(enabledThenDisabled.users.users ? scryer);
assert enabledThenDisabled.systemd.tmpfiles.rules == disabled.systemd.tmpfiles.rules;
assert defaults.services.nzbfast.package.outPath == packages.nzbfast.outPath;
assert defaults.services.scryer.package.outPath == packages.scryer.outPath;
assert customized.services.nzbfast.package.outPath == pkgs.hello.outPath;
assert defaults.services.nzbfast.listenAddress == "127.0.0.1";
assert defaults.services.scryer.listenAddress == "127.0.0.1";
assert !(lib.elem 6789 defaults.networking.firewall.allowedTCPPorts);
assert !(lib.elem 8080 defaults.networking.firewall.allowedTCPPorts);
assert defaults.systemd.services.nzbfast.serviceConfig.User == "nzbfast";
assert defaults.systemd.services.scryer.serviceConfig.User == "scryer";
assert defaults.systemd.services.scryer.serviceConfig.ProtectSystem == "strict";
assert !(defaults.systemd.services.scryer.serviceConfig ? MemoryDenyWriteExecute);
assert lib.elem 12345 customized.networking.firewall.allowedTCPPorts;
assert !(lib.elem 12346 customized.networking.firewall.allowedTCPPorts);
assert customized.systemd.services.nzbfast.serviceConfig.User == "worker";
assert lib.hasInfix "SCRYER_BIND=[::1]:12346"
  customized.systemd.services.scryer.serviceConfig.ExecStart;
assert
  customized.systemd.services.scryer.serviceConfig.EnvironmentFile == [ "/run/secrets/scryer.env" ];
assert lib.elem "/srv/media" customized.systemd.services.scryer.serviceConfig.ReadWritePaths;
assert defaults.services.scryer.supplementaryGroups == [ ];
assert defaults.services.scryer.umask == "0007";
assert defaults.services.scryer.readOnlyPaths == [ ];
assert defaults.services.scryer.adminPasswordFile == null;
assert defaults.services.scryer.adminUsername == "admin";
assert defaults.services.scryer.settings == { };
assert defaults.services.scryer.environment == { };
assert !defaults.services.scryer.waitForReady;
assert !(defaults.systemd.services.scryer.environment ? SCRYER_ADMIN_USERNAME);
assert defaults.systemd.services.scryer.serviceConfig.LoadCredential == [ ];
assert !(defaults.systemd.services.scryer.serviceConfig ? ExecStartPost);
assert !(defaults.systemd.services.scryer.serviceConfig ? TimeoutStartSec);
assert customized.systemd.services.scryer.serviceConfig.SupplementaryGroups == [ "downloads" ];
assert customized.systemd.services.scryer.serviceConfig.UMask == "0027";
assert customized.systemd.services.scryer.serviceConfig.ReadOnlyPaths == [ "/srv/archive" ];
assert
  customized.systemd.services.scryer.serviceConfig.LoadCredential
  == [ "admin-password:/run/secrets/scryer-password" ];
assert customized.systemd.services.scryer.environment.SCRYER_AUTH_ENABLED == "true";
assert customized.systemd.services.scryer.environment.SCRYER_LOG_FORMAT == "text";
assert
  customized.systemd.services.scryer.environment.SCRYER_ADMIN_PASSWORD_FILE == "%d/admin-password";
assert customized.systemd.services.scryer.environment.SCRYER_ADMIN_USERNAME == "operator";
assert customized.systemd.services.scryer.serviceConfig ? ExecStartPost;
assert rejected overlapping "Scryer readOnlyPaths must not overlap writablePaths or stateDir.";
assert rejected storedPassword
  "Scryer adminPasswordFile must be a runtime path outside the Nix store.";
assert rejected invalidUmask "Scryer umask must contain three or four octal digits.";
assert rejected root "NZBFAST must run as an unprivileged user and group.";
assert rejected root "Scryer must run as an unprivileged user and group.";
assert rejected sameDirectory
  "NZBFAST stateDir and downloadDir must differ: credentials must not share the downloads directory.";
pkgs.runCommand "nix-extras-module-options" { } ''
  echo 'Module option assertions passed' > "$out"
''
