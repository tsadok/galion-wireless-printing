#!/usr/bin/perl -wT
# -*- cperl -*-

use strict;
use DateTime;
use File::Spec::Functions;
use Data::Dumper;
use Mail::POP3Client;

our (%input, $authbox, $timezone);
require "./db.pl";
our $datadir = getvariable("wirelessprint", "datadir") || "/var/spool/wirelessprint";
our $logdir  = getvariable("wirelessprint", "logdir")  || "/var/log/wirelessprint";
our $logfile = getvariable("wirelessprint", "getmail_logfile") || catfile($logdir, "mail.log");
our $debug   = getvariable("wirelessprint", "debug_getmail"); $debug = 1 if not defined $debug;

our %format;
require './fileformatlist.pl';

require './include.pl';

$main::dbconfig{timezone} ||= 'America/New_York'; # Suppress irrelevant used-only-once warning.
my $now = DateTime->now( time_zone => ($main::dbconfig{timezone} || 'America/New_York') );
logit("getmail started " . $now->ymd() . " " . $now->hms() . ".");

our $popcredentials;
require "./mailconfig.pl";

my $pop = new Mail::POP3Client( USER      => $$popcredentials{username},
                                PASSWORD  => $$popcredentials{password},
                                HOST      => $$popcredentials{server},
                                PORT      => $$popcredentials{port} || 110,
                                DEBUG     => $$popcredentials{debug},
                              );

my $count = $pop->Count();
my $tries = 0;
logit("POP3 Count: $count ($$popcredentials{username} on $$popcredentials{server})");
while (((not defined $count) or ($count < 0)) and ($tries++ < 3)) {
  logit("Mail::POP3Client error: $!");
  sleep 20;
  $pop = new Mail::POP3Client( USER      => $$popcredentials{username},
                               PASSWORD  => $$popcredentials{password},
                               HOST      => $$popcredentials{server},
                               PORT      => $$popcredentials{port} || 110,
                               DEBUG     => $$popcredentials{debug},
                             );
  $count = $pop->Count();
}
for my $i (1 .. $count) {
  my $try = 0;
  my ($basename, $hdrname, $emlname, $hdrspec, $emlspec) = ("", "", "", "", "");
  while ((not $basename) or (-e $hdrspec) or (-e $emlspec)) {
    $try++;
    $basename = sprintf("%04d-%02d%02d-%02d%02d-%02d%02d",
                        $now->year(), $now->month(), $now->mday(),
                        $now->hour(), $now->minute(), $i, $try) . "-" . $$;
    $hdrname  = $basename . ".hdr";
    $emlname  = $basename . ".eml";
    $hdrspec  = catfile($datadir, $hdrname);
    $emlspec  = catfile($datadir, $emlname);
  }
  if (open OUT, ">", $hdrspec) {
    binmode OUT;
    my $headers = $pop->Head($i);
    print OUT $headers;
    close OUT;
    logit("Parsing headers for message $i");
    my ($from, $ipaddress, $sender, $subject, $patron);
    for my $h (grep { $_ } split /^(?=\w)/m, $headers) {
      my $hline = unwrap_header_line($h);
      if ($hline =~ /^From[:]\s*(.*?)\s*$/) {
        my $f = $1;
        logit("Parsed From header, got $f");
        $from ||= $f;
      } elsif ($hline =~ /^Received[:]\s*from.*?(\d+[.]\d+[.]\d+[.]\d+)/) {
        my $addr = $1;
        logit("Parsed Received header, got IP address, $addr");
        $ipaddress ||= $addr;
      } elsif ($hline =~ /^Subject[:]\s*(.*?)\s*$/) {
        my $s = $1;
        logit("Parsed Subject header, got $s");
        $subject ||= $s;
      } elsif ($hline =~ /^Return-Path[:]\s*(.*?)\s*$/) {
        my $rp = $1;
        logit("Parsed Return-Path header, got $rp");
        $sender ||= $rp;
      } elsif ($debug > 8) {
        logit("Header DRIBBLE: $hline");
      }
    }
    if ($from) {
      ($patron) = $from =~ /([A-Za-z][A-Za-z0-9 ]*)/;
    } else {
      logit("Did not find From: header for message $i");
      if ($sender) {
        ($patron) = $sender =~ /([A-Za-z][A-Za-z0-9 ]*)/;
      } else {
        logit("Found neither From: header nor envelope sender for message $i, something is very wrong with this message");
      }
    }
    if (open OUT, ">", $emlspec) {
      binmode OUT;
      my $message = $pop->HeadAndBody($i);
      print OUT $message;
      close OUT;
      my $rec = +{ emailfrom    => $from,
                   ipaddress    => $ipaddress,
                   smtpsender   => $sender,
                   patron       => $patron,
                   subject      => $subject,
                   srcformat    => "rfc822",
                   filename     => $emlname,
                   submitdate   => DateTime::Format::ForDB($now),
                   process      => "email",
                   flags        => "E",
                 };
      if (addrecord("printjob", $rec)) {
        if ($debug < 5) {
          logit("Informing POP server that we have message $i.");
          $pop->Delete($i);
        }
      } else {
        logit("Failed to save record: ". Dumper($rec));
      }
    } else {
      logit("Error: cannot write email message ($emlspec): $!");
    }
  } else {
    logit("Error: cannot write headers file ($hdrspec): $!");
  }
}

sub unwrap_header_line {
  my ($raw) = @_;
  my $fixed = join " ", map { $_ } split /\r?\n\s*/, $raw;
  return $fixed;
}

sub logit {
  my ($info) = @_;
  open LOG, ">>", $logfile
    or die "Cannot append to logfile: $!";
  print LOG $info . "\n";
  close LOG;
}

