#!/usr/bin/perl -w

use strict;

use Test::More tests => 5;
use Test::Exception;

use IPC::PerlSSH;

my $ips = IPC::PerlSSH->new( Command => "perl" );

$ips->use_library( "t::Math", qw( sum ) );

my $total = $ips->call( "sum", 10, 20, 30 );

is( $total, 60, '$total is 60' );

lives_ok ( sub { $ips->use_library( "t::Math" ) },
           'Loading t::Math a second time succeeds' );

throws_ok( sub { $ips->use_library( "t::Math", qw( missingfunc ) ) },
           qr/^t::Math does not define a library function called missingfunc /,
           'Loading a missing library fails' );

throws_ok( sub { $ips->use_library( "a::library::that::doesn't::exist" ) },
           qr/^Cannot find an IPC::PerlSSH library called a::library::that::doesn't::exist /,
           'Loading a missing library fails' );

dies_ok( sub { $ips->use_library( "t::Error" ) },
         'Loading t::Error fails' );
