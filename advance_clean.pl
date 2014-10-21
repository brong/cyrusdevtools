#!/usr/bin/perl -w

use strict;
use Getopt::Std;

my %Opts;

getopts('b:c:t:l:ufF', \%Opts);

my $base = $Opts{b} || 'clean';
my $target = $Opts{t} || 'work';
my $clean = $Opts{c} || $base;
my $log = $Opts{l} ? 1 : 0;
my $dounit = $Opts{u};

unless (keys %Opts) {
  die <<EOF
Usage: $0 [-b base] [-t target] [-c cleanname] [-l logdir]

Check out every revision from base to target.  Run a full recompile
and unit test.  If the revision passes the test, advance the 'clean'
branch to that revision and move on.  If any commit fails, abort and
leave the failed commit checked out.

If logdir is specified, dump the output of every command into files
in that directory.

  -f means go fast (just make)
EOF
}

my @revs = git_revlist($base, $target);
our $REV;
our $SECTION;
our $N;
our $M;

unless (@revs) {
  die "NO MORE WORK TO DO!\n";
}

my $dofast = $Opts{F};
foreach my $rev (reverse @revs) {
  $REV = $rev;
  $M = 0;
  my (undef, @lines) = run_command("git log --oneline $REV");
  $N = @lines;
  printf("%05d %s", $N, $lines[0]);
  check_start("checkout");
  my ($res, @items) = run_command("git checkout $rev", $log);
  check_res($res, @items);
  unless ($dofast) {
    check_start('configure');
    run_command('git clean -f -x', $log);
    run_command('autoreconf -v -i', $log);
    ($res, @items) = run_command('CFLAGS="-g -W -Wall -Wextra -Werror" ./configure ' .
                                 '--enable-unit-tests --enable-replication ' .
                                 '--enable-nntp --enable-murder --enable-idled --enable-http', $log);
    check_res($res, @items);
  }

  check_start('make');
  ($res, @items) = run_command('make -j 8', $log);
  check_res($res, @items);

  if ($dounit) {
    check_start('check');
    ($res, @items) = run_command('make check', $log);
    $res = 1 if checks_failed(@items);
    check_res($res, @items);
  }

  $dofast = 1 if $Opts{f};

  run_command("git checkout -B $clean");
}

sub git_revlist {
  my ($base, $end) = @_;
  my @res;
  open(FH, "git rev-list $base..$end |");
  while (<FH>) {
    chomp;
    push @res, $_;
  }
  close(FH);
  return @res;
}

sub run_command {
  my $command = shift;
  my $log = shift;
  my @items;
  my $pipe = '|';
  if ($log) {
    my $s = $SECTION;
    $s =~ s/\s//g;
    my $r = substr($REV, 0, 7);
    $pipe = sprintf("| tee -a %s/%04d-%s-%d-%s.out |", $Opts{l}, $N, $r, $M, $s);
  }
  open(FH, "$command 2>&1 $pipe") || die "Failed to run $command";
  @items = <FH>;
  close(FH);
  return ($?, @items);
}

sub check_start {
  my $section = shift;
  $M++;
  $| = 1;
  print "    - $section: ";
  $SECTION = $section;
}

sub check_res {
  my ($res, @items) = @_;
  unless ($res) {
    print "OK\n";
    return;
  }
  print "FAILED\n";
  if (@items > 20) {
    splice @items, 0, -20;
  }
  print @items;
  print "=================================================\n";
  print "Failed $SECTION of $REV\n";
  exit 1;
}

sub checks_failed {
  my $found = 0;
  for (@_) {
    return 1 if m/FAILED/;
    if (m/^\s*(?:suites|tests|asserts).*(\d+)\s*$/) {
      return 1 if $1;
      $found++;
    }
  }
  return $found != 3;
}
