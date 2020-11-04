#!/usr/bin/perl
# -*- cperl -*-

require "./db.pl";
use DateTime;
require "./datetime-extensions.pl";
use HTML::Entities;
use Digest::MD5 qw(md5_base64);
$auth::saltlength = getvariable('wirelessprint', 'salt_length') || 250;

$|++;

$auth::user = undef; # authbox sets this magic variable, which can be queried from anywhere.

my $loggedin = 'You are logged in as';

my $debug=0;  my $status = "<!-- using auth.pl for authentication/login -->\n";
my $default_expiration = DateTime->now->add(days => 1, hours => 12);

# Also requires the database accessed by db.pl to have an authcookies table with the following fields:
#  id              AUTO_INCREMENT   (All tables manipulated by db.pl must have this field.)
#  cookiestring    mediumtext       The identifying part of the cookie string sent to the browser
#  user            integer          id of the user in question (pointing into whatever users table your db uses)
#  restrictip      tinytext         IP address to which session is restricted, if it is so restricted.
#  expires         datetime         Cookie is no good after this date; user must log in from scratch.

# Additionally, requires a users table with the following fields:
#  id              AUTO_INCREMENT   (All tables manipulated by db.pl must have this field.)
#  username        mediumtext       (username for login)
#  hashedpass      tinytext         (MD5 Base64 hashed version of the password, for login)

# If the users table contains a salt field, it will be used.
# If the users table contains a nickname or firstname or fullname
# field, it will be used (in that order of preference), but this is
# not required.  (username will be used in their absense.)

sub generaterandomstring; # Defined below.

sub getrawcookie { # Helper function.  Gets the browser's cookie string from the environment.
  $_ = $ENV{HTTP_COOKIE} || "";
  if (/login=(\w+)/) { return $1 unless ($1 eq 'nobody'); }
  return undef;
}

sub getuserfromcookie {
  # Checks to see if user is already logged in; if so, returns user id
  # otherwise returns undef.
  my $cs = getrawcookie();
  if ($cs) {
    my %cookie = %{findrecord('authcookies', 'cookiestring', $cs)};
    if ($cookie{restrictip} and ($cookie{restrictip} ne $ENV{REMOTE_ADDR})) {
      return undef; # User is not verified for this remote IP address.
      # (Note that if restrictip is unset, it is not restricted.)
    }
    elsif ($cookie{expires} le DateTime::Format::ForDB(DateTime->now)) {
      return undef; # Cookie is stale.  Ptooey.
    } else {
      return $cookie{user};
    }
  } else {
    return undef; # No cookiestring?  Must not be logged in.
  }
}

sub newcookie {
  # Example usage:  my $cookie = newcookie({user=>$auth::user, restrictip=>$ipaddy});
  #                 print "Content-type: $content_type\n";
  #                 print "Set-Cookie: $cookie\n" if $cookie;
  #                 print "\n"; # end of HTTP headers...
  my ($r) = @_;
  my %r = %{$r};
  if ($debug) {
    $status .= "<!-- newcookie args (dereferenced) are as follows: -->\n";
    for (keys %r) {
      $status .= "<!-- $_ => $r{$_} -->\n";
    }
  }
  $r{expires}      ||= DateTime::Format::ForDB($default_expiration);
  $r{cookiestring} ||= generaterandomstring(50);
  if ($debug) {
    for (keys %r) {
      $status .= "<!-- cookie will have $_ set to $r{$_} -->\n";
    }
  }
  if (addrecord('authcookies', \%r)) {
    return ("login=$r{cookiestring}; expires=".DateTime::Format::Cookie(DateTime::From::MySQL($r{expires})));
  } else {
    return undef;
  }
}

sub newsalt {
  my @saltchar    = ('a' .. 'z', 'A' .. 'Z', 2 .. 9);
  return join '', map { $saltchar[rand @saltchar] } 1 .. $auth::saltlength;
}

