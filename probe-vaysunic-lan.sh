#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl
# shellcheck shell=bash
set -euo pipefail

DEFAULT_HOST="192.168.178.79"
DEFAULT_PORT="12416"
DEFAULT_DISCOVERY_PORT="12414"
DEFAULT_READ_IDLE_SECONDS="1"
DEFAULT_STANDARD_STATUS_BYTES="7"
DEFAULT_STATUS_ATTR_IDS="54,0,1,2,3,4,5,8,9,10,11,12"
DEFAULT_MAP_STATUS_IDS=""
SELF_TEST="0"
MAP_STATUS="0"
HOST="${1:-$DEFAULT_HOST}"
PORT="${PORT:-$DEFAULT_PORT}"
DISCOVERY_PORT="${DISCOVERY_PORT:-$DEFAULT_DISCOVERY_PORT}"
READ_IDLE_SECONDS="${READ_IDLE_SECONDS:-$DEFAULT_READ_IDLE_SECONDS}"
STANDARD_STATUS_BYTES="${STANDARD_STATUS_BYTES:-$DEFAULT_STANDARD_STATUS_BYTES}"
STATUS_ATTR_IDS="${STATUS_ATTR_IDS:-$DEFAULT_STATUS_ATTR_IDS}"
MAP_STATUS_IDS="${MAP_STATUS_IDS:-$DEFAULT_MAP_STATUS_IDS}"

if [[ "${1:-}" == "--self-test" ]]; then
  SELF_TEST="1"
  HOST="$DEFAULT_HOST"
fi

if [[ "${1:-}" == "--map-status" ]]; then
  MAP_STATUS="1"
  HOST="${2:-$DEFAULT_HOST}"
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [inverter-ip]
       $0 --self-test
       $0 --map-status [inverter-ip]

Probe a VaySunic/Gizwits inverter on the local LAN.

Defaults:
  inverter-ip:           $DEFAULT_HOST
  TCP port:              $DEFAULT_PORT
  UDP port:              $DEFAULT_DISCOVERY_PORT
  standard status bytes: $DEFAULT_STANDARD_STATUS_BYTES
  focused status ids:    $DEFAULT_STATUS_ATTR_IDS

Override the port with PORT=... if needed.
Override the discovery port with DISCOVERY_PORT=... if needed.
Override the extra-frame read timeout with READ_IDLE_SECONDS=... if needed.
Override the standard status bitmask length with STANDARD_STATUS_BYTES=... if needed.
Override the focused status query with STATUS_ATTR_IDS=comma,separated,ids if needed.
Limit --map-status with MAP_STATUS_IDS=comma,separated,ids if needed.

--map-status reads each known datapoint by itself and prints the non-zero fixed
payload offsets returned by the inverter. It only sends status-read requests.
EOF
  exit 0
fi

export HOST PORT DISCOVERY_PORT READ_IDLE_SECONDS STANDARD_STATUS_BYTES STATUS_ATTR_IDS MAP_STATUS_IDS SELF_TEST MAP_STATUS

perl <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(AF_INET SOCK_DGRAM SOL_SOCKET SO_BROADCAST sockaddr_in inet_aton inet_ntoa);

my $host = $ENV{HOST} || "192.168.178.79";
my $port = int($ENV{PORT} || 12416);
my $discovery_port = int($ENV{DISCOVERY_PORT} || 12414);
my $read_idle_seconds = 0 + ($ENV{READ_IDLE_SECONDS} || 1);
my $standard_status_bytes = int($ENV{STANDARD_STATUS_BYTES} || 7);
my $status_attr_ids = $ENV{STATUS_ATTR_IDS} || "54,0,1,2,3,4,5,8,9,10,11,12";
my $map_status_ids = $ENV{MAP_STATUS_IDS} || "";
my $self_test = int($ENV{SELF_TEST} || 0);
my $map_status = int($ENV{MAP_STATUS} || 0);

