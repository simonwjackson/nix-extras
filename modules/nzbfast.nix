{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nzbfast;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  absolutePath = types.addCheck types.str (s: lib.hasPrefix "/" s && s != "/" && !lib.hasInfix "%" s);
in
{
  options.services.nzbfast = {
    enable = mkEnableOption "the NZBFAST Usenet downloader";
    package = mkOption {
      type = types.package;
      description = "NZBFAST package to run.";
    };
    user = mkOption {
      type = types.str;
      default = "nzbfast";
      description = "Service user. A custom user must already exist.";
    };
    group = mkOption {
      type = types.str;
      default = "nzbfast";
      description = "Service group. This group is created if absent.";
    };
    stateDir = mkOption {
      type = absolutePath;
      default = "/var/lib/nzbfast";
      description = "Private mutable configuration, API key, queue, and history directory.";
    };
    downloadDir = mkOption {
      type = absolutePath;
      default = "/var/lib/nzbfast/downloads";
      description = "Completed downloads directory. Created with group-write permission.";
    };
    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listener IP address.";
    };
    port = mkOption {
      type = types.port;
      default = 6789;
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
      example = "/run/secrets/nzbfast.env";
      description = "Runtime systemd environment file. Use a string path, not a Nix path or store file, for secrets.";
    };
    writablePaths = mkOption {
      type = types.listOf absolutePath;
      default = [ ];
      description = "Additional existing directories the service may write, such as category destinations.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != "root" && cfg.group != "root";
        message = "NZBFAST must run as an unprivileged user and group.";
      }
      {
        assertion = cfg.stateDir != cfg.downloadDir;
        message = "NZBFAST stateDir and downloadDir must differ: credentials must not share the downloads directory.";
      }
    ];
    users.groups.${cfg.group} = { };
    users.users.nzbfast = mkIf (cfg.user == "nzbfast") {
      isSystemUser = true;
      inherit (cfg) group;
      home = cfg.stateDir;
    };
    systemd.tmpfiles.rules = [
      "d ${lib.escapeShellArg cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -"
      "d ${lib.escapeShellArg cfg.downloadDir} 2770 ${cfg.user} ${cfg.group} -"
    ];
    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

    systemd.services.nzbfast = {
      description = "NZBFAST Usenet downloader";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      # Upstream gives saved settings precedence over CLI flags. Only these
      # service-owned fields are synchronized; a first run creates no settings.
      preStart = ''
        settings=${lib.escapeShellArg "${cfg.stateDir}/settings.json"}
        if [ -e "$settings" ]; then
          tmp=$(${pkgs.coreutils}/bin/mktemp "$settings.XXXXXX")
          trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
          ${pkgs.jq}/bin/jq --slurp --exit-status --arg bind ${lib.escapeShellArg cfg.listenAddress} \
            --arg out ${lib.escapeShellArg cfg.downloadDir} --argjson port ${toString cfg.port} \
            'if length == 1 and (.[0] | type) == "object" then .[0] | .bind = $bind | .out_dir = $out | .port = $port else error("settings must contain one JSON object") end' \
            "$settings" > "$tmp"
          ${pkgs.coreutils}/bin/mv "$tmp" "$settings"
        fi
      '';
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = lib.escapeShellArgs [
          "${pkgs.coreutils}/bin/env"
          "NZBFAST_PORT_LOCKED=1"
          (lib.getExe cfg.package)
          "--config"
          "${cfg.stateDir}/config.json"
          "serve"
          "--bind"
          cfg.listenAddress
          "--port"
          (toString cfg.port)
          "--out"
          cfg.downloadDir
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
        ReadWritePaths = [
          cfg.stateDir
          cfg.downloadDir
        ]
        ++ cfg.writablePaths;
      };
    };
  };
}
