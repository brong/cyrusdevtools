#!/usr/bin/perl -w

use strict;

my @revs = git_revlist('clean', 'work');
our $REV;
our $SECTION;

unless (@revs) {
  die "NO MORE WORK TO DO!\n";
}

foreach my $rev (reverse @revs) {
  $REV = $rev;
  run_command("git checkout $rev");
  print "ON $rev\n";
  my $res;
  my @items;
  check_start('configure');
  run_command('make clean');
  run_command('aclocal -I cmulocal');
  run_command('autoheader');
  run_command('autoconf');
  ($res, @items) = run_command('CFLAGS="-g -W -Wall" ./configure ' .
                               '--enable-unit-tests --enable-replication ' .
                               '--enable-nntp --enable-murder --enable-idled');
  check_res($res, @items);
  check_start('make');
  ($res, @items) = run_command('make -j8');
  check_res($res, @items);
  check_start('check');
  ($res, @items) = run_command('make check');
  $res = 1 if grep { m/FAILED/ } @items;
  check_res($res, @items);

  run_command('git checkout -B clean');
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
  my @items;
  open(FH, "$command 2>&1 | tee /tmp/$REV-$SECTION.out |") || die "Failed to run $command";
  @items = <FH>;
  close(FH);
  return ($?, @items);
}

sub check_start {
  my $section = shift;
  $| = 1;
  print "  $section: ";
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
