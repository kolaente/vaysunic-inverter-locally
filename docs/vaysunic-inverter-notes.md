# VaySunic / Gizwits Inverter Notes

Date: 2026-05-03
Last updated: 2026-05-04 (late evening: MQTT topic + payload decoded; cloud channel carries the same P0 frame as LAN reads, every 3 minutes)

This document records what we have learned so far about the VaySunic mini solar inverter, its Wi-Fi module, and the VaySunic Cloud app. The goal is local data access without using the VaySunic/Gizwits cloud account flow.

## Identified Model

The unit is a `VM800WE-P2` (800 W single-unit Balkonkraftwerk micro-inverter, WiFi variant; P2 generation).

Key spec values from the official German installation manual:

```text
Operating DC range:   20-60 V
MPPT range:           33-48 V
Max input voltage:    63 V DC
Max input current:    2 x 15 A (two MPPT inputs)
Output:               230/240 V AC, 50 Hz
Default power factor: >0.99
Peak efficiency:      96.8%
Enclosure:            IP67
```

The comms module is powered from the DC (PV) input. The manual instructs to wait one minute after connecting DC for the comms module to activate.

Manual: `https://res.vaysunic.com/docs/DE/Installationsanleitung/VM-P2%20Serie_VaySunic_Schnellinstallationsanleitung_DE_V3.0.pdf`

## Hardware Observations

The inverter exposes a setup access point before it has been provisioned.

Observed AP:

```text
SSID: XPG-GAgent-f164
BSSID: 4A:CA:43:DD:F1:64
Security: WPA1/WPA2
Password: 123456789
```

When connected to the AP, the network looked like this:

```text
Laptop IP: 10.10.100.154/24
Device/gateway IP: 10.10.100.254
```

TCP scan against `10.10.100.254` found only one open TCP port:

```text
12416/tcp open
```

Ports checked and found closed included common HTTP/MQTT candidates such as `80`, `443`, `8080`, `1883`, and `8883`. A simple binary probe to TCP `12416` did not return a banner or obvious response.

After SoftAP provisioning to the FRITZ!Box Wi-Fi, the inverter joined the LAN as:

```text
Hostname: espressif.fritz.box
IP:       192.168.178.79
MAC:      48:CA:43:DD:F1:64
Vendor:   Espressif
```

The Espressif name is the Wi-Fi chip/module vendor name, not necessarily the inverter vendor.

LAN reachability and scans:

```text
Ping: intermittent but reachable, TTL 255
ARP:  48:CA:43:DD:F1:64 on 192.168.178.79
```

Focused TCP scan:

```text
23/tcp    closed telnet
80/tcp    closed http
443/tcp   closed https
1883/tcp  closed mqtt
8080/tcp  closed http-proxy
8883/tcp  closed secure-mqtt
12414/tcp closed unknown
12416/tcp open   unknown
21027/tcp closed unknown
```

Focused UDP scan:

```text
12414/udp open|filtered unknown
12416/udp closed        unknown
2415/udp  closed        codima-rtp
67/udp    closed        dhcps
68/udp    closed        dhcpc
123/udp   closed        ntp
5353/udp  closed        zeroconf
5683/udp  closed        coap
1883/udp  closed        ibm-mqisdp
8883/udp  closed        secure-mqtt
```

There is no HTTP UI and no obvious MQTT listener. TCP `12416` is the important local Gizwits control socket.

The QR code on the inverter/manual points to:

```text
https://appstore.gizwits.com/VaySunic
```

The relevant Android app package is:

```text
com.vaysunic.app
```

This is not the `com.vaysunic.VipApp` package.

## Exact App

The exact app was downloaded as an XAPK from APKPure using `apkeep`.

Local investigation artifacts were placed under `/tmp`:

```text
/tmp/vaysunic-apks/com.vaysunic.app.xapk
/tmp/vaysunic-xapk/
/tmp/vaysunic-main/
/tmp/vaysunic-arm64/
/tmp/vaysunic-jadx/
```

XAPK manifest:

```json
{
  "package_name": "com.vaysunic.app",
  "name": "VaySunic Cloud",
  "version_code": "11460000",
  "version_name": "1.1.46",
  "min_sdk_version": "26",
  "target_sdk_version": "34"
}
```

The XAPK contains:

```text
com.vaysunic.app.apk
config.arm64_v8a.apk
config.en.apk
config.mdpi.apk
```

Important app assets:

```text
/tmp/vaysunic-main/assets/index.android.bundle
/tmp/vaysunic-main/assets/app.config
/tmp/vaysunic-arm64/lib/arm64-v8a/libGizWifiDaemon.so
/tmp/vaysunic-arm64/lib/arm64-v8a/libBLEasyConfig.so
```

The app is a React Native Gizwits "super app":

```json
{
  "name": "gizwitssuperapprn",
  "currentFullName": "@rbwang/gizwitssuperapprn",
  "android": {
    "package": "com.gizwits.xb"
  }
}
```

## App IDs and Cloud Domains

The VaySunic app bundle contains these Gizwits app credentials:

```text
Android app ID:     f11cd9dd1ea24f8d9a9164a1ebbe4200
Android app secret: 17a4765b4a0b46fba3a7b744a59ffc75
iOS app ID:         43dd9325798e48f78393f80db81ce5fb
iOS app secret:     a84e6c1633264aa5901b0033d712e2af
```

