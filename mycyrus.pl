#!/usr/bin/perl

use strict;
use warnings;
use IO::File;
use IO::Socket::UNIX;
use Mail::IMAPTalk;

my $basedir = shift || "/tmp/ct";

my $cyrusbase = shift || "/usr/cyrus";

#system("rm -rf $basedir");
mkdir($basedir);
mkdir("$basedir/etc");
mkdir("$basedir/run");
mkdir("$basedir/meta");
mkdir("$basedir/metalock");
mkdir("$basedir/data");
mkdir("$basedir/conf");
mkdir("$basedir/conf/db");
mkdir("$basedir/conf/dbbak");
mkdir("$basedir/conf/sieve");
mkdir("$basedir/conf/cores");
mkdir("$basedir/conf/log");
mkdir("$basedir/conf/log/foo");

my $ifh = IO::File->new(">$basedir/etc/imapd.conf");
print $ifh <<__EOF;
admins: admin
allowplaintext: yes
annotation_db: skiplist
duplicate_db: skiplist
mboxlist_db: skiplist
seenstate_db: skiplist
expunge_mode: delayed
delete_mode: delayed
internaldate_heuristic: receivedheader
rfc3028_strict: 0
sievenotifier: mailto
sieve_extensions: fileinto reject vacation imapflags notify envelope body relational regex subaddress copy
sievedir: $basedir/conf/sieve
configdirectory: $basedir/conf
syslog_prefix: test_$$
guid_mode: sha1
metapartition_files: header index cache expunge
defaultpartition: default
partition-default: $basedir/data
metapartition-default: $basedir/meta
metadir-lock-default: $basedir/metalock
servername: test_$$
statuscache: on
statuscache_db: skiplist
sasl_pwcheck_method: saslauthd
sasl_mech_list: PLAIN LOGIN DIGEST-MD5
sasl_saslauthd_path: $basedir/run/mux
__EOF
$ifh->close();

my $cfh = IO::File->new(">$basedir/etc/cyrus.conf");
print $cfh <<__EOF;
START {
  recover       cmd="ctl_cyrusdb -C $basedir/etc/imapd.conf -r"
  idled         cmd="idled -C $basedir/etc/imapd.conf"
}

SERVICES {
  imap          cmd="imapd -C $basedir/etc/imapd.conf -t 600" listen="127.0.0.1:9143" provide_uuid=1 maxfds=2048
  pop3          cmd="pop3d -C $basedir/etc/imapd.conf" listen="127.0.0.1:9110" provide_uuid=1
  lmtp          cmd="lmtpd -C $basedir/etc/imapd.conf" listen="127.0.0.1:9003" provide_uuid=1 maxfds=2048
}

EVENTS {
  checkpoint    cmd="ctl_cyrusdb -C $basedir/etc/imapd.conf" period=180
}
__EOF
$cfh->close();

system("$cyrusbase/bin/mkimap $basedir/etc/imapd.conf");

my $saslpid = fork();
unless ($saslpid) {
  # child;
  saslauthd("$basedir/run");
  exit 0;
}

system("chown -R cyrus $basedir");

my $masterpid = fork();
unless ($masterpid) {
  chdir("$basedir/conf/cores");
  if (-f "/proc/sys/kernel/core_uses_pid") {
    system("echo 1 >/proc/sys/kernel/core_uses_pid");
  }
  system("ulimit -c 102400 && $cyrusbase/bin/master -C $basedir/etc/imapd.conf -M $basedir/etc/cyrus.conf");
  exit 0;
}

sleep 2;

my $admin = Mail::IMAPTalk->new(
  Server   => "127.0.0.1",
  Port     => "9143",
  Username => 'admin',
  Password => 'foo',
);

$admin->create('user.foo');

# XXX - fun here

sleep 10000;

system("kill $masterpid");
system("kill $saslpid");
exit 0;

sub saslauthd {
  my $dir = shift;
  unlink("$dir/mux");
  my $sock = IO::Socket::UNIX->new(
    Local => "$dir/mux",
    Type => SOCK_STREAM,
    Listen => SOMAXCONN,
  );
  die "FAILED to create socket $!" unless $sock;

  while (my $client = $sock->accept()) {
    my $LoginName = get_counted_string($client);
    my $Password = get_counted_string($client);
    my $Service = lc get_counted_string($client);
    my $Realm = get_counted_string($client);

    # XXX - custom logic?

    # OK :)
    $client->print(pack("nA3", 2, "OK\000"));
    $client->close();
  }
}

sub get_counted_string {
  my $sock = shift;
  my $data;
  $sock->read($data, 2);
  my $size = unpack('n', $data);
  $sock->read($data, $size);
  return unpack("A$size", $data);
}
