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
our $datadir = "/var/spool/wirelessprint";
our $printqueuename = "patron_internet_printer";

require './include.pl';

our %format;
require './fileformatlist.pl';

if (not $auth::user) {
  print qq[Content-type: text/html\n\n
<html><head>
  <title>403 Forbidden</title>
</head><body>
  <p>You do not have permission to access this resource.</p>
</body></html>]; # If the user doesn't know about login.cgi (and isn't on the staff network), ispo facto they aren't authorized.
  $auth::user = $auth::user; # Suppress irrelevant "used only once" message.
  exit 0;
}

my $urec = getrecord("users", $auth::user);

my ($content, $refresh) = ("", undef);
my $title = getvariable("wirelessprint", "defaultpagetitle") || "Galion Wireless Printing";
# Default only; the actual print queue gets its own page-specific title, queuepagetitle;
# and likewise the job details view page has its own, jobpagetitle.

if ($input{action} eq "print") {
  $content = doprint();
} elsif ($input{action} eq "cancel") {
  $content = canceljob();
} elsif ($input{action} eq "uncancel") {
  $content = uncanceljob();
} elsif ($input{action} eq "viewjob") {
  $content = viewjob();
} elsif ($input{action} eq "previewjob") {
  $content = previewjob();
} else {
  $content = viewqueue();
}

print output($content,
             title => $title);