The app config uses VaySunic/Gizwits cloud endpoints. For Europe and most selected regions it maps to:

```text
openAPIInfo: euapi.gizwits.com
siteInfo:    eusite.gizwits.com
pushInfo:    eu.push.gizwitsapi.com
aepInfo:     https://app.vaysunic.com/
gatewayInfo: https://euapi.gizwitsapi.com/
oauthInfo:   https://oauth.gizwitsapi.com/
```

The app also contains logging/statistics calls that can report onboarding attempts and device/app metadata. This is why we are avoiding the official app account/setup flow.

## Gizwits SDK Structure

The app uses Gizwits native modules:

```text
com.gizwitssdk.RNGizwitsRnSdkModule
com.gizwitssdk.RNGizwitsRnDeviceModule
```

The React Native bundle exposes these native modules as:

```js
NativeModules.RNGizwitsRnSdk
NativeModules.RNGizwitsRnDevice
```

Key Java classes found after JADX decompilation:

```text
/tmp/vaysunic-jadx/sources/com/gizwitssdk/RNGizwitsRnSdkModule.java
/tmp/vaysunic-jadx/sources/com/gizwitssdk/RNGizwitsRnDeviceModule.java
/tmp/vaysunic-jadx/sources/com/gizwits/gizwifisdk/api/GizWifiSDK.java
/tmp/vaysunic-jadx/sources/com/gizwits/gizwifisdk/api/SDKEventManager.java
/tmp/vaysunic-jadx/sources/com/gizwits/gizwifisdk/api/SoftApConfig.java
/tmp/vaysunic-jadx/sources/com/gizwits/gizwifisdk/api/GizWifiDevice.java
/tmp/vaysunic-jadx/sources/com/gizwits/gizwifisdk/api/MessageHandler.java
/tmp/vaysunic-jadx/sources/com/gizwits/gizwifisdk/GizWifiDaemon.java
```

The Java SDK starts a native daemon through:

```java
System.loadLibrary("GizWifiDaemon");
GizWifiDaemon.initSDK(...)
```

The app process talks to the native daemon over localhost:

```text
127.0.0.1:21027
```

The daemon protocol between Java and native is length-prefixed JSON:

```text
4 byte big-endian JSON length
UTF-8 JSON body
```

Important command IDs observed in the Java layer:

```text
1001  handshake
1002  handshake ack
1011  device onboarding
1012  device onboarding ack
1013  get SoftAP SSID list
1014  get SoftAP SSID list ack
1015  get bound devices
1016  get bound devices ack
1029  device subscribe
1030  device subscribe ack
1033  get device status
1034  get device status ack
1035  device control/write
1036  device control/write ack
1121  device safety register
1122  device safety register ack
1421  get P0 data
1422  get P0 data ack
1423  get status P0 data
1424  get status P0 data ack
1425  get P0 JSON data
1426  get P0 JSON data ack
```

The LAN protocol to the inverter itself is not fully visible in Java. Most of it appears to live inside `libGizWifiDaemon.so`.

Native strings in `libGizWifiDaemon.so` confirm functions and flow such as:

```text
GizWifiSDKSetSoftAPConfig
GizWifiSDKGetPasscodeFromLocalDevice
GizWifiSDKAutoLoginLocalDevice
GizWifiSDKProcessDataFromDeviceUDPFd
GizWifiSDKEncode
GizWifiSDKDecode
GizWifiSDKGetDatapointByProductJsonStr
discover device<MAC:%s,productKey:%s,did:%s,IP:%s...>
get device info from device<MAC:%s,IP:%s> success
send get passcode from local deviceFd %d success
receive get passcode response from deviceFd %d success
send verify passcode to deviceFd %d success
receive verify passcode response...
```

This confirmed that the device can be used locally once it is on the same LAN.
The packet framing/login details and the standard-status P0 read command have
now been reverse engineered enough to request status data locally.

## LAN Protocol Findings

A local probe script exists in this repository:

```bash
./probe-vaysunic-lan.sh 192.168.178.79
```

The script uses a Nix shell shebang and talks directly to TCP `12416`.
It also sends a LAN discovery packet to UDP `12414` before opening the TCP
session.

Successful UDP discovery request:

```text
TX: 00 00 00 03 03 00 00 03
Destination: 255.255.255.255:12414 and <device-ip>:12414
```

Successful UDP discovery response from `192.168.178.79:12414`:

```text
Command:     00 04
DID:         add8a1aB064yb50OdKfV1k
MAC:         48:CA:43:DD:F1:64
Module:      04X3009R
Product key: 81cd0c0164984978910ccd52892c4466
Tail bytes include: api.gizwits.com:80, 4.1.4, 11116431
```

The product key in the discovery response matches the `VM_WIFI` product
configuration from the app bundle.

Gizwits LAN frames are TCP stream messages with this shape:

```text
00 00 00 03
LEN
FLAG
CMD_HI CMD_LO
BODY...
```

`LEN` uses the same variable-length 7-bit encoding seen in `ProtocolBase#getLength`. It is the length of `FLAG + CMD + BODY`, not including the 4 byte header or the length field itself.

