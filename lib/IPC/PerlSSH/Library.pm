#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package IPC::PerlSSH::Library;

use strict;

use base qw( Exporter );
our @EXPORT = qw( func );
use Carp;

our $VERSION = '0.10';

=head1 NAME

C<IPC::PerlSSH::Library> - support package for declaring libraries of remote
functions

=head1 DESCRIPTION

This module allows the creation of pre-prepared libraries of functions which
may be loaded into a remote perl running via C<IPC::PerlSSH>.

=head1 SYNOPSIS

 package IPC::PerlSSH::Library::Info;

 use strict;
 use IPC::PerlSSH::Library;

 func( uname   => 'uname()' );
 func( ostype  => '$^O' );
 func( perlbin => '$^X' );

 1;

This can be loaded by

 use IPC::PerlSSH;

 my $ips = IPC::PerlSSH->new( Host => "over.there" );

 $ips->load_library( "Info" );

 print "Remote perl is running from " . $ips->call("perlbin") . "\n";
 print " Running on a machine of type " . $ips->call("ostype") .
                                          $ips->call("uname") . "\n";

=cut

my %package_funcs;

=head1 FUNCTIONS

=cut

=head2 func( $name, $code )

Declare a function called $name, which is implemented using the source code in
$code. Note that $code must be a plain string, I<NOT> a CODE reference.

=cut

sub func
{
   my ( $name, $code ) = @_;
   my $caller = caller;

   $package_funcs{$caller}->{$name} = $code;
}

sub funcs
{
   my ( $classname, @funcs ) = @_;

   my $package_funcs = $package_funcs{$classname};
   $package_funcs or croak "$classname does not define any library functions";

   my %funcs;

   if( @funcs ) {
      foreach my $f ( @funcs ) {
         $package_funcs->{$f} or croak "$classname does not define a library function called $f";
         $funcs{$f} = $package_funcs->{$f};
      }
   }
   else {
      %funcs = %{ $package_funcs };
   }

   %funcs;
}

# Keep perl happy; keep Britain tidy
1;

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>

=cut
