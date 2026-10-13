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
  readinessAddress =
    if cfg.listenAddress == "0.0.0.0" then
      "127.0.0.1"
    else if cfg.listenAddress == "::" then
      "::1"
    else
      cfg.listenAddress;
  readinessHost =
    if lib.hasInfix ":" readinessAddress then "[${readinessAddress}]" else readinessAddress;
  waitForReady = pkgs.writeShellScript "scryer-wait-ready" ''
    set -o pipefail
    while true; do
      if ${pkgs.curl}/bin/curl --noproxy '*' --fail --silent --max-time 2 \
        ${lib.escapeShellArg "http://${readinessHost}:${toString cfg.port}/health/ready"} \
        | ${pkgs.jq}/bin/jq -e '.ready == true' >/dev/null; then
        exit 0
      fi
      sleep 1
    done
  '';
  normalizePath =
    path:
    "/"
    + lib.concatStringsSep "/" (
      lib.foldl' (
        parts: part:
        if part == "" || part == "." then
          parts
        else if part == ".." then
          lib.take (lib.max 0 (builtins.length parts - 1)) parts
        else
          parts ++ [ part ]
      ) [ ] (lib.splitString "/" path)
    );
  overlaps =
    leftPath: rightPath:
    let
      left = normalizePath leftPath;
      right = normalizePath rightPath;
    in
    left == right
    || left == "/"
    || right == "/"
    || lib.hasPrefix "${left}/" right
    || lib.hasPrefix "${right}/" left;
in
{
  imports = [
    (lib.mkAliasOptionModule [ "services" "scryer" "settings" ] [ "services" "scryer" "environment" ])
  ];
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
    supplementaryGroups = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional groups granted to the service process. Groups must already exist.";
    };
    umask = mkOption {
      type = types.str;
      default = "0007";
      description = "File creation mask passed to systemd UMask.";
    };
    readOnlyPaths = mkOption {
      type = types.listOf absolutePath;
      default = [ ];
      description = "Existing paths mounted read-only. Must not overlap writablePaths or stateDir.";
    };
    adminPasswordFile = mkOption {
      type = types.nullOr absolutePath;
      default = null;
      example = "/run/secrets/scryer-admin-password";
      description = "Root-only runtime password file loaded through systemd credentials. Use a string path outside the store, never a Nix path or builtins.readFile.";
    };
    adminUsername = mkOption {
      type = types.str;
      default = "admin";
      description = "Bootstrap admin username, used only with adminPasswordFile.";
    };
    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra non-secret environment variables. settings is an alias. Use runtime files or credentials for secrets.";
    };
    waitForReady = mkOption {
      type = types.bool;
      default = false;
      description = "Wait up to 180 seconds for health/ready to report ready: true before dependent units start.";
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
      {
        assertion =
          !(lib.any (
            readOnly: lib.any (overlaps readOnly) ([ cfg.stateDir ] ++ cfg.writablePaths)
          ) cfg.readOnlyPaths);
        message = "Scryer readOnlyPaths must not overlap writablePaths or stateDir.";
      }
      {
        assertion =
          cfg.adminPasswordFile == null
          || !(
            normalizePath cfg.adminPasswordFile == builtins.storeDir
            || lib.hasPrefix "${builtins.storeDir}/" (normalizePath cfg.adminPasswordFile)
          );
        message = "Scryer adminPasswordFile must be a runtime path outside the Nix store.";
      }
      {
        assertion = builtins.match "[0-7]{3,4}" cfg.umask != null;
        message = "Scryer umask must contain three or four octal digits.";
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
      environment =
        cfg.environment
        // lib.optionalAttrs (cfg.adminPasswordFile != null) {
          SCRYER_ADMIN_PASSWORD_FILE = "%d/admin-password";
          SCRYER_ADMIN_USERNAME = cfg.adminUsername;
        };
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        # env keeps the Nix-owned bind and upgrade policy authoritative even
        # when the optional runtime environment file also names these keys.
        ExecStart = lib.escapeShellArgs (
          [
            "${pkgs.coreutils}/bin/env"
            "SCRYER_BIND=${bind}"
            "SCRYER_DISABLE_SELF_UPGRADE=1"
            "SCRYER_PACKAGE=nix"
          ]
          ++ lib.optionals (cfg.adminPasswordFile != null) [
            "SCRYER_ADMIN_PASSWORD_FILE=%d/admin-password"
            "SCRYER_ADMIN_USERNAME=${cfg.adminUsername}"
          ]
          ++ [
            (lib.getExe cfg.package)
            "--data-dir"
            cfg.stateDir
          ]
        );
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 120;
        UMask = cfg.umask;
        SupplementaryGroups = cfg.supplementaryGroups;
        ReadOnlyPaths = cfg.readOnlyPaths;
        LoadCredential = lib.optional (
          cfg.adminPasswordFile != null
        ) "admin-password:${cfg.adminPasswordFile}";
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
      }
      // lib.optionalAttrs cfg.waitForReady {
        ExecStartPost = lib.escapeShellArgs [
          "${pkgs.coreutils}/bin/timeout"
          "--verbose"
          "180"
          waitForReady
        ];
        TimeoutStartSec = 185;
      };
    };
  };
}