Important implementation note: TCP reads can contain multiple Gizwits frames back-to-back. The probe must split frames using the Gizwits length field. A single `read(4096)` is not a message boundary.

Successful local passcode/login sequence:

```text
Get passcode request:
TX: 00 00 00 03 03 00 00 06

Get passcode response:
RX: 00 00 00 03 0F 00 00 07 00 0A 47 4E 59 56 4A 47 47 4E 54 4F

Extracted passcode:
GNYVJGGNTO

Verify passcode request:
TX: 00 00 00 03 0F 00 00 08 00 0A 47 4E 59 56 4A 47 47 4E 54 4F

Verify passcode response:
RX: 00 00 00 03 04 00 00 09 00

Heartbeat request:
TX: 00 00 00 03 03 00 00 15

Heartbeat response:
RX: 00 00 00 03 03 00 00 16
```

Observed custom P0 status/query attempts:

```text
Query 0x90:
TX: 00 00 00 03 04 00 00 90 02
RX: 00 00 00 03 03 00 00 91

Query 0x93:
TX: 00 00 00 03 08 00 00 93 00 00 00 04 02
RX: 00 00 00 03 07 00 00 94 00 00 00 04
```

Those prove the local protocol is alive, but they do not produce inverter datapoint values on this device.

The important breakthrough came from disassembling `GizWifiSDKEncodeGetStatus` in
`libGizWifiDaemon.so`. The SDK has two status encodings:

```text
custom/non-standard P0 query without internal SN:
02

standard P0 query without internal SN:
12 <status bitmask>

standard P0 query with internal SN:
53 <4-byte SN> 00 <2-byte bitmask length> <status bitmask>
```

The `VM_WIFI` product config has datapoint IDs up to `54`, so the status bitmask
is `ceil((54 + 1) / 8) = 7` bytes. The SDK maps datapoint IDs into the bitmask
like this:

```text
byte_index = (mask_len - 1) - int(datapoint_id / 8)
bit        = 1 << (datapoint_id & 7)
```

An all-standard-status request through LAN command `00 90`:

```text
TX: 00 00 00 03 0B 00 00 90 12 FF FF FF FF FF FF FF
```

returns a `00 91` frame containing a P0 status payload:

```text
13 FF FF FF FF FF FF FF ...
```

An all-standard-status request through LAN command `00 93`:

```text
TX: 00 00 00 03 0F 00 00 93 00 00 00 05 12 FF FF FF FF FF FF FF
```

returns a `00 94` frame. Its body starts with the 4-byte wrapper serial number,
then the same P0 status shape:

```text
00 00 00 05 13 FF FF FF FF FF FF FF ...
```

This means local status requests work without an app account or cloud token.
The remaining work is decoding the returned binary P0 datapoint values
reliably.

A focused read-only subset currently used by `probe-vaysunic-lan.sh` is:

```text
54,0,1,2,3,4,5,8,9,10,11,12
```

That produces this 7-byte bitmask:

```text
40 00 00 00 00 1F 3F
```

The script prints the echoed mask, selected datapoint IDs, payload length, and
non-zero byte offsets. It intentionally does not decode the returned status
payload yet, because live responses showed that the device does not return a
compact list of only the requested datapoints.

Live standard-status behavior:

```text
Status code byte:       13
Echoed mask:            matches the requested mask
Data bytes after mask:  206 bytes
```

There are two distinct device states. They look the same on the wire (same
command, same length, same mask) but produce very different payloads.

