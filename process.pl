#!/usr/bin/perl -wT
# -*- cperl -*-

use strict;
use DateTime;
use HTML::Entities;
use File::Spec::Functions;
use Data::Dumper;
use Encode;
use Encode::Byte; # Needed for cp437
use Image::Magick;
use Email::MIME;
use Carp;
use IPC::Run qw(run);

our (%input, $authbox, $timezone);
require "./db.pl";
our $datadir = getvariable("wirelessprint", "datadir") || "/var/spool/wirelessprint";
our $logdir  = getvariable("wirelessprint", "logdir")  || "/var/log/wirelessprint";
our $logfile = getvariable("wirelessprint", "process_logfile") || catfile($logdir, "process.log");
our $dflog   = getvariable("wirelessprint", "autodetect_fail_logfile") || catfile($logdir, "autodetect-fail.log");
our $myuser  = getvariable("wirelessprint", "datafile_owner") || "www-data";
our $mygroup = getvariable("wirelessprint", "datafile_group") || "www-data";

our %jobflag = ( E => "email-submitted",
                 F => "Format-autodetected",
                 M => "MIME part",
                 P => "Parent job, processing farmed out to subjobs",
                 S => "Subjob, handling processing of a component part from a parent job",
                 U => "User-canceled: this job was canceled by the patron who submitted it",
                 W => "Webform-submitted",
               );

our %format;
require './fileformatlist.pl';

require './include.pl';
my $now = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' );
my $repeat = $now->clone()->add(seconds => 30);

doprocess();
my $n = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' );
if ($n lt $repeat) {
  while ($n lt $repeat) {
    sleep 2;
    $n = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' );
  }
  doprocess();
}

sub doprocess {
  logit("Processing started " . $now->ymd() . " " . $now->hms() . ".");
  my @job = grep { $$_{process} and not $$_{canceldate} } findnull("printjob", "printdate");
  logit("" . @job . " jobs need processing.");

  for my $j (@job) {
    if (getlock($j)) {
      processjob($j);
    } else {
      logit("job $$j{id} is locked, skipping for now.");
    }
    my $n = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' );
    if ($n gt $now->clone()->add( minutes => 2 )) {
      logit("process $$ has been running for over 2 minutes; exiting.");
      exit 0;
    }
  }
  my $n = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' );
}

