#!/usr/bin/perl -w
use strict;
BEGIN { do "/home/mod_perl/hm/ME/FindLibs.pm"; }
use Mail::IMAPTalk;
use Net::XmtpClient;
use Time::HiRes qw(time sleep);
use Digest::MD5;
use Cache::FastMmap;
use Getopt::Std;
use POSIX ":sys_wait_h";
use Carp;
use Data::Dumper;
use IO::File;
use IO::Socket::UNIX;

# Don't buffer STDOUT
select(STDOUT); $| = 1;

print "Start time: ", scalar(localtime), "\n";

# Configuration {{{

# Command line options
my %Opts;
getopts('B:dcs:l:u:r:tfi:p:n:o:a:D:M:', \%Opts);

# Dir to place temp files/logs in
my $Root = "/tmp/imapstress";
system("rm -rf $Root");
mkdir($Root);
my @Pids = RunCyrus("$Root/cyrus", $Opts{M}, $Opts{D});

# Username prefix to use
my $Prefix = $Opts{q} || 'imapstresstest';
# Number of users
my $NumUsers = int($Opts{n} || 1500);
my $CyrusPath = $Opts{B} || "/usr/cyrus/bin";

my $AdminPassword = "qwerasdf";

# Build messages with this number of lines
my @MsgLines = qw(35 40 45 45 50 50 55 55 60 60 65 65 100 100 150 150 200 200 1000 10000 30000);
my %MsgSizeMD5;

# List of functions and relative number of times to call
my @ActionHist = (
  [\&AppendMessage, 4],
  [\&CheckAll, 2],
  [\&ReadMessage, 16],
  [\&DeleteMessage, 4],
  [\&MoveMessage, 4],
  [\&ChangeFolder, 8],
  [\&NewImapConnection2, 4],
  [\&EmptyFolder, 0]
);
my @Actions = map { ($_->[0]) x $_->[1] } @ActionHist;

# Keep track of folders being used so multiple
# procs don't tread on each other
my $Cache = Cache::FastMmap->new(
  share_file => "$Root/cfm",
  init_file => 1,
  raw_values => 1
);

# Fill in other options
my $Debug = $Opts{d} || 0;
my $Cleanup = $Opts{c} || 0;
my $WantLoad = $Opts{l} || 5;
my $UpdateTime = ToSeconds($Opts{u} || '5m');
my $RunTime = ToSeconds($Opts{r} || '1h');
my $Strace = $Opts{t} || 0;
my $FixedSleep = $Opts{f} ? 15 : 0;

print <<EOF;
Run options:
User prefix: $Prefix
Num mailboxes: $NumUsers
Debug: $Debug
Load: $WantLoad
Update time: $UpdateTime
Run time: $RunTime
Strace children: $Strace
Fixed sleep time: $FixedSleep
EOF

# Globals used to hold current state
my $CurFolder = '';
my $CurUser = '';
my $SleepTime = 0;
my $Imap;
my $StartTime = time();
my $LastUpdate = time();
my %Pids;

my $CurLoad = 0;
my ($NChild, $TCount) = (0, 0);

my ($LogFd, $ExitChild);

# }}}

# Run mode {{{

# Need to pass "go" argument to really run
if ((shift || '') ne 'go') {
  Usage();
  kill(15, $_) for @Pids;
  exit(1);
}

# Connect log to STDOUT for starters
open($LogFd, ">&STDOUT") || die "couldn't dup STDOUT: $!";

# Cleanup mode? Just delete all folders
if ($Opts{c}) {
  DeleteFolders();
  exit(0);
}

# Otherwise run main code
eval { RunTest(); };

# Handle standard expected child exit
if ($@ && $@ =~ /child regular exit/) {
  $Imap = undef;
  RemoveLock();
  close $LogFd;
  exit(0);
}

# Other error in expected child exit
warn "Child unexpected death $$ - $@" if $@;

# }}}

print "End time: ", scalar(localtime), "\n";
exit(0);

sub RunTest {

  # Create messages for delivery
  CreateMessages();
  CreateFolders();
  $Imap = undef;

  # Catch expected signals
  $SIG{CHLD} = \&HandleSigChld;
  $SIG{HUP} = sub { $ExitChild = 1; };
  $SIG{TERM} = sub { exit(0); };

  # Main loop, run for $RunTime seconds
  my $Now = time();
  while ($Now - $StartTime < $RunTime) {

    HandleChildren();
    PrintUpdate($Now);

    # Keep average child count stats
    $NChild += scalar(keys %Pids);
    $TCount++;

    RealSleep(10);

    $Now = time();
  }

  # Print final stats
  print "Final details:\n";
  PrintUpdate();

  # Cleanup all children
  ReapChildren();

}

