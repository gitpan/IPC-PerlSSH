use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new
  (
   module_name => 'IPC::PerlSSH',
   dist_version_from => 'lib/IPC/PerlSSH.pm',
   requires => {
                 'IPC::Open2' => 0,
               },
   build_requires => {
                        'Test::More' => 0,
                     },
   license => 'perl',
   create_makefile_pl => 'traditional',
  );
  
$build->create_build_script;