**Unbound state** (factory-fresh, never associated with a Gizwits cloud
account, even if the device has joined the user's Wi-Fi):

```text
Focused mask payload:   all zeroes (always)
All-mask payload:       only offsets +9 and +10 non-zero (always)
Non-zero bytes:         +9 = 0x23, +10 = 0x28 (= 0x2328 = 9000)
```

We initially read this as evidence that bytes `+9/+10` were the
`VMCx008` power-factor field with raw 9000 → 0.00, and that the rest of
the payload was the rest of the writables and the read-only sensor area.
That whole interpretation was wrong - the payload is byte-identical
whether the inverter is in standby or actively producing. It is just a
fixed pre-bind pattern with no live sensor content.

**Bound state** (after a one-time bind via the official `com.vaysunic.app`
to the Gizwits cloud, even after the inverter's internet is re-blocked at
the FRITZ!Box):

```text
Focused / all-mask payloads carry live sensor values in product-order,
big-endian, 4 bytes per uint32 datapoint, starting at offset +21.
```

Decoded with all the standard read-only `VMx000-VMx009` and PV string
`VMP1x001-VMP8x004` datapoints, plus a tail block. Hex-dump excerpt of
a producing unit (cloud blocked, mid-day):

```text
+21-24   VMx001  grid voltage     uint32  ratio 0.1   ->  230.0 V
+25-28   VMx002  grid frequency   uint32  ratio 0.01  ->  50.04 Hz
+29-32   VMx003  current power    uint32  ratio 1     ->  345 W
+33-36   VMx004  temperature      uint32  ratio 0.1   ->  31.0 °C
+37-40   VMx005  rated power      uint32  ratio 1     ->  800 W
+41-44   VMx006  component count  uint32  ratio 1     ->  2
+45-48   VMx007  fault code 1     uint32              ->  0
+49-52   VMx008  fault code 2     uint32              ->  0
+53-56   VMx009  running status   uint32              ->  1
+57-60   VMP1x001 PV1 voltage     uint32  ratio 0.1   ->  32.7 V
+61-64   VMP1x002 PV1 current     uint32  ratio 0.1   ->  5.6 A
+65-68   VMP1x003 PV1 power       uint32  ratio 0.1   ->  179.2 W
+69-72   VMP1x004 PV1 generation  uint32  ratio 0.01  ->  8.18
+73-76   VMP2x001 PV2 voltage     uint32  ratio 0.1   ->  32.1 V
+77-80   VMP2x002 PV2 current     uint32  ratio 0.1   ->  5.2 A
+81-84   VMP2x003 PV2 power       uint32  ratio 0.1   ->  166.4 W
+85-88   VMP2x004 PV2 generation  uint32  ratio 0.01  ->  7.92
+89-180  VMP3..VMP8 (uint32 x 4 each)                 ->  0 (no PV3-8 connected)
+185-188 VMx000  total generation uint32  ratio 0.01  ->  16.10 kWh
+194-205 ASCII serial number ("353800004548")
```

PV1 + PV2 power = 179.2 + 166.4 = 345.6 W matches the `VMx003` total
exactly. Successive reads return slightly different values, so the data
is live and not cached.

Notes on the layout:

- Offsets `+0..+20` are still mostly zeros plus the `0x2328` constant at
  `+9/+10`. Likely the writable/control datapoints (`VMCx*`) packed in
  some smaller form, but we have not validated those individually yet.
- Field decoding starts at `+21` and continues through `+88` for the
  documented `VMx*` and `VMP1x* / VMP2x*` blocks. `VMP3x*..VMP8x*` are
  reserved space, all zero on this 2-string unit.
- `VMx000` (lifetime generation) is **not** at the start - it is at
  `+185-188`, near the end of the variable-length area.
- The trailing ASCII string at `+194-205` looks like the inverter's
  internal serial/work-order number ("353800004548") and is consistent
  across reads.

The standard-status request mask appears to be irrelevant for sensor
content: an all-`FF` mask and the focused mask both return the same
underlying field positions filled with the same live values when the
device is bound. The mask seems to function as a presence-of-block
selector rather than a per-datapoint filter.

The visible `VM_WIFI` datapoints that are most useful for the first read-only
reader are:

```text
54  VMx000    total generation, uint32, ratio 0.01
0   VMx001    grid voltage, uint32, ratio 0.1
1   VMx002    grid frequency, uint32, ratio 0.01
2   VMx003    current power, uint32, ratio 1
3   VMx004    temperature, uint32, ratio 0.1
4   VMx005    rated power, uint32, ratio 1
5   VMx006    component count, uint32, ratio 1
8   VMx009    running status, uint32, ratio 1
9   VMP1x001  PV1 voltage, uint32, ratio 0.1
10  VMP1x002  PV1 current, uint32, ratio 0.1
11  VMP1x003  PV1 power, uint32, ratio 0.1
12  VMP1x004  PV1 generation, uint32, ratio 0.01
```

`./probe-vaysunic-lan.sh --map-status 192.168.178.79` can send one status mask
per locally-known schema entry. Current evidence shows the device accepts those
masks but still returns a 206-byte data area, so single-entry masks are useful
for clues but do not by themselves prove the full field layout.

Extra frames seen immediately after login:

```text
00 09 ack, repeated
00 62 ack/status
```

Meaning of `00 62` is not decoded yet.

## Captured-Traffic Confirmation

`vaysunic-app/vaysunic-lan.pcap` (gitignored, ~3 MB) contains TCP/UDP traffic
between phone (`.78`) and inverter (`.79`) over a long period covering many
probe sessions. Tally of unique LAN frame commands seen across the entire
capture:

```text
TX 0006 (16x)  RX 0007 (16x)   get passcode
TX 0008 (16x)  RX 0009 (32x)   verify passcode (sometimes acked twice)
TX 0015 (14x)  RX 0016 (14x)   heartbeat
TX 0090 (176x) RX 0091 (165x)  status query / response
TX 0093 (25x)  RX 0094 (24x)   status query with internal SN
               RX 0062 (16x)   mystery ack after verify
```

That is the complete set. No subscribe, no notify/push, no other read variant.
The phone does not use a LAN command we have missed.

UDP `255.255.255.255:2415` carries the inverter's outbound LAN beacon (cmd
`00 05`). Each beacon contains the same DID, MAC, module version, product key,
and `api.gizwits.com:80` cloud endpoint as the discovery response. Useful for
passive presence detection only; no telemetry.

Native daemon strings additionally distinguish "standard protocol" vs "variety
protocol" products. VaySunic VM_WIFI is "standard". The dispatcher is
`processP0DataPayload`. Action bytes follow Gizwits convention:

```text
0x02 / 0x03   read all (no mask) / response
0x12 / 0x13   read with bitmask / response
0x04          status report (push from device)
```

We have never seen the device emit an unsolicited `0x04` push frame.

## Status LED

The inverter has a single bicolor LED that combines Wi-Fi-module signaling
with inverter run state.

Observed states (2026-05-04):