sub HandleChildren {
  $CurLoad = GetCurLoad();

  # Add or kill children to bring load into line
  my $LoadDiff = $WantLoad - $CurLoad;
  if ($LoadDiff >= 0.5) {
    AddChildren($LoadDiff)
  } elsif ($LoadDiff <= -0.5) {
    KillChildren($LoadDiff);
  }

}

sub PrintUpdate {
  my $Now = shift;

  # Print update to log if $UpdateTime has passed
  if (!defined($Now) || $Now - $LastUpdate > $UpdateTime) {
    print "Time: ", scalar(localtime), "\n";
    print "Children: ", scalar keys %Pids, "\n";
    print "Load: $CurLoad\n";
    print "Run time left: ", $RunTime - ($Now - $StartTime), "\n";
    print "Child count average: ", ($NChild/$TCount), "\n";

    $LastUpdate = $Now;
  }
}

sub ReapChildren {
  print "Killing all children\n";

  # Kill all running children
  my @Pids = keys %Pids;
  for (0 .. scalar(@Pids)-1) {
    my $Pid = $Pids[$_];

    # Print progress states
    Progress($_+1, scalar(@Pids)+1);

    # When you kill a child, an attached strace will
    # also exit, removing itself from the %Pids hash
    # via the SIGCHLD handler. Slight race condition here
    next if !exists $Pids{$Pid};
    my $State = $Pids{$Pid};

    # Mark child as expected to exit and kill
    if ($State eq 'running') {
      $Pids{$Pid} = 'exiting';
      kill 'TERM', $Pid;
    }

    # Kill up to 100 procs a second...
    RealSleep(0.01);
  }

  print "Waiting for children\n";

  # Wait for all children to exit
  my $PidCount;
  my $Start = time();
  while (($PidCount = scalar keys %Pids) && $Start + 20 > time()) {
    print "$PidCount children left ... ";
    RealSleep(1.0);
  }
  print "\n";

  if ($PidCount) {
    print "Unexpected children left: $PidCount\n";
    for (keys %Pids) {
      print "  $_: $Pids{$_}\n";
    }
  } else {
    print "All children exited\n";
  }
}

sub GetCurLoad {

  # Hacky way to build a "current load".
  # 1 min seems too short, 5 min too long, so use weighted value
  my $Cmd = "cat /proc/loadavg";
  my ($L1, $L2) = split / /, `$Cmd`;
  return ($L1*2 + $L2)/3;
}

sub AddChildren {
  my $LoadDiff = shift;

  # This calculation is basically arbitrary, and seems to work "about right"
  my $AddChildren = int((3*$LoadDiff) ** 1.5) + 1;

  if ($FixedSleep) {
    $SleepTime = $FixedSleep;
  } else {
    # This calculation is also arbitrary, and seems to work "about right"
    $SleepTime = 3 + 100 / (1 + 10 * $LoadDiff);
  }
  print "Adding $AddChildren children, sleep time $SleepTime\n";

  # Add given number of child procs
  for (1 .. $AddChildren) {

    # In parent, mark child as running
    if (my $Pid = fork()) {
      $Pids{$Pid} = 'running';

      # If stracing requested, fork and run strace on child
      if ($Strace) {
        if (my $STPid = fork()) {
          $Pids{$STPid} = 'strace';
        } else {
          print "strace($$) ... ";
          exec("strace -tt -p $Pid -o $Root/log/st.$Pid");
          die "exec failed";
        }
      }

    # In child, do child stuff
    } else {
      srand($$ + int(time));
      DoChild();
      # Hacky way to exit out of subs...
      die "child regular exit";
    }
  }

  # Child print their pid as they fork, assume all done after 0.5 seconds
  RealSleep(0.5);
  print "\n";
}

sub KillChildren {
  my $LoadDiff = -shift;

  # This calculation is basically arbitrary, and seems to work "about right"
  my $KillChildren = int((3*$LoadDiff) ** 1.5) + 1;

  # Limit number to kill, since killing lots in one go INCREASES load
  $KillChildren = 3 if $KillChildren > 3;

  print "Killing $KillChildren children\n";

  for (1 .. $KillChildren) {
    my @Pids = keys %Pids;

    # What, no pids to choose from? Just leave loop...
    last if !@Pids || !grep { $Pids{$_} eq 'running' } @Pids;

    # Pick a random pid
    my $Pid = $Pids[rand(scalar(@Pids))];
    # Better be a running child (don't kill strace or exiting childs)
    redo if $Pids{$Pid} ne 'running';

    # Set to exiting and kill
    $Pids{$Pid} = 'exiting';
    kill 'HUP', $Pid;
  }

}

