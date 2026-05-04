# vaysunic-inverter-locally

Local, cloudless monitoring of a [VaySunic VM800WE-P2][datasheet]
Wi-Fi micro-inverter (the 800 W "Balkonkraftwerk" model with a
Gizwits / Tencent Cloud back-end).

The inverter normally talks only to `api.gizwits.com` over plaintext
MQTT; this repo replaces that talk with a local Mosquitto broker on a
LAN host, so all telemetry stays in the home network and the
manufacturer's cloud is permanently blocked at the FRITZ!Box. Home
Assistant picks the data up via standard MQTT auto-discovery.

The full reverse-engineering log lives in
[`docs/vaysunic-inverter-notes.md`](./docs/vaysunic-inverter-notes.md).

## Architecture

```text
        PV  +  panels
         |
   [VM800WE-P2 inverter] ----- AC export to the grid
         |
         | TCP 1883 to 119.29.42.117 (the inverter's hardcoded "cloud" IP)
         | + plaintext MQTT (MQIsdp), username = DID, password = LAN passcode
         v
   [FRITZ!Box]
         | static IPv4 route: 119.29.42.117/32 via NAS
         | (Kindersicherung blocks all other WAN traffic from the inverter)
         v
   [NAS]  br0 has 119.29.42.117/32 as a secondary IP, so it answers as the
          "cloud broker"
         |
         v
   [Mosquitto]  topic: dev2app/<DID>  (Gizwits-framed P0 telemetry, every ~3 min)
         |
         v
   [vaysunic-mqtt-bridge]  decodes the binary frame, republishes JSON +
                           HA MQTT-discovery configs
         |
         v
   [Home Assistant]  one device, ~18 sensors auto-discovered
```

## Tools in this repo

| File                                      | Purpose                                                                                                                           |
|-------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `provision-vaysunic.sh`                   | One-time SoftAP -> FRITZ!Box Wi-Fi onboarding for a fresh-from-the-box inverter. Reproduces the Gizwits app's UDP packet on 12414. |
| `probe-vaysunic-lan.sh`                   | Raw LAN protocol explorer. Discovery, login, status reads, frame dumps. Useful for debugging.                                     |
| `read-vaysunic.sh`                        | Human-readable LAN reader. Logs in over TCP 12416, sends a standard-status read, prints decoded values (V, Hz, W, °C, kWh, …).    |
| `bridge/bridge.py`                        | Python service. Subscribes to `dev2app/<DID>` on the local broker, decodes the P0 frame, republishes JSON + HA discovery configs. |
| `bridge/module.nix`                       | NixOS module that packages and runs the bridge as a hardened systemd unit.                                                        |
| `docs/vaysunic-inverter-notes.md`         | Detailed reverse-engineering log: protocol findings, layout decoding, MQTT analysis, deployment record.                           |

The shell scripts use a `nix-shell` shebang and pull `bash` and `perl`
on demand, so they run on any NixOS box without needing anything
pre-installed.

## Quick reference

### Read live values once

After the inverter has been bound (or while the local broker is
running so its bind cache stays fresh):

```sh
./read-vaysunic.sh 192.168.178.79
```

### Run the broker emulation

The NAS-side Nix config (separate repo) imports
`bridge/module.nix` via `builtins.fetchGit` and enables the service:

```nix
imports = [ "${vaysunicSrc}/bridge/module.nix" ];

services.vaysunic-bridge = {
  enable = true;
  did = "<your-DID>";
  username = "vaysunic-bridge";
  passwordFile = "/var/lib/secrets/vaysunic-bridge-password";
  logFramesFile = "/var/log/vaysunic-bridge/device.log";
};
```

Plus, on the broker side:

- A Mosquitto user `<DID>` with the device's LAN passcode as password
  and `readwrite` ACL on `dev2app/<DID>/#` and `app2dev/<DID>/#`.
- A second user `vaysunic-bridge` with `read` on `dev2app/<DID>/#`,
  `readwrite` on `vaysunic/#` and `homeassistant/sensor/+/config`.
- `119.29.42.117/32` as a secondary IP on the broker host's LAN
  interface, plus a matching FRITZ!Box static route.

See the notes file for the exact configuration that's currently
running.

### Diagnosing

```sh
# Bridge service state (on the NAS)
systemctl status vaysunic-bridge
journalctl -u vaysunic-bridge -f

# Live MQTT traffic from the inverter
mosquitto_sub -h <broker> -u <DID> -P <passcode> \
  -i monitor -t 'dev2app/<DID>' -F '%I %t %x'

# Decoded HA-style state JSON (republished by the bridge)
mosquitto_sub -h <broker> -u homeassistant -P <ha-password> \
  -t 'vaysunic/<DID>/state' -v
```

## Hardware findings (incidental)

- Wi-Fi module: Espressif **ESP32-C3**, firmware tag `04X3009R`.
- Inverter: VM800WE-P2, 800 W, 2 MPPT inputs (DC 33-48 V each),
  230/240 V AC, IP67, peak efficiency 96.8 %.
- LED: bicolor, slow green flash = on the LAN with cloud unreachable
  (the desired steady state once you've blocked the cloud).
- The MQTT password the device authenticates with on the cloud broker
  is the same 10-char passcode the LAN protocol returns via
  command `0x0006` over TCP 12416.

[datasheet]: https://res.vaysunic.com/docs/DE/Installationsanleitung/VM-P2%20Serie_VaySunic_Schnellinstallationsanleitung_DE_V3.0.pdf
