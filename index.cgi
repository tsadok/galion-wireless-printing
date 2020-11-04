#!/usr/bin/perl -wT
# -*- cperl -*-

use strict;
use DateTime;
use HTML::Entities;
use File::Spec::Functions;
use Data::Dumper;
our (%input, $authbox, $timezone);
require './include.pl';

our $datadir = getvariable("wirelessprint", "datadir") || "/var/spool/wirelessprint";

our %format;
require './fileformatlist.pl';

my ($content, $refresh) = ("", undef);
my $title = getvariable("wirelessprint", "defaultpagetitle") || "Galion Wirless Printing";

if ($input{action} eq "upload") {
  $content = uploadjob();
} elsif ($input{action} eq "checkstatus") {
  $content = checkstatus();
} elsif ($input{action} eq "preview") {
  $content = preview();
} elsif ($input{action} eq "cancel") {
  $content = cancel();
} elsif ($input{action} eq "uncancel") {
  $content = uncancel();
} else {
  $content = blankform();
}

print output( $content,
              title       => $title,
              headmarkup  => $refresh,
            );
exit 0;

sub blankform {
  return showform();
}

sub newviewkey {
  my @c = ("a" .. "k", "m" .. "z", 2 .. 9);
  return "PJ" . join("", map { $c[rand @c] } 1 .. 17) . "X";
}

sub uploadjob {
  my $filecontent = $input{filetoprint_file_contents};
  $filecontent or return errordiv("Error: Nothing Uploaded",
                                  qq[There was no file content uploaded.  This can happen if you forget to select a file to upload,
                                     or if the file you select is empty, or if your computer will not allow you to read it.])
    . showform(%input);
  my $now = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York');
  my $fmt = $format{$input{srcformat}};
  ref $fmt or return errordiv("Error: Format Not Specified", qq[You must select the file format that indicates what format your file is in.])
    . showform(%input);
  my $filename = ($now->year()
                  . "_" . sprintf("%02d%02d", $now->month, $now->mday)
                  . "_" . sprintf("%02d%02d%02d", $now->hour(), $now->minute, $now->second())
                  . "_" . sprintf("%04d", ($$ % 9967))
                 );
  my $filespec = catfile($datadir, $filename . "." . $$fmt{extension});
  while (-e $filespec) {
    $filename++;
    $filespec = catfile($datadir, $filename . "." . $$fmt{extension});
  }
  open FILE, ">", $filespec
    or return errordiv("Server-Side Error: Failed to Save File",
                       qq[Oh, dear.  Something has gone horribly wrong on my end, and I find that I am unable to save a copy
                          of the file you uploaded.  Unfortunately, that means I won't have a copy to send to the printer.
                          We will need to get the computer guy to look into it.  Sorry.],
                       warn("Failed to write '$filespec': $!")
                      );
  binmode FILE;
  print FILE $filecontent;
  close FILE;

  my $vk  = newviewkey();
  my $rec = +{
              ipaddress    => $ENV{REMOTE_ADDR},
              patron       => $input{patron} || "Anonymous Coward",
              subject      => $input{subject} || "Untitled Print Job",
              srcformat    => $input{srcformat},
              origfilename => $input{filetoprint},
              filename     => $filename . "." . $$fmt{extension},
              submitdate   => DateTime::Format::ForDB($now),
              viewkey      => $vk,
              process      => $$fmt{handler},
              flags        => "W", # Submitted via web form.
             };
  addrecord("printjob", $rec);
  my $recid = $db::added_record_id;
     $recid = $db::added_record_id; # Suppress "used only once" warning.  (The real other use is in db.pl, but the warning ignores include files.)
  my $checkurl = qq[index.cgi?action=checkstatus&amp;printjob=$recid&amp;view=$vk];
  $refresh = qq[<meta http-equiv="refresh" content="1; url=$checkurl" />];
  return infodiv("File Uploaded",
                 qq[<a href="$checkurl">Click here to check the status of your print job.</a>]);
}

sub uncancel {
  setcanceldate("uncancel", undef);
}
sub cancel {
  my $now = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York');
  setcanceldate("cancel", DateTime::Format::ForDB($now));
}

sub setcanceldate {
  my ($action, $canceldate) = @_;
  my $id = getnum("printjob");
  return errordiv("Need Printjob ID",
                  qq[I am sorry, but I cannot $action the status of a print job, without its ID number.]) if not $id;
  my $pj = getrecord("printjob", $id);
  return errordiv("Printjob Not Found",
                  qq[I am sorry, but i have no record of a print job with ID number '$input{printjob}'.])
    if not ref $pj;
  my $vk = $input{view};
  return errordiv("Cannot " . ucfirst($action) . " Print Job",
                  qq[Sorry, but I cannot change the cancel date of print job number '$id'])
    if ($vk ne $$pj{viewkey});
  $$pj{canceldate} = $canceldate;
  $$pj{flags} =~ s/U//; $$pj{flags} .= "U";
  updaterecord("printjob", $pj);
  return checkstatus();
}

