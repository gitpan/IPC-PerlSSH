package t::Stash;

use IPC::PerlSSH::Library;

init 'our %pad;';

func put => '$pad{$_[0]} = $_[1]';

func get => '$pad{$_[0]}';

1;