sub DoChild {
  print "$$ ... ";

  # Connect to per-child log file
  -d "$Root/log" || mkdir "$Root/log";
  close $LogFd;
  open $LogFd, ">>$Root/log/out.$$" 
    || die "failed to create $Root/log/out.$$";
  print $LogFd "Starting child $$\n";

  # Start new connection
  NewImapConnection();
  ChangeFolder();

  # We signal a child to exit, which sets $ExitChild
  while (!$ExitChild) {
    my $Action = $Actions[int(rand(@Actions))];
    my $Time = time();
    # print "About to perform action\n";
    $Action->();
    print $LogFd scalar(localtime()), " ", time() - $Time, "\n";

    RealSleep($SleepTime);
  }

  # Die to exit out of loop
  die "child regular exit";
}

sub Usage {

  print <<EOF;
Usage: imapstress.pl go
  -c               - cleanup, delete all mailboxes
  -d               - debug mode (log imap commands to $Root/log)
  -s <server>      - connect to server instead of localhost
  -l <load>        - run enough procs to get load on server to "load" (default 5)
  -u <time>        - update status every "time" to log (default 5m)
  -r <time>        - run for "time" (default 1h)
  -n <number>      - number of mailboxes to use (defaults to 1500)
  -t               - strace all children (to $Root/log)
  -f               - fixed sleep time (15 seconds) for comparative testing
  -i <port>        - imap port number (defaults to 2143)
  -p <port>        - lmtp port number (defaults to 2003)
  -o <partition>   - partition to use (defaults to data1)
  -q <prefix>      - username prefix to use (defaults to imapstresstest)
  -a <password>    - admin password

EOF
}

# Check all folders (ala Outlook Express)
sub CheckAll {
  print $LogFd "CheckAll ", scalar(localtime), "\n";

  debug("Checking all folders for $CurUser");

  # Check each folder one after another
  my $FolderList = GetFolders();
  for (@$FolderList) {
    NewImapConnection($CurUser);
    ChangeFolder($_) || next;
    my $Msgs = $Imap->search('1:*', 'not', 'deleted')
      || die "failed to search $CurFolder";
    if (@$Msgs) {
      my $BS = $Imap->fetch($Msgs, '(bodystructure rfc822.header)');
    }
    RealSleep(0.05);
  }
}

# Read a single message (and check md5)
sub ReadMessage {
  print $LogFd "ReadMessage ", scalar(localtime), "\n";

  ChangeFolder() || return if !$CurFolder;

  # Pick random message
  my $MsgNum = PickRandomMessage() || return;
  debug ("getting message # $MsgNum");

  # Fetch message body to file
  my $FileName = "$Root/downloadmsg.$$." . int(rand(10000));
  open(my $Fh, "+>$FileName");
  $Imap->literal_handle_control($Fh);
  my $Msg = $Imap->fetch($MsgNum, 'body[1]')
    || die "failed to fetch $MsgNum - $@";
  $Imap->literal_handle_control(0);

  # Move back to start of file
  flush $Fh;
  seek $Fh, 0, 0;

  # Check md5
  my $Context = Digest::MD5->new;
  $Context->addfile($Fh);
  my $Digest = $Context->b64digest;

  close($Fh);

  my $Length = -s($FileName);
  debug ("message len # $Length");
  if ($MsgSizeMD5{$Length} ne $Digest) {
    print "MD5 checksum failed, len=$Length, gen=$Digest\n";
    print "Digests: ", join ", ", map { "$_ => $MsgSizeMD5{$_}" } keys %MsgSizeMD5;
    die "Checksum failed";
  }

  unlink $FileName;
}

# Move a single message
sub MoveMessage {
  print $LogFd "MoveMessage ", scalar(localtime), "\n";

  my $MsgNum = PickRandomMessage() || return;
  my $Folder = PickRandomFolder(1);
  debug ("moving message # $MsgNum to $Folder");

  $Imap->copy($MsgNum, $Folder) ||
    die "failed to move $MsgNum to $Folder";
  $Imap->store($MsgNum, '+flags', '\\Deleted') ||
    die "failed to delete $MsgNum";
  $Imap->expunge() || die "failed to expunge: $@";

  RemoveLock($Folder);
}