```text
Red flashing       inverter not generating - transient at startup, before
                   grid sync, or while in protection delay
Green slow flash   inverter operating normally + Wi-Fi connected to LAN +
                   cloud unreachable (expected when internet is blocked at
                   the FRITZ!Box)
Green solid        connected to LAN AND cloud (expected before blocking)
Green fast flash   SoftAP / Wi-Fi pairing config mode (only during setup)
```

The "fast flash (1 s 4 times)" / "slow flash (1 s 1 time)" descriptions come
directly from the bundled `COMMON_TEXT_3` / `COMMON_TEXT_6` strings inside the
React Native bundle (Wi-Fi pairing wizard). The red/green color split for run
state matches general inverter convention and was confirmed on this unit by
watching the LED transition red -> green when grid sync completed.

The slow green flash is the cloudless steady-state we want.

## Cloudless Production - Confirmed

Multiple independent German retail listings for the VM800WE-P2 explicitly
state that the inverter produces power independently of the app or cloud
connection - the app is monitoring-only:

> "Der Wechselrichter produziert Strom unabhaengig davon, ob die App oder
>  Cloud-Verbindung aktiv ist. Die App dient also hauptsaechlich zur
>  Ueberwachung und nicht als Voraussetzung fuer die Stromproduktion."

This was further validated on 2026-05-04: with internet blocked at the
FRITZ!Box, panels delivering 38 V each, mains live, the inverter completed
grid sync (LED red -> green) and entered its normal operating state. So the
"the inverter needs to bind to the cloud once" theory is unlikely.

## SoftAP Provisioning

The exact SoftAP provisioning packet was decompiled from:

```text
com.gizwits.gizwifisdk.api.SoftApConfig#getSendData
```

The Java implementation:

```java
byte[] bytes = this.pwd.getBytes();
byte[] bytes2 = this.ssid.getBytes();
byte[] bArr = new byte[bytes.length + bytes2.length + 12];
bArr[0] = 0;
bArr[1] = 0;
bArr[2] = 0;
bArr[3] = 3;
bArr[4] = (byte) ((bytes.length + bytes2.length + 7) & 255);
bArr[5] = 0;
bArr[6] = 0;
bArr[7] = 1;
bArr[8] = 0;
bArr[9] = (byte) (bytes2.length & 255);
System.arraycopy(bytes2, 0, bArr, 10, bytes2.length);
int length = 10 + bytes2.length;
int i = length + 1;
bArr[length] = 0;
bArr[i] = (byte) (bytes.length & 255);
System.arraycopy(bytes, 0, bArr, i + 1, bytes.length);
```

Packet layout:

```text
00 00 00 03
LEN
00 00 01
00
SSID_LEN
SSID_BYTES
00
PASSWORD_LEN
PASSWORD_BYTES
```

Where:

```text
LEN = SSID_LEN + PASSWORD_LEN + 7
```

The app sends this packet:

```text
UDP source port: 12345
UDP destination: 255.255.255.255:12414
Interval: about every 5 seconds
```

Our script also sends it directly to:

```text
10.10.100.254:12414
```

The provisioning script is:

```text
provision-vaysunic.sh
```

It checks that the current Wi-Fi SSID starts with `XPG-GAgent-`, verifies that the route to `10.10.100.254` uses an interface with a `10.10.100.x` address, prompts for the target Wi-Fi SSID and password, then sends the SoftAP payload for 90 seconds.

Run it while connected to the inverter AP:

```bash
./provision-vaysunic.sh
```

It uses a `nix-shell` shebang:

```bash
#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl iproute2 iputils gawk gnugrep networkmanager
```

Perl is used only for binary UDP packet construction and sending from source port `12345`.

## Product Configurations

The React Native bundle contains all bundled product configs. Relevant products:

### VM_WIFI

Likely the direct Wi-Fi microinverter product.

```text
Name: VM_WIFI
Protocol: WIFI
Product key: 81cd0c0164984978910ccd52892c4466
Product secret: c8c564bd246f40d3b46910a6c4827eea
SoftAP SSID prefix: XPG-GAgent-
SoftAP password: 123456789
Network config type: BT_WIFI
Adapter: GizAdapterWifiBle
```

Read-only datapoints:

```text
VMx000   total generation, uint32, ratio 0.01
VMx001   grid voltage, uint32, ratio 0.1
VMx002   grid frequency, uint32, ratio 0.01
VMx003   current power, uint32, ratio 1
VMx004   temperature, uint32, ratio 0.1
VMx005   rated power, uint32, ratio 1
VMx006   component count, uint32, ratio 1
VMx007   fault code 1, uint32, ratio 1
VMx008   fault code 2, uint32, ratio 1
VMx009   running status, uint32, ratio 1
```

PV datapoints:

