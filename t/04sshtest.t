#!/usr/bin/perl -w

use strict;

use Test::More tests => 2;

use IPC::PerlSSH;

my $ips = IPC::PerlSSH->new( Host => "localhost" );
ok( defined $ips, "Constructor" );

# Test basic eval / return
my $result = $ips->eval( '( 10 + 30 ) / 2' );
is( $result, 20, "Scalar eval return" );
