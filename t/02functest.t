#!/usr/bin/perl -w

use strict;

use Test::More tests => 15;

use IPC::PerlSSH;

my @readbuffer;
sub readfunc
{
   if( @readbuffer == 0 ) {
      print STDERR "Ran out of read data\n";
      exit( 1 );
   }

   if( defined $_[1] ) {
      if( $_[1] > length $readbuffer[0] ) {
         print STDERR "Wanted to read more data than available\n";
         exit( 1 );
      }
      else {
         $_[0] = substr( $readbuffer[0], 0, $_[1], "" );
         shift @readbuffer unless length $readbuffer[0];
      }
   }
   else {
      $_[0] = shift @readbuffer;
   }

   length $_[0];
}

my $writeexpect;
sub writefunc
{
   return unless defined $writeexpect;

   if( $_[0] eq substr( $writeexpect, 0, length $_[0] ) ) {
      substr( $writeexpect, 0, length $_[0], "" );
      return length $_[0];
   }

   print STDERR "Buffer starts: '$_[0]'\n";
   print STDERR "Was expecting: '" . ( substr( $writeexpect, 0, length $_[0] ) ) . "'\n";
   exit( 1 );
}

undef $writeexpect;
my $ips = IPC::PerlSSH->new( Readfunc => \&readfunc, Writefunc => \&writefunc );
ok( defined $ips, "Constructor" );

# Test basic eval / return
$writeexpect = 
   "EVAL\n" .
   "1\n" .
   "15\n" . "( 10 + 30 ) / 2";
@readbuffer = ( 
   "RETURNED\n",
   "1\n",
   "2\n", "20",
);
my $result = $ips->eval( '( 10 + 30 ) / 2' );
is( $result, 20, "Scalar eval return" );
is( length $writeexpect, 0, "length writeexpect" );
is( scalar @readbuffer,  0, "scalar readbuffer" );

# Test list return
$writeexpect = 
   "EVAL\n" .
   "1\n" .
   "29\n" . 'split( m//, "Hello, world!" )';
@readbuffer = (
   "RETURNED\n",
   "13\n",
   "1\n", "H",
   "1\n", "e",
   "1\n", "l",
   "1\n", "l",
   "1\n", "o",
   "1\n", ",",
   "1\n", " ",
   "1\n", "w",
   "1\n", "o",
   "1\n", "r",
   "1\n", "l",
   "1\n", "d",
   "1\n", "!",
);

my @letters = $ips->eval( 'split( m//, "Hello, world!" )' );
is_deeply( \@letters, [qw( H e l l o ), ",", " ", qw( w o r l d ! )], "List eval return" );
is( length $writeexpect, 0, "length writeexpect" );
is( scalar @readbuffer,  0, "scalar readbuffer" );

# Test argument passing
$writeexpect =
   "EVAL\n" .
   "4\n" .
   "15\n" . 'join( ":", @_ )' .
   "4\n" . "some" .
   "6\n" . "values" .
   "4\n" . "here";
@readbuffer = (
   "RETURNED\n",
   "1\n",
   "16\n", "some:values:here"
);
$result = $ips->eval( 'join( ":", @_ )', qw( some values here ) );
is( $result, "some:values:here", "Scalar eval argument passing" );
is( length $writeexpect, 0, "length writeexpect" );
is( scalar @readbuffer,  0, "scalar readbuffer" );

# Test stored procedures
$writeexpect =
   "STORE\n" .
   "2\n" .
   "3\n" . "add" .
   "146\n" . 'my $t = 0; 
                     while( defined( $_ = shift ) ) {
                        $t += $_;
                     }
                     $t';
@readbuffer = (
   "OK\n",
   "0\n"
);
$ips->store( 'add', 'my $t = 0; 
                     while( defined( $_ = shift ) ) {
                        $t += $_;
                     }
                     $t' );
is( length $writeexpect, 0, "length writeexpect" );
is( scalar @readbuffer,  0, "scalar readbuffer" );

$writeexpect =
   "CALL\n" .
   "6\n" .
   "3\n" . "add" .
   "2\n" . "10" .
   "2\n" . "20" .
   "2\n" . "30" .
   "2\n" . "40" .
   "2\n" . "50";
@readbuffer = (
   "RETURNED\n",
   "1\n",
   "3\n", "150",
);
my $total = $ips->call( 'add', 10, 20, 30, 40, 50 );
is( $total, 150, "Stored procedure storing/invokation" );
is( length $writeexpect, 0, "length writeexpect" );
is( scalar @readbuffer,  0, "scalar readbuffer" );

# Make sure we don't complain about the final QUIT
undef $writeexpect;