```text
VMP1x001  PV1 voltage, uint32, ratio 0.1
VMP1x002  PV1 current, uint32, ratio 0.1
VMP1x003  PV1 power, uint32, ratio 0.1
VMP1x004  PV1 generation, uint32, ratio 0.01

VMP2x001  PV2 voltage, uint32, ratio 0.1
VMP2x002  PV2 current, uint32, ratio 0.1
VMP2x003  PV2 power, uint32, ratio 0.1
VMP2x004  PV2 generation, uint32, ratio 0.01

VMP3x001  PV3 voltage, uint32, ratio 0.1
VMP3x002  PV3 current, uint32, ratio 0.1
VMP3x003  PV3 power, uint32, ratio 0.1
VMP3x004  PV3 generation, uint32, ratio 0.01

VMP4x001  PV4 voltage, uint32, ratio 0.1
VMP4x002  PV4 current, uint32, ratio 0.1
VMP4x003  PV4 power, uint32, ratio 0.1
VMP4x004  PV4 generation, uint32, ratio 0.01

VMP5x001  PV5 voltage, uint32, ratio 0.1
VMP5x002  PV5 current, uint32, ratio 0.1
VMP5x003  PV5 power, uint32, ratio 0.1
VMP5x004  PV5 generation, uint32, ratio 0.01

VMP6x001  PV6 voltage, uint32, ratio 0.1
VMP6x002  PV6 current, uint32, ratio 0.1
VMP6x003  PV6 power, uint32, ratio 0.1
VMP6x004  PV6 generation, uint32, ratio 0.01

VMP7x001  PV7 voltage, uint32, ratio 0.1
VMP7x002  PV7 current, uint32, ratio 0.1
VMP7x003  PV7 power, uint32, ratio 0.1
VMP7x004  PV7 generation, uint32, ratio 0.01

VMP8x001  PV8 voltage, uint32, ratio 0.1
VMP8x002  PV8 current, uint32, ratio 0.1
VMP8x003  PV8 power, uint32, ratio 0.1
VMP8x004  PV8 generation, uint32, ratio 0.01
```

Writable/control datapoints:

```text
VMCx001  inverter on/off, bool
VMCx002  clear ground fault, bool
VMCx004  grid standard, uint16
VMCx005  power limit percent of rated power, uint16
VMCx006  absolute power limit, uint16, max 5000
VMCx007  current power increment, uint16, addition -5000, max 5000
VMCx008  power factor, uint16, ratio 0.01, addition -90
VMCx009  generation clear, uint16
VMCx010  sub-1G channel, uint16
VMCx011  Wi-Fi module Bluetooth reset command, uint16
```

The app uses `VMCx001` for on/off:

```js
gizwitsSdk.sendCmd({
  device: device,
  data: { VMCx001: true_or_false }
})
```

We should avoid sending writable datapoints until read-only status access is stable and understood.

### VM

Likely RF/subdevice inverter product.

```text
Name: VM
Protocol: RF
Product key: 6c4bc07eff8a403f9c253d9c54423ca6
Product secret: f6ff0c54147d4f7c85125494e81f2242
Gateway subdevice product: true
```

It has similar `VMx...` and `VMP...` datapoints. Its temperature datapoint uses addition `-40`, unlike the direct Wi-Fi config observed for `VM_WIFI`.

### VSH_WIFI

Storage/PCS-style Wi-Fi product.

```text
Name: VSH_WIFI
Protocol: WIFI
Product key: 362027f1afed46bc8d276fbdaa47c551
Product secret: 72f3ec83d07240e389091f5226c7de63
SoftAP SSID prefix: XPG-GAgent-
SoftAP password: 123456789
Network config type: BT_WIFI
Adapter: GizAdapterWifiBle
```

Contains datapoints for PCS/storage and PV fields such as:

```text
PCSx001...
PCSCx001...
VSHP1x001...
VSHP2x001...
```

### SCG_G1

Gateway product.

```text
Name: SCG_G1
Product key: d0b8b1c69b61424e89db683444b88439
Product secret: be34248597bf4ccaa047b4ec77f8af0f
SoftAP SSID prefix: XPG-GAgent-
SoftAP password: 123456789
```

Contains gateway datapoints such as daily generation, current power, cumulative generation, and Wi-Fi signal.

## Expected Local Flow

Based on app code and Gizwits SDK behavior, the likely flow is:

1. App starts Gizwits SDK with the VaySunic app ID, app secret, product keys, product secrets, adapter types, and cloud service info.
2. SDK starts `libGizWifiDaemon.so`.
3. Java client handshakes with the native daemon on localhost port `21027`.
4. For SoftAP setup, Java also sends the simple UDP packet to the inverter AP on port `12414`.
5. Native daemon handles LAN discovery with command `00 03` -> `00 04` on UDP `12414`.
6. Direct local login on TCP `12416` works with commands `00 06` -> `00 07` and `00 08` -> `00 09`.
7. Keepalive uses `00 15` -> `00 16`.
8. Once a device is discovered/logged in, the app likely subscribes using product key/product secret and then receives datapoint updates.
9. Device reads use `getDeviceStatus` or P0 commands.
10. Device writes use `write` or `sendCmd`.

The app's own device list logic expects a cloud account token for `getBoundDevices`, but the native SDK has local discovery strings and functions. That is the opening for a cloudless LAN reader.

## FRITZ!Box Plan

First get the inverter onto the normal FRITZ!Box Wi-Fi, then block its internet access.

Recommended order:

1. Connect laptop to `XPG-GAgent-f164` with password `123456789`.
2. Run `./provision-vaysunic.sh`.
3. Enter the FRITZ!Box Wi-Fi SSID and password.
4. Wait for the inverter AP to disappear.
5. Open `http://fritz.box`.
6. Find the new inverter device.
7. Give it a recognizable name and fixed DHCP lease if possible.
8. Block its internet access under `Internet -> Filters`.
9. Keep LAN access enabled.

