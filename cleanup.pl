#!/usr/bin/perl -wT
# -*- cperl -*-

use strict;
use DateTime;
use HTML::Entities;
use File::Spec::Functions;
use Data::Dumper;
use Carp;
use IPC::Run qw(run);

our (%input, $authbox, $timezone);
require './include.pl';

our $datadir = getvariable("wirelessprint", "datadir") || "/var/spool/wirelessprint";
our $logdir  = getvariable("wirelessprint", "logdir")  || "/var/log/wirelessprint";
our $logfile = getvariable("wirelessprint", "cleanup_logfile") || catfile($logdir, "cleanup.log");
our $myuser  = getvariable("wirelessprint", "datafile_owner") || "www-data";
our $mygroup = getvariable("wirelessprint", "datafile_group") || "www-data";

my $debug = getvariable("wirelessprint", "debug_cleanup"); $debug = 1 if not defined $debug;

our %format;
require './fileformatlist.pl';

$main::dbconfig{timezone} ||= 'America/New_York'; # Suppress spurious "used only once" warning.
my $now          = DateTime->now( time_zone => ($main::dbconfig{timezone} || 'America/New_York') );
my $dbnow        = DateTime::Format::ForDB($now);
my $orphancutoff = DateTime::Format::ForDB($now->clone()->subtract( months => getvariable("wirelessprint", "cleanup_orphancutoff") || 1 ));
my $cancelcutoff = DateTime::Format::ForDB($now->clone()->subtract( months => getvariable("wirelessprint", "cleanup_cancelcutoff") || 3 ));
my $printcutoff  = DateTime::Format::ForDB($now->clone()->subtract( months => getvariable("wirelessprint", "cleanup_printcutoff")  || 6 ));
my $finalcutoff  = DateTime::Format::ForDB($now->clone()->subtract( months => getvariable("wirelessprint", "cleanup_finalcutoff")  || 18 ));

logit("Cleanup started " . $now->ymd() . " " . $now->hms() . ".");

for my $filespec (<$datadir/*>) {
  my $filename = strip_leading_directory($filespec, $datadir);
  logit("File: $filename (full path: $filespec)") if $debug > 1;
  my ($record) = findnull("printjobdatafile", "removed", "filename", $filename);
  if (ref $record) {
    process($record, $filename);
  } else {
    notice($filename);
  }
}

exit 0;

sub process {
  my ($rec, $file) = @_;
  my $job = getrecord("printjob", $$rec{job}) if $$rec{job};
  my $cutoff = ($$rec{flags} =~ /O/) ? $orphancutoff :
    ($$rec{job} and $$job{printdate}) ? $printcutoff :
    ($$rec{job} and $$job{canceldate}) ? $cancelcutoff : $finalcutoff;
  my $date = ($$rec{flags} =~ /O/) ? $$rec{noticed} :
    ((ref $job) and ($$job{printdate} || $$job{canceldate} || $$job{submitdate})) || $$rec{noticed};
  my ($safefilename) = $file =~ m!((?:\w+|[.][^./\\]+|[^.]+)*)$!;
  my $fspec = catfile($datadir, $safefilename);
  if ($date lt $cutoff) {
    if (not -e $fspec) {
      $$rec{removed} = $dbnow;
      updaterecord("printjobdatafile", $rec);
      logit(" * Already unlinked (last minute): $file" . ((ref $job) ? " (job $$job{id})" : "") . " [cutoff: $cutoff]");
    } elsif (unlink $fspec) {
      $$rec{removed} = $dbnow;
      updaterecord("printjobdatafile", $rec);
      logit(" * Unlinked: $file" . ((ref $job) ? " (job $$job{id})" : "") . " [cutoff: $cutoff]");
    } else {
      logit(" ! Failed to unlink $fspec: $!");
    }
  } elsif (not -e $fspec) { # Notice that it has been removed, even if we didn't do it.
    $$rec{removed} = $dbnow;
    updaterecord("printjobdatafile", $rec);
    logit(" * Already unlinked (early): $file" . ((ref $job) ? " (job $$job{id})" : "") . " [cutoff: $cutoff]");
  } elsif ($debug) {
    logit(" * Not past cutoff: $file ($date / $cutoff)");
  }
}

sub notice {
  my ($fname) = @_;
  if (-d catfile($datadir, $fname)) {
    notice_directory_contents($fname);
  }
  my (@j)     = findrecord("printjob", "filename", $fname);
  my $job     = pop @j; # The most recent, if there's more than one.
  my $flags   = (ref $job) ? "" : "O"; # Orphaned files are ones that no job still claims.  Usually they have been format-converted into other files.
  my $newrec  = +{  filename => $fname,
                    noticed  => $dbnow,
                    flags    => $flags,
                    job      => ((ref $job) ? $$job{id} : undef),
                 };
  addrecord("printjobdatafile", $newrec);
}

sub notice_directory_contents {
  my ($dirname) = @_;
  my $dirspec   = catfile($datadir, $dirname);
  die "Not a directory" if not -d $dirspec;
  if (opendir DIR, $dirspec) {
    for my $f (readdir(DIR)) {
      if ($f =~ /^[.]*$/) {
        # No.
      } else {
        notice(catfile($dirname, $f));
      }
    }
    closedir DIR;
  }
}

sub fatalerror {
  my ($msg, $shortmsg) = @_;
  $shortmsg ||= $msg;
  logit($msg);
  die $shortmsg;
}

sub strip_leading_directory {
  my ($fspec, $dir) = @_;
  my $fname = $fspec;
  $fname =~ s!\Q$dir\E[/]?!!;
  my $matchspec = catfile($dir, $fname);
  if ($matchspec eq $fspec) {
    return $fname;
  } else {
    fatalerror(" ! strip_leading_directory() failed to strip leading '$dir' from '$fspec': got '$fname', but catfile('$dir', '$fname') results in '$matchspec'.",
               "strip_leading_directory() failed, see $logfile for details.");
  }
}

sub logit {
  my ($info) = @_;
  open LOG, ">>", $logfile
    or die "Cannot append to logfile: $!";
  print LOG $info . "\n";
  close LOG;
}
