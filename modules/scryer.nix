{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.scryer;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  absolutePath = types.addCheck types.str (s: lib.hasPrefix "/" s && s != "/" && !lib.hasInfix "%" s);
  bind =
    if lib.hasInfix ":" cfg.listenAddress then
      "[${cfg.listenAddress}]:${toString cfg.port}"
    else
      "${cfg.listenAddress}:${toString cfg.port}";
in
{
  options.services.scryer = {
    enable = mkEnableOption "the Scryer media manager";
    package = mkOption {
      type = types.package;
      description = "Scryer package to run, including the embedded web UI.";
    };
    user = mkOption {
      type = types.str;
      default = "scryer";
      description = "Service user. A custom user must already exist.";
    };
    group = mkOption {
      type = types.str;
      default = "scryer";
      description = "Service group. This group is created if absent.";
    };
    stateDir = mkOption {
      type = absolutePath;
      default = "/var/lib/scryer";
      description = "Private mutable database, encryption keys, plugins, and cache directory.";
    };
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listener IP address. IPv6 addresses are bracketed automatically.";
    };
    port = mkOption {
      type = types.port;
      default = 8080;
      description = "HTTP listener port.";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Allow inbound TCP connections to the listener port.";
    };
    environmentFile = mkOption {
      type = types.nullOr absolutePath;
      default = null;
      example = "/run/secrets/scryer.env";
      description = "Runtime systemd environment file for secrets and upstream options. Use a string path, not a Nix path or store file.";
    };
    writablePaths = mkOption {
      type = types.listOf absolutePath;
      default = [ ];
      description = "Additional existing directories the service may write, including media libraries and download directories used for imports.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != "root" && cfg.group != "root";
        message = "Scryer must run as an unprivileged user and group.";
      }
    ];
    users.groups.${cfg.group} = { };
    users.users.scryer = mkIf (cfg.user == "scryer") {
      isSystemUser = true;
      inherit (cfg) group;
      home = cfg.stateDir;
    };
    systemd.tmpfiles.rules = [ "d ${lib.escapeShellArg cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -" ];
    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

    systemd.services.scryer = {
      description = "Scryer media manager";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        # env keeps the Nix-owned bind and upgrade policy authoritative even
        # when the optional runtime environment file also names these keys.
        ExecStart = lib.escapeShellArgs [
          "${pkgs.coreutils}/bin/env"
          "SCRYER_BIND=${bind}"
          "SCRYER_DISABLE_SELF_UPGRADE=1"
          "SCRYER_PACKAGE=nix"
          (lib.getExe cfg.package)
          "--data-dir"
          cfg.stateDir
        ];
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 120;
        UMask = "0007";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        ReadWritePaths = [ cfg.stateDir ] ++ cfg.writablePaths;
        # Do not set MemoryDenyWriteExecute: the Wasmtime plugin JIT needs it.
      };
    };
  };
}
