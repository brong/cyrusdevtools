#!/usr/bin/perl

use strict;
use warnings;
use IO::File;
use IO::Socket::UNIX;
use Mail::IMAPTalk;

my $del = shift;
my $rootdir = shift || "/tmpfs/ct";

$rootdir =~ s{/$}{};

my @pids;
my @tokill;

open(FH, "ps ax |");
while (<FH>) {
    my ($pid) = split;
    if (m/murder\.pl/ || m/cyrus/ || m{$rootdir/}) {
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
system qq(echo "test" | saslpasswd2 -c -p -utest test);
system qq(echo "test" | saslpasswd2 -c -p -utest admin);
system qq(echo "bar" | saslpasswd2 -c -p -ufoo test);
system qq(echo "bar" | saslpasswd2 -c -p -ufoo admin);

my %ip = (
    mmaster => '127.0.0.10',
    mfrontend1 => '127.0.0.11',
    mfrontend2 => '127.0.0.12',
    mfrontend3 => '127.0.0.13',
    mbackend1 => '127.0.0.21',
    mbackend2 => '127.0.0.22',
    mbackend3 => '127.0.0.23',
);

my %version = (
    mmaster => 'cyrus24',
    mfrontend1 => 'cyrus24',
    mfrontend2 => 'cyrus24',
    mfrontend3 => 'cyrus24',
    #mfrontend2 => 'cyrus22',
    #mfrontend3 => 'cyrus23',
    mbackend1 => 'cyrus24',
    mbackend2 => 'cyrus24',
    mbackend3 => 'cyrus24',
    #mbackend2 => 'cyrus22',
    #mbackend3 => 'cyrus23',
);

my @order = qw(mmaster
	       mbackend1 mbackend2 mbackend3 
	       mfrontend1 mfrontend2 mfrontend3);

mkdir($rootdir);
system("openssl req -batch -new -nodes -out $rootdir/server.csr -keyout $rootdir/server.key");
system("openssl x509 -in $rootdir/server.csr -out $rootdir/server.crt -req -signkey $rootdir/server.key -days 9999");
system("cat $rootdir/server.key $rootdir/server.crt > $rootdir/server.pem");
system("chmod 600 $rootdir/server.pem");
system("chown cyrus $rootdir/server.pem");

foreach my $type (@order) {
    my $cyrusbase = "/usr/$version{$type}";
    system qq(echo "test" | saslpasswd2 -c -p -u$type test);
    system qq(echo "test" | saslpasswd2 -c -p -u$type admin);
    system qq(echo "bar" | saslpasswd2 -c -p -u$type foo);
    system("chown cyrus /etc/sasldb2");
    system("ip addr add $ip{$type} dev lo");
    my $basedir = "$rootdir/$type";
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
    mkdir("$basedir/conf/log/test");

    my $ifh = IO::File->new(">$basedir/etc/imapd.conf");
    print $ifh <<__EOF;
admins: admin test mbackend1 mbackend2 mbackend3 mfrontend1 mfrontend2 mfrontend3
allowallsubscribe: 1
allowplaintext: yes
allowusermoves: yes
annotation_db: skiplist
auditlog: yes
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
mboxname_lockpath: $basedir/metalock
servername: $type
statuscache: on
statuscache_db: skiplist
sasl_pwcheck_method: saslauthd
sasl_mech_list: DIGEST-MD5 CRAM-MD5 PLAIN LOGIN
sasl_saslauthd_path: $basedir/run/mux
sasl_maximum_layer: 0
tls_cipher_list: TLSv1 :SSLv3 :SSLv2 : !DES : !LOW :\@STRENGTH 
tls_ca_file: $rootdir/server.pem
tls_cert_file: $rootdir/server.pem
tls_key_file: $rootdir/server.pem
unixhierarchysep: on
xlist-drafts: Drafts
xlist-sent: Sent Items
xlist-trash: Trash
xlist-spam: Junk Mail
virtdomains: userid
__EOF
    if ($type eq 'mmaster') {
	print $ifh <<__EOF;
proxyservers:   test
__EOF
    }
    if ($type =~ m/^mbackend/) {
	print $ifh <<__EOF;
metapartition_files: header index cache expunge
defaultpartition: default
partition-default: $basedir/data
metapartition-default: $basedir/meta
mupdate_config: standard
mupdate_server: $ip{mmaster}
mupdate_username: admin
mupdate_authname: test
mupdate_realm: test
mupdate_password: test
mbackend1_password: test
mbackend2_password: test
mbackend3_password: test
proxy_authname: test
proxy_realm:    test
proxyservers:   test
__EOF
    }
    if ($type =~ m/^mfrontend/) {
	print $ifh <<__EOF;
defaultserver: mbackend1
mupdate_server: $ip{mmaster}
mupdate_username: admin
mupdate_authname: test
mupdate_realm: test
mupdate_password: test
mbackend1_password: test
mbackend2_password: test
mbackend3_password: test
proxy_authname: test
proxy_realm:    test
__EOF
    }

    $ifh->close();

    my $LMTPD = 'lmtpd';
    my $IMAPD = 'imapd';
    my $start = "";
    my $rest = "";

    if ($type eq 'mmaster') {
	$rest =  qq(mupdate       cmd="$cyrusbase/bin/mupdate -C $basedir/etc/imapd.conf -m" listen="$ip{$type}:3905" prefork=1);
    }
    elsif ($type =~ m/^mbackend/) {
	$start = qq(mupdatepush   cmd="$cyrusbase/bin/ctl_mboxlist -C $basedir/etc/imapd.conf -m");
	#$rest =  qq(mupdate       cmd="$cyrusbase/bin/mupdate -C $basedir/etc/imapd.conf" listen="$ip{$type}:3905" prefork=1);
    }
    elsif ($type =~ m/^mfrontend/) {
	$rest =  qq(mupdate       cmd="$cyrusbase/bin/mupdate -C $basedir/etc/imapd.conf" listen="$ip{$type}:3905" prefork=1);
	$LMTPD = 'lmtpproxyd';
	$IMAPD = 'proxyd';
    }

    my $cfh = IO::File->new(">$basedir/etc/cyrus.conf");
    print $cfh <<__EOF;
START {
  recover       cmd="$cyrusbase/bin/ctl_cyrusdb -C $basedir/etc/imapd.conf -r"
  idled         cmd="$cyrusbase/bin/idled -C $basedir/etc/imapd.conf"
  $start
}

SERVICES {
  imap          cmd="$cyrusbase/bin/$IMAPD -C $basedir/etc/imapd.conf -t 600" listen="$ip{$type}:143" provide_uuid=1 maxfds=2048
  pop3          cmd="$cyrusbase/bin/pop3d -C $basedir/etc/imapd.conf" listen="$ip{$type}:110" provide_uuid=1
  lmtp          cmd="$cyrusbase/bin/$LMTPD -C $basedir/etc/imapd.conf -a" listen="$ip{$type}:2003" provide_uuid=1 maxfds=2048
  $rest
}

EVENTS {
  checkpoint    cmd="$cyrusbase/bin/ctl_cyrusdb -C $basedir/etc/imapd.conf" period=180
}
__EOF
    $cfh->close();

    system("/usr/cyrus/bin/mkimap $basedir/etc/imapd.conf");

    my $saslpid = fork();
    unless ($saslpid) {
      # child;
      $0 = "saslauthd: $basedir";
      saslauthd("$basedir/run");
      exit 0;
    }

    system("chown -R cyrus $basedir");

    my $masterpid = fork();
    unless ($masterpid) {
      $0 = "cyrusmaster: $basedir";
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
sleep 2;

my $admin = Mail::IMAPTalk->new(
  Server   => $ip{mbackend3},
  Port     => "143",
  Username => 'admin',
  Password => 'test',
);

my $admin2 = Mail::IMAPTalk->new(
  Server   => $ip{mbackend2},
  Port     => "143",
  Username => 'admin',
  Password => 'test',
);

$admin->create('user/foo', 'default');
$admin->create('user/foo/subdir', 'default');
$admin->create('user/foo/Sent Items', 'default');
$admin->create('user/foo/Drafts', 'default');
$admin->create('user/foo/Trash', 'default');
$admin->setacl('user/foo', 'admin', "lrswipcd");
$admin->setquota('user/foo', "(STORAGE 100000)");

$admin2->create('user/user.name@domain.com', 'default');
$admin2->create('user/user.name/Drafts@domain.com', 'default');
$admin2->setacl('user/user.name@domain.com', 'foo', "lrswipcd");
$admin2->setquota('user/user.name@domain.com', "(STORAGE 100000)");

my $msg = <<EOF;
From: test <test\@example.com>
To: test <test\@example.com>

Some stuff in the body...
EOF
$msg =~ s/\012/\r\n/gs;
$msg .= ".\r\n";
$admin->append('user.foo', "(\\Seen \\Flagged)", "08-Mar-2010 16:18:11 +1000", $msg);
print "created\n";
# let's see about dupelim then...
dolmtp('foo', $msg);

# XXX - fun here

sleep 10000;

system("kill @pids");
exit 0;

sub saslauthd {
  my $dir = shift;

  $0 = "saslauthd: $dir";
  unlink("$dir/mux");
  my $sock = IO::Socket::UNIX->new(
    Local => "$dir/mux",
    Type => SOCK_STREAM,
    Listen => SOMAXCONN,
  );
  die "FAILED to create socket $!" unless $sock;
  system("chown cyrus $dir/mux");

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
  my $sock = IO::Socket::INET->new("$ip{mfrontend1}:2003");
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