# Delete a single message
sub DeleteMessage {
  print $LogFd "DeleteMessage ", scalar(localtime), "\n";

  my $MsgNum = PickRandomMessage() || return;
  debug ("deleting message # $MsgNum");

  $Imap->store($MsgNum, '+flags', '\\Deleted') ||
    die "failed to delete $MsgNum";
  $Imap->expunge() || die "failed to expunge: $@";
}

# Change to another folder
sub ChangeFolder {
  $Imap->unselect();

  RemoveLock();
  $CurFolder = shift || PickRandomFolder(1);

  debug ("selecting $CurFolder");

  $Imap->select($CurFolder)
    || Carp::confess "could not select $CurUser:$CurFolder - $@";

  return 1;
}

# Empty folder
sub EmptyFolder {
  debug ("emptying $CurFolder");
  $Imap->store("1:*", '+flags', '\\Deleted') ||
    die "failed to empty $CurFolder";
  $Imap->expunge() || die "failed to expunge: $@";
}

# Add a message to the folder
sub AppendMessage {

  my $MsgLines = $MsgLines[int(rand(@MsgLines))];
  my $FileName = "$Root/msg$MsgLines";
  debug("append $MsgLines to $CurUser:$CurFolder");

  my $Client = Net::XmtpClient->new(Server => "$Root/cyrus/run/lmtp.sock")
    || die "Could not connect to lmtp - $@";
  my $Socket = $Client->{Socket};

  my $DelFolder = $CurFolder;
  $DelFolder =~ s/^inbox\.?//i;
  $DelFolder = '+' . $DelFolder if $DelFolder;
  $DelFolder =~ s/ /_/g;

  my $From = 'robm@fastmail.fm';
  my $To = "${CurUser}${DelFolder}\@internal";

  $Client->lhlo("locallmtpdelivery") =~ /^2/
    || die "Unexpected lhlo reponse - $Client->{LastResp}";
  $Client->mail_from($From) =~ /^2/
    || die "Unexpected mail_from reponse - $Client->{LastResp}";
  $Client->rcpt_to($To) =~ /^2/
    || die "Unexpected rcpt_to reponse - $To, $Client->{LastResp}";
  $Client->data() =~ /^3/
    || die "Unexpected data reponse - $Client->{LastResp}";

  open(my $MsgFile, $FileName) || die "Could not open message file - $@";
  while (<$MsgFile>) {
    chomp;
    print $Socket $_, "\r\n";
  }
  print $Socket ".\r\n";

  $Client->read_server_response() =~ /^2/
    || die "Unexpected end-of-data reponse - $@"; 
  
  undef $MsgFile;
  undef $Socket;
  undef $Client;

  RealSleep(0.02);

  $Imap->unselect();
  $Imap->select($CurFolder);
}

# Pick a random message
sub PickRandomMessage {
  # Get message list
  my $Msgs = $Imap->search('1:*', 'not', 'deleted')
    || die "Failed to search - $@";

  # Return undef if no messages
  @$Msgs || return undef;

  # Pick random message
  return $Msgs->[int(rand(@$Msgs))];
}

# Create a new imap connection
sub NewImapConnection {
  RemoveLock();

  if ($Imap) {
    $Imap->logout();
    $Imap = undef;
  }

  $CurUser = shift || PickUser();

  my $Sock = IO::Socket::UNIX->new("$Root/cyrus/run/imap.sock");
  $Sock->autoflush(1);

  $Imap = Mail::IMAPTalk->new(
    Socket => $Sock,
    Username => $CurUser,
    RootFolder => 'inbox',
    AltRootFolder => 'user',
    CaseInsensitive => 1,
    Separator => '.',
    Password=> (defined $_[0] ? $_[0] : 'qwerasdf')
  ) || die "failed to login to $CurUser";
  $Imap->{Timeout} = 30;

  $Imap->set_tracing($LogFd) if $Debug;

  debug ("new imap connection as $CurUser");

  $CurFolder = undef;
}

sub NewImapConnection2 {
  NewImapConnection(@_);
  ChangeFolder();
}

# Pick a random user
sub PickUser {
  return $Prefix . (int(rand($NumUsers))+1);
}

