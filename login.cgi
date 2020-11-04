#!/usr/bin/perl -wT
# -*- cperl -*-

require './forminput.pl';
require './auth.pl';
require './include.pl';
our $cookie = $auth::cookie;

my $ab = authbox();
print "Content-type: text/html\n$cookie\n\n" . assemble_page(content => qq[
  <div>$ab</div>
  <ol><li>Enter your username and password above.</li>
      <li>Click the Log In button once.</li>
      <li>Proceed to
            <a href="queue.cgi">the Printjob Queue</a>.
      </li></ol>]);
