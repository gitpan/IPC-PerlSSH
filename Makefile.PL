use ExtUtils::MakeMaker;

WriteMakefile(
   NAME         => "IPC::PerlSSH",
   VERSION_FROM => "lib/IPC/PerlSSH.pm",
   PREREQ_PM => {
      'IPC::Open2' => 0,
      'Test::More' => 0,
   },
);
