#!/usr/bin/env nix-shell
#! nix-shell -i bash -p bash perl
set -euo pipefail

DEFAULT_HOST="192.168.178.79"
DEFAULT_PORT="12416"
HOST="${1:-$DEFAULT_HOST}"
PORT="${PORT:-$DEFAULT_PORT}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 [inverter-ip]

Probe a VaySunic/Gizwits inverter on the local LAN.

Defaults:
  inverter-ip: $DEFAULT_HOST
  TCP port:    $DEFAULT_PORT

Override the port with PORT=... if needed.
EOF
  exit 0
fi

export HOST PORT

perl <<'PERL'
use strict;
use warnings;
use IO::Socket::INET;

my $host = $ENV{HOST} || "192.168.178.79";
my $port = int($ENV{PORT} || 12416);

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

sub exchange {
  my ($name, $payload) = @_;

  print "\n>>> $name\n";
  print "TX: ", hexify($payload), "\n";

  my $written = syswrite($sock, $payload);
  die "write failed for $name: $!\n" unless defined $written;
  die "short write for $name: wrote $written of " . length($payload) . " bytes\n"
    unless $written == length($payload);

  my $rin = "";
  vec($rin, fileno($sock), 1) = 1;
  my $ready = select(my $rout = $rin, undef, undef, 5);
  die "timeout waiting for $name response\n" unless $ready;

  my $buf = "";
  my $len = sysread($sock, $buf, 4096);
  die "read failed for $name: $!\n" unless defined $len;
  die "connection closed while waiting for $name response\n" unless $len;

  print "RX: ", hexify($buf), "\n";
  return $buf;
}

print "Connecting to Gizwits LAN port $host:$port\n";

my $passcode_response = exchange("get passcode", h("0000000303000006"));

die "unexpected passcode response: too short\n" unless length($passcode_response) >= 20;
die "unexpected passcode response command\n" unless substr($passcode_response, 6, 2) eq h("0007");

my $passcode = substr($passcode_response, 10, 10);
print "PASSCODE ASCII: $passcode\n";

exchange("verify passcode", h("000000030f000008000a") . $passcode);
exchange("query data 0x90", h("000000030400009002"));
exchange("query data 0x93", h("00000003080000930000000402"));
exchange("heartbeat", h("0000000303000015"));
PERL
