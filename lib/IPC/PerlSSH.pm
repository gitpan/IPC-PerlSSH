#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2008 -- leonerd@leonerd.org.uk

package IPC::PerlSSH;

use strict;

use base qw( IPC::PerlSSH::Base );

use IPC::Open2;

use Carp;

our $VERSION = "0.09";

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

Optionally passing in an alternative username

 User => $user

Optionally specifying a different path to the F<ssh> binary

 SshPath => $path

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

The functions are called as

 read( my $buffer, $len );

 write( $buffer );

In each case, the returned value should be the number of bytes read or
written.

=back

=cut

sub new
{
   my $class = shift;
   my %opts = @_;

   my $self = bless {
      readbuff => "",
   }, $class;

   my ( $readfunc, $writefunc ) = ( $opts{Readfunc}, $opts{Writefunc} );

   my $pid = $opts{Pid};

   if( !defined $readfunc || !defined $writefunc ) {
      my @command = $self->build_command( %opts );

      my ( $readpipe, $writepipe );
      $pid = open2( $readpipe, $writepipe, @command );

      $readfunc = sub {
         sysread( $readpipe, $_[0], $_[1] );
      };

      $writefunc = sub {
         syswrite( $writepipe, $_[0] );
      };
   }

   $self->{pid}       = $pid;
   $self->{readfunc}  = $readfunc;
   $self->{writefunc} = $writefunc;

   $self->send_firmware;

   return $self;
}

sub write
{
   my $self = shift;
   my ( $data ) = @_;

   $self->{writefunc}->( $data );
}

sub read_message
{
   my $self = shift;

   my ( $message, @args );

   while( !defined $message ) {
      my $b;
      $self->{readfunc}->( $b, 8192 ) or die "Readfunc failed - $!";
      $self->{readbuff} .= $b;
      ( $message, @args ) = $self->parse_message( $self->{readbuff} );
   }

   return ( $message, @args );
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

   $self->write_message( "EVAL", $code, @args );

   my ( $ret, @retargs ) = $self->read_message;

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

   $self->write_message( "STORE", $name, $code );

   my ( $ret, @retargs ) = $self->read_message;

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

   $self->write_message( "CALL", $name, @args );

   my ( $ret, @retargs ) = $self->read_message;

   # If the caller didn't want an array and we received more than one result
   # from the far end; we'll just have to throw it away...
   return wantarray ? @retargs : $retargs[0] if( $ret eq "RETURNED" );

   die "Remote host threw an exception:\n$retargs[0]" if( $ret eq "DIED" );

   die "Unknown return result $ret\n";
}

=head2 $ips->use_library( $library, @funcs )

This method loads a library of code from a module, and stores them to the
remote perl by calling C<store> on each one. The C<$library> name may be a
full class name, or a name within the C<IPC::PerlSSH::Library::> space.

If the C<@funcs> list is non-empty, then only those named functions are stored
(analogous to the C<use> perl statement). This may be useful in large
libraries that define many functions, only a few of which are actually used.

For more information, see L<IPC::PerlSSH::Library>.

=cut

sub use_library
{
   my $self = shift;

   my %funcs = $self->load_library( @_ );

   foreach my $name ( keys %funcs ) {
      $self->store( $name, $funcs{$name} );
   }
}

sub DESTROY
{
   my $self = shift;

   undef $self->{readfunc};
   undef $self->{writefunc};
   # This will clean up the closures, and hence close the filehandles that are
   # referenced by them. The remote perl will then shut down, and we can wait
   # for the child process to exit

   waitpid $self->{pid}, 0 if defined $self->{pid};
}

# Keep perl happy; keep Britain tidy
1;

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

=cut
