#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl
set -euo pipefail

DEFAULT_HOST="192.168.178.79"
DEFAULT_PORT="12416"
DEFAULT_DISCOVERY_PORT="12414"
DEFAULT_READ_IDLE_SECONDS="1"
HOST="${1:-$DEFAULT_HOST}"
PORT="${PORT:-$DEFAULT_PORT}"
DISCOVERY_PORT="${DISCOVERY_PORT:-$DEFAULT_DISCOVERY_PORT}"
READ_IDLE_SECONDS="${READ_IDLE_SECONDS:-$DEFAULT_READ_IDLE_SECONDS}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [inverter-ip]

Probe a VaySunic/Gizwits inverter on the local LAN.

Defaults:
  inverter-ip: $DEFAULT_HOST
  TCP port:    $DEFAULT_PORT
  UDP port:    $DEFAULT_DISCOVERY_PORT

Override the port with PORT=... if needed.
Override the discovery port with DISCOVERY_PORT=... if needed.
Override the extra-frame read timeout with READ_IDLE_SECONDS=... if needed.
EOF
  exit 0
fi

export HOST PORT DISCOVERY_PORT READ_IDLE_SECONDS

perl <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(AF_INET SOCK_DGRAM SOL_SOCKET SO_BROADCAST sockaddr_in inet_aton inet_ntoa);

my $host = $ENV{HOST} || "192.168.178.79";
my $port = int($ENV{PORT} || 12416);
my $discovery_port = int($ENV{DISCOVERY_PORT} || 12414);
my $read_idle_seconds = 0 + ($ENV{READ_IDLE_SECONDS} || 1);

sub h {
  return pack("H*", shift);
}

sub hexify {
  my ($data) = @_;
  my $hex = uc unpack("H*", $data);
  $hex =~ s/(..)/$1 /g;
  $hex =~ s/\s+\z//;
  return $hex;
}

sub frame_length_offset {
  my ($frame) = @_;
  my $offset = 4;
  my $length = 0;
  my $multiplier = 1;

  while (1) {
    my $value = ord(substr($frame, $offset++, 1));
    $length += ($value & 0x7f) * $multiplier;
    last if ($value & 0x80) == 0;
    $multiplier *= 128;
  }

  return ($length, $offset);
}

sub frame_command {
  my ($frame) = @_;
  my (undef, $offset) = frame_length_offset($frame);
  return substr($frame, $offset + 1, 2);
}

sub frame_body {
  my ($frame) = @_;
  my (undef, $offset) = frame_length_offset($frame);
  return substr($frame, $offset + 3);
}

sub read_len16_field {
  my ($data_ref, $offset_ref) = @_;
  return undef if $$offset_ref + 2 > length($$data_ref);

  my $len = unpack("n", substr($$data_ref, $$offset_ref, 2));
  $$offset_ref += 2;
  return undef if $$offset_ref + $len > length($$data_ref);

  my $value = substr($$data_ref, $$offset_ref, $len);
  $$offset_ref += $len;
  return $value;
}

sub discover_device {
  socket(my $udp, AF_INET, SOCK_DGRAM, 0)
    or die "could not open UDP discovery socket: $!\n";
  setsockopt($udp, SOL_SOCKET, SO_BROADCAST, pack("i", 1))
    or die "could not enable UDP broadcast: $!\n";
  bind($udp, sockaddr_in($discovery_port, inet_aton("0.0.0.0")))
    or die "could not bind UDP discovery port $discovery_port: $!\n";

  my $payload = h("0000000303000003");
  for my $ip ("255.255.255.255", $host) {
    defined(send($udp, $payload, 0, sockaddr_in($discovery_port, inet_aton($ip))))
      or die "failed to send UDP discovery to $ip:$discovery_port: $!\n";
  }

  print "Sending UDP discovery on port $discovery_port\n";

  my $deadline = time() + 5;
  while (time() < $deadline) {
    my $rin = "";
    vec($rin, fileno($udp), 1) = 1;
    last unless select(my $rout = $rin, undef, undef, $deadline - time());

    my $buf = "";
    my $peer = recv($udp, $buf, 4096, 0);
    next unless defined $peer;
    my ($peer_port, $peer_addr) = sockaddr_in($peer);
    my $peer_ip = inet_ntoa($peer_addr);
    next if $peer_ip ne $host;
    next unless length($buf) >= 8 && frame_command($buf) eq h("0004");

    print "DISCOVERY RX from $peer_ip:$peer_port: ", hexify($buf), "\n";

    my $body = frame_body($buf);
    my $offset = 0;
    my $did = read_len16_field(\$body, \$offset);
    my $mac = read_len16_field(\$body, \$offset);
    my $module_version = read_len16_field(\$body, \$offset);
    my $product_key = read_len16_field(\$body, \$offset);

    print "DISCOVERY DID: $did\n" if defined $did;
    print "DISCOVERY MAC: ", hexify($mac), "\n" if defined $mac;
    print "DISCOVERY MODULE: $module_version\n" if defined $module_version;
    print "DISCOVERY PRODUCT_KEY: $product_key\n" if defined $product_key;
    print "DISCOVERY TAIL: ", hexify(substr($body, $offset)), "\n" if $offset < length($body);
    return;
  }

  print "No UDP discovery response from $host:$discovery_port\n";
}

