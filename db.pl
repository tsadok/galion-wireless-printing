#!/usr/bin/perl -T
# -*- cperl -*-

$cgidb::version = "0.0.5";
# Version 0.0.1 was developed by jonadab at home.
# Version 0.0.2 was enhanced by Nathan at GPL for use in the inventory database.
# Version 0.0.3 was adjusted with optimizations for the resource scheduling database.
# Version 0.0.4 was adapted for the library blog
# Version 0.0.5 (done for the calendar) enhances findrecord with the ability to limit by multiple fields

# Database functions for inclusion:
# ADD:     $result  = addrecord(tablename, $record_as_hashref);
# UPDATE:  @changes = @{updaterecord(tablename, $record_as_hashref)};
# GET:     %record  = %{getrecord(tablename, id)};
# GETALL:  @records =   getrecord(tablename);     # Not for enormous tables.
# GETNEW:  @records =   getsince(tablename, timestampfield, datetimeobject);
# FIND:    @records = findrecord(tablename, fieldname, exact_value);
# FINDGT:  @records = findgreater(tablename, fieldname, limit_value);
# SEARCH:  @records =   searchrecord(tablename, fieldname, value_substring);
# COUNT:   %counts  = %{countfield(tablename, fieldname)}; # Returns a hash with counts for each value.
# COUNT:   %counts  = %{countfield(tablename, fieldname, start_dt, end_dt)}; # Ditto, but within the date range; pass DateTime objects.
# GET BY DATE:        (Last 3 args optional.  Dates, if specified, must be formatted for MySQL already.)
#          @records = @{getrecordbydate(tablename, datefield, mindate, maxdate, maxfields)};
# Special variables stored in the database:
# GET:     $value   = getvariable(namespace, varname);
# SET:     $result  = setvariable(namespace, varname, value);

# MySQL also provides regular expression capabilities; I might add a
# function for that here at some future point.

use strict;
use DBI();
use Carp;
require "./dbconfig.pl";

sub DateTime::Format::ForDB {
  my ($dt) = @_;
  return DateTime::Format::MySQL->format_datetime($dt) if $dt;
  carp "Pestilence and Discomfort: $dt";
}
sub DateTime::From::DB {
  return DateTime::From::MySQL(@_);
}

my $db;
sub dbconn {
  # Returns a connection to the database.
  # Used by the other functions in this file.
  $db = DBI->connect("DBI:mysql:database=$dbconfig::database;host=$dbconfig::host",
                     $dbconfig::user, $dbconfig::password, {'RaiseError' => 1})
    or die ("Cannot Connect: $DBI::errstr\n");
  #my $q = $db->prepare("use $dbconfig::database");
  #$q->execute();
  return $db;
}

sub getsince {
# GETNEW:  @records =   getsince(tablename, timestampfield, datetimeobject);
  my ($table, $dtfield, $dt, $q) = @_;
  die "Too many arguments: getrecord(".(join', ',@_).")" if $q;
  my $when = DateTime::Format::ForDB($dt);
  my $db = dbconn();
  $q = $db->prepare("SELECT * FROM $table WHERE $dtfield >= $when");  $q->execute();
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    push @answer, $r;
  }
  return @answer;
}

sub getrecordbydate {
# GET BY DATE:        (Dates, if specified, must be formatted for MySQL already.)
#          @records = @{getrecordbydate(tablename, datefield, mindate, maxdate, maxfields)};
  my ($table, $field, $mindate, $maxdate, $maxfields, $q) = @_;
  die "Too many arguments: getrecordbydate(".(join', ',@_).")" if $q;
  die "Must specify either mindate or maxdate (or both) when calling getrecordbydate." if ((not $mindate) and (not $maxdate));
  die "Must specify date field when calling getrecordbydate." if not $field;
  #warn "DEBUG:  getrecordbydate(table $table, field $field, min $mindate, max $maxdate, maxfields $maxfields);";
  my $db = dbconn();
  my (@where, @arg);
  if ($mindate) {
    push @where, "$field >= ?";
    push @arg, $mindate;
  }
  if ($maxdate) {
    push @where, "$field <= ?";
    push @arg, $maxdate;
  }
  $q = $db->prepare("SELECT * FROM $table WHERE " . (join " AND ", @where) . ";");  $q->execute(@arg);
  my (@r, $r);
  while ($r = $q->fetchrow_hashref()) { push @r, $r; }
  if ($maxfields and @r > $maxfields) {
    # Fortuitously, MySQL-formatted datetime strings sort correctly when sorted ASCIIbetically:
    @r = sort { $$a{$field} <=> $$b{$field} } @r;
    if ($maxdate and not $mindate) {
      # If only the maxdate is specified, we want the _last_ n items before that:
      @r = @r[(0 - $maxfields) .. -1];
    } else {
      # Otherwise, take the first n:
      @r = @r[1 .. $maxfields];
    }
  }
  return \@r;
}

