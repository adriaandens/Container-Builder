# NAME

Container::Builder - Build Container archives.

# SYNOPSIS

    # See also the examples/ folder of this module.
    use v5.40;
    
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
    # Perl base
    $builder->add_deb_package('libcrypt1');
    $builder->add_deb_package('perl-base');
    $builder->add_group('root', 0);
    $builder->add_group('tty', 5);
    $builder->add_group('staff', 50);
    $builder->add_group('larry', 1337);
    $builder->add_group('nobody', 65000);
    $builder->add_user('root', 0, 0, '/sbin/nologin', '/root');
    $builder->add_user('nobody', 65000, 65000, '/sbin/nologin', '/nohome');
    $builder->add_user('larry', 1337, 1337, '/sbin/nologin', '/home/larry');
    $builder->runas_user('larry');
    $builder->set_env('PATH', '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin');
    $builder->set_work_dir('/home/larry/');
    $builder->set_entry('perl', 'testproggie.pl');
    my $testproggie = <<'PROG';
    use v5.36;
    say "Hallo vriendjes en vriendinnetjes!";
    PROG
    $builder->add_file_from_string($testproggie, '/home/larry/testproggie.pl', 0644, 1337, 1337); # our program
    $builder->build('01-hello-world.tar');
    say "Now run: podman load -i 01-hello-world.tar";
    say "Then run: podman run " . substr($builder->get_digest(), 0, 12);

# DESCRIPTION

Container::Builder builds a TAR archive that can be imported into Podman or Docker. It's main use is to craft specific, small containers based on Debian package (.deb) files. The type of functions to extend are similar to those that you can find in a Dockerfile. 

We use a Build pattern to build the archive. Most functions return quickly, and only the `build()` function actually creates all the layers of the container and writes the result to disk.

Look into the `examples/` folder for some examples to make working Perl (Dancer2) images.

**Note**: This module is not production-ready! It's still in early stages of development and maturity.

# METHODS

- new(debian\_pkg\_hostname => 'mirror.as35701.net', \[compress\_deb\_tar => 1\], \[os\_version => 'bookworm'\], \[cache\_folder => 'artifacts/'\], \[enable\_packages\_cache => 0\], \[packages\_file => 'Packages'\])
(the square brackets signify that the parameter is optional, not an array ref)

            field $enable_packages_cache :param = 0;
            field $packages_file :param = 'Packages';

    Create a Container::Builder object. Only the `debian_pkg_hostname` parameter is required so you can pick a Debian mirror close to the geographical region from where the code is running. See [https://www.debian.org/mirror/list](https://www.debian.org/mirror/list).

    `compress_deb_tar` compresses the debian TAR archives with Gzip before storing. You're trading build speeds in for less disk space.

    `os_version` controls which Debian Packages will be used to find the packages on the mirror.

    When `cache_folder` is defined, the folder will be used to store the downloaded deb packages and it will be used in subsequent runs as a cache so we don't retrieve it from the debian mirror every single time.

    `enable_packages_cache` will look for a Packages file defined by `packages_file` option. If it doesn't exist, it will be downloaded from the Debian mirror. If it does exist, it will be read from disk instead of getting a fresh copy.

- add\_deb\_package('libperl5.36')

    Add a Debian package to the container. The `data.tar` file inside the Debian package file (`.deb`) will be stored as a layer in the resulting container. 

- add\_deb\_package\_from\_file($filepath\_deb)

    Add a Debian package file to the container. The `data.tar` file inside the Debian package file (`.deb`) will be stored as a layer in the resulting container. 

- extract\_from\_deb($package\_name, $files\_to\_extract)

    Extract certain files from the Debian package before storing as a layer. `$package_name` is the name of the Debian package, `$files_to_extract` is an array ref containing a list of files to extract. Rudimentary support for globs/wildcards (only useable at the end of the string).

- add\_file($file\_on\_disk, $location\_in\_ctr, $mode, $user, $group)

    Adds the local file `$file_on_disk` inside the container at location `$location_in_ctr` with the specified `$mode`, `$user` and `$group`.

- add\_file\_from\_string($data, $location\_in\_ctr, $mode, $user, $group)

    Adds the data in the scalar `$data` to the container at location `$location_in_ctr` with the specified `$mode`, `$user` and `$group`.

- copy($local\_dirpath, $location\_in\_ctr, $mode, $user, $group)

    Recursively copy the `$local_dirpath` directory into a layer of the container. The resulting path inside the container is defined by `$location_in_ctr`. `$mode` controls the directory permission of `$location_in_ctr` only. Inner directories will have the permissions as on the local filesystem. All directories and files will be changed to be owned by `$user` and `$group`.

    If `$location_in_ctr` has a slash at the end, the last directory of `$local_dirpath` will become a subdirectory of the path `$location_in_ctr`. Otherwise, the last directory of `$local_dirpath` will be renamed to the last directory of `$location_in_ctr`.

    For example `copy('lib/', '/app/')` will create `/app/lib/` but `copy('lib/', '/app')` will put all put the files and directories directly inside `/app`, there will be no `lib` directory.

- create\_directory($path, $mode, $uid, $gid)

    Create an empty directory at `$path` inside the container with the specified `$mode`, `$user` and `$group`.

- add\_user($name, $uid, $main\_gid, $shell, $homedir)

    Add a user to the container. This puts the user inside the `/etc/passwd` file.

- add\_group($name, $gid)

    Add a group to the container. This puts the group inside the `/etc/group` file.

- runas\_user($user)

    Specify the user to run the entrypoint as.

- set\_env($key, $value)

    Add a environment variable to the container definition.

- set\_entry(@command\_str)

    Set the default entrypoint of the container.

- set\_work\_dir($workdirectory)

    Set the default working directory of the container.

- build()
- build('mycontainer.tar')

    Build the container and write the result to the filepath specified. If no argument is given, the entire archive is returned as a scalar from the method.

- get\_digest()

    Returns the digest of the embedded config file in the archive. This digest is used by tools such as podman as a unique ID to your container.

- get\_layers()

    Returns a list of `Container::Builder::Layer` objects as currently added to the Builder. 

    Note: During build() extra layers can be added in the front or at the end of this list.

# AUTHOR

Adriaan Dens <adri@cpan.org>

# COPYRIGHT

Copyright 2026- Adriaan Dens

# LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# SEE ALSO

Google distroless containers are the main inspiration for creating this module. The idea of creating minimal containers based on Debian packages comes from the Bazel build code that uses these packages to provide a minimal working container. My own examples do the same.
