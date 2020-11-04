#!/usr/bin/perl
# -*- cperl -*-

require './binpath.pl';
require './forminput.pl';
require '/usr/local/bin/stylesheet-include-basic.pl';

our %input = %{getforminput() || +{ action => ''}};
use HTML::Entities;
use Carp;
require './auth.pl';
our $authbox  = authbox();
our $pulldownmenus = 0;

our $timezone = $main::dbconfig{timezone} || 'America/New_York';

my $fqdn = getvariable("wirelessprint", "fqdn") || "error.example.com";

sub output {
  my ($content, %arg) = @_;
  my $type = $arg{"content-type"} || qq[text/html];
  print "Content-type: $type\n\n"
    . assemble_page( content => $content,
                     %arg);
  exit 0;
}

sub assemble_page {
  my (%arg) = @_;
  my $doctype    = doctype();
  $arg{title}  ||= getvariable("wirelessprint", "defaultpagetitle") || 'Galion Wireless Printing';
  my $dochead    = dochead(%arg);
  my $content    = $arg{content} || "Content is planned for this space.";
  my $pageheader = $arg{header}  || "";
  my $sidebar    = $arg{sidebar} || "";
  my $pagefooter = $arg{footer}  || "";
    return qq{$doctype
<html xml:lang="en" xmlns="http://www.w3.org/1999/xhtml"><head>
$dochead
</head><body>
$pageheader
$sidebar
$arg{content}
$pagefooter
</body></html>\n};
}

sub doctype {
  return qq[<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">];
}

sub dochead {
  my %arg       = @_;
  my $title     = $arg{title} || getvariable("wirelessprint", "defaultpagetitle") || 'Galion Wireless Printing';
  my $js        = $arg{javascript} || ''; # This is for page-specific.  Any that applies to all pages can be linked from headmarkup.
  my $allcss    = getvariable("wirelessprint", "stylesheet_allmedia") || "all.css";
  my $printcss  = getvariable("wirelessprint", "stylesheet_print")    || "print.css";
  my $screencss = getvariable("wirelessprint", "stylesheet_screen")   || "screen.css";
  my $css       = $arg{stylesheet} || ''; # This is for page-specific styling; the ones above (all/print/screen) apply to all pages.
  my $favicon   = $arg{favicon} || getvariable("wirelessprint", "shortcut_icon") || "printer-icon.ico";
  my $charenc   = $arg{character_encoding} || getvariable("wirelessprint", "character_encoding") || 'US-ASCII';
  my $more      = $arg{headmarkup} || getvariable("wirelessprint", "headmarkup") || '';
  return qq[
   <title>$title</title>
   <meta http-equiv="X-UA-Compatible" content="IE=Edge" />
   <meta http-equiv="Content-type" content="text/html;charset=$charenc" />
   <meta name="viewport" content="initial-scale=1.0, width=device-width, height=device-height" />

   <link rel="SHORTCUT ICON" href="$favicon" />

   <link rel="stylesheet" type="text/css" media="all" href="$allcss" />
   <link rel="stylesheet" type="text/css" media="print" href="print.css" />
   <link rel="stylesheet" type="text/css" media="screen" href="screen.css" />
   <link rel="stylesheet" type="text/css" media="screen" href="index.cgi?action=teamcolorcss" />
   $css
   $js
   $more
];
}

sub infodiv {
  my ($title, $detail) = @_;
  return qq[<div class="box infobox">
   <div class="boxtitle">FYI: $title</div>
   <div>$detail</div>
  </div>]
}

sub warningdiv {
  my ($title, $detail) = @_;
  return qq[<div class="warning box">
   <div class="boxtitle">Warning: $title</div>
   <div>$detail</div>
   <div class="explan">This is a warning, not a full-fledged error.  It's possible, at least in some cases, that some aspect of what you were trying to do may have partially succeeded.  Conceivably.</div>
  </div>]
}

sub errordiv {
  my ($title, $detail) = @_;
  return qq[<div class="error box">
   <div class="boxtitle">Error: $title</div>
   <div>$detail</div>
  </div>]
}

sub buildselect {
  my ($name, $options, $default, $id, $onchange) = @_;
  $name or carp "buildselect called without name.";
  my @option = @$options;  @option or carp "buildselect called with no options.";
  $id       ||= $name;
  $onchange ||= "";
  return qq[<select name="$name" id="$id"$onchange>
     ] . (join "\n", map {
       qq[   <option value="$$_[0]"] . ($$_[0] eq $default ? ' selected="selected"' : '') . qq[>$$_[1]</option>]
     } @option) . qq[
  </select>]

}

sub friendlydate {
  my ($date) = @_;
  my $dt  = (ref $date) ? $date : DateTime::From::DB($date);
  my $now = DateTime->now( time_zone => $main::dbconfig{timezone} || 'America/New_York' );
  if ($now->ymd() eq $dt->ymd()) {
    my $pm = "";
    my $hour = $dt->hour();
    if ($hour > 12) {
      $hour = $hour % 12;
      $pm = "pm";
    }
    return sprintf("%1d:%02d", $hour, $now->min()) . $pm;
  }
  my $yesterday = $now->clone()->subtract( days => 1 );
  if ($yesterday->ymd() eq $dt->ymd()) {
    return "Yesterday";
  }
  return $dt->year() . " " . $dt->month_name() . " " . htmlordinal($dt->mday());
}

sub htmlordinal {
  my ($num) = @_;
  if ($num > 10 and $num < 20) {
    return "$num<sup>th</sup>";
  } elsif ($num =~ /3$/) {
    return "$num<sup>rd</sup>";
  } elsif ($num =~ /2$/) {
    return "$num<sup>nd</sup>";
  } elsif ($num =~ m/1$/) {
    return "$num<sup>st</sup>";
  } else {
    return "$num<sup>th</sup>";
  }
}

sub sgorpl {
  my ($qtty, $unit, $plunit) = @_;
  # Appends a singular or plural unit label, as appropriate, to a number.
  if ($qtty == 1) { return "$qtty $unit"; }
  $plunit ||= $unit . 's';
  return "$qtty $plunit";
}

sub getnum {
  my ($name) = @_;
  my ($value) = ($input{$name} || '') =~ /(-?[0-9]+(?:[.][0-9]+)?)/;
  return 0 + ($value || 0);
}
sub uniq {
  my %seen;
  my @answer = map { $seen{$_}++ ? () : ($_) } @_;
  return @answer;
}

42;
