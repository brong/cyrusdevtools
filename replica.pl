#!/usr/bin/perl

use strict;
use warnings;
use IO::File;
use IO::Socket::UNIX;
use Mail::IMAPTalk;

my $del = shift;
my $rootdir = shift || "/tmpfs/ct";
my $cyrusbase = shift || "/usr/cyrus";

my @pids;
my @tokill;

open(FH, "ps ax |");
while (<FH>) {
    my ($pid) = split;
    if (m/replica\.pl/ || m/cyrus/ || m{/tmp/ct}) {
	push(@tokill, $pid) unless $pid == $$;
    }
}
if (@tokill) {
    print "killing @tokill\n";
    kill(9, @tokill);
}
close(FH);
system("rm -f /tmp/*valgrind*");

system("rm /etc/sasldb2");

my %ip = (
    slot1 => '127.0.0.51',
    slot2 => '127.0.0.52',
    slot3 => '127.0.0.53',
);

foreach my $type (sort keys %ip) {
    my @others = grep { $_ ne $type } sort keys %ip;
    system qq[echo "replpass" | saslpasswd2 -c -p -utest_${type}_$$ repluser];
    system("chown cyrus /etc/sasldb2");
    my $basedir = "$rootdir-$type";
    system("find $basedir -type f -print0 | xargs -0 rm -f") if $del;
    mkdir($basedir);
    mkdir("$basedir/etc");
    mkdir("$basedir/run");
    mkdir("$basedir/meta");
    mkdir("$basedir/meta2");
    mkdir("$basedir/metalock");
    mkdir("$basedir/data");
    mkdir("$basedir/data2");
    mkdir("$basedir/conf");
    mkdir("$basedir/conf/db");
    mkdir("$basedir/conf/dbbak");
    mkdir("$basedir/conf/sieve");
    mkdir("$basedir/conf/cores");
    mkdir("$basedir/conf/log");
    mkdir("$basedir/conf/log/admin");
    mkdir("$basedir/conf/log/foo");
    mkdir("$basedir/conf/log/repluser");

    system("ip addr add $ip{$type} dev lo");

    my $ifh = IO::File->new(">$basedir/etc/imapd.conf");
    print $ifh <<__EOF;
admins: admin repluser
allowplaintext: yes
allowusermoves: yes
annotation_db: skiplist
auditlog: yes
conversations: yes
debug: 1
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
syslog_prefix: test_${type}_$$
guid_mode: sha1
metapartition_files: header index cache expunge
defaultpartition: default
partition-default: $basedir/data
metapartition-default: $basedir/meta
partition-p2: $basedir/data2
metapartition-p2: $basedir/meta2
mboxname_lockpath: $basedir/metalock
servername: test_${type}_$$
statuscache: on
statuscache_db: skiplist
sasl_pwcheck_method: saslauthd
sasl_mech_list: PLAIN LOGIN
sasl_saslauthd_path: $basedir/run/mux
xlist-drafts: Drafts
xlist-sent: Sent Items
xlist-trash: Trash
xlist-spam: Junk Mail
virtdomains: userid
sync_log: 1
sync_log_channels: @others
sync_authname: repluser
sync_password: replpass
sync_realm: internal
httpmodules: caldav carddav
httpallowcompress: no
caldav_realm: FastMail
__EOF
    foreach my $other (@others) {
	print $ifh $other . "_sync_host: $ip{$other}\n";
    }
    $ifh->close();

    my $cfh = IO::File->new(">$basedir/etc/cyrus.conf");
    print $cfh <<__EOF;
START {
  recover       cmd="$cyrusbase/bin/ctl_cyrusdb -C $basedir/etc/imapd.conf -r"
  idled         cmd="$cyrusbase/bin/idled -C $basedir/etc/imapd.conf"
__EOF
    foreach my $other (@others) {
	print $cfh <<__EOF;
  sync$other    cmd="$cyrusbase/bin/sync_client -C $basedir/etc/imapd.conf -n $other -r -v"
__EOF
    }
    print $cfh <<__EOF;
}

SERVICES {
  imap          cmd="$cyrusbase/bin/imapd -C $basedir/etc/imapd.conf -t 600" listen="$ip{$type}:143"
  #imap          cmd="$cyrusbase/bin/debug_imapd -C $basedir/etc/imapd.conf -t 600" listen="$ip{$type}:144"
  pop3          cmd="$cyrusbase/bin/pop3d -C $basedir/etc/imapd.conf" listen="$ip{$type}:110"
  lmtp          cmd="$cyrusbase/bin/lmtpd -C $basedir/etc/imapd.conf -a" listen="$ip{$type}:2003"
  syncserver    cmd="$cyrusbase/bin/sync_server -C $basedir/etc/imapd.conf -p 1" listen="$ip{$type}:2005"
  sieve         cmd="$cyrusbase/bin/timsieved -C $basedir/etc/imapd.conf" listen="$ip{$type}:2000"
  httpd         cmd="$cyrusbase/bin/httpd -C $basedir/etc/imapd.conf" listen="$ip{$type}:80"
}

EVENTS {
  checkpoint    cmd="$cyrusbase/bin/ctl_cyrusdb -C $basedir/etc/imapd.conf" period=180
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
      system("ulimit -c 102400 && $cyrusbase/bin/master -C $basedir/etc/imapd.conf -M $basedir/etc/cyrus.conf -p $basedir/run/cyrus-$type.pid");
      exit 0;
    }
    push @pids, ($masterpid, $saslpid);

    sleep 2;
}
sleep 10;