sub preview {
  my $id = getnum("printjob");
  return errordiv("Need Printjob ID",
                  qq[I am sorry, but I cannot check the status of a print job, without its ID number.]) if not $id;
  my $pj = getrecord("printjob", $id);
  return errordiv("Printjob Not Found",
                  qq[I am sorry, but i have no record of a print job with ID number '$input{printjob}'.])
    if not ref $pj;
  my $vk = $input{view};
  return errordiv("Cannot View Print Job",
                  qq[Sorry, but I cannot tell you anything about print job number '$id'])
    if ($vk ne $$pj{viewkey});
  return errordiv("Job Not Ready",
                  qq[This print job still requires processing.  It is not ready to preview or print yet.])
    if $$pj{process};
  my $filespec = catfile($datadir, $$pj{filename});
  return errordiv("File Lost",
                  qq[Oh, dear, I seem to have lost track of the actual file for print job $$pj{id}.
                     This is a bug and should be reported to the computer guy at the library.
                     He will probably need the job ID number, $$pj{id}, in order to figure out what went wrong.])
    if not -e $filespec;
  open FILE, "<", $filespec
    or return errordiv("Cannot Read File",
                       qq[Oh, dear, I can't seem to read my stored copy of the file for print job $$pj{id}.
                          This is a bug and should be reported to the computer guy at the library.
                          He will probably need the job ID number, $$pj{id}, in order to figure out what went wrong.]);
  my $ctype = "application/pdf";
  if ($$pj{srcformat} eq "postscript") { $ctype = "application/postscript"; }
  # Any other non-PDF format that we treat as directly printable, would likewise need to be handled here, and in queue.cgi as well.
  local $/ = undef;
  my $contents = <FILE>;
  close FILE;
  print qq[Content-type: $ctype\n\n] . $contents;
  exit 0;
}

sub checkstatus {
  my $id = getnum("printjob");
  return errordiv("Need Printjob ID",
                  qq[I am sorry, but I cannot check the status of a print job, without its ID number.]) if not $id;
  my $vk = $input{view};
  my $pj = getrecord("printjob", $id);
  return errordiv("Printjob Not Found",
                  qq[I am sorry, but i have no record of a print job with ID number '$input{printjob}'.])
    if not ref $pj;
  return errordiv("Cannot View Print Job",
                  qq[Sorry, but I cannot tell you anything about print job number '$id'])
    if ($vk ne $$pj{viewkey});
  my %e = map { $_ => encode_entities($$pj{$_}) } keys %$pj;
  my $subdate = friendlydate($$pj{submitdate});
  my $submethod = ($$pj{flags} =~ /E/) ? "by email"
    : ($$pj{flags} =~ /W/) ? "via web form"
    # TODO: other submission methods?
    : "";
  my $fmt = $format{$$pj{srcformat}}{shortdesc} || $format{$$pj{srcformat}}{label} || $$pj{srcformat} || "[Error: Format Unknown]";
  my ($status, $statusnote, $subjobs) = getjobstatus($pj);
  my $notes = ($$pj{notes}) ? qq[<tr><th>Notes:</th>
         <td>$$pj{notes}</td></tr>] : "";
  $title = getvariable("wirelessprint", "jobpagetitle") || "Print Job Status - Galion Wirless Printing";
  return qq[<table class="viewprintjob"><tbody>
     <tr><th>Job ID #</th>
         <td>$$pj{id}</td></tr>
     <tr><th>Submitted:</th>
         <td>$subdate $submethod</td></tr>
     <tr><th>Hold For:</th>
         <td>$e{patron}</td></tr>
     <tr><th>Job Name:</th>
         <td>$e{subject}</td></tr>
     <tr><th>Format:</th>
         <td>$fmt</td></tr>
     <tr><th>Status:</th>
         <td>$status</td></tr>
     $notes
     $subjobs
  </tbody></table>\n
  <div class="p">$statusnote</div>
  <div>&nbsp;</div>
  <div><a href="index.cgi">Submit another print job.</a></div>];
}

