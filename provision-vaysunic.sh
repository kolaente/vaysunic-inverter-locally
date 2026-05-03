#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl iproute2 iputils gawk gnugrep networkmanager
set -euo pipefail

AP_PREFIX="${AP_PREFIX:-XPG-GAgent-}"
DEVICE_IP="${DEVICE_IP:-10.10.100.254}"
UDP_PORT="${UDP_PORT:-12414}"
SOURCE_PORT="${SOURCE_PORT:-12345}"
SEND_SECONDS="${SEND_SECONDS:-90}"
SEND_INTERVAL="${SEND_INTERVAL:-5}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

current_ssid() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f active,ssid dev wifi | awk -F: '$1 == "yes" {print $2; exit}'
    return
  fi

  if command -v iwgetid >/dev/null 2>&1; then
    iwgetid -r
    return
  fi

  return 1
}

wifi_device_for_inverter_route() {
  ip route get "$DEVICE_IP" 2>/dev/null | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

check_connected_to_inverter_ap() {
  need_cmd ip

  local ssid
  ssid="$(current_ssid || true)"

  if [[ -z "$ssid" ]]; then
    die "could not determine current Wi-Fi SSID; connect to ${AP_PREFIX}... first"
  fi

  if [[ "$ssid" != "$AP_PREFIX"* ]]; then
    die "current Wi-Fi is '$ssid', expected an inverter AP starting with '$AP_PREFIX'"
  fi

  local dev
  dev="$(wifi_device_for_inverter_route || true)"
  if [[ -z "$dev" ]]; then
    die "no route to $DEVICE_IP; are you connected to the inverter AP?"
  fi

  if ! ip -4 addr show dev "$dev" | grep -q '10\.10\.100\.'; then
    die "interface '$dev' does not have a 10.10.100.x address; are you connected to the inverter AP?"
  fi

  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 2 "$DEVICE_IP" >/dev/null 2>&1 || die "cannot ping $DEVICE_IP on '$ssid'"
  fi

  printf 'Connected to inverter AP: %s via %s\n' "$ssid" "$dev"
}

prompt_wifi_credentials() {
  printf 'FRITZ!Box Wi-Fi SSID: '
  IFS= read -r WIFI_SSID
  [[ -n "$WIFI_SSID" ]] || die "SSID must not be empty"

  printf 'FRITZ!Box Wi-Fi password: '
  IFS= read -rs WIFI_PASSWORD
  printf '\n'
  [[ -n "$WIFI_PASSWORD" ]] || die "password must not be empty"

  printf 'Target Wi-Fi: %s\n' "$WIFI_SSID"
}

send_softap_packets() {
  need_cmd perl

  export WIFI_SSID WIFI_PASSWORD DEVICE_IP UDP_PORT SOURCE_PORT SEND_SECONDS SEND_INTERVAL

  perl <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(sockaddr_in inet_aton);
use Time::HiRes qw(sleep);

my $ssid = $ENV{WIFI_SSID} // "";
my $password = $ENV{WIFI_PASSWORD} // "";
my $device_ip = $ENV{DEVICE_IP} // "10.10.100.254";
my $udp_port = int($ENV{UDP_PORT} // 12414);
my $source_port = int($ENV{SOURCE_PORT} // 12345);
my $send_seconds = int($ENV{SEND_SECONDS} // 90);
my $send_interval = int($ENV{SEND_INTERVAL} // 5);

my $ssid_len = length($ssid);
my $password_len = length($password);
die "SSID is too long ($ssid_len bytes); expected <= 255\n" if $ssid_len > 255;
die "password is too long ($password_len bytes); expected <= 255\n" if $password_len > 255;
die "Gizwits SoftAP packet is too long\n" if ($ssid_len + $password_len + 7) > 255;

# Decompiled from com.gizwits.gizwifisdk.api.SoftApConfig#getSendData:
# 00 00 00 03, length, 00 00 01, 00, ssid_len, ssid, 00, password_len, password.
my $packet = pack("C*", 0, 0, 0, 3, ($ssid_len + $password_len + 7) & 0xff, 0, 0, 1, 0, $ssid_len)
  . $ssid
  . pack("C*", 0, $password_len)
  . $password;

my $sock = IO::Socket::INET->new(
  Proto     => "udp",
  LocalPort => $source_port,
  Broadcast => 1,
) or die "could not open UDP socket on source port $source_port: $!\n";

my $deadline = time() + $send_seconds;
my $count = 0;
print "Sending SoftAP provisioning packet to 255.255.255.255:$udp_port";
print " and $device_ip:$udp_port for $send_seconds seconds...\n";

while (time() < $deadline) {
  $sock->send($packet, 0, sockaddr_in($udp_port, inet_aton("255.255.255.255")))
    or die "failed to send broadcast packet: $!\n";
  $sock->send($packet, 0, sockaddr_in($udp_port, inet_aton($device_ip)))
    or die "failed to send unicast packet: $!\n";
  $count++;
  print "sent batch $count\n";
  sleep($send_interval);
}

print "Done. If the credentials were accepted, the inverter AP should disappear and the inverter should join your FRITZ!Box Wi-Fi.\n";
PERL
}

main() {
  check_connected_to_inverter_ap
  prompt_wifi_credentials
  send_softap_packets

  cat <<EOF

Next:
1. Open http://fritz.box
2. Find the new inverter device in the home network list
3. Block its internet access under Internet -> Filters
4. Keep LAN access enabled so we can scan it locally
EOF
}

main "$@"
