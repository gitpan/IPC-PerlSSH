#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2009 -- leonerd@leonerd.org.uk

package IPC::PerlSSH;

use strict;
use warnings;

use base qw( IPC::PerlSSH::Base );

use IPC::Open2;

use Carp;

our $VERSION = '0.14';

=head1 NAME

C<IPC::PerlSSH> - execute remote perl code over an SSH link

=head1 SYNOPSIS

 use IPC::PerlSSH;

 my $ips = IPC::PerlSSH->new( Host => "over.there" );

 $ips->eval( "use POSIX qw( uname )" );
 my @remote_uname = $ips->eval( "uname()" );

 # We can pass arguments
 $ips->eval( 'open FILE, ">", $_[0]; print FILE $_[1]; close FILE;',
             "foo.txt", "Hello, world!" );

 # We can pre-compile stored procedures
 $ips->store( "get_file", 'local $/; 
                           open FILE, "<", $_[0];
                           $_ = <FILE>;
                           close FILE;
                           return $_;' );
 foreach my $file ( @files ) {
    my $content = $ips->call( "get_file", $file );
    ...
 }

 # We can use existing libraries for remote stored procedures
 $ips->use_library( "FS", qw( readfile ) );
 foreach my $file ( @files ) {
    my $content = $ips->call( "readfile", $file );
    ...
 }

=head1 DESCRIPTION

This module provides an object class that provides a mechanism to execute perl
code in a remote instance of perl running on another host, communicated via an
SSH link or similar connection. Where it differs from most other IPC modules
is that no special software is required on the remote end, other than the
ability to run perl. In particular, it is not required that the
C<IPC::PerlSSH> module is installed there. Nor are any special administrative
rights required; any account that has shell access and can execute the perl
binary on the remote host can use this module.

=head2 Argument Passing

The arguments to, and return values from, remote code are always transferred
as lists of strings. This has the following effects on various types of
values:

=over 8

=item *

String values are passed as they stand.

=item *

Booleans and integers will become stringified, but will work as expected once
they reach the other side of the connection.

=item *

Floating-point numbers will get converted to a decimal notation, which may
lose precision.

=item *

A single array of strings, or a single hash of string values, can be passed
by-value as a list, possibly after positional arguments:

 $ips->store( 'foo', 'my ( $arg, @list ) = @_; ...' );

 $ips->store( 'bar', 'my %opts = @_; ...' );

=item *

No reference value, including IO handles, can be passed; instead it will be
stringified.

=back

To pass or return a more complex structure, consider using a module such as
L<Storable>, which can serialise the structure into a plain string, to be
deserialised on the remote end. Be aware however, that C<Storable> was only
added to core in perl 5.7.3, so if the remote perl is older, it may not be
available.

To work with remote IO handles, see the L<IPC::PerlSSH::Library::IO> module.

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

The C<Command> key can be used to create an C<IPC::PerlSSH> running perl
directly on the local machine, for example; so that the "remote" perl is in
fact running locally, but still in its own process.

 my $ips = IPC::PerlSSH->new( Command => $^X );

=cut

sub new
{
   my $class = shift;
   my %opts = @_;

   my $self = bless {
      readbuff => "",
      stored => {},
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

If the remote code threw an exception, then this function propagates it as a
plain string.

=cut

sub eval
{
   my $self = shift;
   my ( $code, @args ) = @_;

   $self->write_message( "EVAL", $code, @args );

   my ( $ret, @retargs ) = $self->read_message;

   if( $ret eq "RETURNED" ) {
      # If the caller didn't want an array and we received more than one result
      # from the far end; we'll just have to throw it away...
      return wantarray ? @retargs : $retargs[0];
   }
   elsif( $ret eq "DIED" ) {
      my ( $message ) = @retargs;
      if( $message =~ m/^While compiling code:.* at \(eval \d+\) line (\d+)/ ) {
         $message .= " ==> " . (split m/\n/, $code)[$1 - 1] . "\n";
      }
      die "Remote host threw an exception:\n$message";
   }
   else {
      die "Unknown return result $ret\n";
   }
}

=head2 $ips->store( $name, $code )

=head2 $ips->store( %funcs )

This method sends code to the remote host to store in named procedure(s) which
can be executed later. The code should be passed in strings.

While the code is not executed, it will still be compiled into CODE references
in the remote host. Any compile errors that occur will be throw as exceptions
by this method.

Multiple functions may be passed in a hash, to reduce the number of network
roundtrips, which may help latency.

=cut

sub store
{
   my $self = shift;
   my %funcs = @_;

   foreach my $name ( keys %funcs ) {
      $self->_has_stored_code( $name ) and croak "Already have a stored function called '$name'";
   }

   $self->write_message( "STORE", %funcs );

   my ( $ret, @retargs ) = $self->read_message;

   if( $ret eq "OK" ) {
      $self->{stored}{$_} = 1 for keys %funcs;
      return;
   }
   elsif( $ret eq "DIED" ) {
      my ( $message ) = @retargs;
      if( $message =~ m/^While compiling code for (\S+):.* at \(eval \d+\) line (\d+)/ ) {
         my $code = $funcs{$1};
         $message .= " ==> " . (split m/\n/, $code)[$2 - 1] . "\n";
      }
      die "Remote host threw an exception:\n$message";
   }
   else {
      die "Unknown return result $ret\n";
   }
}

sub _has_stored_code
{
   my $self = shift;
   my ( $name ) = @_;
   return exists $self->{stored}{$name};
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

   $self->_has_stored_code( $name ) or croak "Do not have a stored function called '$name'";

   $self->write_message( "CALL", $name, @args );

   my ( $ret, @retargs ) = $self->read_message;

   if( $ret eq "RETURNED" ) {
      # If the caller didn't want an array and we received more than one result
      # from the far end; we'll just have to throw it away...
      return wantarray ? @retargs : $retargs[0];
   }
   elsif( $ret eq "DIED" ) {
      die "Remote host threw an exception:\n$retargs[0]";
   }
   else {
      die "Unknown return result $ret\n";
   }
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

   my ( $package, $funcs ) = $self->load_library_pkg( @_ );

   $self->{stored_pkg}{$package} and delete $funcs->{_init};

   $self->write_message( "STOREPKG", $package, %$funcs );

   my ( $ret, @retargs ) = $self->read_message;

   if( $ret eq "OK" ) {
      $self->{stored_pkg}{$package} = 1;
      $self->{stored}{$_} = 1 for keys %$funcs;
      return;
   }
   elsif( $ret eq "DIED" ) {
      die "Remote host threw an exception:\n$retargs[0]";
   }
   else {
      die "Unknown return result $ret\n";
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

Paul Evans <leonerd@leonerd.org.uk>

=cut