Do not use the guest Wi-Fi for this investigation, because guest Wi-Fi usually blocks local LAN access.

Prefer a 2.4 GHz SSID. The app/SDK explicitly warns about 5 GHz during onboarding, and many Gizwits Wi-Fi modules are 2.4 GHz only.

## Where We Are

The LAN path works **conditionally**. Once the inverter has been bound
to the Gizwits cloud via the official `com.vaysunic.app`, the standard
status read (`00 90 12 <mask>` -> `00 91 13 <mask> <206 bytes>`) returns
live sensor values via the layout decoded above. While that "bound"
state is active, internet can be blocked at the FRITZ!Box and reads
keep working.

**The bound state is not permanent.** End-to-end observation on
2026-05-04:

1. Inverter freshly installed the previous evening. FRITZ!Box internet
   blocked. Standard-status payload was the static pre-bind pattern
   (only `+9/+10 = 0x2328`), regardless of sun, grid sync, LED state,
   or producing/standby state.
2. Internet temporarily allowed. App installed, account created,
   device bound through the standard onboarding flow.
3. While bound and producing, `./probe-vaysunic-lan.sh` returned a
   fully populated payload matching physical reality (230.0 V /
   50.04 Hz mains, 31.0 °C, 800 W rated, 2 modules, two PV strings
   around 32 V / 5.5 A, AC output equal to PV1+PV2).
4. Internet re-blocked at the FRITZ!Box. Probe re-run shortly after:
   sensor values still present, slightly different from the previous
   read - confirming live data.
5. Roughly 30 minutes later (cloud still blocked, no other state
   change), probe re-run again: payload **back to the static pre-bind
   pattern**. Reader script's empty-payload detection caught it cleanly.
6. Internet allowed again, brief delay, full payload populates again
   without re-running the app.

So the device caches a "I have an active cloud subscriber" flag,
conditions the LAN read response on it, and the cache expires within
tens of minutes once the cloud channel is silent. To get a permanent
cloudless reader we need to keep that flag fresh.

## Cloud-Side Findings

Captured the inverter's WAN traffic via the FRITZ!Box built-in packet
capture (`http://fritz.box/html/capture.html`, per-client WLAN entry
for `espressif`). Output is a `.eth` file that is just pcap. Captures
placed under `captures/` (gitignored).

The inverter's entire WAN footprint is one long-lived TCP connection
to a single hardcoded IP, on plaintext MQTT:

```text
Inverter -> 119.29.42.117:1883 (TCP)
```

`119.29.42.117` is in Tencent Cloud. There are no DNS lookups (the IP
is cached/hardcoded in the device), no HTTPS, no TLS, no WebSocket,
no other destinations. Plain MQTT only.

### MQTT Cadence

```text
TCP session:    one long-lived connection, source port 56226
PINGREQ:        every ~50 s, 2-byte packet from inverter
PINGRESP:       ~300 ms after each PINGREQ, server replies 2 bytes
PUBLISH:        every ~180 s (3 minutes), inverter -> server, ~255 bytes
Server -> dev:  PINGRESPs and TCP ACKs only. No SUBSCRIBE response,
                no downstream PUBLISH, no commands.
```

So MQTT keep-alive is 50 s, telemetry rate is one push every 3 minutes,
and the broker is essentially a passive sink for our purposes.

### MQTT Topic and Payload

```text
Topic:    dev2app/<DID>            (this device: dev2app/add8a1aB064yb50OdKfV1k)
Payload:  the same Gizwits P0 status frame we get from a LAN read,
          byte-for-byte (header, length, command, mask, 206-byte data)
          except the status-code byte is 0x14 (vs 0x13 over LAN).
```

Decoded with the existing LAN reader's offset map, the first PUBLISH
in the capture was:

```text
Grid:    228.0 V  /  50.00 Hz
Output:  195 W
Temp:    29.5 °C
PV1:      32.3 V  /  3.1 A  =   99.2 W   (gen 8.22 kWh)
PV2:      32.6 V  /  3.0 A  =   96.0 W   (gen 7.98 kWh)
PV1+PV2 = 195.2 W  (matches Output)
Total:   16.20 kWh lifetime
Serial:  353800004548
```

So the MQTT path delivers the same telemetry as the LAN read. We do not
need to keep the LAN bind state alive at all - the inverter pushes its
own data on its own timer and we just need to be the broker that
receives it.

### Still Unknown

```text
The CONNECT packet content. The captures so far were taken mid-session,
  with the TCP connection already established before the capture started,
  so client ID / username / password / will / announced keepalive are not
  visible. To see them, capture during a fresh session: power-cycle the
  inverter, or close the existing TCP session at the network level, then
  let it reconnect.
Whether the broker authenticates. Most Gizwits stacks use productKey as
  username and a derivation involving productSecret as password. With
  Mosquitto running anonymous and accepting any CONNECT, the inverter
  may or may not be happy depending on what return code it expects.
Whether the device subscribes to a downstream topic (likely
  app2dev/<DID>) and whether the broker normally publishes anything on
  it that the device requires.
```