my %datapoints = (
  0  => { name => "VMx001", type => "uint32", ratio => 0.1,  addition => 0 },
  1  => { name => "VMx002", type => "uint32", ratio => 0.01, addition => 0 },
  2  => { name => "VMx003", type => "uint32", ratio => 1,    addition => 0 },
  3  => { name => "VMx004", type => "uint32", ratio => 0.1,  addition => 0 },
  4  => { name => "VMx005", type => "uint32", ratio => 1,    addition => 0 },
  5  => { name => "VMx006", type => "uint32", ratio => 1,    addition => 0 },
  6  => { name => "VMx007", type => "uint32", ratio => 1,    addition => 0 },
  7  => { name => "VMx008", type => "uint32", ratio => 1,    addition => 0 },
  8  => { name => "VMx009", type => "uint32", ratio => 1,    addition => 0 },
  9  => { name => "VMP1x001", type => "uint32", ratio => 0.1,  addition => 0 },
  10 => { name => "VMP1x002", type => "uint32", ratio => 0.1,  addition => 0 },
  11 => { name => "VMP1x003", type => "uint32", ratio => 0.1,  addition => 0 },
  12 => { name => "VMP1x004", type => "uint32", ratio => 0.01, addition => 0 },
  13 => { name => "VMP2x001", type => "uint32", ratio => 0.1,  addition => 0 },
  14 => { name => "VMP2x002", type => "uint32", ratio => 0.1,  addition => 0 },
  15 => { name => "VMP2x003", type => "uint32", ratio => 0.1,  addition => 0 },
  16 => { name => "VMP2x004", type => "uint32", ratio => 0.01, addition => 0 },
  17 => { name => "VMP3x001", type => "uint32", ratio => 0.1,  addition => 0 },
  18 => { name => "VMP3x002", type => "uint32", ratio => 0.1,  addition => 0 },
  19 => { name => "VMP3x003", type => "uint32", ratio => 0.1,  addition => 0 },
  20 => { name => "VMP3x004", type => "uint32", ratio => 0.01, addition => 0 },
  21 => { name => "VMP4x001", type => "uint32", ratio => 0.1,  addition => 0 },
  22 => { name => "VMP4x002", type => "uint32", ratio => 0.1,  addition => 0 },
  23 => { name => "VMP4x003", type => "uint32", ratio => 0.1,  addition => 0 },
  24 => { name => "VMP4x004", type => "uint32", ratio => 0.01, addition => 0 },
  25 => { name => "VMP5x001", type => "uint32", ratio => 0.1,  addition => 0 },
  26 => { name => "VMP5x002", type => "uint32", ratio => 0.1,  addition => 0 },
  27 => { name => "VMP5x003", type => "uint32", ratio => 0.1,  addition => 0 },
  28 => { name => "VMP5x004", type => "uint32", ratio => 0.01, addition => 0 },
  29 => { name => "VMP6x001", type => "uint32", ratio => 0.1,  addition => 0 },
  30 => { name => "VMP6x002", type => "uint32", ratio => 0.1,  addition => 0 },
  31 => { name => "VMP6x003", type => "uint32", ratio => 0.1,  addition => 0 },
  32 => { name => "VMP6x004", type => "uint32", ratio => 0.01, addition => 0 },
  33 => { name => "VMP7x001", type => "uint32", ratio => 0.1,  addition => 0 },
  34 => { name => "VMP7x002", type => "uint32", ratio => 0.1,  addition => 0 },
  35 => { name => "VMP7x003", type => "uint32", ratio => 0.1,  addition => 0 },
  36 => { name => "VMP7x004", type => "uint32", ratio => 0.01, addition => 0 },
  37 => { name => "VMP8x001", type => "uint32", ratio => 0.1,  addition => 0 },
  38 => { name => "VMP8x002", type => "uint32", ratio => 0.1,  addition => 0 },
  39 => { name => "VMP8x003", type => "uint32", ratio => 0.1,  addition => 0 },
  40 => { name => "VMP8x004", type => "uint32", ratio => 0.01, addition => 0 },
  41 => { name => "VMCx001", type => "bool", ratio => 1, addition => 0 },
  42 => { name => "VMCx002", type => "bool", ratio => 1, addition => 0 },
  44 => { name => "VMCx004", type => "uint16", ratio => 1,    addition => 0 },
  45 => { name => "VMCx005", type => "uint16", ratio => 1,    addition => 0 },
  46 => { name => "VMCx006", type => "uint16", ratio => 1,    addition => 0 },
  47 => { name => "VMCx007", type => "uint16", ratio => 1,    addition => -5000 },
  48 => { name => "VMCx008", type => "uint16", ratio => 0.01, addition => -90 },
  49 => { name => "VMCx009", type => "uint16", ratio => 1,    addition => 0 },
  50 => { name => "VMCx010", type => "uint16", ratio => 1,    addition => 0 },
  51 => { name => "VMCx011", type => "uint16", ratio => 1,    addition => 0 },
  52 => { name => "VMCx012", type => "uint16", ratio => 1,    addition => 0 },
  53 => { name => "VMCx013", type => "uint16", ratio => 1,    addition => 0 },
  54 => { name => "VMx000", type => "uint32", ratio => 0.01, addition => 0 },
);

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