sub getjobstatus {
  my ($job) = @_;
  my ($status, $statusnote, $subjobs) = ("", "", "");
  if ($$job{printdate}) {
    $status = "Printed " . friendlydate($$job{printdate});
    $statusnote = qq[The job has been released to the printer already.
        If you have not yet done so, please stop by the main desk and pick it up.];
  } elsif ($$job{canceldate}) {
    if ($$job{flags} =~ /P/) {
      $status = "Divided " . friendlydate($$job{canceldate});
      $statusnote = qq[This print job has been divided into one or more subjobs.
          This happens when you submit a job in a container format that gathers multiple files together into one, such as MIME multipart email.];
      $subjobs = qq[<tr><th>Subjobs:</th>\n         <td>] . list_subjobs($job) . qq[</td></tr>];
    } else {
      $status = "Canceled " . friendlydate($$job{canceldate});
      if ($$job{flags} =~ /U/) {
        $statusnote = qq[You canceled this print job yourself.
        If you have changed your mind, you can <a href="index.cgi?action=uncancel&amp;printjob=$$job{id}&amp;view=$input{view}">uncancel it</a>.];
      } else {
        $statusnote = qq[This print job has been canceled.
        If you think it should not have been canceled, please stop by the main desk and discuss it with the library staff.];
      }
    }
  } elsif ($$job{process}) {
    $status = "Processing";
    $statusnote = qq[This print job requires some processing, before it will be ready to print.
        This happens if the file submitted is in a format that the printer cannot natively handle,
             or does not natively handle particularly well.
        Our processing software is working on converting it to a more printable format.
        You can refresh this page after a few minutes to see if it is ready to print yet.
        <span class="explan">(You can bypass this step for future print jobs by submitting them in PDF format.)
        You can also <a href="index.cgi?action=cancel&amp;printjob=$$job{id}&amp;view=$input{view}">Cancel This Job</a>.</span>
        ];
  } else {
    $status = "Ready";
    $statusnote = qq[<strong>This print job is ready to be printed and claimed.</strong>
        ] . ($$job{viewkey} ? qq[<a href="index.cgi?action=preview&amp;printjob=$$job{id}&amp;view=$$job{viewkey}">You can download a preview of your print job by clicking here.</a>] : '') . qq[
        Please stop by the main desk and ask the library staff to release it to the printer for you.
        <span class="explan">You can also <a href="index.cgi?action=cancel&amp;printjob=$$job{id}&amp;view=$input{view}">Cancel This Job</a>.</span>];
  }
  return ($status, $statusnote, $subjobs);
}

sub list_subjobs {
  my ($parent) = @_;
  my @sj = findrecord("printjob", "parentjob", $$parent{id});
  if (scalar @sj) {
    my $pn = 0;
    return qq[<div class="subjoblist"><ol>
       ] . (join "\n       ", map {
         my $j = $_;
         $pn++;
         my $jobname = "Part $pn";
         my ($status, $statusnote, $subjobs) = getjobstatus($j);
         my $sj = $subjobs ? qq[<div><table><tbody>$subjobs</tbody></table></div>] : "";
         qq[<li><a href="index.cgi?action=checkstatus&amp;printjob=$$j{id}&amp;view=$$j{viewkey}">$jobname</a> - $status $statusnote
                $sj</li>]
       } @sj) . qq[</ol></div>];
  } else {
    return errordiv("Error: Subjobs Not Found", qq[That's strange.  I can't seem to find any subjobs.]);
  }
}

sub showform {
  my (%i) = @_;
  my %e = map { $_ => encode_entities($i{$_}) } keys %i;
  $e{subject} ||= "Untitled Print Job";
  $e{patron}  ||= "";
  my @format = grep {
    not $format{$_}{noui}
  } map {
    [ $_ => $format{$_}{label} ]
  } sort {
    $format{$a}{sort} <=> $format{$b}{sort}
  } keys %format;
  my $fmt = buildselect("srcformat",
                        [#["" => ""],
                         @format ],
                        ($i{srcformat} || ""), "srcformat");
  $title = getvariable("wirelessprint", "uploadformtitle") || "Print Job Upload - Galion Wirless Printing";
  my $where    = getvariable("wirelessprint", "wheretopickup") || "our main desk";
  my $we       = getvariable("wirelessprint", "we") || "our staff";
  my $media    = getvariable("wirelessprint", "supportedmedia") || "letter sized paper and black toner";
  my $pagesize = getvariable("wirelessprint", "pagesize");
  my $price    = getvariable("wirelessprint", "price")
    || "500 zorkmids per page"; # No way am I defaulting this to a real-world dollar value.  Configure it in your DB.
  return qq[<form class="uploadform" action="index.cgi" method="post" enctype="multipart/form-data">
     <input type="hidden" name="action" value="upload" />
     <div class="h">GPL Print Job Upload:</div>
     <div class="p">Upload your print job here; pick it up from $where.</div>
     <table><tbody>
         <tr><th><label for="patron">Your Name:</label></th>
             <td><input type="text" name="patron" id="patron" size="30" value="$e{patron}" /></td>
             <td class="explan">so $we know who to give it to</td></tr>
         <tr><th><label for="subject">Print Job Name:</label></th>
             <td><input type="text" name="subject" id="subject" size="30" value="$e{subject}" /></td>
             <td class="explan">another way to identify which print job is which</td></tr>
         <tr><th><label for="srcformat">File Format:</label></th>
             <td>$fmt</td>
             <td class="explan">what kind of file you want to print; several formats are supported</td></tr>
         <tr><th>Page Size:</th>
             <td>$pagesize</td></tr>
         <tr><th><label for="filetoprint">File to Print:</label></th>
             <td><input type="file" id="filetoprint" name="filetoprint" /></td>
             <td class="explan">the file itself, that you want printed</td></tr>
     </tbody></table>
     <input type="submit" value="Upload" />
  </form>
  <div class="p">Instructions:<ul>
      <li>Fill out the above form and click the Upload button.</li>
      <li>Go to $where to claim your print job.
          ] . ucfirst($we) . qq[ will release it to the printer for you.</li>
      <li>The printer only supports $media.</li>
      <li>Print jobs are $price.</li>
  </ul></div>]
}
