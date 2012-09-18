#!/usr/bin/perl

use strict;
use warnings;
use IO::File;
use IO::Socket::UNIX;
use Mail::IMAPTalk;
use Data::Dumper;
use threads;

my $admin = Mail::IMAPTalk->new(
  Server   => '127.0.0.11',
  Port     => "143",
  Username => 'admin',
  Password => 'test',
);

my $thr = threads->create(sub { _messages() });

$admin->rename("user.foo", "user.foo", "mbackend2");

my $res = $thr->join();

my $client = Mail::IMAPTalk->new(
  Server   => '127.0.0.11',
  Port     => "143",
  Username => 'foo',
  Password => 'test',
);

$client->select("INBOX");
my $data = $client->fetch("1:*", "(envelope)");

my %found;
foreach my $item (values %$data) {
   next unless $item->{envelope}{Subject};
   next unless $item->{envelope}{Subject} =~ m/Test (\d+)/;
   my $n = $1;
   $found{$n} = 1;
}

foreach my $key (sort { $a <=> $b } keys %$res) {
   if ($found{$key}) {
      print "ERROR $key: found but not sent\n" if $res->{$key}[0];
   }
   else {
      if ($res->{$key}[0]) {
        print "OK FAILED $key: $res->{$key}[1]\n";
      }
      else {
        print "ERROR $key: sent but not found\n";
      }
   }
}

sub _messages {
  my %res;
  foreach my $n (1..1000) {
    my ($code, $res) = do_msg($n);
    $res{$n} = [$code, $res];
  }
  return \%res;
}

sub do_msg {
  my $n = shift;
  my $msg = <<EOF;
From: test <test\@example.com>
To: test <test\@example.com>
Message-Id: <test-message-$n\@example.com>
Subject: Test $n

Some stuff in the body...
EOF
  $msg =~ s/\012/\r\n/gs;
  return dolmtp('foo', $msg);
}

sub dolmtp {
  my $tgt = shift;
  my $msg = shift;
  my ($code, $line);
  my $sock = IO::Socket::INET->new("127.0.0.11:2003");
  die "FAILED to create socket $!" unless $sock;

  $line = <$sock>;

  print $sock "LHLO local\r\n";
  ($code, $line) = slurpto($sock);
  return ($code, $line) unless $code == 250;

  print $sock "MAIL FROM:<brong\@brong.net>\r\n";
  ($code, $line) = slurpto($sock);
  return ($code, $line) unless $code == 250;

  print $sock "RCPT TO:<foo>\r\n";
  ($code, $line) = slurpto($sock);
  return ($code, $line) unless $code == 250;

  print $sock "DATA\r\n";
  ($code, $line) = slurpto($sock);
  return ($code, $line) unless $code == 354;

  print $sock "$msg\r\n.\r\n";
  ($code, $line) = slurpto($sock);
  return ($code, $line) unless $code == 250;

  print $sock "QUIT\r\n";
  return (0, "WOOHOO");
}

sub slurpto {
  my $sock = shift;
  while (my $line = <$sock>) {
    return ($1, $line) if $line =~ m/^(\d\d\d) /;
  }
}
