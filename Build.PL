use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
   module_name => 'IPC::PerlSSH',
   dist_version_from => 'lib/IPC/PerlSSH.pm',
   requires => {
      'IPC::Open2' => 0,
   },
   build_requires => {
      'File::Temp' => 0,
      'IO::Handle' => 0,
      'Test::Fatal' => 0,
      'Test::More' => 0,
   },
   license => 'perl',
   create_makefile_pl => 'traditional',
   create_license => 1,
   create_readme  => 1,
);

$build->create_build_script;
