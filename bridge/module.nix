{ config, lib, pkgs, ... }:

let
  cfg = config.services.vaysunic-bridge;

  python = pkgs.python3.withPackages (ps: [ ps.paho-mqtt ]);

  bridgeScript = pkgs.writeShellApplication {
    name = "vaysunic-mqtt-bridge";
    runtimeInputs = [ python ];
    text = ''
      exec ${python}/bin/python3 ${./bridge.py} "$@"
    '';
  };
in
{
  options.services.vaysunic-bridge = {
    enable = lib.mkEnableOption "VaySunic / Gizwits inverter MQTT-to-Home-Assistant bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = bridgeScript;
      description = "Bridge script package.";
    };

    did = lib.mkOption {
      type = lib.types.str;
      example = "add8a1aB064yb50OdKfV1k";
      description = "Inverter DID. Used as the topic key on dev2app/<DID>.";
    };

    broker = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "MQTT broker host.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "MQTT broker port.";
    };

    username = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "vaysunic-bridge";
      description = "MQTT username for the bridge to connect with. Null for anonymous.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/secrets/vaysunic-bridge-password";
      description = ''
        Path to a file containing the MQTT password for ${"\${username}"}. Read at
        service start (not embedded in the Nix store).
      '';
    };

    clientId = lib.mkOption {
      type = lib.types.str;
      default = "vaysunic-bridge";
      description = "MQTT client ID for the bridge. Must differ from the inverter's own client ID (the DID).";
    };

    haDiscoveryPrefix = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant";
      description = "Home Assistant MQTT discovery prefix.";
    };

    stateTopicPrefix = lib.mkOption {
      type = lib.types.str;
      default = "vaysunic";
      description = "Prefix for the republished JSON state topic. Final topic is <prefix>/<DID>/state.";
    };

    expireAfter = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = ''
        Seconds before a Home Assistant sensor is marked unavailable if no new
        value arrives. The inverter publishes every ~180 s, so 600 s gives a
        comfortable two-cycle margin.
      '';
    };

    logFramesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/log/vaysunic-bridge/device.log";
      description = ''
        If set, the bridge appends 0x06 ASCII log frames received from the
        Wi-Fi module to this file. Useful for diagnosing reconnects and
        firmware messages. The file's parent directory is created if missing.
      '';
    };

    verbose = lib.mkEnableOption "verbose logging in the bridge";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.vaysunic-bridge = {
      description = "VaySunic inverter MQTT-to-HA bridge";
      after = [ "network.target" "mosquitto.service" ];
      wants = [ "mosquitto.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = lib.mkMerge [
        {
          MQTT_BROKER = cfg.broker;
          MQTT_PORT = toString cfg.port;
          VAYSUNIC_DID = cfg.did;
          MQTT_CLIENT_ID = cfg.clientId;
          HA_DISCOVERY_PREFIX = cfg.haDiscoveryPrefix;
          STATE_PREFIX = cfg.stateTopicPrefix;
        }
        (lib.mkIf (cfg.username != null) { MQTT_USERNAME = cfg.username; })
        (lib.mkIf (cfg.passwordFile != null) {
          MQTT_PASSWORD_FILE = "/run/credentials/vaysunic-bridge.service/mqtt-password";
        })
        (lib.mkIf (cfg.logFramesFile != null) { LOG_FRAMES_FILE = toString cfg.logFramesFile; })
      ];

      serviceConfig = {
        DynamicUser = true;
        ExecStart = "${cfg.package}/bin/vaysunic-mqtt-bridge --expire-after ${toString cfg.expireAfter}"
          + lib.optionalString cfg.verbose " --verbose";
        Restart = "on-failure";
        RestartSec = "10s";

        # Read password file via systemd credentials so the file's path / contents
        # stay outside the Nix store. Bridge resolves the in-cred path via the
        # MQTT_PASSWORD_FILE env var set above.
        LoadCredential = lib.mkIf (cfg.passwordFile != null) [
          "mqtt-password:${toString cfg.passwordFile}"
        ];

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        PrivateTmp = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];

        # Allow appending to a single log file under /var/log if requested
        ReadWritePaths = lib.mkIf (cfg.logFramesFile != null)
          [ (builtins.dirOf (toString cfg.logFramesFile)) ];
        StateDirectory = lib.mkIf (cfg.logFramesFile != null) [ "vaysunic-bridge" ];
      };
    };
  };
}