sub encode_length {
  my ($length) = @_;
  my $encoded = "";

  while (1) {
    my $byte = $length & 0x7f;
    $length >>= 7;
    $byte |= 0x80 if $length > 0;
    $encoded .= chr($byte);
    last if $length == 0;
  }

  return $encoded;
}

sub frame_for {
  my ($cmd_hex, $body) = @_;
  $body //= "";
  return h("00000003") . encode_length(3 + length($body)) . h("00$cmd_hex") . $body;
}

sub sn_p0_body {
  my ($sn, $p0) = @_;
  return pack("N", $sn) . $p0;
}

sub standard_status_p0 {
  return h("12") . ("\xff" x $standard_status_bytes);
}

sub status_attr_id_list {
  return parse_id_list($status_attr_ids, "STATUS_ATTR_IDS");
}

sub parse_id_list {
  my ($raw_list, $name) = @_;
  my @ids;
  for my $raw (split /,/, $raw_list) {
    next unless length $raw;
    die "invalid $name entry: $raw\n" unless $raw =~ /\A\d+\z/;
    push @ids, int($raw);
  }
  return @ids;
}

sub status_p0_for_ids {
  my (@ids) = @_;
  my @mask = (0) x $standard_status_bytes;

  for my $id (@ids) {
    die "status id $id does not fit in $standard_status_bytes mask bytes\n"
      if $id < 0 || int($id / 8) >= $standard_status_bytes;
    my $byte_index = ($standard_status_bytes - 1) - int($id / 8);
    $mask[$byte_index] |= 1 << ($id & 7);
  }

  return h("12") . pack("C*", @mask);
}

sub ids_from_status_mask {
  my ($mask) = @_;
  my @ids;

  for my $byte_index (0 .. length($mask) - 1) {
    my $byte = ord(substr($mask, $byte_index, 1));
    my $base_id = (length($mask) - 1 - $byte_index) * 8;
    for my $bit (0 .. 7) {
      push @ids, $base_id + $bit if $byte & (1 << $bit);
    }
  }

  return @ids;
}

sub status_payload_from_frame {
  my ($frame) = @_;
  my $cmd = frame_command($frame);
  return undef unless $cmd eq h("0091") || $cmd eq h("0094");

  my $payload = frame_body($frame);
  $payload = substr($payload, 4) if $cmd eq h("0094") && length($payload) >= 4;
  return undef unless length($payload) >= 1 + $standard_status_bytes;
  return undef unless substr($payload, 0, 1) eq h("13");

  return $payload;
}

sub nonzero_offsets {
  my ($data) = @_;
  my @offsets;

  for my $offset (0 .. length($data) - 1) {
    push @offsets, $offset if ord(substr($data, $offset, 1)) != 0;
  }

  return @offsets;
}

sub print_nonzero_blocks {
  my ($label, $data) = @_;
  my @offsets = nonzero_offsets($data);

  if (!@offsets) {
    print "$label NONZERO: <none>\n";
    return;
  }

  print "$label NONZERO OFFSETS: ", join(", ", map { sprintf("+%d=0x%02X", $_, ord(substr($data, $_, 1))) } @offsets), "\n";

  my %blocks;
  for my $offset (@offsets) {
    $blocks{int($offset / 16) * 16} = 1;
  }

  for my $base (sort { $a <=> $b } keys %blocks) {
    my $chunk = substr($data, $base, 16);
    printf "%s BLOCK +%04d: %s\n", $label, $base, hexify($chunk);
  }
}

sub maybe_print_standard_status {
  my ($frame) = @_;
  my $payload = status_payload_from_frame($frame);
  return unless defined $payload;

  my $mask = substr($payload, 1, $standard_status_bytes);
  my @ids = ids_from_status_mask($mask);
  my $data = substr($payload, 1 + $standard_status_bytes);

  print "P0 STATUS MASK: ", hexify($mask), "\n";
  print "P0 STATUS IDS: ", join(",", @ids), "\n";
  print "P0 STATUS DATA LEN: ", length($data), " bytes after status code and mask\n";
  print_nonzero_blocks("P0 STATUS DATA", $data);
  print "P0 STATUS: fixed-layout payload; compact datapoint decoding is intentionally skipped\n";
}