# Pick a random folder
sub PickRandomFolder {
  my $DoLock = shift;

  my $FolderList = GetFolders();

  my $Folder = '';
  my $Locked = 0;
  while ((!$Folder || $Folder eq ($CurFolder || '')) && !$Locked) {

    # Pick a random folder
    my $FolderNum = int(rand(@$FolderList));
    $Folder = $FolderList->[$FolderNum];

    # Lock it if requested
    if ($DoLock) {
      $Locked = AddLock($Folder);
      RealSleep(0.05);

    } else {
      $Locked = 1;
    }
  }
  return $Folder;
}

# Get a list of folders for the user
sub GetFolders {
  my $FolderList = $Imap->list("", "*")
    || die "Could not get folder list - $CurUser";

  if (!ref($FolderList)) {
    die "$CurUser returned empty folder list: $@";
  }

  eval { @$FolderList = map { $_->[2] } @$FolderList; };
  if ($@) { print Dumper($FolderList); die $@; }

  return $FolderList;
}

sub CreateFolders {
  print "Creating folders\n";
  NewImapConnection('admin', $AdminPassword);
  for (1 .. $NumUsers) {
    Progress($_, $NumUsers);
    my $Name = "${Prefix}$_";
    my $Folder = "user.$Name";

    # Create folder
    my $Res = $Imap->create($Folder);

    # Skip if error and already exists, otherwise error is fatal
    next if !$Res && $@ =~ /Mailbox already exists/;
    $Res || die "Could not create folder '$Folder' - $@";

    $Imap->setquota($Folder, "(storage 1000000)")
      || warn "Could not set quota on user folder $Folder";
    $Imap->setacl($Folder, $Name, 'lrswipdca')
      || warn "Could not set ACL - $@";
    $Imap->setacl($Folder, 'admin', 'lrswipdca')
      || warn "Could not set ACL - $@";
    $Imap->setacl($Folder, 'anyone', 'p')
      || warn "Could not set ACL - $@";
    $Imap->create("$Folder.Drafts");
    $Imap->create("$Folder.Sent Items");
    $Imap->create("$Folder.Trash");
    $Imap->create("$Folder.sub1");
    $Imap->create("$Folder.sub2");
  }
  print "Done\n";
}

sub DeleteFolders {
  print "Deleting existing folders\n";
  NewImapConnection('admin', $AdminPassword);
  for (1 .. $NumUsers) {
    Progress($_, $NumUsers);
    my $Folder = "user.${Prefix}$_";
    $Imap->delete($Folder) && $@ !~ /Mailbox does not exist/
      || warn "Could not delete folder '$Folder' - $@";
  }
  print "Done\n";
}

sub Progress {
  my ($Count, $Total) = @_;

  if ($Count == 1) {
    print "($Total): $Count ... ";
    return;
  }
  if ($Count == $Total) {
    print "$Total\n";
    return;
  }
  if ($Count % 100 == 0) {
    print "$Count ... ";
    return;
  }
}

# Create a bunch of messages
sub CreateMessages {

  my $BodyLine = "This is a test. This is a test. This is a test. This is a test. ";
  foreach my $MsgNum (1 .. @MsgLines) {
    $_ = $MsgLines[$MsgNum-1];

    my $Subject = "Message with $_ lines";
    my $From = "\"Sender $_\" <sender$_\@fastmail.fm>";
    my $Header = <<EOF;
X-Sasl-enc: rJMxT5e6s6fPonivYntW/3W57O0ewL86bpNUa1atvkJQ 1143442350
Received: from robm (dsl-202-173-180-52.vic.westnet.com.au [202.173.180.52])
  by frontend3.messagingengine.com (Postfix) with ESMTP id 9A6044BD
  for <robm\@fastmail.fm>; Mon, 27 Mar 2006 01:52:30 -0500 (EST)
From: $From
To: $From
Subject: $Subject
Date: Mon, 27 Mar 2006 17:52:53 +1000
MIME-Version: 1.0
Content-Type: text/plain;
  format=flowed;
  charset="iso-8859-1";
  reply-type=original
Content-Transfer-Encoding: 7bit
X-Priority: 3
X-MSMail-Priority: Normal
X-Mailer: Microsoft Outlook Express 6.00.2900.2670
X-MimeOLE: Produced By Microsoft MimeOLE V6.00.2900.2670

EOF

    # Create 2 files. One with full message and one with just body
    my $FileName = "$Root/msg$_";
    open my $MsgFd1, ">$FileName";
    open my $MsgFd2, "+>$FileName.body";
    print $MsgFd1 $Header;
    for (1 .. $_) {
      print $MsgFd1 $BodyLine, "\n";
      print $MsgFd2 $BodyLine, "\r\n";
    }
    close $MsgFd1;

    # Move back to start of body file
    flush $MsgFd2;
    seek $MsgFd2, 0, 0;

    # Create MD5 checksum of body part
    my $Context = Digest::MD5->new;
    $Context->addfile($MsgFd2);
    my $Digest = $Context->b64digest;

    close $MsgFd2;

    my $Length = -s("$FileName.body");
    $MsgSizeMD5{$Length} = $Digest;
  }

}