sub getrecord {
# GET:     %record  = %{getrecord(tablename, id)};
# GETALL:  @recrefs = getrecord(tablename);     # Don't use this way on enormous tables.
  my ($table, $id, $q) = @_;
  die "Too many arguments: getrecord(".(join', ',@_).")" if $q;
  my $db = dbconn();
  eval {
    $q = $db->prepare("SELECT * FROM $table".(($id)?" WHERE id = '$id'":""));  $q->execute();
  }; use Carp;  croak() if $@;
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub changerecord {
  # Used by updaterecord.  Do not call directly; use updaterecord instead.
  my ($table, $id, $field, $value) = @_;
  my $db = dbconn();
  my $q = $db->prepare("update $table set $field=? where id='$id'");
  my $answer;
  eval { $answer = $q->execute($value); };
  carp "Unable to change record: $@" if $@;
  return $answer;
}

sub updaterecord {
# UPDATE:  @changes = @{updaterecord(tablename, $record_as_hashref)};
# See end of function for format of the returned changes arrayref
  my ($table, $r, $f) = @_;
  die "Too many arguments: updaterecord(".(join', ',@_).")" if $f;
  die "Invalid record: $r" if not (ref $r eq 'HASH');
  my %r = %{$r};
  my $o = getrecord($table, $r{id});
  die "No such record: $r{id}" if not ref $o;
  my %o = %{$o};
  my @changes = ();
  foreach $f (keys %r) {
    if (($r{$f} || '__MISMATCH_9764__') ne ($o{$f} || '__MISMATCH__9647__')) {
      my $result = changerecord($table, $r{id}, $f, $r{$f});
      push @changes, [$f, $r{$f}, $o{$f}, $result];
    } else {
      push @changes, ["Not changed: $f", $r{$f}, $o{$f}, ''] if ((defined $main::debug) and $main::debug > 2);
    }
  }
  return \@changes;
  # Each entry in this arrayref is an arrayref containing:
  # field changed, new value, old value, result
}

sub addrecord {
# ADD:     $result  = addrecord(tablename, $record_as_hashref);
  my ($table, $r, $f) = @_;
  die "Too many arguments: addrecord(".(join', ',@_).")" if $f;
  my %r = %{$r};
  my $db = dbconn();
  my @clauses = map { "$_=?" } sort keys %r;
  my @values  = map { $r{$_} } sort keys %r;
  my $q = $db->prepare("INSERT INTO $table SET ". (join ", ", @clauses));
  my $result = $q->execute(@values);
  if ($result) {
    $db::added_record_id=$q->{mysql_insertid}; # Calling code can read this magic variable if desired.
  } else {
    warn "addrecord failed: " . $q->errstr;
  }
  return $result;
}

sub countfield {
# COUNT:   $number  = countfind(tablename, fieldname);
  my ($table, $field, $startdt, $enddt, %crit) = @_;
  my $q;
  die "Incorrect arguments: date arguments, if defined, must be DateTime objects." if (defined $startdt and not ref $startdt) or (defined $enddt and not ref $enddt);
  die "Incorrect arguments: you must define both dates or neither" if (ref $startdt and not ref $enddt) or (ref $enddt and not ref $startdt);
  for my $criterion (keys %crit) {
    die "Incorrect arguments:  criterion $criterion specified without values." if not $crit{$criterion};
  }
  my $whereclause;
  if (ref $enddt) {
    my $start = DateTime::Format::MySQL->format_datetime($startdt);
    my $end   = DateTime::Format::MySQL->format_datetime($enddt);
    $whereclause = " WHERE fromtime > '$start' AND fromtime < '$end'";
  }
  for my $field (keys %crit) {
    my $v = $crit{$field};
    my $whereword = $whereclause ? 'AND' : 'WHERE';
    if (ref $v eq 'ARRAY') {
      $whereclause .= " $whereword $field IN (" . (join ',', @$v) . ") ";
    } else {
      warn "Skipping criterion of unknown type: $field => $v";
    }
  }
  my $db = dbconn();
  $q = $db->prepare("SELECT id, $field FROM $table $whereclause");
  $q->execute();
  my %c;
  while (my $r = $q->fetchrow_hashref()) {
    ++$c{$$r{$field}};
  }
  return \%c;
}

sub findgreater {
# FIND:    @records = findgreater(tablename, fieldname, limit_value);
  my ($table, $field, $value, @more) = @_;
  my (%fv, @field, $fval, $fld);
  my ($limit, $order, $desc) = ('', '', '');
  while (@more) {
    ($fld, $fval, @more) = @more;
    die "findgreater() called with unbalanced arguments (no value for $fld field)" if not defined $fval;
    if ($fld eq '__LIMIT__') {
      my ($lim) = $fval =~ /^(\d+)$/;
      $lim or die "findgreater() called with invalid __LIMIT__ ($fval)";
      $limit = " LIMIT $lim";
    } elsif ($fld eq '__ORDERBY__') {
      $order = " ORDER BY $fval"; # Note: order should be code-supplied, not user-supplied
    } elsif ($fld eq '__DESC__') {
      $desc  = " DESC" if $fval;
    } else {
      push @field, $fld;
      $fv{$fld} = $fval;
    }
  }
  $desc = '' unless $order;
  my $db = dbconn();
  my $q = $db->prepare((join " AND ", "SELECT * FROM $table WHERE $field > ?", map { qq[$_=?] } @field) . $order . $desc . $limit);
  $q->execute($value, map { $fv{$_} } @field);
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub findlessthan {
# FIND:    @records = findlessthan(tablename, fieldname, limit_value);
  my ($table, $field, $value, @more) = @_;
  my (%fv, @field, $fld, $fval);
  my ($limit, $order, $desc) = ('', '', '');
  while (@more) {
    ($fld, $fval, @more) = @more;
    die "findlessthan() called with unbalanced arguments (no value for $fld field)" if not defined $fval;
    if ($fld eq '__LIMIT__') {
      my ($lim) = $fval =~ /^(\d+)$/;
      $lim or die "findglessthan() called with invalid __LIMIT__ ($fval)";
      $limit = " LIMIT $lim";
    } elsif ($fld eq '__ORDERBY__') {
      $order = " ORDER BY $fval"; # Note: order should be code-supplied, not user-supplied
    } elsif ($fld eq '__DESC__') {
      $desc  = " DESC" if $fval;
    } else {
      push @field, $fld;
      $fv{$fld} = $fval;
    }
  }
  $desc = '' unless $order;
  my $db = dbconn();
  my $q = $db->prepare((join " AND ", "SELECT * FROM $table WHERE $field < ?", map { qq[$_=?] } @field) . $order . $desc . $limit);
  $q->execute($value, map { $fv{$_} } @field);
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub findinlist {
# FIND:    @records = findinlist(tablename, fieldname, [exact_value_1, exact_value_2, ... ]);
  my ($table, $field, $valuelist, @more) = @_;
  my (%fv, @field, $fval, $fld);
  my ($limit, $order, $desc) = ('', '', '');
  while (@more) {
    ($fld, $fval, @more) = @more;
    die "findinlist() called with unbalanced arguments (no value for $fld field)" if not defined $fval;
    if ($fld eq '__LIMIT__') {
      my ($lim) = $fval =~ /^(\d+)$/;
      $lim or die "findinlist() called with invalid __LIMIT__ ($fval)";
      $limit = " LIMIT $lim";
    } elsif ($fld eq '__ORDERBY__') {
      $order = " ORDER BY $fval"; # Note: order should be code-supplied, not user-supplied
    } elsif ($fld eq '__DESC__') {
      $desc  = " DESC" if $fval;
    } else {
      push @field, $fld;
      $fv{$fld} = $fval;
    }
  }
  $desc = '' unless $order;
  my $queslist = "(" . (join ", ", map { "?" } @$valuelist) . ")";
  my $db = dbconn();
  my $q = $db->prepare((join " AND ", "SELECT * FROM $table WHERE $field IN $queslist", map { qq[$_=?] } @field) . $order . $desc . $limit);
  $q->execute((@$valuelist), map { $fv{$_} } @field);
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub findnull {
# FIND:    @records = findnull(tablename, fieldname);
  my ($table, $field, @more) = @_;
  my (%fv, @field, $fval, $fld);
  my ($limit, $order, $desc) = ('', '', '');
  while (@more) {
    ($fld, $fval, @more) = @more;
    die "findnull() called with unbalanced arguments (no value for $fld field)" if not defined $fval;
    if ($fld eq '__LIMIT__') {
      my ($lim) = $fval =~ /^(\d+)$/;
      $lim or die "findnull() called with invalid __LIMIT__ ($fval)";
      $limit = " LIMIT $lim";
    } elsif ($fld eq '__ORDERBY__') {
      $order = " ORDER BY $fval"; # Note: order should be code-supplied, not user-supplied
    } elsif ($fld eq '__DESC__') {
      $desc  = " DESC" if $fval;
    } else {
      push @field, $fld;
      $fv{$fld} = $fval;
    }
  }
  $desc = '' unless $order;
  my $db = dbconn();
  my $q = $db->prepare((join " AND ", "SELECT * FROM $table WHERE $field IS NULL", map { qq[$_=?] } @field) . $order . $desc . $limit);
  $q->execute(map { $fv{$_} } @field);
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub findnotnull {
# FIND:    @records = findnotnull(tablename, fieldname);
  my ($table, $field, @more) = @_;
  my (%fv, @field, $fval, $fld);
  my ($limit, $order, $desc) = ('', '', '');
  while (@more) {
    ($fld, $fval, @more) = @more;
    die "findnotnull() called with unbalanced arguments (no value for $fld field)" if not defined $fval;
    if ($fld eq '__LIMIT__') {
      my ($lim) = $fval =~ /^(\d+)$/;
      $lim or die "findnotnull() called with invalid __LIMIT__ ($fval)";
      $limit = " LIMIT $lim";
    } elsif ($fld eq '__ORDERBY__') {
      $order = " ORDER BY $fval"; # Note: order should be code-supplied, not user-supplied
    } elsif ($fld eq '__DESC__') {
      $desc  = " DESC" if $fval;
    } else {
      push @field, $fld;
      $fv{$fld} = $fval;
    }
  }
  $desc = '' unless $order;
  my $db = dbconn();
  my $q = $db->prepare((join " AND ", "SELECT * FROM $table WHERE $field IS NOT NULL", map { qq[$_=?] } @field) . $order . $desc . $limit);
  $q->execute(map { $fv{$_} } @field);
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub findrecord {
# FIND:    @records = findrecord(tablename, fieldname, exact_value);
  my ($table, $field, $value, @more) = @_;
  my (%fv, @field);
  my ($limit, $order, $desc) = ('', '', '');
  croak "findrecord called with unbalanced arguments (no value for $field field)" if not defined $value;
  push @field, $field; $fv{$field} = $value;
  while (@more) {
    ($field, $value, @more) = @more;
    die "findrecord called with unbalanced arguments (no value for $field field)" if not defined $value;
    if ($field eq '__LIMIT__') {
      my ($lim) = $value =~ /^(\d+)$/;
      $lim or die "findrecord called with invalid __LIMIT__ ($value)";
      $limit = " LIMIT $lim";
    } elsif ($field eq '__ORDERBY__') {
      $order = " ORDER BY $value"; # Note: this should be code-supplied, not order-supplied
    } elsif ($field eq '__DESC__') {
      $desc  = " DESC" if $value;
    } else {
      push @field, $field;
      $fv{$field} = $value;
    }
  }
  $desc = '' unless $order;
  my $db = dbconn();
  my $q = $db->prepare(("SELECT * FROM $table WHERE " . (join " AND ", map { qq[$_=?] } @field )) . $order . $desc . $limit);
  $q->execute(map { $fv{$_} } @field);
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}
#sub findrecord {
## FIND:    @records = findrecord(tablename, fieldname, exact_value);
#  my ($table, $field, $value, $q) = @_;
#  die "Too many arguments: findrecord(".(join', ',@_).")" if $q;
#  my $db = dbconn();
#  $q = $db->prepare("SELECT * FROM $table WHERE $field=?");  $q->execute($value);
#  my @answer; my $r;
#  while ($r = $q->fetchrow_hashref()) {
#    if (wantarray) {
#      push @answer, $r;
#    } else {
#      return $r;
#    }
#  }
#  return @answer;
#}

sub searchrecord {
# SEARCH:  @records = @{searchrecord(tablename, fieldname, value_substring)};
  my ($table, $field, $value, $q) = @_;
  die "Too many arguments: searchrecord(".(join', ',@_).")" if $q;
  my $db = dbconn();
  $q = $db->prepare("SELECT * FROM $table WHERE $field LIKE '%$value%'");  $q->execute();
  my @answer; my $r;
  while ($r = $q->fetchrow_hashref()) {
    if (wantarray) {
      push @answer, $r;
    } else {
      return $r;
    }
  }
  return @answer;
}

sub getvariable {
  my ($namespace, $var, $q) = @_;
  die "Too many arguments: searchrecord(".(join', ',@_).")" if $q;
  my $db = dbconn();
  $q = $db->prepare("SELECT * FROM misc_variables WHERE namespace=? AND name=?");  $q->execute($namespace, $var);
  my $r = $q->fetchrow_hashref();
  return $$r{value};
}
sub setvariable {
  my ($namespace, $var, $value, $q) = @_;
  die "Too many arguments: searchrecord(".(join', ',@_).")" if $q;
  my $db = dbconn();
  $q = $db->prepare("SELECT * FROM misc_variables WHERE namespace=? AND name=?");  $q->execute($namespace, $var);
  my $r = $q->fetchrow_hashref();
  return changerecord('misc_variables', $$r{id}, 'value', $value);
}

1;