Raw 802.11 captures (`wlan-129...`) are encrypted Wi-Fi frames, not
useful without the WPA key. Pick the per-client decoded entry on the
FRITZ!Box capture page (labelled by hostname/MAC) instead.

## Local-Broker Emulation Plan

Plaintext MQTT, single hardcoded IP, passive broker, `dev2app/<DID>`
push every 3 minutes carrying the exact LAN P0 frame. Plan:

1. Run Mosquitto on a LAN host (Pi, NAS, always-on Linux box).
2. Add `119.29.42.117/32` as a **secondary IP** on that host's
   interface so the host owns the broker IP locally.
3. Add a **static route** on the FRITZ!Box (`Internet -> Freigaben /
   Statische Routing-Tabelle`): `119.29.42.117/32 via <LAN host>`.
4. Inverter sends to `119.29.42.117:1883`, FRITZ!Box routes to our
   LAN host, our host owns that IP, Mosquitto answers. No DNAT.
5. Mosquitto config: accept (initially) anonymous CONNECT, log topics
   and payloads. Subscribe to `dev2app/+/+` to capture all DIDs.
6. Decoder: the existing `read-vaysunic.sh` Perl logic, applied to
   the MQTT payload. Status byte is 0x14 instead of 0x13 - either
   accept both or remove the strict marker check.
7. Block the inverter's actual internet at the FRITZ!Box permanently.
   The static route catches the broker IP, everything else is blocked.
   No data leaves the LAN.

The MQTT path is independent of the volatile LAN-bind state. As long
as the inverter has TCP reachability to the (faked) broker IP, it will
publish telemetry every 3 minutes on its own. Once the broker is in
place, `read-vaysunic.sh` becomes optional - useful for on-demand
reads while the bind cache is still fresh, but no longer the primary
data path.

## Open Items

```text
A capture of a fresh MQTT session (CONNECT included) to see client ID,
  username, password, will, announced keepalive. Easiest trigger: power-
  cycle the inverter while the FRITZ!Box capture is running.
Whether the broker authenticates and what return codes the inverter
  tolerates from CONNACK.
Whether the device subscribes to a downstream topic (likely
  app2dev/<DID>) and whether the broker normally publishes anything
  on it that the device requires.
Decoding of the writable/control area at offsets +0..+20 in the LAN
  status payload.
Decoding of the trailing block (+181 onwards beyond VMx000 at +185-188
  and the ASCII serial at +194-205).
Meaning of LAN command 00 62 (still: mystery ack after verify).
```

## Tools In This Repo

```text
provision-vaysunic.sh     One-time SoftAP -> FRITZ!Box Wi-Fi onboarding.
probe-vaysunic-lan.sh     Raw LAN protocol explorer; prints framing,
                          login, status payloads, non-zero offsets.
read-vaysunic.sh          Human-readable LAN reader. Decodes the
                          standard-status payload into named fields
                          (grid V/Hz, output W, temp, total kWh, per-PV
                          V/I/P/gen). Detects unbound state.
```

## Engineering Next Steps

```text
1. Capture a fresh MQTT session (power-cycle the inverter during the
   FRITZ!Box capture) to see the CONNECT packet and confirm auth.
2. Stand up Mosquitto on a LAN host. Start with allow_anonymous,
   subscribe to dev2app/+ and log everything. Tighten auth later if
   the inverter requires specific credentials.
3. Add 119.29.42.117/32 as a secondary IP on the broker host, add
   the FRITZ!Box static route for 119.29.42.117/32 via that host.
4. Decoder: reuse the read-vaysunic.sh decode logic against MQTT
   payloads. Accept status-byte 0x14 (MQTT) and 0x13 (LAN read).
5. Forward decoded values to wherever they need to go (Prometheus,
   Home Assistant, MQTT topic of our own, plain log file).
6. Long-running check: on-demand read-vaysunic.sh should also keep
   working once the broker is in place, because the device's bind
   cache stays fresh.
```

Capture commands:

```bash
# FRITZ!Box (preferred): http://fritz.box/html/capture.html, pick the
# per-client WLAN entry for the inverter, save the .eth file (it is pcap).

# Local LAN observation only (does not see the WAN side):
sudo nix-shell -p tcpdump --run 'tcpdump -i any -n -s0 -w /tmp/vaysunic-lan.pcap host <INVERTER_IP> or udp port 2415 or udp port 12414 or tcp port 12416'
```

## Useful References

Official Gizwits docs used during the investigation:

```text
https://docs.gizwits.com/en-us/DeviceDev/GAgent.html
https://docs.gizwits.com/en-us/AppDev/AndroidSDKA2.html
```

AVM FRITZ!Box internet blocking docs:

```text
https://fritz.com/en/apps/knowledge-base/FRITZ-Box-7490/8_8_Restricting-internet-use-with-the-FRITZ-Box-parental-controls
```

Official VaySunic VM-P2 series German installation manual:

```text
https://res.vaysunic.com/docs/DE/Installationsanleitung/VM-P2%20Serie_VaySunic_Schnellinstallationsanleitung_DE_V3.0.pdf
```

FRITZ!Box built-in packet capture (use the per-client WLAN entry for
the inverter; output is a `.eth` file in pcap format):

```text
http://fritz.box/html/capture.html
```
