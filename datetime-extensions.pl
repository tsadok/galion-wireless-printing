#!/usr/bin/perl

use DateTime;
use DateTime::Format::MySQL;
use Carp;

use strict;
require "./db.pl";

# The following can be overridden:
our $firsthour = 8;
our $lasthour = 20;

sub DateTime::Format::Cookie {
  my ($dt) = @_;
  $dt->set_time_zone('UTC');
  # Example of the correct format:  Wed, 01 Jan 3000 00:00:00 GMT
  return ((ucfirst $dt->day_abbr())   . ", " .
          sprintf("%02d",$dt->mday()) . " "  .
          $dt->month_abbr()           . " "  .
          sprintf("%04d", $dt->year)  . " "  .
          $dt->hms()                  . " GMT");
}

sub DateTime::Format::ts {
  my ($dt) = @_;
  return sprintf "%04d%02d%02d%02d%02d%02d", $dt->year, $dt->month, $dt->mday, $dt->hour, $dt->minute, $dt->second; 
}

sub DateTime::From::MySQL {
  my ($dtstring, $tzone, $dbgmsg) = @_;
  $tzone ||= $main::dbconfig{timezone} || 'America/New_York';
  if ($dtstring =~ /(\d{4})-(\d{2})-(\d{2})(?:(?:\s+|T)(\d{2})[:](\d{2})[:](\d{2}))?/) {
    my ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4, $5, $6);
    carp "Month is zero" if $month == 0;
    return DateTime->new(
                         year   => $year,
                         month  => $month,
                         day    => $day,
                         hour   => $hour   || 0,
                         minute => $minute || 0,
                         second => $second || 0,
                         time_zone => $tzone,
                        );
  } else {
    carp "from_mysql $dbgmsg:  Cannot parse datetime string: '$dtstring'";
    return undef;
  }
  # It may be possible to simplify this using Time::Piece::MySQL,
  # which has a from_mysql_datetime method that returns the time
  # in the same format as time(), which can probably be fed to
  # DateTime::from_epoch
}

sub DateTime::NormaliseInput {
  # Basically, this lets you get datetimes out of years, months, and
  # stuff.  For the reverse operation, see DateTime::Form::Fields

  # Takes a hashref, which is presumed to contain CGI input.  Picks
  # out keys of the form foo_datetime_bar (where bar is 'year',
  # 'month', and so on and so forth) and synthesizes them into
  # foo_datetime (the value of which will be a DateTime object) for
  # all foo.  Returns a hashref containing the normalised data.  The
  # year is mandatory for synthesis to occur; all other portions of
  # the date if missing will default to DateTime's defaults; if that's
  # a problem, ||= your own defaults into the hash beforehand.  Input
  # fields that do not match the magic pattern are unchanged.
  my %input = %{shift@_};
  for (grep { $_ =~ m/_datetime_year$/ } keys %input) {
    /^(.*)[_]datetime_year/;
    my $prefix = $1;
    my %dt = map {
      /${prefix}_datetime_(.*)/;
      my $k = $1;
      my $v = $input{"${prefix}_datetime_$k"};
      delete $input{$_};
      # push @DateTime::NormaliseInput::Debug, "<!-- $k => $v -->";
      $k => $v;
    } grep {
      /${prefix}_datetime_/;
    } keys %input;
    push @DateTime::NormaliseInput::Debug, "<!-- " . Dumper(\%dt) . " -->";
    $input{"${prefix}_datetime"} = DateTime->new(%dt);
  }
  push @DateTime::NormaliseInput::Debug, "<!-- " . Dumper(\%input) . " -->";
  return \%input;
}

my %monthname =
  (
   1 => "January",
   2 => "February",
   3 => "March",
   4 => "April",
   5 => "May",
   6 => "June",
   7 => "July",
   8 => "August",
   9 => "September",
   10 => "October",
   11 => "November",
   12 => "December",
  );

sub DateTime::Form::Fields {
  my ($dt, $prefix, $skipdate, $skiptime, $dbgmsg) = @_;
  croak "DateTime::Form::Fields requires a datetime object as the first argument" if not ref $dt;
  # skipdate and skiptime, if set to the magic value of 'disable',
  # don't skip, but "disable" editing.  (This is a UI feature only; it
  # is not secure.)
  #confess " DateTime::Form::Fields $dbgmsg [@_]" if $dbgmsg;
  my $result = "<div class=\"datetimeformfields\">
     <table><tbody>\n";
  my ($disabledate, $disabletime);
  if ($skiptime eq 'disable') { $disabletime = " disabled=\"disabled\""; undef $skiptime; }
  if ($skipdate eq 'disable') { $disabledate = " disabled=\"disabled\""; undef $skipdate; }
  my $dtyear = $dt->year; # For debugging purposes, I want this clearly on its own line, for now.
  $result .= "<!-- DateTime::Form::Fields $dbgmsg -->
         <tr><td>Year:</td><td><input type=\"text\" size=\"6\" name=\"${prefix}_datetime_year\" value=\"".
           ($dtyear)."\"$disabledate></input></td></tr>
         <tr><td>Month:</td><td><select name=\"${prefix}_datetime_month\"$disabledate>$/                ".(join $/, map {
           my $selected = ($_ == $dt->month) ? " selected=\"selected\"" : "";
           "                <option value=\"$_\" $selected>$monthname{$_}</option>"
         } 1..12)."</select></td></tr>
         <tr><td>Day:</td><td><input type=\"text\" size=\"3\" name=\"${prefix}_datetime_day\" value=\"".
           ($dt->mday)."\"$disabledate></input></td></tr>" unless $skipdate;
  $result .= "
         <tr><td>Time:</td><td><nobr><select name=\"${prefix}_datetime_hour\"$disabletime>".(join $/, map {
           my $selected = ($_ == $dt->hour) ? " selected=\"selected\"" : "";
           "<option value=\"$_\" $selected>".(($_>12)?(($_-12) . " pm"):(($_<12)?"$_ am":$_))."</option>"
         } $firsthour .. $lasthour)."</select> : <select name=\"${prefix}_datetime_minute\"$disabletime>
           ".(join $/, map {
           my $selected = ($_ == $dt->minute) ? " selected=\"selected\"" : "";
           "<option value=\"$_\" $selected>$_</option>"
         } map { sprintf "%02d", $_ } 0 .. 59)."</select></nobr></td></tr>
" unless $skiptime;
  $result .= "
     </tbody></table></div>";
  return $result;
}


42;