sub authbox {
  # Returns a string containing a hunk of xhtml suitable for inclusion
  # wherever a div can legally be put (e.g., inside a table cell or a
  # paragraph).  If the user is not logged in, the box offers login
  # options.  If the user is logged in, it offers a logout link.
  # Here's the really fun part: if the user clicks the login link, the
  # authbox should handle it internally.  That is, the same page
  # should be redisplayed, but with the login status changed.  In
  # order to accomplish this magic, the authbox claims all content of
  # %main::input with keys starting with 'AUTH_', and this hash is
  # expected to contain the user input, which expected to have already
  # been retrieved (using getforminput() presumably).

  # Additionally, this routine claims the magic global $auth::cookie,
  # which it sets when the user successfully logs in, and this MUST be
  # passed on to the browser.  Thus, this routine must be _called_
  # before the http headers go out, though its return value can be
  # printed later.  Thus,. the following will do the right thing:
  # %input = getforminput();
  # my $ab = authbox(sub { my $x = getrecord('users', shift); "<div>Hi, $$x{nickname}</div>"; });
  # print "Content-type: text/html\n" . $auth::cookie . "\n";
  # do_stuff(); print $ab; do_more_stuff();

  # If you pass an argument, it must be a coderef that, when called
  # with a user id, returns the remainder of the user-specific content
  # that belongs in the authbox (e.g., links to the user's preferences
  # or whatnot).
  my ($callback) = @_;
  my ($calltheuser, $newcookie) = ();

  if ($debug) {
    for (keys %main::input) {
      if (/^AUTH_/) {
        $status .= "<!-- $_ is $main::input{$_} -->\n";
      }
    }
  }
  # Is user trying to log IN?
  if ($main::input{AUTH_login_username}) {
    $status .= "<!-- Looking up username... -->" if ($debug);
    my $r = findrecord('users', 'username', $main::input{AUTH_login_username});
    if ($r and $debug) {
      $status .= "<!-- Got record for user $$r{id}. -->\n";
    }
    my $chash = md5_base64($main::input{AUTH_login_password} . $$r{salt});
    #use Data::Dumper; warn "Attempting login: " . Dumper(+{
    #                                                       rpass => $$r{password},
    #                                                       rhash => $$r{hashedpass},
    #                                                       rsalt => $$r{salt},
    #                                                       apass => $main::input{AUTH_login_password},
    #                                                       user  => $main::input{AUTH_login_username},
    #                                                       recid => $$r{id},
    #                                                       chash => $chash,
    #                                                      });
    if ($r and
        (
         ($$r{password} and not $$r{hashedpass} and $$r{password} eq $main::input{AUTH_login_password})
         or
         ((defined $$r{hashedpass}) and ($$r{hashedpass} eq $chash))
        )
       ) {
      $status .= "<!-- Verified password.  Setting user to $$r{id} -->\n";
      $auth::user = $$r{id};
      if (($$r{hashedpass} eq $chash) and ($$r{password}) and (not getvariable('wirelessprint', 'retain_cleartext_passwords'))) {
        # If the user can successfully authenticate via hashed password,
        # then the clear-text password is no longer wanted and should be removed:
        $$r{password} = undef;
        updaterecord('users', $r);
      } elsif (not $$r{hashedpass}) {
        # If the hashed password is not yet stored in the database, it should be.
        # Generate fresh salt while we're at it:
        $$r{salt}       = newsalt();
        $$r{hashedpass} = md5_base64($main::input{AUTH_login_password} . $$r{salt});
        updaterecord('users', $r);
      }
      # Kill off old expired login cookies for this user:
      my @oldcookie = grep { $$_{expires} lt $dbnow } findrecord('logincookies', "userid", $$r{id});
      # For performance reasons, if there's a large backlog, only process a few at a time:
      @oldcookie = @oldcookie[ 0 .. 80 ] if ((scalar @oldcookie) > 100);
      for my $oc (@oldcookie) {
        my $db = dbconn();
        my $q  = $db->prepare("DELETE FROM authcookies WHERE id = ?");
        $q->execute($$oc{id});
      }
      $calltheuser = $$r{nickname} || $$r{firstname} || $$r{fullname} || $$r{username};
      $status .= "<!-- Calling the user $calltheuser -->\n";
      my %args;
      $args{user}=$auth::user;
      if ($debug) {
        for (keys %args) {
          $status .= "<!-- cookie should theoretically have $_ set to $args{$_} -->\n";
        }
        $status .= "<!-- Checking IP restriction... -->";
      }
      # Should we restrict the session to just the current IP address?
      if (   ($auth::ALWAYS_RESTRICT_IP)              # Set this magic variable to make it always so for all users.
          or ($main::input{AUTH_login_restrict_ip}))  # The authbox login form has this checkbox.
        {
          $args{restrictip} = $ENV{REMOTE_ADDR};
          $status .= "<!-- Restricting session to current IP address -->\n";
        }
      if ($debug) {
        for (keys %args) {
          $status .= "<!-- cookie should hopefully have $_ set to $args{$_} -->\n";
        }
      }
      $auth::cookie = "Set-Cookie: " .newcookie(\%args). "\n";
    }
    # $auth::user is now set, so the results will be returned by the if($auth::user) stuff below.
  }

  $status .= "<!-- Raw Cookie:  ".(getrawcookie() || "")." -->";
  $auth::user ||= getuserfromcookie();
  $status .= "<!-- Constructing authbox for " . ($auth::user || "unknown user") . " -->\n";
  if ($auth::user) {
    my $r = getrecord('users', $auth::user);
    $status .= "<!-- Finding out what to call user $$r{id} -->\n";
    $calltheuser = $$r{nickname} || $$r{firstname} || $$r{fullname} || $$r{username};
  }

  # Determine whether to authenticate by IP address:
  # $status .= "<!-- Determining whether to authenticate via IP address for $ENV{REMOTE_ADDR} -->\n";
  my $authbyip = findrecord('auth_by_ip', 'ip', ($ENV{REMOTE_ADDR} || "__UNKNOWN__"));
  if ((not $auth::user) and $authbyip) {
    # User is not logged in, but we can authenticate by IP:
    $auth::user = $$authbyip{user};
    if ($auth::user) {
      $loggedin = 'Hi, you must be';
      # But we don't set a cookie or anything for this kind of auth.
      # We do need certain things from the user record...
      $status .= "<!-- Authenticating by IP address:  $ENV{REMOTE_ADDR} => $auth::user -->\n";
      my $r = getrecord('users',$auth::user);
      $calltheuser = $$r{nickname} || $$r{firstname} || $$r{fullname} || $$r{username};
      $status .= "<!-- Calling the user $calltheuser -->\n";
    }
  }



  # Is user trying to log OUT?
  if ($main::input{AUTH_logout}) {
    my $dbc = dbconn();
    my $q = $dbc->prepare("DELETE FROM authcookies WHERE cookiestring=?");
    # TODO:  Instead of just this cookie, kill off all cookies with the same user, unless
    #        the user has turned on "allow multiple logins" in his prefs.
    $q->execute(getrawcookie());
    $auth::user = undef; # So the results will be output by the else stuff below.
    $auth::cookie = "Set-Cookie: login=nobody\n"; # Save us the trouble of looking and finding it missing.
  }

  if ($auth::user) {
    # User is logged in already.  Display logout option and whatever the callback returns (if any):
    my $r = getrecord('users', $auth::user);
    my $more = "";
    if ($callback) { $more = $callback->($auth::user); }
    my $href = (-e 'user.cgi') ? qq[ href="user.cgi?user=$auth::user"]
      : (($$r{flags} =~ /A/) ? qq[ href="admin.cgi?action=edituser&amp;userid=$auth::user"] : '');
    return qq[<div class="authbox">$status
       <div>$loggedin <a$href>$calltheuser</a>.</div>
       <div><a href="index.cgi?AUTH_logout=$auth::user">Log Out</a></div>
       $more</div>];
  } else {
    # User is not logged in currently.  Display login form.
    # The real trick, though, is we want to preserve any current
    # input (_unless_ it is auth related) to be processed after
    # the login.
    $uri ||= "index.cgi";
    my %input_to_keep = map { ((/^AUTH_/)?(undef):(($_=>$main::input{$_}))); } keys %main::input;
    my $result = qq[<!-- ****************** BEGIN AUTHBOX ****************** -->\n$status
     <div class="authbox"><!-- TODO:  put login image here? -->
      <div>You are currently Anonymous (not logged in).</div>
      <form method="POST" action="$uri">\n];
    for (keys %input_to_keep) {
      $result   .= qq[      <input type="hidden" name="$_" value="$input_to_keep{$_}"></input>\n];
    }
    $result     .= qq[      <div>Username:  <input type="text"     name="AUTH_login_username" size="12"></input></div>
      <div>Password:  <input type="password" name="AUTH_login_password" size="12"></input></div>\n];
    if (not $auth::ALWAYS_RESTRICT_IP) {
      $result   .= qq[      <div><input type="checkbox" name="AUTH_login_restrict_ip" id="AUTH_login_restrict_ip">
                                 <label for="AUTH_login_restrict_ip">Restrict session to my current IP address only.</label></input></div>\n];
    }
    $result     .= qq[      <div><input type="submit" value="Log In"></input></div>\n   </form></div>
    <!-- ******************  END AUTHBOX  ****************** -->];
    return $result;
  }
}

sub generaterandomstring { # Used to generate cookie strings.
  my ($numofchars, $charstouse) = @_;
  $charstouse ||= "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz1234567890_"; # Reasonable default
  my @validchars = map { if ($_=~/\w/) {$_} else { undef }} split //, $charstouse;
  my $string = "";
  $string .= $validchars[rand @validchars] for 1..$numofchars;
  return $string;
}

1;
