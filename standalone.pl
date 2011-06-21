#!/usr/bin/perl

use strict;
use warnings;
use IO::File;
use IO::Socket::UNIX;
use Mail::IMAPTalk;

my $del = shift;
my $rootdir = shift || "/tmp/ct";
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
    slot2 => '127.0.0.52',
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
    mkdir("$basedir/metalock");
    mkdir("$basedir/data");
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
altnamespace: yes
lmtplocal_altnamespace: no
allowplaintext: yes
allowusermoves: yes
annotation_db: skiplist
auditlog: yes
conversations: yes
duplicate_db: skiplist
mboxlist_db: skiplist
seenstate_db: skiplist
expunge_mode: delayed
#delete_mode: delayed
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
postuser: postuser
partition-default: $basedir/data
metapartition-default: $basedir/meta
mboxname_lockpath: $basedir/metalock
#quota_db: skiplist
quota_db: quotalegacy
servername: test_${type}_$$
statuscache: on
statuscache_db: skiplist
#suppress_capabilities: QRESYNC SEARCH SORT
sasl_pwcheck_method: saslauthd
sasl_mech_list: PLAIN LOGIN DIGEST-MD5
sasl_saslauthd_path: $basedir/run/mux
xlist-drafts: Drafts
xlist-sent: Sent Items
xlist-trash: Trash
xlist-spam: Junk Mail
virtdomains: userid
unixhierarchysep: yes
lmtplocal_unixhierarchysep: no
lmtp_downcase_rcpt: 1
popuseacl: 1
allowapop: 0
imapidresponse: 0
mailnotifier: log
username_tolower: 1
__EOF
    $ifh->close();

    my $cfh = IO::File->new(">$basedir/etc/cyrus.conf");
    print $cfh <<__EOF;
START {
  recover       cmd="$cyrusbase/bin/ctl_cyrusdb -C $basedir/etc/imapd.conf -r"
__EOF
    print $cfh <<__EOF;
}

SERVICES {
  imap          cmd="$cyrusbase/bin/imapd -C $basedir/etc/imapd.conf -t 600" listen="$ip{$type}:143"
  #imapdebug     cmd="$cyrusbase/bin/debug_imapd -C $basedir/etc/imapd.conf -t 600" listen="$ip{$type}:144"
  pop3          cmd="$cyrusbase/bin/pop3d -C $basedir/etc/imapd.conf" listen="$ip{$type}:110"
  lmtp          cmd="$cyrusbase/bin/lmtpd -C $basedir/etc/imapd.conf -a" listen="$ip{$type}:2003"
  lmtplocal     cmd="$cyrusbase/bin/lmtpd -C $basedir/etc/imapd.conf" listen="$basedir/conf/socket/lmtp"
  fud           cmd="$cyrusbase/bin/fud -C $basedir/etc/imapd.conf" listen="$ip{$type}:4201" proto="udp"
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
}
sleep 3;


my $admin = Mail::IMAPTalk->new(
  Server   => $ip{slot2},
  Port     => "143",
  Username => 'admin',
  Password => 'pass',
);


$admin->create('user/foo');
$admin->setannotation("user/foo", "/vendor/cmu/cyrus-imapd/condstore", [ "value.shared", 'true' ]);
$admin->create('user/foo/subdir');
$admin->create('user/foo/Sent Items');
$admin->create('user/foo/Drafts');
$admin->create('user/foo/Trash');
$admin->create('user/bar');
$admin->setacl('user/bar', 'foo', "lrswipcd");
$admin->setacl('user/foo', 'admin', "lrswipcd");
$admin->setacl('user/foo', 'anyone', "0");
$admin->setacl('user/foo/subdir', 'anyone', "p");
$admin->setquota('user/foo', "(STORAGE 100000)");
$admin->create('random');
$admin->setacl('random', 'foo', "lrswipcd");

sleep 2;
$admin->setacl('user/foo', 'hello', "lrswipcd");

my $msg = <<EOF;
From: test <test\@example.com>
To: test <test\@example.com>

Some stuff in the body...
EOF
$msg =~ s/\012/\r\n/gs;
$msg .= ".\r\n";
$admin->append('user/foo', "(\\Seen \\Flagged)", "08-Mar-2010 16:18:11 +1000", $msg);
if (open(FH, "<8440-1290290440-1")) {
  local $/ = undef;
  my $slurp = <FH>;
  print "APPENDING SLURP FILE\n";
  $admin->append('user/foo', "(\\Seen \\Flagged)", "08-Mar-2010 16:18:11 +1000", $slurp);
  close(FH);
}
print "created\n";
# let's see about dupelim then...
dolmtp('foo', $msg);

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

sub slurpto {
  my $sock = shift;
  while (my $line = <$sock>) {
    print $line;
    last if $line =~ m/^\d\d\d /;
  }
}