sub map_status_offsets {
  my @ids = length($map_status_ids)
    ? parse_id_list($map_status_ids, "MAP_STATUS_IDS")
    : sort { $a <=> $b } keys %datapoints;

  for my $id (@ids) {
    my $point = $datapoints{$id};
    if (!defined $point) {
      print "STATUS MAP: id $id has no local schema; skipped\n";
      next;
    }

    my @frames = exchange(
      sprintf("map status id %d %s", $id, $point->{name}),
      frame_for("0090", status_p0_for_ids($id)),
      allow_no_response => 1,
      quiet => 1,
    );
    my ($status_frame) = grep { defined status_payload_from_frame($_) } @frames;
    next unless defined $status_frame;

    my $payload = status_payload_from_frame($status_frame);
    my $data = substr($payload, 1 + $standard_status_bytes);
    my @offsets = nonzero_offsets($data);
    my $offset_summary = @offsets
      ? join(",", map { sprintf("+%d=0x%02X", $_, ord(substr($data, $_, 1))) } @offsets)
      : "<all zero>";
    printf "STATUS MAP: id %2d %-8s %-6s nonzero %s\n", $id, $point->{name}, $point->{type}, $offset_summary;
  }
}

sub assert_hex {
  my ($name, $actual, $expected_hex) = @_;
  my $actual_hex = uc unpack("H*", $actual);
  $expected_hex = uc $expected_hex;
  die "$name failed: got $actual_hex expected $expected_hex\n"
    unless $actual_hex eq $expected_hex;
}

sub run_self_test {
  assert_hex("get passcode frame", frame_for("0006"), "0000000303000006");
  assert_hex("custom status frame", frame_for("0090", h("02")), "000000030400009002");
  assert_hex("custom status sn frame", frame_for("0093", sn_p0_body(4, h("02"))), "00000003080000930000000402");
  assert_hex("standard status frame", frame_for("0090", standard_status_p0()), "000000030b00009012ffffffffffffff");
  assert_hex("standard status sn frame", frame_for("0093", sn_p0_body(5, standard_status_p0())), "000000030f0000930000000512ffffffffffffff");
  assert_hex("focused status frame", frame_for("0090", status_p0_for_ids(54, 0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12)), "000000030b0000901240000000001f3f");
  print "self-test passed\n";
}

if ($self_test) {
  run_self_test();
  exit 0;
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
  my ($name, $payload, %options) = @_;

  if (!$options{quiet}) {
    print "\n>>> $name\n";
    print "TX: ", hexify($payload), "\n";
  }

  my $written = syswrite($sock, $payload);
  die "write failed for $name: $!\n" unless defined $written;
  die "short write for $name: wrote $written of " . length($payload) . " bytes\n"
    unless $written == length($payload);

  my $first_frame = read_frame(5, $options{allow_no_response} ? 1 : 0);
  if (!defined $first_frame) {
    print "RX: <none>\n" unless $options{quiet};
    return;
  }

  my @frames = ($first_frame);
  while (defined(my $frame = read_frame($read_idle_seconds, 1))) {
    push @frames, $frame;
  }

  for my $i (0 .. $#frames) {
    next if $options{quiet};
    print "RX[", $i + 1, " cmd ", hexify(frame_command($frames[$i])), "]: ", hexify($frames[$i]), "\n";
    maybe_print_standard_status($frames[$i]);
  }

  return @frames;
}

discover_device();

print "\nConnecting to Gizwits LAN port $host:$port\n";
connect_tcp();

my @passcode_responses = exchange("get passcode", frame_for("0006"));
my ($passcode_response) = grep { frame_command($_) eq h("0007") } @passcode_responses;

die "missing passcode response command 00 07\n" unless defined $passcode_response;
die "unexpected passcode response: too short\n" unless length($passcode_response) >= 20;

my $passcode = substr($passcode_response, 10, 10);
print "PASSCODE ASCII: $passcode\n";

exchange("verify passcode", frame_for("0008", h("000a") . $passcode));
exchange("query custom status 0x90", frame_for("0090", h("02")), allow_no_response => 1);
exchange("query custom status 0x93", frame_for("0093", sn_p0_body(4, h("02"))), allow_no_response => 1);
my @focused_status_ids = status_attr_id_list();
exchange("query focused standard status 0x90", frame_for("0090", status_p0_for_ids(@focused_status_ids)), allow_no_response => 1);
exchange("query standard status 0x90", frame_for("0090", standard_status_p0()), allow_no_response => 1);
exchange("query standard status 0x93", frame_for("0093", sn_p0_body(5, standard_status_p0())), allow_no_response => 1);
map_status_offsets() if $map_status;
exchange("heartbeat", frame_for("0015"));
PERL
