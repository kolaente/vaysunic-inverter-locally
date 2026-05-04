#!/usr/bin/env python3
"""
vaysunic-mqtt-bridge

Subscribes to the local Mosquitto broker that the VaySunic / Gizwits
inverter publishes to, decodes the binary Gizwits P0 status frame on
``dev2app/<DID>``, and republishes a clean JSON document plus
Home Assistant MQTT-discovery configs.

Frames with status byte ``0x14`` are telemetry. Frames with status byte
``0x06`` are ASCII log dumps from the Wi-Fi module (only seen after the
device reconnects to a broker after an outage); the bridge logs those
and otherwise ignores them.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys

import paho.mqtt.client as mqtt


# Field offsets inside the 206-byte data area that follows the 7-byte
# all-FF mask. Each entry: (offset, key, scale, unit, device_class,
# state_class). offset is from the start of the data area, scale is a
# float multiplier applied to the big-endian uint32 raw value.
FIELDS: list[tuple[int, str, float, str | None, str | None, str | None]] = [
    (21,  "grid_voltage",      0.1,  "V",   "voltage",     "measurement"),
    (25,  "grid_frequency",    0.01, "Hz",  "frequency",   "measurement"),
    (29,  "ac_power",          1.0,  "W",   "power",       "measurement"),
    (33,  "temperature",       0.1,  "°C",  "temperature", "measurement"),
    (37,  "rated_power",       1.0,  "W",   "power",       None),
    (41,  "modules_connected", 1.0,  None,  None,          None),
    (45,  "fault_code_1",      1.0,  None,  None,          None),
    (49,  "fault_code_2",      1.0,  None,  None,          None),
    (53,  "running_status",    1.0,  None,  None,          None),
    (57,  "pv1_voltage",       0.1,  "V",   "voltage",     "measurement"),
    (61,  "pv1_current",       0.1,  "A",   "current",     "measurement"),
    (65,  "pv1_power",         0.1,  "W",   "power",       "measurement"),
    (69,  "pv1_generation",    0.01, "kWh", "energy",      "total_increasing"),
    (73,  "pv2_voltage",       0.1,  "V",   "voltage",     "measurement"),
    (77,  "pv2_current",       0.1,  "A",   "current",     "measurement"),
    (81,  "pv2_power",         0.1,  "W",   "power",       "measurement"),
    (85,  "pv2_generation",    0.01, "kWh", "energy",      "total_increasing"),
    (185, "total_generation",  0.01, "kWh", "energy",      "total_increasing"),
]
SERIAL_OFFSET = 194
SERIAL_LEN = 12


def varint_decode(buf: bytes, offset: int) -> tuple[int, int]:
    """Decode a Gizwits 7-bit varint at ``offset``; return (value, bytes_consumed)."""
    value = 0
    shift = 0
    n = 0
    while True:
        b = buf[offset + n]
        value |= (b & 0x7F) << shift
        n += 1
        if (b & 0x80) == 0:
            return value, n
        shift += 7


def parse_frame(payload: bytes) -> tuple[int, int | None, bytes]:
    """Strip the Gizwits envelope.

    Returns ``(cmd, status_byte, body)`` where ``body`` is everything
    after the status byte for cmd 0x0091, or after the cmd for any
    other cmd. ``status_byte`` is ``None`` if cmd is not 0x0091 or
    the body has no status byte.
    """
    if len(payload) < 9 or payload[:4] != b"\x00\x00\x00\x03":
        raise ValueError(f"bad frame header: {payload[:8].hex()}")
    length, n = varint_decode(payload, 4)
    p = 4 + n
    if p + 3 > len(payload):
        raise ValueError("truncated cmd")
    flag = payload[p]
    cmd = (payload[p + 1] << 8) | payload[p + 2]
    body = payload[p + 3:]
    if cmd == 0x0091 and body:
        return cmd, body[0], body[1:]
    return cmd, None, body


def decode_telemetry(body: bytes) -> dict[str, object]:
    """body = 7-byte mask + 206-byte data area (no leading status byte)."""
    if len(body) < 7 + 206:
        raise ValueError(f"telemetry body too short: {len(body)} bytes")
    data = body[7:]
    out: dict[str, object] = {}
    for offset, name, scale, _u, _d, _s in FIELDS:
        raw = struct.unpack_from(">I", data, offset)[0]
        if scale == 1.0:
            out[name] = int(raw)
        else:
            out[name] = round(raw * scale, 3)
    serial = bytes(data[SERIAL_OFFSET:SERIAL_OFFSET + SERIAL_LEN]).decode(
        "ascii", errors="replace"
    ).strip()
    if serial:
        out["serial"] = serial
    return out


def discovery_payload(
    did: str,
    field: str,
    unit: str | None,
    device_class: str | None,
    state_class: str | None,
    state_topic: str,
    expire_after: int,
) -> dict:
    cfg: dict = {
        "name": field.replace("_", " "),
        "unique_id": f"vaysunic_{did}_{field}",
        "object_id": f"vaysunic_{did}_{field}",
        "state_topic": state_topic,
        "value_template": "{{ value_json." + field + " }}",
        "expire_after": expire_after,
        "device": {
            "identifiers": [f"vaysunic_{did}"],
            "name": "VaySunic Inverter",
            "manufacturer": "VaySunic",
            "model": "VM800WE-P2",
        },
    }
    if unit:
        cfg["unit_of_measurement"] = unit
    if device_class:
        cfg["device_class"] = device_class
    if state_class:
        cfg["state_class"] = state_class
    return cfg


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.strip())
    p.add_argument("--broker",   default=os.environ.get("MQTT_BROKER", "127.0.0.1"))
    p.add_argument("--port",     type=int, default=int(os.environ.get("MQTT_PORT", "1883")))
    p.add_argument("--username", default=os.environ.get("MQTT_USERNAME"))
    p.add_argument("--password", default=os.environ.get("MQTT_PASSWORD"))
    p.add_argument("--password-file",
                   default=os.environ.get("MQTT_PASSWORD_FILE"),
                   help="read password from this file (overrides --password)")
    p.add_argument("--did",      default=os.environ.get("VAYSUNIC_DID"),
                   help="device DID, e.g. add8a1aB064yb50OdKfV1k")
    p.add_argument("--client-id", default=os.environ.get("MQTT_CLIENT_ID",
                                                          "vaysunic-bridge"))
    p.add_argument("--ha-prefix", default=os.environ.get("HA_DISCOVERY_PREFIX",
                                                          "homeassistant"))
    p.add_argument("--state-prefix", default=os.environ.get("STATE_PREFIX",
                                                             "vaysunic"))
    p.add_argument("--expire-after", type=int, default=600,
                   help="HA expire_after seconds for telemetry sensors")
    p.add_argument("--log-file",
                   default=os.environ.get("LOG_FRAMES_FILE"),
                   help="if set, append device 0x06 log frames here")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()

    if not args.did:
        p.error("--did (or VAYSUNIC_DID) is required")
    if args.password_file:
        try:
            with open(args.password_file, encoding="utf-8") as f:
                args.password = f.read().strip()
        except OSError as e:
            p.error(f"could not read --password-file: {e}")

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    log = logging.getLogger("vaysunic-bridge")

    in_topic = f"dev2app/{args.did}"
    state_topic = f"{args.state_prefix}/{args.did}/state"

    client = mqtt.Client(client_id=args.client_id, clean_session=True)
    if args.username:
        client.username_pw_set(args.username, args.password)

    def publish_discovery() -> None:
        for _o, name, _s, unit, dc, sc in FIELDS:
            cfg = discovery_payload(
                args.did, name, unit, dc, sc, state_topic, args.expire_after,
            )
            topic = f"{args.ha_prefix}/sensor/vaysunic_{args.did}_{name}/config"
            client.publish(topic, json.dumps(cfg), qos=0, retain=True)
        log.info("published HA discovery for %d fields", len(FIELDS))

    def on_connect(_c, _u, _f, rc):
        if rc != 0:
            log.error("MQTT connect failed: rc=%s", rc)
            return
        log.info("connected to %s:%s as %s", args.broker, args.port,
                 args.username or "<anonymous>")
        publish_discovery()
        client.subscribe(in_topic, qos=0)
        log.info("subscribed to %s", in_topic)

    def on_message(_c, _u, msg):
        try:
            cmd, status, body = parse_frame(msg.payload)
        except ValueError as e:
            log.warning("unparseable frame on %s: %s (%d bytes)",
                        msg.topic, e, len(msg.payload))
            return
        if cmd != 0x0091:
            log.debug("ignoring cmd=%04x len=%d", cmd, len(body))
            return
        if status == 0x14:
            try:
                values = decode_telemetry(body)
            except ValueError as e:
                log.warning("undecodable telemetry: %s", e)
                return
            client.publish(state_topic, json.dumps(values), qos=0, retain=True)
            log.info(
                "telemetry: %sW out, grid %sV/%sHz, pv1 %sW pv2 %sW, total %skWh",
                values.get("ac_power"),
                values.get("grid_voltage"),
                values.get("grid_frequency"),
                values.get("pv1_power"),
                values.get("pv2_power"),
                values.get("total_generation"),
            )
        elif status == 0x06:
            text = body.decode("utf-8", errors="replace")
            preview = text.replace("\n", " ").replace("\r", "")[:80]
            log.info("device log frame (%d bytes): %s", len(body), preview)
            if args.log_file:
                try:
                    with open(args.log_file, "a", encoding="utf-8") as f:
                        f.write(text)
                except OSError as e:
                    log.warning("could not append to %s: %s", args.log_file, e)
        else:
            log.info("frame status=%s len=%d (ignored)",
                     "0x%02x" % status if status is not None else "None",
                     len(body))

    def on_disconnect(_c, _u, rc):
        if rc != 0:
            log.warning("unexpected disconnect rc=%s; paho will reconnect", rc)

    client.on_connect = on_connect
    client.on_message = on_message
    client.on_disconnect = on_disconnect

    client.connect(args.broker, args.port, keepalive=60)
    try:
        client.loop_forever(retry_first_connection=True)
    except KeyboardInterrupt:
        log.info("interrupted, exiting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
