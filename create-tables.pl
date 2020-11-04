#!/usr/bin/perl
# -*- cperl -*-

require "./db.pl";
my $db = dbconn();

$db->prepare("use $dbconfig::database")->execute();

$db->prepare("CREATE TABLE IF NOT EXISTS
    printjob ( id           integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
               ipaddress    tinytext,
               smtpsender   tinytext,
               emailfrom    tinytext,
               patron       tinytext,
               subject      tinytext,
               srcformat    tinytext,
               origfilename tinytext,
               filename     tinytext,
               submitdate   datetime,
               printdate    datetime,
               canceldate   datetime,
               viewkey      tinytext,
               process      tinytext,
               proclockps   tinytext,
               proclockdt   datetime,
               notes        tinytext,
               pages        integer,
               parentjob    integer,
               flags        tinytext);
   ")->execute();

$db->prepare("CREATE TABLE IF NOT EXISTS
   printjobdatafile ( id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
                      job      integer,
                      filename tinytext,
                      noticed  datetime,
                      removed  datetime,
                      flags    tinytext);
   ")->execute();

$db->prepare(
    "CREATE TABLE IF NOT EXISTS
     authcookies (
          id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
          cookiestring mediumtext,
          user integer,
          restrictip tinytext,
          expires datetime
     )"
    )->execute();

$db->prepare(
    "CREATE TABLE IF NOT EXISTS
     users (
          id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
          username   tinytext,
          hashedpass tinytext,
          fullname   mediumtext,
          nickname   mediumtext,
          prefs      mediumtext,
          salt       mediumtext,
          initials   tinytext,
          flags      tinytext
     )"
    )->execute();

$db->prepare(
    "CREATE TABLE IF NOT EXISTS
     misc_variables (
          id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
          namespace  tinytext,
          name       mediumtext,
          value      longtext
     )"
    )->execute();

$db->prepare(
    "CREATE TABLE IF NOT EXISTS
    auth_by_ip (
          id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
          ip tinytext,
          user integer
    )"
    )->execute();

