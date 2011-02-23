#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2006-2011 -- leonerd@leonerd.org.uk

package IPC::PerlSSH::Base;

use strict;
use warnings;

use Carp;

our $VERSION = '0.15';

=head1 NAME

C<IPC::PerlSSH::Base> - base functionallity behind L<IPC::PerlSSH>

=head1 DESCRIPTION

This module provides the low-level message formatting and parsing code used by
C<IPC::PerlSSH>, and the perl code to be executed on the remote server once a
connection is established.

This split exists, in order to make it easier to write other modules that use
the same behaviour. For example, an asynchronous version could be written
using this as a base class.

=cut

# And now for the main loop of the remote firmware
my $REMOTE_PERL = <<'EOP';
$| = 1;

sub send_message
{
   my ( $message, @args ) = @_;

   my $buffer = "";

   $buffer .= "$message\n";
   $buffer .= scalar( @args ) . "\n";

   foreach my $arg ( @args ) {
      $buffer .= length( $arg ) . "\n" . "$arg";
   }

   print STDOUT $buffer;
};

sub read_message
{
   local $/ = "\n";

   my $message = <STDIN>;
   defined $message or return "QUIT";
   chomp $message;

   my $numargs = <STDIN>;
   defined $numargs or die "Expected number of arguments\n";
   chomp $numargs;

   my @args;
   while( $numargs ) {
      my $arglen = <STDIN>;
      defined $arglen or die "Expected length of argument\n";
      chomp $arglen;

      my $arg = "";
      while( $arglen ) {
         my $n = read( STDIN, $arg, $arglen, length $arg );
         die "read() returned $!\n" unless( defined $n );
         $arglen -= $n;
      }

      push @args, $arg;
      $numargs--;
   }

   return ( $message, @args );
}

my %compilers;
my %stored_procedures;

sub store
{
   my ( $package, %subs ) = @_;

   my $compiler;
   unless( $compiler = $compilers{$package} ) {
      my $preamble = delete $subs{_init} || "";
      $compiler = eval "package $package; $preamble; sub { eval \$_[0] }";
      if( $@ ) {
         send_message( "DIED", "While compiling initialisation code: $@" );
         return;
      }
      $compilers{$package} = $compiler;
   }

   foreach my $name ( keys %subs ) {
      $stored_procedures{$name} = $compiler->( "sub { $subs{$name} }" ) and next;
      send_message( "DIED", "While compiling code for $name: $@" );
      return;
   }

   send_message( "OK" );
   return;
}

while( 1 ) {
   my ( $message, @args ) = read_message;

   if( $message eq "QUIT" ) {
      # Immediate controlled shutdown
      exit( 0 );
   }

   if( $message eq "EVAL" ) {
      my $code = shift @args;

      my $subref = eval "sub { $code }";
      if( $@ ) {
         send_message( "DIED", "While compiling code: $@" );
         next;
      }

      my @results = eval { $subref->( @args ) };
      if( $@ ) {
         send_message( "DIED", "While running code: $@" );
         next;
      }

      send_message( "RETURNED", @results );
      next;
   }
   
   if( $message eq "STORE" ) {
      store( "main", @args );
      next;
   }

   if( $message eq "STOREPKG" ) {
      store( @args );
      next;
   }

   if( $message eq "CALL" ) {
      my $name = shift @args;

      my $subref = $stored_procedures{$name};
      if( !defined $subref ) {
         send_message( "DIED", "No such stored procedure '$name'" );
         next;
      }

      my @results = eval { $subref->( @args ) };
      if( $@ ) {
         send_message( "DIED", "While running code: $@" );
         next;
      }

      send_message( "RETURNED", @results );
      next;
   }

   send_message( "DIED", "Unknown message $message" );
}
EOP

sub build_command
{
   my $self = shift;
   my %opts = @_;

   my @command;
   if( exists $opts{Command} ) {
      my $c = $opts{Command};
      @command = ref($c) && UNIVERSAL::isa( $c, "ARRAY" ) ? @$c : ( "$c" );
   }
   else {
      my $host = $opts{Host} or
         croak ref($self)." requires a Host, a Command or a Readfunc/Writefunc pair";

      defined $opts{User} and $host = "$opts{User}\@$host";

      my @options;

      push @options, "-p", $opts{Port} if defined $opts{Port};

      push @options, @{ $opts{SshOptions} } if defined $opts{SshOptions};

      @command = ( $opts{SshPath} || "ssh", @options, $host, $opts{Perl} || "perl" );
   }

   return @command;
}

sub send_firmware
{
   my $self = shift;

   $self->write( <<EOF );
use strict;

$REMOTE_PERL

__END__
EOF
}

sub parse_message
{
   my $self = shift;
   my $buffer = $_[0]; # We'll assign it back at the end if successful

   $buffer =~ s/^(.*)\n(.*)\n// or return;
   my ( $message, $numargs ) = ( $1, $2 );

   my @args;
   while( $numargs ) {
      $buffer =~ s/^(.*)\n// or return;
      my $arglen = $1;

      length $buffer >= $arglen or return;

      my $arg = substr( $buffer, 0, $arglen, "" );

      push @args, $arg;
      $numargs--;
   }

   # If we got this far, we've successfully parsed a message. Reassign the
   # buffer back again
   $_[0] = $buffer;

   return ( $message, @args );
}

# Internal methods
sub write_message
{
   my $self = shift;
   my ( $message, @args ) = @_;

   my $buffer = "";

   $buffer .= "$message\n";
   $buffer .= scalar( @args ) . "\n";

   foreach my $arg ( @args ) {
      $buffer .= length( $arg ) . "\n" . "$arg";
   }

   $self->write( $buffer );
}

sub load_library_pkg
{
   my $self = shift;
   my ( $library, @funcs ) = @_;

   require IPC::PerlSSH::Library;

   my $classname;

   # $library may or may not have IPC::PerlSSH::Library:: prefix... try both
   # ways
   foreach my $module ( "IPC::PerlSSH::Library::$library", "$library" ) {
      ( my $filename = $module ) =~ s{::}{/}g; $filename .= ".pm";

      $classname = $module;

      eval { require $filename } and last;

      undef $classname;

      # Examine the error - if we can't find it, go on to the next.
      # Anything else, we'll throw a wobbly. Make sure also it's this file
      # in particular it wants, as opposed to one of its dependencies.
      next if $@ =~ m/^Can't locate \Q$filename\E in \@INC/;

      die $@;
   }

   unless( defined $classname ) {
      croak "Cannot find an IPC::PerlSSH library called $library";
   }

   my %funcs = IPC::PerlSSH::Library::funcs( $classname, @funcs );

   # Don't bother loading again anything already present
   foreach my $name ( keys %funcs ) {
      next if $name =~ m/^_/;

      $self->_has_stored_code( $name ) and delete $funcs{$name};
   }

   return $classname, \%funcs;
}

sub load_library
{
   my $self = shift;
   ( undef, my $funcs ) = $self->load_library_pkg( @_ );
   return %$funcs;
}

# for subclasses to override
sub _has_stored_code
{
   return 0;
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;