#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;

use IPC::PerlSSH;

my $ips = IPC::PerlSSH->new( Command => "perl" );
ok( defined $ips, "Constructor" );

# Test basic eval / return
my $result = $ips->eval( '( 10 + 30 ) / 2' );
is( $result, 20, "Scalar eval return" );

# Test list return
my @letters = $ips->eval( 'split( m//, "Hello, world!" )' );
is_deeply( \@letters, [qw( H e l l o ), ",", " ", qw( w o r l d ! )], "List eval return" );

# Test argument passing
$result = $ips->eval( 'join( ":", @_ )', qw( some values here ) );
is( $result, "some:values:here", "Scalar eval argument passing" );

# Test stored procedures
$ips->store( 'add', 'my $t = 0; 
                     while( defined( $_ = shift ) ) {
                        $t += $_;
                     }
                     $t' );

my $total = $ips->call( 'add', 10, 20, 30, 40, 50 );
is( $total, 150, "Stored procedure storing/invokation" );

# Test caller binding
$ips->bind( 'dosomething', 'return "My string is $_[0]"' );
$result = dosomething( "hello" );
is( $result, "My string is hello", "Caller bound stored procedure" );