sub HandleSigChld {
  my $Pid;
  while (($Pid = waitpid(-1,WNOHANG)) > 0) {
    my $State = delete $Pids{$Pid};
    if (!$State) {
      print "Caught unknown child death $Pid\n";
    } elsif ($State eq 'running') {
      print "Caught unexpected child death $Pid\n";
    } elsif ($State eq 'exiting') {
      # Expected child to exit
    } elsif ($State eq 'strace') {
      # strace child exited
    }

    # Unlock and folder locked by this pid
    my $LockedFolder = $Cache->get("$Pid");
    if ($LockedFolder) {
      $Cache->remove("$Pid");
      $Cache->remove($LockedFolder);
    }
  }
}

sub ToSeconds {
  local $_ = shift;
  return $_ * { m=>60, h=>60*60, d=>24*60*60 }->{$1} if s/([mhd])$//i;
  return $_;
}

sub AddLock {
  my $Folder = shift;
  my $Locked = 0;
  $Cache->get_and_set("$CurUser.$Folder", sub { return ($Locked = $_[0]) ? $_[0] : $$; });
  $Cache->set("$$", "$CurUser.$Folder") if !$Locked;
  return $Locked;
}

sub RemoveLock {
  my $Folder = shift || $CurFolder;
  $Cache->remove("$CurUser.$Folder") if $CurUser && $Folder;
  $Cache->remove("$$");
}

sub RealSleep {
  my $SleepTime = shift;

  # Signal causes sleep to exit early, loop
  # to ensure correct sleep time
  my $SleepTill = time() + $SleepTime;
  do {
    sleep($SleepTime);
    $SleepTime = $SleepTill - time();
  } while $SleepTime > 0;

  return;
}
    
sub debug {
  print $LogFd $_[0] if $Debug;
}

sub RunCyrus {
  my $basedir = shift;
  my $metadir = shift || $basedir;
  my $datadir = shift || $metadir;

  system("rm -rf $basedir");
  mkdir($basedir);
  mkdir("$basedir/etc");
  mkdir("$basedir/run");
  mkdir("$basedir/conf");
  mkdir("$basedir/conf/db");
  mkdir("$basedir/conf/dbbak");
  mkdir("$basedir/conf/sieve");
  mkdir("$basedir/conf/cores");
  mkdir("$metadir/meta");
  mkdir("$datadir/data");

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
partition-default: $datadir/data
metapartition-default: $metadir/meta
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
  imap          cmd="imapd -C $basedir/etc/imapd.conf -t 600" listen="$basedir/run/imap.sock" provide_uuid=1 maxfds=2048
  pop3          cmd="pop3d -C $basedir/etc/imapd.conf" listen="$basedir/run/pop3.sock" provide_uuid=1
  lmtp          cmd="lmtpd -C $basedir/etc/imapd.conf" listen="$basedir/run/lmtp.sock" provide_uuid=1 maxfds=2048
}

EVENTS {
  checkpoint    cmd="ctl_cyrusdb -C $basedir/etc/imapd.conf" period=180
}
__EOF
  $cfh->close();

  system("$CyrusPath/mkimap $basedir/etc/imapd.conf");

  my $saslpid = fork();
  unless ($saslpid) {
    # child;
    saslauthd("$basedir/run");
    exit 0;
  }

  system("chown -R cyrus $basedir");

  my $masterpid = fork();
  unless ($masterpid) {
    system("$CyrusPath/master -C $basedir/etc/imapd.conf -M $basedir/etc/cyrus.conf");
    exit 0;
  }

  sleep 2;

  return ($masterpid, $saslpid);
}


sub saslauthd {
  my $dir = shift;
  my $sock = IO::Socket::UNIX->new(
    Local => "$dir/mux",
    Type => SOCK_STREAM,
    Listen => SOMAXCONN,
  );

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
