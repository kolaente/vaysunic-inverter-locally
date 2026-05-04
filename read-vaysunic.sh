#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl
# shellcheck shell=bash
set -euo pipefail

DEFAULT_HOST="192.168.178.79"
DEFAULT_PORT="12416"
HOST="${1:-$DEFAULT_HOST}"
PORT="${PORT:-$DEFAULT_PORT}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [inverter-ip]

Read live values from a bound VaySunic / Gizwits VM-P2 micro-inverter and
print them in human-readable form.

Defaults:
  inverter-ip: $DEFAULT_HOST
  TCP port:    $DEFAULT_PORT

Override the port with PORT=... if needed.

The inverter must have been bound once via the official VaySunic Cloud app.
After that the bind persists across reboots and the cloud may be blocked.
EOF
  exit 0
fi

export HOST PORT

perl <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;

my $host = $ENV{HOST};
my $port = int($ENV{PORT});

sub h { return pack("H*", shift); }

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

sub frame_length_offset {
  my ($frame) = @_;
  my $offset = 4;
  while (1) {
    my $b = ord(substr($frame, $offset++, 1));
    last if ($b & 0x80) == 0;
  }
  return $offset;
}

sub frame_command {
  my ($frame) = @_;
  my $o = frame_length_offset($frame);
  return substr($frame, $o + 1, 2);
}

sub frame_body {
  my ($frame) = @_;
  my $o = frame_length_offset($frame);
  return substr($frame, $o + 3);
}

my $sock = IO::Socket::INET->new(
  PeerAddr => $host,
  PeerPort => $port,
  Proto    => "tcp",
  Timeout  => 5,
) or die "could not connect to $host:$port: $!\n";
$sock->autoflush(1);

sub wait_readable {
  my ($timeout) = @_;
  my $rin = "";
  vec($rin, fileno($sock), 1) = 1;
  return select(my $rout = $rin, undef, undef, $timeout);
}

sub read_exact {
  my ($want, $timeout, $allow_initial) = @_;
  my $buf = "";
  while (length($buf) < $want) {
    my $ready = wait_readable($timeout);
    if (!$ready) {
      return undef if $allow_initial && length($buf) == 0;
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
  my $hdr = read_exact(4, $timeout, $allow_timeout);
  return undef unless defined $hdr;
  die "unexpected frame header: " . unpack("H*", $hdr) . "\n"
    unless $hdr eq h("00000003");
  my $len = 0; my $mult = 1; my $len_bytes = "";
  while (1) {
    my $byte = read_exact(1, $timeout, 0);
    $len_bytes .= $byte;
    my $v = ord($byte);
    $len += ($v & 0x7f) * $mult;
    last if ($v & 0x80) == 0;
    $mult *= 128;
  }
  my $body = read_exact($len, $timeout, 0);
  return $hdr . $len_bytes . $body;
}

sub exchange {
  my ($payload) = @_;
  my $written = syswrite($sock, $payload);
  die "short write\n" unless defined $written && $written == length($payload);
  my @frames;
  push @frames, read_frame(5, 0);
  while (defined(my $f = read_frame(1, 1))) { push @frames, $f; }
  return @frames;
}

# 1. Login
my @resp = exchange(frame_for("0006"));
my ($passcode_frame) = grep { frame_command($_) eq h("0007") } @resp;
die "no passcode response\n" unless defined $passcode_frame;
my $pbody = frame_body($passcode_frame);
die "passcode response too short\n" unless length($pbody) >= 12;
my $passcode = substr($pbody, 2, 10);

exchange(frame_for("0008", h("000a") . $passcode));

# 2. Standard-status read with all-FF mask
@resp = exchange(frame_for("0090", h("12") . ("\xff" x 7)));
my ($status_frame) = grep { frame_command($_) eq h("0091") } @resp;
die "no 0091 response\n" unless defined $status_frame;

my $payload = frame_body($status_frame);
die "0091 payload too short\n" unless length($payload) >= 1 + 7;
die "0091 payload missing status marker 0x13\n"
  unless ord(substr($payload, 0, 1)) == 0x13;

my $data = substr($payload, 1 + 7);
die "0091 data area unexpectedly short: " . length($data) . " bytes\n"
  if length($data) < 206;

# 3. Decode
sub u32 {
  my ($d, $o) = @_;
  return unpack("N", substr($d, $o, 4));
}

my $grid_v   = u32($data,  21) * 0.1;
my $grid_hz  = u32($data,  25) * 0.01;
my $power_w  = u32($data,  29);
my $temp     = u32($data,  33) * 0.1;
my $rated    = u32($data,  37);
my $modules  = u32($data,  41);
my $fault1   = u32($data,  45);
my $fault2   = u32($data,  49);
my $running  = u32($data,  53);
my $total    = u32($data, 185) * 0.01;

my $serial = "";
for my $i (194 .. 205) {
  my $b = ord(substr($data, $i, 1));
  $serial .= chr($b) if $b >= 0x20 && $b < 0x7f;
}

my @pvs;
for my $idx (0 .. 7) {
  my $base = 57 + $idx * 16;
  push @pvs, {
    n   => $idx + 1,
    v   => u32($data, $base)      * 0.1,
    i   => u32($data, $base +  4) * 0.1,
    p   => u32($data, $base +  8) * 0.1,
    gen => u32($data, $base + 12) * 0.01,
  };
}

my $unbound = ($grid_v == 0 && $power_w == 0 && $rated == 0 && $modules == 0);

printf "VaySunic inverter at %s\n", $host;
printf "Serial:   %s\n", length($serial) ? $serial : "(unknown)";

if ($unbound) {
  print "\n*** Device appears unbound. Sensor payload is empty.\n";
  print "    Bind it once via the official VaySunic Cloud app, then this\n";
  print "    script will return live values.\n\n";
  exit 1;
}

my $status_text = $running == 1 ? "running" : "running status code $running";
my $fault_text  = ($fault1 == 0 && $fault2 == 0)
  ? "no faults"
  : sprintf("FAULT codes: 1=%d, 2=%d", $fault1, $fault2);

printf "Status:   %s, %s\n",  $status_text, $fault_text;
print  "\n";
printf "Grid:     %.1f V  /  %.2f Hz\n", $grid_v, $grid_hz;
printf "Output:   %d W   (rated %d W)\n", $power_w, $rated;
printf "Temp:     %.1f \xc2\xb0C\n", $temp;
printf "Modules:  %d connected\n", $modules;
printf "Total:    %.2f kWh lifetime\n", $total;
print  "\n";

my $pv_sum = 0;
for my $pv (@pvs) {
  my $connected = $pv->{v} > 0 || $pv->{i} > 0 || $pv->{p} > 0 || $pv->{gen} > 0;
  if ($connected) {
    printf "PV%d:      %5.1f V  /  %4.1f A  =  %6.1f W   (gen %.2f kWh)\n",
      $pv->{n}, $pv->{v}, $pv->{i}, $pv->{p}, $pv->{gen};
    $pv_sum += $pv->{p};
  }
}

if ($pv_sum > 0) {
  printf "\nPV sum:   %.1f W   (AC output: %d W, diff: %+.1f W)\n",
    $pv_sum, $power_w, $power_w - $pv_sum;
}
PERL