my $admin = Mail::IMAPTalk->new(
  Server   => $ip{slot2},
  Port     => "143",
  Username => 'admin',
  Password => 'pass',
);

$admin->create('user.foo');
$admin->create('user.foo.subdir');
$admin->create('user.foo.Sent Items');
$admin->create('user.foo.Drafts');
$admin->create('user.foo.Trash');
$admin->create('user.bar');
$admin->setacl('user.bar', 'foo', "lrswipcd");
$admin->setacl('user.foo', 'admin', "lrswipcd");

sleep 2;
$admin->setacl('user.foo', 'hello', "lrswipcd");

my $msg = <<__EOF;
From: test <test\@example.com>
To: test <test\@example.com>

Some stuff in the body...
__EOF
$msg =~ s/\012/\r\n/gs;
$msg .= ".\r\n";
$admin->append('user.foo', "(\\Seen \\Flagged)", "08-Mar-2010 16:18:11 +1000", $msg);
print "created\n";
# let's see about dupelim then...
dolmtp('foo', $msg);
my $filename = "/tmp/sieve.$$";
open(FH, ">$filename");
print FH <<__EOF;
require ["envelope", "imapflags", "fileinto", "reject", "notify", "vacation", "regex", "relational", "comparator-i;ascii-numeric", "body", "copy"];

if not header :contains ["X-Spam-known-sender"] "yes" {
if allof(
  header :contains ["X-Backscatter"] "yes",
  not header :matches ["X-LinkName"] "*" 
) {
  fileinto "INBOX.Junk Mail";
  stop;
}
}
__EOF
close(FH);
#dosieve($filename);

# XXX - fun here

sleep 10000;

system("kill @pids");
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
  system("chmod 777 $dir/mux");

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

sub dolmtp {
  my $tgt = shift;
  my $msg = shift;
  my $sock = IO::Socket::INET->new("$ip{slot2}:2003");
  die "FAILED to create socket $!" unless $sock;

  my $line;
  $line = <$sock>;
  print "$line\n";
  print $sock "LHLO local\r\n";

  slurpto($sock);
  print $sock "MAIL FROM:<brong\@brong.net>\r\n";

  slurpto($sock);
  print $sock "RCPT TO:<foo>\r\n";

  slurpto($sock);
  print $sock "DATA\r\n";

  slurpto($sock);
  print $sock "$msg\r\n.\r\n";

  slurpto($sock);
  print $sock "QUIT\r\n";
}

sub prompt {
  my ($type, $prompt) = @_;

  if ($type eq "username") {
    return 'foo';
  }
  elsif ($type eq "authname") {
    return 'foo';
  }
  elsif ($type eq "password") {
    return 'foo';
  }
  elsif ($type eq "realm") {
    return '';
  }
}

sub dosieve {
  my $LocalFile = shift;
  my $obj = sieve_get_handle("$ip{slot2}:2000", "prompt", "prompt", "prompt", "prompt");
  my $ret = sieve_put_file_withdest($obj, $LocalFile, 'testscript');
  if ( $ret != 0 ) {
    my $errstr = sieve_get_error($obj);
    $errstr = "unknown error" if ( !defined($errstr) );
    warn "upload failed: $errstr\n";
    print "upload failed: $errstr\n";
  }
  $ret = sieve_activate($obj, 'testscript');
  if ( $ret != 0 ) {
    my $errstr = sieve_get_error($obj);
    $errstr = "unknown error" if ( !defined($errstr) );
    warn "activate failed: $errstr\n";
    print "activate failed: $errstr\n";
  }
  sieve_logout($obj);
}

sub slurpto {
  my $sock = shift;
  while (my $line = <$sock>) {
    print $line;
    last if $line =~ m/^\d\d\d /;
  }
}
