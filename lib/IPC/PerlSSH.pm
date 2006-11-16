#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Library General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software
#  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
#  (C) Paul Evans, 2006 -- leonerd@leonerd.org.uk

package IPC::PerlSSH;

use strict;

use Symbol;
use IPC::Open2;

use Carp;

our $VERSION = "0.04";

=head1 NAME

C<IPC::PerlSSH> - a class for executing remote perl code over an SSH link

=head1 DESCRIPTION

This module provides an object class that provides a mechanism to execute perl
code in a remote instance of perl running on another host, communicated via an
SSH link or similar connection. Where it differs from most other IPC modules
is that no special software is required on the remote end, other than the
ability to run perl. In particular, it is not required that the
C<IPC::PerlSSH> module is installed there. Nor are any special administrative
rights required; any account that has shell access and can execute the perl
binary on the remote host can use this module.

=head1 SYNOPSIS

 use IPC::PerlSSH;

 my $ips = IPC::PerlSSH->new( Host => "over.there" );

 $ips->eval( "use POSIX qw( uname )" );
 my @remote_uname = $ips->eval( "uname()" );

 # We can pass arguments
 $ips->eval( "open FILE, ">", shift; print FILE shift; close FILE;",
             "foo.txt",
             "Hello, world!" );

 # We can pre-compile stored procedures
 $ips->store( "get_file", "local $/; 
                           open FILE, "<", shift;
                           $_ = <FILE>;
                           close FILE;
                           return $_;" );
 foreach my $file ( @files ) {
    my $content = $ips->call( "get_file", $file );
    ...
 }

=cut

# We have a "shared library" of common functions between this end and the
# remote end

my $COMMON_PERL = <<'EOP';
sub read_operation
{
   my ( $readfunc ) = @_;

   local $/ = "\n";

   $readfunc->( my $operation, undef );
   defined $operation or die "Expected operation\n";
   chomp $operation;

   $readfunc->( my $numargs, undef );
   defined $numargs or die "Expected number of arguments\n";
   chomp $numargs;

   my @args;
   while( $numargs ) {
      $readfunc->( my $arglen, undef );
      defined $arglen or die "Expected length of argument\n";
      chomp $arglen;

      my $arg = "";
      while( $arglen ) {
         my $buffer;
         my $n = $readfunc->( $buffer, $arglen );
         die "read() returned $!\n" unless( defined $n );
         $arg .= $buffer;
         $arglen -= $n;
      }

      push @args, $arg;
      $numargs--;
   }

   return ( $operation, @args );
}

sub send_operation
{
   my ( $writefunc, $operation, @args ) = @_;

   # Buffer this for speed - this makes a big difference
   my $buffer = "";

   $buffer .= "$operation\n";
   $buffer .= scalar( @args ) . "\n";

   foreach my $arg ( @args ) {
      $buffer .= length( $arg ) . "\n" . "$arg";
   }

   $writefunc->( $buffer );
}

EOP

# And now for the main loop of the remote firmware
my $REMOTE_PERL = <<'EOP';
$| = 1;

my %stored_procedures;

my $readfunc = sub {
   if( defined $_[1] ) {
      read( STDIN, $_[0], $_[1] );
   }
   else {
      $_[0] = <STDIN>;
      length $_[0];
   }
};

my $writefunc = sub {
   print STDOUT $_[0];
};

while( 1 ) {
   my ( $operation, @args ) = read_operation( $readfunc );

   if( $operation eq "QUIT" ) {
      # Immediate controlled shutdown
      exit( 0 );
   }

   if( $operation eq "EVAL" ) {
      my $code = shift @args;

      my $subref = eval "sub { $code }";
      if( $@ ) {
         send_operation( $writefunc, "DIED", "While compiling code: $@" );
         next;
      }

      my @results = eval { $subref->( @args ) };
      if( $@ ) {
         send_operation( $writefunc, "DIED", "While running code: $@" );
         next;
      }

      send_operation( $writefunc, "RETURNED", @results );
      next;
   }
   
   if( $operation eq "STORE" ) {
      my ( $name, $code ) = @args;

      my $subref = eval "sub { $code }";
      if( $@ ) {
         send_operation( $writefunc, "DIED", "While compiling code: $@" );
         next;
      }

      $stored_procedures{$name} = $subref;
      send_operation( $writefunc, "OK" );
      next;
   }

   if( $operation eq "CALL" ) {
      my $name = shift @args;

      my $subref = $stored_procedures{$name};
      if( !defined $subref ) {
         send_operation( $writefunc, "DIED", "No such stored procedure '$name'" );
         next;
      }

      my @results = eval { $subref->( @args ) };
      if( $@ ) {
         send_operation( $writefunc, "DIED", "While running code: $@" );
         next;
      }

      send_operation( $writefunc, "RETURNED", @results );
      next;
   }

   send_operation( $writefunc, "DIED", "Unknown operation $operation" );
}
EOP

=head1 FUNCTIONS

=cut

=head2 $ips = IPC::PerlSSH->new( @args )

This function returns a new instance of a C<IPC::PerlSSH> object. The
connection can be specified in one of three ways, given in the C<@args> list:

=over 4

=item *

Connecting to a named host.

 Host => $hostname

Optionally passing in the path to the perl binary in the remote host

 Perl => $perl

=item *

Running a specified command, connecting to its standard input and output.

 Command => $command

Or

 Command => [ $command, @args ]

=item *

Using a given pair of functions as read and write operators.

 Readfunc => \&read, Writefunc => \&write

Usually this form won't be used in practice; it largely exists to assist the
test scripts. But since it works, it is included in the interface in case the
earlier alternatives are not suitable.

In this case, the write functions are called as

 read( my $buffer, undef );    # read a line, like <$handle>
 read( my $buffer, $len );     # read a fixed-length buffer

 write( $buffer );

In each case, the returned value should be the number of bytes read or
written.

=back

=cut

sub new
{
   my $class = shift;
   my %opts = @_;


   my ( $readfunc, $writefunc ) = ( $opts{Readfunc}, $opts{Writefunc} );

   my $pid = $opts{Pid};

   if( !defined $readfunc || !defined $writefunc ) {
      my @command;
      if( exists $opts{Command} ) {
         my $c = $opts{Command};
         @command = ref($c) && $c->isa("ARRAY") ? @$c : ( "$c" );
      }
      else {
         my $host = $opts{Host} or
            carp __PACKAGE__."->new() requires a Host, a Command or a Readfunc/Writefunc pair";

         @command = ( "ssh", $host, $opts{Perl} || "perl" );
      }
      
      my ( $readpipe, $writepipe );
      $pid = open2( $readpipe, $writepipe, @command );

      $readfunc = sub {
         if( defined $_[1] ) {
            read( $readpipe, $_[0], $_[1] );
         }
         else {
            $_[0] = <$readpipe>;
            length( $_[0] );
         }
      };

      $writefunc = sub {
         print $writepipe $_[0];
      };
   }

   # Now stream it the "firmware"
   $writefunc->( <<EOF );
use strict;

$COMMON_PERL

$REMOTE_PERL

__END__
EOF

   my $self = {
      readfunc  => $readfunc,
      writefunc => $writefunc,
      pid       => $pid,
   };

   return bless $self, $class;
}

=head2 @result = $ips->eval( $code, @args )

This method evaluates code in the remote host, passing arguments and returning
the result.

The code should be passed in a string, and is evaluated using a string
C<eval> in the remote host, in list context. If this method is called in
scalar context, then only the first element of the returned list is returned.
Only string scalar values are supported in either the arguments or the return
values; no deeply-nested structures can be passed.

To pass or return a more complex structure, consider using a module such as
L<Storable>, which can serialise the structure into a plain string, to be
deserialised on the remote end.

If the remote code threw an exception, then this function propagates it as a
plain string.

=cut

sub eval
{
   my $self = shift;
   my ( $code, @args ) = @_;

   send_operation( $self->{writefunc}, "EVAL", $code, @args );

   my ( $ret, @retargs ) = read_operation( $self->{readfunc} );

   # If the caller didn't want an array and we received more than one result
   # from the far end; we'll just have to throw it away...
   return wantarray ? @retargs : $retargs[0] if( $ret eq "RETURNED" );

   die "Remote host threw an exception:\n$retargs[0]" if( $ret eq "DIED" );

   die "Unknown return result $ret\n";
}

=head2 $ips->store( $name, $code )

This method sends code to the remote host to store in a named procedure which
can be executed later. The code should be passed in a string, along with a
name which can later be called by the C<call> method.

While the code is not executed, it will still be compiled into a CODE
reference in the remote host. Any compile errors that occur will be throw as
exceptions by this method.

=cut

sub store
{
   my $self = shift;
   my ( $name, $code ) = @_;

   send_operation( $self->{writefunc}, "STORE", $name, $code );

   my ( $ret, @retargs ) = read_operation( $self->{readfunc} );

   return if( $ret eq "OK" );

   die "Remote host threw an exception:\n$retargs[0]" if( $ret eq "DIED" );

   die "Unknown return result $ret\n";
}

=head2 $ips->bind( $name, $code )

This method is identical to the C<store> method, except that the remote
function will be available as a plain function within the local perl
program, as a function of the given name in the caller's package.

=cut

sub bind
{
   my $self = shift;
   my ( $name, $code ) = @_;

   $self->store( $name, $code );

   my $caller = (caller)[0];
   {
      no strict 'refs';
      *{$caller."::$name"} = sub { $self->call( $name, @_ ) };
   }
}

=head2 @result = $ips->call( $name, @args )

This method invokes a remote method that has earlier been defined using the
C<store> or C<bind> methods. The arguments are passed and the result is
returned in the same way as with the C<eval> method.

If an exception occurs during execution, it is propagated and thrown by this
method.

=cut

sub call
{
   my $self = shift;
   my ( $name, @args ) = @_;

   send_operation( $self->{writefunc}, "CALL", $name, @args );

   my ( $ret, @retargs ) = read_operation( $self->{readfunc} );

   # If the caller didn't want an array and we received more than one result
   # from the far end; we'll just have to throw it away...
   return wantarray ? @retargs : $retargs[0] if( $ret eq "RETURNED" );

   die "Remote host threw an exception:\n$retargs[0]" if( $ret eq "DIED" );

   die "Unknown return result $ret\n";
}

sub DESTROY
{
   my $self = shift;

   send_operation( $self->{writefunc}, "QUIT" );

   waitpid $self->{pid}, 0 if defined $self->{pid};
}

# We need to include the common shared perl library
eval $COMMON_PERL;

1;

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

=cut
