# VaySunic / Gizwits Inverter Notes

Date: 2026-05-03

This document records what we have learned so far about the VaySunic mini solar inverter, its Wi-Fi module, and the VaySunic Cloud app. The goal is local data access without using the VaySunic/Gizwits cloud account flow.

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

This strongly suggests the device can be used locally once it is on the same LAN, but the packet framing/login details still need to be captured or reverse engineered.

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
5. Native daemon handles LAN discovery and local login/passcode exchange.
6. Once a device is discovered, the app subscribes using product key/product secret and then receives datapoint updates.
7. Device reads use `getDeviceStatus`.
8. Device writes use `write` or `sendCmd`.

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

## Remaining Unknowns

The remaining hard part is the local LAN protocol between our computer and the inverter once it is on the FRITZ!Box Wi-Fi.

Known unknowns:

```text
LAN discovery packet format
Whether discovery uses UDP 2415, UDP 12414, TCP 12416, or a combination
How passcode retrieval works
How passcode verification works
How product secret is applied to LAN subscribe/control
Whether status payloads are JSON datapoints, binary P0 packets, or both
Whether the inverter requires cloud-derived DID/binding state before local reads
```

Likely next investigations:

```text
1. Provision inverter to FRITZ!Box Wi-Fi with internet blocked.
2. Scan LAN for the inverter IP and open ports.
3. Capture traffic while the official app or a minimal SDK stub talks to the device.
4. Reverse engineer the LAN subscribe/status messages.
5. Implement a small local reader.
6. Map received datapoints using the product config above.
```

Potential capture command after the inverter is on LAN:

```bash
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