sub doprint {
  my ($jobid) = getnum("job");
  $jobid or return errordiv("Error: Job ID Needed", qq[I cannot print a job, without knowing which job to print.
    Showing the list of current jobs in the queue, instead.])
    . viewqueue();
  my ($j) = getrecord("printjob", $jobid);
  ref $j or return errordiv("Error:  Job Not Found", qq[I failed to find any record of print job # '$$j{id}']);
  return errordiv("Processing Needed", qq[Printjob #$$j{id} needs $$j{process} processing before it will be ready to print.])
    if $$j{process};
  my $filespec = catfile($datadir, $$j{filename});
  -e $filespec or return errordiv("Error: Job File is Lost",
                                  qq[I seem to have lost track of the file for print job # $$j{id}.  This is a server-side error
                                     and should be reported to the Computer Guy at the library.  Sorry.]);
  my $pdate = DateTime::Format::ForDB(DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York'));
  $$j{printdate} = $pdate;
  updaterecord("printjob", $j);
  my ($output, $lperr, $lpin) = ("", "", "");
  eval {
    local %ENV;
    $ENV{PATH} = $main::binpath{lppath};
    my @lp = ($main::binpath{lp}, "-d", $printqueuename, $filespec);
    run(\@lp, \$lpin, \$output, \$lperr);
  };
  return infodiv("Printing Now", qq[I have sent this job to the printer.  It should be printing very soon, if it hasn't already.
    <!-- lp stdout: $output -->
    <!-- lp stderr: $lperr -->])
    . viewjob();
}

sub uncanceljob {
  my ($jobid) = getnum("job");
  $jobid or return errordiv("Error: Job ID Needed", qq[I cannot uncancel a job, without knowing which job to uncancel.
    Showing the list of current jobs in the queue, instead.])
    . viewqueue();
  my ($j) = getrecord("printjob", $jobid);
  ref $j or return errordiv("Error:  Job Not Found", qq[I failed to find any record of print job # '$$j{id}']);
  $$j{canceldate} = undef;
  updaterecord("printjob", $j);
  return viewjob();
}
sub canceljob {
  my ($jobid) = getnum("job");
  my $cdate = DateTime::Format::ForDB(DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York'));
  $jobid or return errordiv("Error: Job ID Needed", qq[I cannot cancel a job, without knowing which job to cancel.
    Showing the list of current jobs in the queue, instead.])
    . viewqueue();
  my ($j) = getrecord("printjob", $jobid);
  ref $j or return errordiv("Error:  Job Not Found", qq[I failed to find any record of print job # '$$j{id}']);
  $$j{canceldate} = $cdate;
  updaterecord("printjob", $j);
  return viewjob();
}

sub previewjob {
  my ($jobid) = getnum("job");
  $jobid or return errordiv("Error: Job ID Needed", qq[I cannot preview a specific job, without knowing which job to preview.
    Showing the list of current jobs in the queue, instead.])
    . viewqueue();
  my ($j) = getrecord("printjob", $jobid);
  ref $j or return errordiv("Error:  Job Not Found", qq[I failed to find any record of print job # '$$j{id}']);
  if ($$j{process}) {
    my $name = encode_entities($$j{subject} || "");
    return errordiv("Error: Processing Required",
                    qq[Print Job # $$j{id}, <q>$name</q>, requires $$j{process} processing.]);
  }
  my $filespec = catfile($datadir, $$j{filename});
  -e $filespec or return errordiv("Error: File Lost", qq[I seem to have lost track of the file for print job # $$j{id}.
     This is a server-side error and should be reported to the Computer Guy at the library.]);
  open IN, "<", $filespec
    or return errordiv("Error:  Cannot Read File", qq[I seem to have lost access to the file for print job # $$j{id}.
     This isn't supposed to happen, is a server-side error, and should be reported to the Computer Guy at the library.]);
  local $/ = undef;
  my $contents = <IN>;
  close IN;
  my $ct = "application/pdf";
  if ($$j{srcformat} eq "postscript") {
    $ct = "application/postscript";
  } # Any other non-PDF format that we treat as directly printable, would need to be handled here, and in index.cgi as well.
  print qq[Content-type: $ct\n\n] . $contents;
  exit 0;
}

sub viewjob {
  my ($jobid) = getnum("job");
  $jobid or return errordiv("Error: Job ID Needed", qq[I cannot view a specific job, without knowing which job to view.
    Showing the list of current jobs in the queue, instead.])
    . viewqueue();
  my ($j) = getrecord("printjob", $jobid);
  ref $j or return errordiv("Error:  Job Not Found", qq[I failed to find any record of print job # <q>$$j{id}</q>]);
  $title = getvariable("wirelessprint", "jobpagetitle") || "Print Job Details - Galion Wireless Printing";
  my %e = map {
    $_ => encode_entities($$j{$_} || ""),
  } keys %$j;
  my $preview = "";
  if (not $$j{process}) {
    if ($$j{srcformat} eq "postscript") {
      $preview = qq[  <tr><th>Preview</th>
      <td><a href="queue.cgi?action=previewjob&amp;job=$$j{id}">Click here to open this PostScript file</a></td></tr>]
    } else {
      $preview = qq[  <tr><th>Preview</th>
      <td><a href="queue.cgi?action=previewjob&amp;job=$$j{id}">Click here to open this print job as a PDF</a></td></tr>];
    }
  }
  my $mailfields = "";
  my $jobname    = "Job Name";
  if ($$j{flags} =~ /E/) {
    $mailfields = qq[<tr><th>SMTP Sender</th>
      <td>$e{smtpsender}</td></tr>
  <tr><th>email From</th>
      <td>$e{emailfrom}</td></tr>];
    $jobname = "Subject";
  }
  return qq[<div class="h">Print Job Details:</div>
  <table class="table viewprintjob"><tbody>
  <tr><th>Job ID</th>
      <td>$e{id}</td></tr>
  <tr><th>Patron</th>
      <td>$e{patron}</td></tr>
  <tr><th>Source IP Address</th>
      <td>$e{ipaddress}</td></tr>
  $mailfields
  <tr><th>$jobname</th>
      <td>$e{subject}</td></tr>
  <tr><th>Source Format</th>
      <td>$e{srcformat}</td></tr>
  <tr><th>Original Filename</th>
      <td>$e{origfilename}</td></tr>
  <tr><th>Current Filename</th>
      <td>$e{filename}</td></tr>
  <tr><th>Submit Date</th>
      <td>$e{submitdate}</td></tr>
  <tr><th>Print Date</th>
      <td>$e{printdate}</td></tr>
  <tr><th>Cancel Date</th>
      <td>$e{canceldate}</td></tr>
  <tr><th>View Key</th>
      <td>$e{viewkey}</td></tr>
  <tr><th>Processing Needed</th>
      <td>$e{process}</td></tr>
  <tr><th>Notes</th>
      <td>$e{notes}</td></tr>
  <tr><th>Page Count</th>
      <td>$e{pages}</td></tr>
  <tr><th>Flags</th>
      <td>$e{flags}</td></tr>
  $preview
</tbody></table>
<div><span class="navbutton"><a href="queue.cgi?action=viewqueue">Show Print Queue</a></span></div>
];
}

sub viewqueue {
  my @job;
  my $title    = "Print Queue";
  my $admin    = ($$urec{flags} =~ /A/) ? 1 : 0;
  my $today    = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York'
                              )->subtract( hours => 4 );
  my $midnight = DateTime::Format::ForDB(DateTime->new( time_zone => $main::dbconfig{timezone} || 'America/New_York',
                                                        year      => $today->year(),
                                                        month     => $today->month(),
                                                        day       => $today->mday()));
  $title = getvariable("wirelessprint", "queuepagetitle") || "Print Job Queue - Galion Wireless Printing";
  if ($input{showprinted}) {
    if ($admin and $input{showpast}) { # TODO: support specifying a date range.
      $title = "Printed Jobs";
      @job = findnotnull("printjob", "printdate");
    } else {
      $title = "Recently Printed Jobs";
      @job = findgreater("printjob", "printdate", $midnight);
    }
  } else {
    @job = findnull("printjob", "printdate");
  }
  if ($input{showcanceled}) {
    if ($admin and $input{showpast}) { # TODO: support specifying a date range.
      $title = "Canceled Jobs";
      @job = grep { $$_{canceldate} } @job;
    } else {
      $title = "Recently Canceled Jobs";
      @job = grep { $$_{canceldate} ge $midnight } @job;
    }
  } else {
    @job = grep { not $$_{canceldate} } @job;
  }
  my $navbar = qq[<div>
      ] . (($input{showprinted} or $input{showcanceled}) ? qq[<span class="navbutton"><a href="queue.cgi?action=viewqueue">Show Print Queue</a></span>] : "") . qq[
      ] . (($input{showprinted})  ? "" : qq[<span class="navbutton"><a href="queue.cgi?action=viewqueue&amp;showprinted=1">Show Printed</a></span>]) . qq[
      ] . (($input{showcanceled}) ? "" : qq[<span class="navbutton"><a href="queue.cgi?action=viewqueue&amp;showcanceled=1">Show Canceled</a></span>]) . qq[
      ] . (($admin and ($input{showprinted} || $input{showcanceled}))
           # TODO: past week / month / quarter / year, or some such jazz
           ? qq[<span class="navbutton"><a href="queue.cgi?action=viewqueue&amp;showprinted=] . ($input{showprinted} || "") . qq[&amp;showcanceled=] . ($input{showcanceled} || "") . qq[&amp;showpast=1">Show Past</a></span>] : "") . qq[
  </div>];
  if (not scalar @job) {
    return qq[<div class="printjobqueue">$title is an Empty List</div>] . $navbar;
  }
  return qq[<div class="printjobqueue"><table class="table">
  <thead>
    <tr><th>Action</th><th>Status</th><th>Print Job</th><th>Hold For</th><th>Format (as submitted)</th><th class="numeric">Pages</th>
        <th>Submitted</th><th>Notes</th></tr>
  </thead><tbody>
    ] . (join "\n    ", map {
      my $j = $_;
      my $name   = encode_entities($$j{subject} || qq[untitled job $$j{id}]);
      my $patron = encode_entities($$j{patron}) || qq[unknown patron, $$j{ipaddress}];
      my $fmt    = $format{$$j{srcformat}} || +{ shortdesc => "[Unknown Format]", id => 0 };
      my $fmtnam = $$fmt{shortdesc} || $$fmt{label} || $$j{srcformat};
      my $status = ($$j{canceldate})
        ? ('Canceled ' . friendlydate($$j{canceldate}) . (($$j{flags} =~ /U/) ? " by the submitter" : ""))
        : ($$j{printdate}) ? 'Printed ' . friendlydate($$j{printdate})
                           : ($$j{process}) ? "Processing ($$j{process})" : "Ready";
      my $submitted = friendlydate($$j{submitdate}) .
        (($$j{flags} =~ /E/) ? " via email" :
         ($$j{flags} =~ /W/) ? " via web form" :
         "");
      my ($statusclass) = (lc $status) =~ /^(\w+)/;
      my $notes = encode_entities($$j{notes});
      my @action;
      my $pagecount = "??";
      if ($statusclass eq "ready") {
        push @action, qq[<span class="actionbutton"><a href="queue.cgi?action=print&amp;job=$$j{id}">Print</a></span>];
        $pagecount = $$j{pages} || getpagecount($$j{filename});
        if (not ($$j{pages} == $pagecount)) {
          $$j{pages} = $pagecount;
          updaterecord("printjob", $j);
        }
      } elsif ($statusclass eq "printed") {
        push @action, qq[<span class="actionbutton"><a href="queue.cgi?action=print&amp;job=$$j{id}">Print Another Copy</a></span>];
      } elsif ($statusclass eq "canceled") {
        push @action, qq[<span class="actionbutton"><a href="queue.cgi?action=uncancel&amp;job=$$j{id}">Uncancel</a></span>];
      }
      if ($statusclass ne "canceled") {
        push @action, qq[<span class="actionbutton"><a href="queue.cgi?action=cancel&amp;job=$$j{id}">Cancel</a></span>];
      }
      qq[<tr class="$statusclass">
             <td>@action</td>
             <td>$status</td>
             <td><a href="queue.cgi?action=viewjob&amp;job=$$j{id}">$name</a></td>
             <td>$patron</td>
             <td>$fmtnam</td>
             <td class="numeric">$pagecount</td>
             <td>$submitted</td>
             <td>$notes</td>
         </tr>]
    } @job) . qq[
  </tbody></table>
  </div>
  $navbar];
}


sub getpagecount {
  my ($filename) = @_;
  my $filespec = catfile($datadir, $filename);
  return qq[<abbr class="error" title="Error: File Missing from Server Storage">??*</abbr>]
    if not -e $filespec;
  my $pagecount;
  eval {
    use PDF::Tiny;
    my $pdf = PDF::Tiny->new($filespec);
    $pagecount = $pdf->page_count;
  };
  warn "Failed to get page count due to PDF::Tiny error." if $@ and not $pagecount;
  return $pagecount;
}

#sub getpagecount {
#  my ($filename) = @_;
#  my $filespec = catfile($datadir, $filename);
#  return qq[<abbr class="error" title="Error: File Missing from Server Storage">??*</abbr>]
#    if not -e $filespec;
#  use PDF;
#  my $pdf = PDF->new();
#  my $result; eval {
#    $result = $pdf->TargetFile( $filespec );
#  };
#  carp("PDF TargetFile failed ($@), result $result")
#    if $@;
#  return qq[<abbr class="error" title="Error: File is not a PDF">??*</abbr>]
#    if not $pdf->IsaPDF();
#  my $pagecount; eval {
#    $pagecount = $pdf->Pages;
#  };
#  carp("Failed to get page count: $@") if $@;
#  return $pagecount;
#}
