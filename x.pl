use v5.40;

# Big TODO:
# * Be more flexible in what it can generate (currently fixed debian, amd64, ...)
# * Do a lot more input checking on input from the User like the environment variables, CMD, username that runs, ...
# * Maybe remove the /usr/share/doc/ files from the archives since it's an execute-only container, there's no tools to view docs anyway...
# * Make the builder generate the same artifacts every time, so no "created" dates etc. but a byte-per-byte exact archive with the same input. (Also remove Builder version)
#   * This also implies controlling all dates from all files in the TAR.
# * Make the builder "date" aware. When passed a certain date (< today), we want to "see" the Debian packages that were available back then, not the latest ones that are available today. Effectively allowing you to go back in time and regenerate the exact image as you did on date X.
# * Scrub GZIP archive timestamps so that they generate the same digest every time!

use Container::Builder;

my $builder = Container::Builder->new(debian_pkg_hostname => 'debian.inf.tu-dresden.de');
$builder->create_directory('/', 0755, 0, 0);
$builder->create_directory('bin/', 0755, 0, 0);
$builder->create_directory('tmp/', 01777, 0, 0);
$builder->create_directory('root/', 0700, 0, 0);
$builder->create_directory('home/', 0755, 0, 0);
$builder->create_directory('home/larry/', 0700, 1337, 1337);
$builder->create_directory('etc/', 0755, 0, 0);
$builder->create_directory('app/', 0755, 1337, 1337);
# C dependencies (to run a compiled executable)
$builder->add_deb_package('libc-bin');
$builder->add_deb_package('libc6');
$builder->add_deb_package('gcc-12-base');
$builder->add_deb_package('libgcc-s1');
$builder->add_deb_package('libgomp1');
$builder->add_deb_package('libstdc++6');
$builder->add_deb_package('ca-certificates');
# SSL support
$builder->add_deb_package('libssl3');
# Perl dependencies (to run a basic Perl program)
$builder->add_deb_package('libcrypt1');
$builder->add_deb_package('perl-base');
# This is all extra (not needed for a hello world)
#$builder->add_deb_package('perl-modules-5.36');
#$builder->add_deb_package('libperl5.36');
#$builder->add_deb_package('perl');
# My fatpack expects these to be already installed somehow
$builder->add_deb_package('libtry-tiny-perl');
$builder->add_deb_package('libdevel-stacktrace-perl');
$builder->add_deb_package('libdevel-stacktrace-ashtml-perl');
# html::parser contains xs code so no can do with fatpack
$builder->add_deb_package('libhtml-parser-perl');
	# depends on:
	$builder->add_deb_package('liburi-perl');
		$builder->add_deb_package('libregexp-ipv6-perl');
	$builder->add_deb_package('libhtml-tagset-perl');
# same for Clone 
$builder->add_deb_package('libclone-perl');
$builder->add_group('root', 0);
$builder->add_group('tty', 5);
$builder->add_group('staff', 50);
$builder->add_group('larry', 1337);
$builder->add_group('nobody', 65000);
$builder->add_user('root', 0, 0, '/sbin/nologin', '/root');
$builder->add_user('nobody', 65000, 65000, '/sbin/nologin', '/nohome');
$builder->add_user('larry', 1337, 1337, '/sbin/nologin', '/home/larry');
$builder->runas_user('root');
$builder->set_env('PATH', '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin');
$builder->set_work_dir('/');
$builder->set_entry('perl');
$builder->add_file('testproggie.pl', '/home/larry/testproggie.pl', 0644, 1337, 1337); # our program
$builder->build('hehe.tar');
