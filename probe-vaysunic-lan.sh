#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl
set -euo pipefail

DEFAULT_HOST="192.168.178.79"
DEFAULT_PORT="12416"
DEFAULT_READ_IDLE_SECONDS="1"
HOST="${1:-$DEFAULT_HOST}"
PORT="${PORT:-$DEFAULT_PORT}"
READ_IDLE_SECONDS="${READ_IDLE_SECONDS:-$DEFAULT_READ_IDLE_SECONDS}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [inverter-ip]

Probe a VaySunic/Gizwits inverter on the local LAN.

Defaults:
  inverter-ip: $DEFAULT_HOST
  TCP port:    $DEFAULT_PORT

Override the port with PORT=... if needed.
Override the extra-frame read timeout with READ_IDLE_SECONDS=... if needed.
EOF
  exit 0
fi

export HOST PORT READ_IDLE_SECONDS

perl <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;

my $host = $ENV{HOST} || "192.168.178.79";
my $port = int($ENV{PORT} || 12416);
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

my $sock = IO::Socket::INET->new(
  PeerAddr => $host,
  PeerPort => $port,
  Proto    => "tcp",
  Timeout  => 5,
) or die "connect to $host:$port failed: $!\n";

$sock->autoflush(1);

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

sub frame_command {
  my ($frame) = @_;
  my $offset = 4;
  while (ord(substr($frame, $offset++, 1)) & 0x80) {
  }
  return substr($frame, $offset + 1, 2);
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

print "Connecting to Gizwits LAN port $host:$port\n";

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