sub getlock {
  my ($job) = @_;
  my ($j) = getrecord("printjob", $$job{id}); # Get most up-to-date record.
  if ($$j{proclockps} eq $$) {
    # We already have the lock.  Good.
    return $j;
  } elsif ($$j{proclockps}) {
    # Someone else has the lock.
    my $dt = DateTime::From::DB($$j{proclockdt});
    my $expires = $dt->clone()->add(minutes => 5);
    if ($expires lt $now) {
      # If the lock is old, kill it and let the next process get a new lock.
      killprocess($$j{proclockps});
      unlock($j);
    }
    return;
  }
  # Job not already locked.  Attempt to get the lock, wait, and then retest whether we have the lock:
  $$j{proclockps} = $$;
  $$j{proclockdt} = DateTime::Format::ForDB(DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' ));
  updaterecord("printjob", $j);
  sleep 3;
  return getlock($j);
}

sub unlock {
  my ($j) = @_;
  logit("Unlocking and saving job $$j{id}");
  $$j{proclockps} = undef;
  $$j{proclockdt} = undef;
  if ($$j{id}) {
    updaterecord("printjob", $j);
  } else { # This can happen due to MIME multi-part messages.
    addrecord("printjob", $j);
  }
}

sub killprocess {
  my ($psid) = @_;
  local %ENV;
  $ENV{PATH} = $main::binpath{killpath};
  system($main::binpath{kill}, "-9", $psid);
}

sub processjob {
  my ($job) = @_;
  my ($j) = getrecord("printjob", $$job{id}); # Get most up-to-date record.
  if ($$j{process}) {
    logit("job id $$j{id} needs $$j{process} processing");
    if ($$j{process} eq "auto") {
      autodetect($j);
    } elsif ($$j{process} eq "text") {
      processtext($j);
    } elsif ($$j{process} eq "html") {
      processhtml($j);
    } elsif ($$j{process} eq "image") {
      processimage($j);
    } elsif ($$j{process} eq "imgfmt") {
      processimageformat($j);
    } elsif ($$j{process} eq "msoffice") {
      processofficeformat($j);
    } elsif ($$j{process} eq "openoffice") {
      processofficeformat($j);
    } elsif ($$j{process} eq "email") {
      processemail($j);
    } elsif ($$j{process} eq "compression") {
      processcompression($j);
    } elsif ($$j{process} eq "archive") {
      processarchive($j);
    } else {
      error($j, qq[Unknown handler: '$$j{process}'],
            qq[don't know how to do '$$j{process}' processing]);
    }
  } else {
    logit("job $$j{id} seems to have already been processed.");
  }
}

sub error {
  my ($job, $logtext, $note) = @_;
  logit(" ! $logtext");
  $$job{notes} = join(" ", grep { $_ } ($$job{notes},
                                      qq[Processing Error: $note.  Canceling job.]));
  $$job{canceldate} = DateTime::Format::ForDB(DateTime->now(time_zone => $main::dbconfig{timezone} || "America/New_York"));
  unlock($job); # This also saves it.
}

sub autodetect {
  my ($job) = @_;
  my $filespec = catfile($datadir, $$job{filename});
  my (@cmd) = ($main::binpath{file}, $filespec);
  my ($input, $output, $error) = ("", "", "");
  {
    local %ENV;
    $ENV{PATH} = $main::binpath{filepath} || undef;
    run(\@cmd, \$input, \$output, \$error);
  }
  my ($fspec, $info) = split(/[:]\s*/, $output, 2);
  my ($fmt, @detail) = split(/,\s*/, $info, 2);
  if ($fmt =~ /^PDF/) {
    detected($job, "adobepdf", undef);
  } elsif ($fmt =~ /^PostScript/) {
    detected($job, "postscript", undef);
  } elsif ($fmt =~ /^UTF-8 Unicode text/) {
    detected($job, "plaintext", "text");
  } elsif ($fmt =~ /^ASCII text/) {
    detected($job, "plaintext", "text");
  } elsif ($fmt =~ /^ISO-8859 text/) {
    detected($job, "latinone", "text");
  } elsif ($fmt =~ /^Non-ISO extended-ASCII text/) {
    # We have to just guess at the encoding.  Best guess:
    detected($job, "cp437", "text");
  } elsif ($fmt =~ /^HTML document/) {
    detected($job, "html", "html");
  } elsif ($fmt =~ /^PNG image data/) {
    detected($job, "png", "image");
  } elsif ($fmt =~ /^JPEG image data/) {
    detected($job, "jpg", "image");
  } elsif ($fmt =~ /^GIF image data/) {
    detected($job, "gif", "image");
  } elsif ($fmt =~ /^SVG Scalable Vector Graphics image/) {
    detected($job, "svg", "image");
  } elsif ($fmt =~ /^PC bitmap/) {
    detected($job, "bmp", "imgfmt");
  } elsif ($fmt =~ /^GIMP XCF image data/) {
    detected($job, "xcf", "imgfmt");
  } elsif ($fmt =~ /image data/) {
    detected($job, "bmp", "imgfmt");
  } elsif ($fmt =~ /OpenDocument Text/) {
    detected($job, "writer", "openoffice");
  } elsif ($fmt =~ /OpenDocument/) {
    # Honestly, I don't really care which OO.o format is which here,
    # we're gonna do the same thing with them all anyway.
    detected($job, "oocalc", "openoffice");
  } elsif ($fmt =~ /Composite Document File/) {
    # Likewise, don't really need to know _which_ MS Office format this is.
    detected($job, "msword", "msoffice");
  } elsif ($fmt =~ /Rich Text Format/) {
    detected($job, "rtf", "msoffice");
  } elsif ($fmt =~ /Microsoft Word/) {
    detected($job, "mswordx", "msoffice");
  } elsif ($fmt =~ /^Microsoft/) {
    # Again, this could also be one of the other OOXML formats, but that isn't important.
    detected($job, "excelx", "msoffice");
  } elsif ($fmt =~ /^gzip compressed data/) {
    detected($job, "gz", "compression");
  } elsif ($fmt =~ /^bzip2 compressed data/) {
    detected($job, "bz2", "compression");
  } elsif ($fmt =~ /^XZ compressed data/) {
    detected($job, "xz", "compression");
  } elsif ($fmt =~ /^Zip archive data/) {
    detected($job, "zip", "archive");
  } elsif ($fmt =~ /^POSIX tar archive/) {
    detected($job, "tar", "archive");
  } else {
    logit("Format auto-detection failed (job $$job{id}, filename $$job{filename}).");
    dflog($$job{filename});
    error($job, "Format auto-detection failed.",
          qq[Failed to automatically detect this file's format.  You may need to select the format from the drop-down list when uploading the file.]);
  }
}

sub detected {
  my ($j, $format, $processneeded) = @_;
  $$j{process} = $processneeded;
  $$j{notes} = join "\n", grep { $_ } ($$j{notes}, "Format detected: $format");
  $$j{srcformat} = $format;
  $$j{flags} =~ s/F//g; $$j{flags} = "F" . $$j{flags}; # Format-autodetected
  unlock($j); # This also saves it.
}

sub processemail {
  my ($job) = @_;
  my $filespec   = catfile($datadir, $$job{filename});
  open MAIL, "<", $filespec
    or return error($job, "failed to read saved mail file for job $$job{id}",
                    qq[Failed to open $filespec: $!]);
  logit("processing job $$job{id} as email");
  my ($message, $mime);
  eval { local $/ = undef;
         $message = <MAIL>;
         close MAIL;
         $mime = Email::MIME->new($message);
       };
  return error($job, "MIME processing error",
               "Email::MIME failed to parse, or we failed to read, the message from job $$job{id}: $@")
    if $@;
  process_mime_part($job, $mime);
}

sub process_mime_part {
  my ($job, $part, $partnum) = @_;
  my $ct = $part->content_type;
  my @sp = $part->subparts;
  logit("MIME processing, job $$job{id}, content type $ct, has " . @sp . " subparts.");
  if (scalar @sp) {
    my $spcount = 0;
    my @sj;
    for my $subpart (@sp) {
      $spcount++; logit("Subpart $spcount of " . @sp . " (for job $$job{id}):");
      my $newjob = +{ map {
        $_ => $$job{$_}
      } keys %$job };
      $$newjob{id} = undef;
      $$newjob{parentjob} = $$job{id};
      $$newjob{flags} =~ s/S//g;
      $$newjob{flags} .= "S"; # Subjob
      logit("Enqueued subjob $spcount");
      push @sj, [$newjob, $subpart, $spcount];
    }
    for (@sj) {
      my ($j, $sp, $pn) = @$_;
      logit("MIME processing for job $$job{id}, processing subjob $pn");
      process_mime_part($j, $sp, $pn);
      logit(" - finished processing subjob $pn from job $$job{id}.");
    }
    $$job{flags} =~ s/P//g;
    $$job{flags} .= "P"; # Finished processing, job no longer needed because subjobs.
    $$job{canceldate} = DateTime::Format::ForDB($now); # Cancel in this case stands in for, we farmed everything out to sub-jobs.
    unlock($job); # This also saves it.
    return;
  } else {
    my $charset = undef;
    if ($ct =~ m/^([^;]+);\s*charset=(.*?)\s*$/) {
      ($ct, $charset) = ($1, $2);
    }
    # TODO: actually take $charset into consideration, or at least verify whether the MIME module already handles it adequately.
    my ($fmt) = grep {
      my $f = $_;
      grep { $ct eq $_ } @{$format{$f}{mime} || +[]};
    } keys %format;
    if ($fmt) {
      logit("MIME processing, job $$job{id}, content type $ct corresponds to $fmt format.");
    } else {
      logit("Unrecognized content type: $ct; will attempt to autodetect for job $$job{id}, $$job{filename}");
      $fmt = "auto";
    }
    assign_mime_part_to_job($job, $part, $fmt, $partnum || 0);
    filepermissions($$job{filename}) if -e $$job{filename};
    return;
  }
}

sub assign_mime_part_to_job {
  my ($job, $part, $fmt, $mnum) = @_;
  my ($fname, $fspec) = ("", "");
  $mnum ||= 0;
  logit("Assigning MIME part ($fmt format) to job $$job{id}");
  $format{$fmt} or return error($job, "Unknown format: $fmt");
  while ((not $fname) or (-e $fspec)) {
    $fname = $$job{filename} . "_mime" . sprintf("%03d", $mnum) . "." . $format{$fmt}{extension};
    $fspec = catfile($datadir, $fname);
    $mnum++;
  }
  logit("Assigned MIME part will have filename $fname");
  logit("Decoding content.");
  my $content; eval {
    $content = $part->body;
  };
  if ($@ and not $content) {
    close OUT;
    logit("Error getting decoded content: $@");
    error($job, "Failed to decode content: $@");
  }
  logit("Attempting to write to $fspec");
  if (open OUT, ">", $fspec) {
    logit("Opened file.");
    binmode OUT;
    print OUT $content;
    close OUT;
    logit("Wrote file ($fspec).");
    filepermissions($fspec);
    $$job{srcformat} = $fmt;
    $$job{filename}  = $fname;
    $$job{process}   = $format{$fmt}{handler};
    my $label        = $format{$fmt}{shortdesc} || $format{$fmt}{label} || $fmt;
    $$job{notes}     = join "\n", (grep { $_ } ($$job{notes}, qq[Found MIME part in $label format.]));
    $$job{flags}     =~ s/M//g;
    $$job{flags}    .= "M";
    unlock($job); # This also saves it.
    return;
  } else {
    logit("Failed to write MIME part to file ($fspec): $!");
    return error($job, "failed to write MIME part to file",
                 qq[Cannot write to $fspec: $!]);
  }
}

sub processofficeformat {
  my ($job) = @_;
  my $filespec   = catfile($datadir, $$job{filename});
  my $newdirname = "workdir_" . $$job{id};
  my $newdirspec = catfile($datadir, $newdirname);
  my $namecnt    = 1;
  while (-e $newdirspec) {
    $namecnt++;
    $newdirname  = "workdir_" . $$job{id} . "_" . $namecnt;
    $newdirspec  = catfile($datadir, $newdirname);
  }
  mkdir $newdirspec;
  $ENV{PATH} = $main::binpath{officepath};
  my @cmd = ($main::binpath{openoffice}, "--headless", "--convert-to", "pdf", $filespec, "--outdir", $newdirspec);
  warn "system(@cmd)";
  system(@cmd);
  my (@pdf) = <$newdirspec/*.pdf>;
  if (scalar @pdf) {
    if (1 < scalar @pdf) {
      warn "libreoffice appears to have created " . @pdf . " PDF files.  Using the first one.";
    }
    my $pdfname    = $$job{filename} . ".pdf";
    my $pdfspec    = catfile($datadir, $pdfname);
    my $namecnt    = 1;
    while (-e $pdfspec) {
      $namecnt++;
      $pdfname    = $$job{filename} . "_" . $namecnt . ".pdf";
      $pdfspec    = catfile($datadir, $pdfname);
    }
    my $srcfile; ($srcfile) = $pdf[0] =~ m!([a-z0-9._-]+.pdf)$!;
    logit("Attempting to retrieve $srcfile from $newdirspec as $pdfspec");
    $ENV{PATH} = $main::binpath{mvpath};
    system($main::binpath{mv}, catfile($newdirspec, $srcfile), $pdfspec);
    $$job{filename} = $pdfname;
    $$job{process}  = undef;
    unlock($job); # This also saves it.
    rmdir($newdirspec); # This either works or it doesn't; e.g., if there were multiple PDFs created,
                        # I actually want to leave the extra ones there so I can investigate.
                        # But if the directory is empty, might as well clean up after ourselves.
  } else {
    warn "libreoffice failed to create a PDF file.";
  }
}

sub processhtml {
  my ($job) = @_;
  my $htmlspec = catfile($datadir, $$job{filename});
  my $pdfname  = $$job{filename} . ".pdf";
  my $pdfspec  = catfile($datadir, $pdfname);
  my $namecnt  = 1;
  while (-e $pdfspec) {
    $namecnt++;
    $pdfname = $$job{filename} . $namecnt . ".pdf";
    $pdfspec = catfile($datadir, $pdfname);
  }
  $ENV{PATH} = $main::binpath{pandocpath}; # This directory needed for wkhtmltopdf
  system($main::binpath{pandoc}, $htmlspec, "-t", "html", "-o", $pdfspec);
  if (-e $pdfspec) {
    $$job{filename} = $pdfname;
    $$job{process}  = undef;
    unlock($job); # This also saves the record.
  } else {
    error($job, "pandoc failed to create $pdfspec",
          qq[HTML processing step (pandoc) failed to create PDF]);
  }
}

sub processimageformat {
  my ($job) = @_;
  my $imgfile = catfile($datadir, $$job{filename});
  if (-e $imgfile) {
    my $m = new Image::Magick;
    $m->read($imgfile);
    my $pngfile = $$job{filename} . ".png";
    my $pngspec = catfile($datadir, $pngfile);
    my $namecnt = 1;
    while (-e $pngspec) {
      $namecnt++;
      $pngfile = $$job{filename} . "_" . $namecnt . ".png";
      $pngspec = catfile($datadir, $pngfile);
    }
    $m->Write($pngspec);
    $$job{filename} = $pngfile;
    $$job{process} = "image";
    unlock($job); # This also saves the record.
  } else {
    error($job, qq[File does not exist: $imgfile],
          qq[misplaced job file (this is a bug; please tell the computer guy)]);
  }
}

sub processimage {
  my ($job) = @_;
  my $imgfile = catfile($datadir, $$job{filename});
  if (-e $imgfile) {
    my $htmlfilename = $$job{filename} . ".html";
    my $htmlfilespec = catfile($datadir, $htmlfilename);
    my $attempt  = 1;
    while (-e $htmlfilespec) {
      $attempt++;
      $htmlfilename = $$job{filename} . "_" . $attempt . ".html";
      $htmlfilespec = catfile($datadir, $htmlfilespec);
    }
    my %e = map {
      $_ => encode_entities($$job{$_})
    } qw(subject);
    open HTML, ">", $htmlfilespec
      or return error($job, "failed to write $htmlfilename",
                      qq[internal storage error on the server, cannot write HTML version of your file]);
    print HTML qq[<html><head>
         <title>$e{subject}</title>
    </head><body>
         <center>
           <img width="95%" src="$imgfile" alt="[Failed: $imgfile]" />
         </center>
    </body></html>];
    close HTML;
    filepermissions($htmlfilespec);
    $$job{filename} = $htmlfilename;
    $$job{process}  = "html";
    unlock($job); # This also saves the record.
  } else {
    error($job, qq[File does not exist: $imgfile],
          qq[misplaced job file (this is a bug; please tell the computer guy)]);
  }
}

sub processtext {
  my ($job) = @_;
  my $infile = catfile($datadir, $$job{filename});
  if (-e $infile) {
    my $fmt = $format{$$job{srcformat}};
    $fmt or return error($job, qq[format unknown: $$job{srcformat}],
                         qq[can't figure out what format the print job file is in, sorry]);
    if (open IN, "<", $infile) {
      binmode IN;
      local $/ = undef;
      my $filecontent = <IN>;
      close IN;
      if ($$fmt{charset} and not ($$fmt{charset} =~ /utf.*8/i)) {
        my $characters; eval {
          $characters = decode($$fmt{charset}, $filecontent, Encode::FB_CROAK);
        };
        return error($job, "charset $$fmt{charset} decode error: $@",
                     qq[charset decoder failed to parse your file as $$fmt{charset}; maybe it is in a different character set?
                        if all else fails try the ASCII/UTF-8 setting, then instead of errors you will at worst get mojibake])
          if $@;
        eval {
          $filecontent = encode('UTF-8', $characters, Encode::FB_CROAK);
        };
        return error($job, "UTF-8 encode error: $@",
                     qq[charset encoder failed to encode your data as UTF-8; this is very strange and may represent a bug in our software])
          if $@;
      }
      my $newfn = $$job{filename} . ".html";
      my $htmlfilespec = catfile($datadir, $newfn);
      my $newnamecount = 1;
      while (-e $htmlfilespec) {
        $newnamecount++;
        $newfn = $$job{filename} . $newnamecount . ".html";
        $htmlfilespec = catfile($datadir, $newfn);
      }
      open HTML, ">", $htmlfilespec
        or return error($job, "failed to write $htmlfilespec",
                        qq[internal storage error on the server, cannot write HTML version of your file]);
      my %e = map {
        $_ => encode_entities($$job{$_})
      } qw(subject);
      print HTML qq[<html><head>
         <title>$e{subject}</title>
      </head><body>
         <pre>$filecontent</pre>
      </body></html>];
      close HTML;
      filepermissions($htmlfilespec);
      $$job{filename} = $newfn;
      $$job{process}  = "html";
      unlock($job); # This also saves the record.
    } else {
      error($job, qq[Cannot read $infile],
            qq[internal file permissions error on the server, please tell the computer guy]);
    }
  } else {
    error($job, qq[File does not exist: $infile],
          qq[misplaced job file (this is a bug; please tell the computer guy)]);
  }
}

sub processcompression {
  my ($job) = @_;
  my $fmt = $format{$$job{srcformat}};
  $fmt or return error($job, qq[format unknown: $$job{srcformat}],
                       qq[can't remember what format the compressed file is in, sorry]);
  my ($dfn, $cfn, $ext);
  $ext = $$fmt{extension};
  $cfn = $$job{filename};
  $dfn = $cfn; $dfn =~ s![.]$ext!!;
  my $cfspec = catfile($datadir, $cfn);
  my $dfspec = catfile($datadir, $dfn);
  while (($cfn ne ($dfn . "." . $ext)) or (-e $dfspec)
         or ((-e $cfspec) and ($cfn ne $$job{filename}))) {
    if ($dfn =~ m/(.*?)(\d+)[.](\w+)/) {
      my ($base, $num, $e) = ($1, $2, $3);
      $num++;
      $dfn  = sanitizefilename($base) . $num . "." . $e;
    } else {
      $dfn  = sanitizefilename($dfn);
      $dfn .= "_001.dat";
    }
    $cfn    = $dfn . "." . $ext;
    $cfspec = catfile($datadir, $cfn);
    $dfspec = catfile($datadir, $dfn);
  }
  if ($cfn ne $$job{filename}) {
    logit("processcompression(): job $$job{id}, filename is $$job{filename}, want to make it $cfn so it decompresses to $dfn");
    my $ospec = catfile($datadir, $$job{filename});
    eval {
      local %ENV;
      $ENV{PATH} = $main::binpath{mvpath};
      system($main::binpath{mv}, "-i", $ospec, $cfspec);
    };
    logit("File rename error.  mv says: $@") if $@;
    if (-e $cfspec) {
      $$job{filename} = $cfn;
      updaterecord("printjob", $job);
    } else {
      return error($job, qq[File rename failed.],
                   qq[Attempted to rename file from $$job{filename} to $cfn in preparation for decompression.  Failed]);
    }
  } else {
    logit("processcompression(): job $$job{id}, filename is ok: $$job{filename}");
  }
  ref $$fmt{extract} or return error($job, "Don't know how to uncompress.",
                                     qq[I don't know what extractor to use for $$fmt{label} compression.]);
  my @cmd = @{$$fmt{extract}};
  push @cmd, $cfspec;
  my ($input, $output, $error) = ("", "", "");
  eval {
    local %ENV;
    $ENV{PATH} = $main::binpath{uncompresspath} || "/bin:/usr/bin";
    run(\@cmd, \$input, \$output, \$error);
    logit("Decompressor finished for job $$job{id}");
    logit("STDOUT: $output");
    logit("STDERR: $error");
  };
  if (-e $dfspec) {
    logit("Successfully decompressed to $dfn");
    $$job{filename} = $dfn;
    $$job{process}  = "auto";
    unlock($job);
  } else {
    logit("Failed to uncompress $cfn");
    error($job, "Failed to uncompress: $@", "The uncompressor says: " . $error);
  }
}

sub processarchive {
  my ($job) = @_;
  my $fmt = $format{$$job{srcformat}};
  $fmt or return error($job, qq[format unknown: $$job{srcformat}],
                       qq[can't remember what format the compressed file is in, sorry]);
  my %archivedispatch =
    ( tar => +{ open => sub {
                  my ($tarball) = @_;
                  use Archive::Tar;
                  my $archive = Archive::Tar->new();
                  $archive->read($tarball);
                  return $archive;
                },
                listcontents => sub {
                  my ($archive) = @_;
                  return $archive->list_files();
                },
                makefilespec => sub {
                  my ($archive, $suggestedfilename) = @_;
                  my $filename = sanitizefilename($suggestedfilename);
                  my $retry    = 0;
                  my $newname  = $$job{id} . "_" . $filename;
                  my $newspec  = catfile($datadir, $newname);
                  while (-e $newspec) {
                    $retry++;
                    $newname = $$job{id} . "_" . $retry . "_" . $filename;
                    $newspec = catfile($datadir, $newname);
                  }
                  return ($newname, $newspec);
                },
                extractfile => sub {
                  my ($archive, $filename, $destination) = @_;
                  $archive->chown($filename, $myuser, $mygroup);
                  return $archive->extract_file($filename, $destination);
                },
              },
      zip => +{ open => sub {
                  my ($zipfile) = @_;
                  use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
                  my $archive = Archive::Zip->new();
                  my $result = $archive->read($zipfile);
                  if ($result == AZ_OK) {
                    return $archive;
                  } else {
                    logit("Archive::Zip failed to read $zipfile");
                    error($job, "Archive processing failed.",
                          "Archive::Zip failed to read the zipfile.");
                    return;
                  }
                }, listcontents => sub {
                  my ($archive) = @_;
                  return grep { not ($_->isDirectory() or $_->isSymbolicLink)
                              } $archive->members();
                },
                makefilespec => sub {
                  my ($archive, $member) = @_;
                  my $suggestedfilename = $member->fileName();
                  my $filename = sanitizefilename($suggestedfilename);
                  my $retry    = 0;
                  my $newname  = $$job{id} . "_" . $filename;
                  my $newspec  = catfile($datadir, $newname);
                  while (-e $newspec) {
                    $retry++;
                    $newname = $$job{id} . "_" . $retry . "_" . $filename;
                    $newspec = catfile($datadir, $newname);
                  }
                  return ($newname, $newspec);
                },
                extractfile => sub {
                  my ($archive, $member, $destination) = @_;
                  return $archive->extractMember($member, $destination);
                  # return $member->extractToFileNamed($destination); # should also work.
                },
              },
    );
  my $ad = $archivedispatch{$$job{srcformat}};
  ref $ad or return error($job, qq[unsupported archive format: $$job{srcformat}],
                          qq[I don't have a method dispatch table for $$fmt{label}s, sorry.]);
  my $aspec = catfile($datadir, $$job{filename});
  -e $aspec or return error($job, "Archive File Lost",
                            qq[I cannot seem to find the file for job $$job{id}]);
  my $arch = $$ad{open}->($aspec);
  ref $arch or return error($job, "Archive Failed to Open",
                            qq[I was unable to open the archive file for job $$job{id}]);
  logit("Opened archive file: $$job{filename}");
  for my $f ($$ad{listcontents}->($arch)) {
    my ($fname, $fspec) = $$ad{makefilespec}->($arch, $f);
    logit("Attempting to extract $fname");
    eval {
      $$ad{extractfile}->($arch, $f, $fspec);
    };
    logit("Extraction failed: $@") if $@;
    my $newjob = +{ map {
      $_ => $$job{$_}
    } keys %$job };
    $$newjob{id} = undef;
    $$newjob{parentjob} = $$job{id};
    $$newjob{flags} =~ s/S//g;
    $$newjob{flags} .= "S"; # Subjob
    if (-e $fspec) {
      logit("Extracted $fname, assigning to new job for automatic format detection.");
      $$newjob{filename} = $fname;
      $$newjob{process} = "auto";
      filepermissions($fspec);
      unlock($newjob);
    } else {
      logit("Failed to extract $fname");
      error($newjob, "Archive Extraction Failed", "Failed to extract $fname from $$job{filename}.");
    }
  }
  $$job{flags}  =~ s/P//g;
  $$job{flags} .= "P";
  $$job{canceldate} = DateTime::Format::ForDB($now);
  unlock($job);
}

sub filepermissions {
  my ($filespec) = @_;
  eval {
    local %ENV;
    $ENV{PATH} = $main::binpath{chownpath};
    system($main::binpath{chown}, $myuser, $filespec);
    system($main::binpath{chgrp}, $mygroup, $filespec);
  };
  logit("Permissions error: $@") if $@;
}

sub sanitizefilename {
  my ($raw) = @_;
  my $candidate = lc $raw;
  my ($safe) = $candidate =~ m!((?:\w+\s*[.]?)+)!;
  $safe ||= "Untitled_File_" . $$;
  return $safe;
}

sub logit {
  my ($info) = @_;
  open LOG, ">>", $logfile
    or die "Cannot append to logfile: $!";
  print LOG $info . "\n";
  close LOG;
}

sub dflog {
  my ($info) = @_;
  open LOG, ">>", $$dflog
    or die "Cannot append to $dflog: $!";
  print LOG $info . "\n";
  close LOG;
}