my $sock;

sub connect_tcp {
  $sock = IO::Socket::INET->new(
    PeerAddr => $host,
    PeerPort => $port,
    Proto    => "tcp",
    Timeout  => 5,
  ) or die "connect to $host:$port failed: $!\n";

  $sock->autoflush(1);
}

sub wait_readable {
  my ($timeout) = @_;
  my $rin = "";
  vec($rin, fileno($sock), 1) = 1;
  return select(my $rout = $rin, undef, undef, $timeout);
}

sub read_exact {
  my ($want, $timeout, $allow_initial_timeout) = @_;
  my $buf = "";

  while (length($buf) < $want) {
    my $ready = wait_readable($timeout);
    if (!$ready) {
      return undef if $allow_initial_timeout && length($buf) == 0;
      die "timeout while reading frame\n";
    }

    my $chunk = "";
    my $len = sysread($sock, $chunk, $want - length($buf));
    die "read failed: $!\n" unless defined $len;
    die "connection closed while reading frame\n" unless $len;
    $buf .= $chunk;
  }

  return $buf;
}

sub read_frame {
  my ($timeout, $allow_timeout) = @_;

  my $header = read_exact(4, $timeout, $allow_timeout);
  return undef unless defined $header;
  die "unexpected frame header: " . hexify($header) . "\n" unless $header eq h("00000003");

  my $length = 0;
  my $multiplier = 1;
  my $len_bytes = "";
  while (1) {
    my $byte = read_exact(1, $timeout, 0);
    $len_bytes .= $byte;
    my $value = ord($byte);
    $length += ($value & 0x7f) * $multiplier;
    last if ($value & 0x80) == 0;
    $multiplier *= 128;
  }

  my $body = read_exact($length, $timeout, 0);
  return $header . $len_bytes . $body;
}

sub exchange {
  my ($name, $payload) = @_;

  print "\n>>> $name\n";
  print "TX: ", hexify($payload), "\n";

  my $written = syswrite($sock, $payload);
  die "write failed for $name: $!\n" unless defined $written;
  die "short write for $name: wrote $written of " . length($payload) . " bytes\n"
    unless $written == length($payload);

  my @frames = (read_frame(5, 0));
  while (defined(my $frame = read_frame($read_idle_seconds, 1))) {
    push @frames, $frame;
  }

  for my $i (0 .. $#frames) {
    print "RX[", $i + 1, " cmd ", hexify(frame_command($frames[$i])), "]: ", hexify($frames[$i]), "\n";
  }

  return @frames;
}

discover_device();

print "\nConnecting to Gizwits LAN port $host:$port\n";
connect_tcp();

my @passcode_responses = exchange("get passcode", h("0000000303000006"));
my ($passcode_response) = grep { frame_command($_) eq h("0007") } @passcode_responses;

die "missing passcode response command 00 07\n" unless defined $passcode_response;
die "unexpected passcode response: too short\n" unless length($passcode_response) >= 20;

my $passcode = substr($passcode_response, 10, 10);
print "PASSCODE ASCII: $passcode\n";

exchange("verify passcode", h("000000030f000008000a") . $passcode);
exchange("query data 0x90", h("000000030400009002"));
exchange("query data 0x93", h("00000003080000930000000402"));
exchange("heartbeat", h("0000000303000015"));
PERL
