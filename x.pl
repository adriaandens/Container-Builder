use v5.40;
use feature 'class';
use feature 'defer';
no warnings 'experimental::class';
no warnings 'experimental::defer';

# Big TODO:
# * Instead of concatenating a JSON string (many issues with escaping characters, injections, ...) make an object and let a Perl module handle this.
# * Be more flexible in what it can generate (currently fixed debian, amd64, ...)
# * Do a lot more input checking on input from the User like the environment variables, CMD, username that runs, ...
# * Maybe remove the /usr/share/doc/ files from the archives since it's an execute-only container, there's no tools to view docs anyway...
# * Make the builder generate the same artifacts every time, so no "created" dates etc. but a byte-per-byte exact archive with the same input. (Also remove Builder version)
#   * This also implies controlling all dates from all files in the TAR.
# * Make the builder "date" aware. When passed a certain date (< today), we want to "see" the Debian packages that were available back then, not the latest ones that are available today. Effectively allowing you to go back in time and regenerate the exact image as you did on date X.

use Archive::Ar;
use Archive::Tar;
use IO::Uncompress::UnXz qw(unxz); # Uncompress the XZ (only tar+gzip is supported in OCI spec)
use IO::Compress::Gzip qw(gzip); # Recompress as GZIP (supported by OCI spec)
use Cwd;
use DateTime;
use File::Copy;
use Crypt::Digest::SHA256 qw(sha256_hex sha256_file_hex);

class Container::Layer {
	field $blob_dir :param :reader(get_blob_dir);

	# This method is called in the builder to generate the artifact (bytes on disk) that will be put in the container image
	method generate_artifact() { }

	# These three methods are used by the manifest to generate the layers array
	method get_media_type() { }
	method get_digest() { }
	method get_size() { }
}

class Container::Layer::Tar :isa(Container::Layer) {
	field $data :param;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		$digest = Crypt::Digest::SHA256::sha256_hex($data);
		$size = length($data);
		open(my $f, '>', $self->get_blob_dir() . $digest);
		print $f $data;
		close($f);
		return $self->get_blob_dir() . $digest;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Layer::TarGzip :isa(Container::Layer) {
	field $file :param;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		die "Unable to read file $file\n" if !-r $file;
		$digest = Crypt::Digest::SHA256::sha256_file_hex($file);
		File::Copy::copy($file, $self->get_blob_dir() . $digest);
		$size = (stat($self->get_blob_dir() . $digest))[7];
		return $self->get_blob_dir() . $digest;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar+gzip" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Layer::SingleFile :isa(Container::Layer) {
	field $file :param = undef;
	field $data :param = undef;
	field $dest :param;
	field $mode :param;
	field $user :param;
	field $group :param;
	field $generated_artifact = 0;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		my $tar = Container::Builder::Tar->new();
		if(defined($file)) { # We gotta read the file
			local $/ = undef;
			open(my $f, '<', $file) or die "Cannot read $file\n";
			$data = <$f>;
			close($f);
		}
		if(!defined($data)) {
			$data = ""; # Set data to an empty string if nothing was passed (we want an empty file...)
		}
		$tar->add_file($dest, $data, $mode, $user, $group);
		my $tar_content = $tar->get_tar();
		$digest = Crypt::Digest::SHA256::sha256_hex($tar_content);
		$size = length($tar_content);
		say "writing file $dest $digest to disk";
		open(my $t, '>', $self->get_blob_dir() . $digest) or die "Cannot open blob file for writing\n";
		print $t $tar_content;
		close($t);
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar+gzip" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Layer::DebianPackageFile :isa(Container::Layer) { 
	field $file :param;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		die "Unable to read file $file\n" if !-r $file;
		my $ar = Archive::Ar->new($file);
		# TODO: support data.tar, data.tar.gz, data.tgz, ...
		die "Unable to find data.tar.xz inside deb package\n" if !$ar->contains_file('data.tar.xz');
		$ar->extract_file('data.tar.xz');
		# TODO: we should probably be dropping these in work_dir from Container::Config ? and not in the cwd ?
		IO::Uncompress::UnXz::unxz('data.tar.xz' => 'data.tar') or die "Unable to extract data.tar from data.tar.xz\n";
		IO::Compress::Gzip::gzip('data.tar' => 'data.tar.gz') or die "Unable to gzip data.tar into data.tar.gz\n";
		unlink('data.tar'); unlink('data.tar.xz'); # TODO: Instead of dying above, we need to cleanup the files we make...

		# Now that we have our tar+gzip file, we basically have our layer so we just move and rename it.
		$digest = Crypt::Digest::SHA256::sha256_file_hex('data.tar.gz');
		File::Copy::move("data.tar.gz", $self->get_blob_dir() . $digest);
		$size = (stat($self->get_blob_dir() . $digest))[7];
		return $self->get_blob_dir() . $digest;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar+gzip" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

# Our own implementation for creating directories because Archive::Tar doesn't allow us to do this.
# It supports adding data via "add_data()" but this doesn't set the correct options in Archive::Tar::File
# since it's instantiated as a file with data Archive::Tar::File->new(data => $filename, $data, $options)
# which in that class does not check the options because we're passing data...
# 
# So here we are making TAR files from scratch...
class Container::Builder::Tar {
	field $full_tar = '';

	method get_tar() {
		my $str = $full_tar;
		$str .= "\x00" x 1024; # 2 empty blocks at the end
		return $str;
	}

	method add_dir($path, $mode, $uid, $gid) {
		$path = '.' . $path if $path =~ /^\//;
		die "Path is longer than 98 chars" if length($path) > 98;
		die "Mode is too long" if length(sprintf("%07o", int($mode))) > 7;
		die "Uid is too long" if length(sprintf("%07o", int($uid))) > 7;
		die "Gid is too long" if length(sprintf("%07o", int($gid))) > 7;
		my $tar = $path . "\x00" x (100-length($path)); #  char name[100];               /*   0 */
		$tar .= sprintf("%07o", int($mode)) . "\x00"; #  char mode[8];                 /* 100 */
		$tar .= sprintf("%07o", int($uid)) . "\x00"; #  char uid[8];                  /* 108 */ -> not sure why we use 6 bytes but that's how other tars do it
		$tar .= sprintf("%07o", int($gid)) . "\x00"; #  char gid[8];                  /* 116 */ -> not sure why we use 6 bytes but that's how other tars do it
		$tar .= sprintf("%011o", 0) . "\x00"; #  char size[12];                /* 124 */ -> dir size is always 0...
		$tar .= sprintf("%011o", time()) . "\x00"; #  char mtime[12];               /* 136 */
		$tar .= "\x20" x 8; #  char chksum[8];               /* 148 */ -> we'll do this later
		$tar .= "5"; #  char typeflag;                /* 156 */ --> A dir is 5
		$tar .= "\x00" x 100; #  char linkname[100];           /* 157 */
		$tar .= "ustar\x00"; #  char magic[6];                /* 257 */
		$tar .= "00"; #  char version[2];              /* 263 */
		#$tar .= "ustar\x20\x20\x00";
		$tar .= "\x00" x 32; #  char uname[32];               /* 265 */
		$tar .= "\x00" x 32; #  char gname[32];               /* 297 */
		$tar .= "\x00" x 8; #  char devmajor[8];             /* 329 */
		$tar .= "\x00" x 8; #  char devminor[8];             /* 337 */
		$tar .= "\x00" x 155; #  char prefix[155];             /* 345 */

		my $checksum = 0;
		map { $checksum += ord($_) } split //, $tar;
		# NOT LIKE THE SPEC!
		# I don't know why but all tar archives that I look at only use 6 bytes for the checksum instead of 7 + null byte.
		# When I followed the spec to a tee, it gave errors. When I do the same and make a 6 byte number (no zeroes in front) + null byte + left over space (\x20), it works...
		# Don't ask me why...
		my $checksum_str = sprintf("%6o", $checksum);
		say "Checksum is $checksum_str";
		$tar =~ s/^(.{148}).{7}/$1.$checksum_str."\x00"/e; # Overwrite checksum bytes

		$tar .= "\x00" x 12; # create a block of 512, the header is 500 bytes.

		$full_tar .= $tar;
	}

	method add_file($filepath, $data, $mode, $uid, $gid) {
		$filepath = '.' . $filepath if $filepath =~ /^\//; # When given an absolute path, we actually need to make it ./
		die "Path is longer than 98 chars" if length($filepath) > 98;
		die "Mode is too long" if length(sprintf("%07o", int($mode))) > 7;
		die "Uid is too long" if length(sprintf("%07o", int($uid))) > 7;
		die "Gid is too long" if length(sprintf("%07o", int($gid))) > 7;
		my $tar = $filepath . "\x00" x (100-length($filepath)); #  char name[100];               /*   0 */
		$tar .= sprintf("%07o", int($mode)) . "\x00"; #  char mode[8];                 /* 100 */
		$tar .= sprintf("%07o", int($uid)) . "\x00"; #  char uid[8];                  /* 108 */
		$tar .= sprintf("%07o", int($gid)) . "\x00"; #  char gid[8];                  /* 116 */ 
		$tar .= sprintf("%011o", length($data)) . "\x00"; #  char size[12];                /* 124 */ 
		$tar .= sprintf("%011o", time()) . "\x00"; #  char mtime[12];               /* 136 */
		$tar .= "\x20" x 8; #  char chksum[8];               /* 148 */ -> we'll do this later
		$tar .= "0"; #  char typeflag;                /* 156 */ --> A regular file is 0
		$tar .= "\x00" x 100; #  char linkname[100];           /* 157 */
		$tar .= "ustar\x00"; #  char magic[6];                /* 257 */
		$tar .= "00"; #  char version[2];              /* 263 */
		$tar .= "\x00" x 32; #  char uname[32];               /* 265 */
		$tar .= "\x00" x 32; #  char gname[32];               /* 297 */
		$tar .= "\x00" x 8; #  char devmajor[8];             /* 329 */
		$tar .= "\x00" x 8; #  char devminor[8];             /* 337 */
		$tar .= "\x00" x 155; #  char prefix[155];             /* 345 */

		my $checksum = 0;
		map { $checksum += ord($_) } split //, $tar;
		# NOT LIKE THE SPEC!
		# I don't know why but all tar archives that I look at only use 6 bytes for the checksum instead of 7 + null byte.
		# When I followed the spec to a tee, it gave errors. When I do the same and make a 6 byte number (no zeroes in front) + null byte + left over space (\x20), it works...
		# Don't ask me why...
		my $checksum_str = sprintf("%6o", $checksum);
		say "Checksum is $checksum_str";
		$tar =~ s/^(.{148}).{7}/$1.$checksum_str."\x00"/e; # Overwrite checksum bytes

		$tar .= "\x00" x 12; # create a block of 512, the header is 500 bytes.

		$tar .= $data;
		my $remainder = length($data) % 512;
		$tar .= "\x00" x (512 - $remainder);

		$full_tar .= $tar;
	}
}

class Container::Layer::Directory :isa(Container::Layer) {
	field $path :param;
	field $mode :param;
	field $uid :param;
	field $gid :param;
	field $digest = 0;
	field $size = 0;

	method generate_artifact() {
		my $tar = Container::Builder::Tar->new();
		$tar->add_dir($path, $mode, $uid, $gid);
		my $tar_content = $tar->get_tar();
		$digest = Crypt::Digest::SHA256::sha256_hex($tar_content);
		$size = length($tar_content);
		open(my $f, '>', $self->get_blob_dir() . $digest) or die "Cannot open $digest for writing\n";
		print $f $tar_content;
		close($f);
		return $self->get_blob_dir() . $digest;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }

}

class Container::Config {
	field $digest = '';
	field $size = '';

	method generate_config($user = 'root', $env = [], $entry = [], $cmd = [], $working_dir = '/', $layers = []) {
		# TODO: if we want to make deterministic oci images, we should remove these create dates so it's gonna be byte-per-byte the same no matter when you make the image.
		my $json = ' { "created": "' . DateTime->now() . 'Z", ';# Optional https://datatracker.ietf.org/doc/html/rfc3339#section-5.6
		$json .= '"architecture": "amd64",'; # required, see https://go.dev/doc/install/source#environment for values TODO: make as parameter
		$json .= '"os": "linux",'; # required, TODO: make as parameter
		$json .= '"config": {';
		$json .= '"User": "' . $user . '",';
		$json .= '"Env": [';
		$json .= join(',', map { '"' . $_ . '"' } @$env);
        $json .= '],';
		$json .= '"Entrypoint": [';
		$json .= join(',', map {'"' . $_ . '"' } @$entry);
		$json .= '],';
        $json .= '"Cmd": [';
		$json .= join(',', map { '"' . $_ . '"' } @$cmd);
        $json .= '],';
        $json .= '"WorkingDir": "' . $working_dir . '"';
		$json .= '},';
		$json .= '"rootfs": {';
        $json .= '"type": "layers",';
        $json .= '"diff_ids": [';
		$json .= join(',', map { '"sha256:' . $_->get_digest() . '"' } @$layers);
        $json .= ']}}';

		$digest = Crypt::Digest::SHA256::sha256_hex($json);
		$size = length($json);
		return $json;
	}

	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Manifest {
	field $digest = '';
	field $size = '';

	method generate_manifest($config_digest, $config_size, $layers) {
		my $json = '{ "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:' . $config_digest . '", "size": ' . $config_size .' }, "layers": [';
		$json .= join(',', map { '{ "mediaType": "' . $_->get_media_type() . '", "digest": "sha256:' . $_->get_digest() . '", "size": ' . $_->get_size() . ' }' } @$layers);
		$json .= ' ], "annotations": { "generator": "Container::Builder vX.Y", "generator_url": "a link to (meta)cpan" } }';

		$digest = Crypt::Digest::SHA256::sha256_hex($json);
		$size = length($json);
		return $json;
	}

	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

# https://specs.opencontainers.org/image-spec/image-index/?v=v1.1.1
class Container::Index {
	method generate_index($manifest_digest, $manifest_size) {
		# TODO: you can annotate and pass the container name
		return '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:' . $manifest_digest . '","size":' . $manifest_size . '}]}'
	}
}

class Container::Builder {
	field $os = 'debian';
	field $arch = 'amd64';
	field $os_version = 'bookworm';
	field @layers = ();
	field $build_dir :param = '/tmp';
	field $work_dir :param = '/tmp';
	field $original_dir = Cwd::getcwd();
	field $runas = 'root';
	field @entry = ();
	field @cmd = ();
	field @env = ();
	field @dirs = ();
	field @users = ();
	field @groups = ();

	ADJUST {
		# Create build dir
		$work_dir .= '/ctrbuilder_' . time() . '/';
		my $success = mkdir($work_dir, 0700);
		die "Unable to create build dir $work_dir\n" if !$success;
		$build_dir = $work_dir . 'build/';
		$success = mkdir($build_dir, 0700);
		die "Unable to create build dir $build_dir/build\n" if !$success;
		$success = mkdir($build_dir . 'blobs/', 0700);
		die "Unable to create build dir $build_dir/build/blobs\n" if !$success;
		$success = mkdir($build_dir . 'blobs/' . 'sha256/', 0700);
		die "Unable to create build dir $build_dir/build/blobs/sha256\n" if !$success;
	}

	# Create a layer that adds a package to the container
	method add_deb_package_from_file($filepath_deb) {
		die "Unable to read $filepath_deb\n" if !-r $filepath_deb;
		push @layers, Container::Layer::DebianPackageFile->new(blob_dir => $build_dir . 'blobs/sha256/', file => $filepath_deb);
	}

	# Create a layer that has one file
	method add_file($file_on_disk, $location_in_ctr, $mode, $user, $group) {
		die "Cannot read file at $file_on_disk\n" if !-r $file_on_disk;
		say "Adding file $file_on_disk";
		my $tar = Container::Builder::Tar->new();
		$tar->add_dir('bin/', 0755, 0, 0);
		open(my $f, '<', 'testproggie') or die "cannot read testproggie\n";
		local $/ = undef;
		my $content = <$f>;
		close($f);
		$tar->add_file('bin/testproggie', $content, 0755, 0, 0);
		my $tar_content = $tar->get_tar();
		push @layers, Container::Layer::Tar->new(blob_dir => $build_dir . 'blobs/sha256/', data => $tar_content);
		#push @layers, Container::Layer::SingleFile->new(blob_dir => $build_dir . 'blobs/sha256/', file => $file_on_disk, dest => $location_in_ctr, mode => $mode, user => $user, group => $group);
	}

	method add_file_from_string($data, $location_in_ctr, $mode, $user, $group) {
		push @layers, Container::Layer::SingleFile->new(blob_dir => $build_dir . 'blobs/sha256/', data => $data, dest => $location_in_ctr, mode => $mode, user => $user, group => $group);
	}

	# Create a layer that creates a directory in the container
	method create_directory($path, $mode, $uid, $gid) {
		my %dir = (path => $path, mode => $mode, uid => $uid, gid => $gid);
		push @dirs, \%dir;
	}

	# Create a layer that adds a user to the container
	# this is a wrapper to make a change to passwd?
	method add_user($name, $uid, $main_gid, $shell, $homedir) {
		$name =~ s/[^a-z]//ig;
		$uid =~ s/[^\d]//g;
		$main_gid =~ s/[^\d]//g;
		die "Conflicting user" if grep { $_->{name} eq $name || $_->{uid} == $uid || $_->{gid} == $main_gid } @users;
		my %new_user = (name => $name, uid => $uid, gid => $main_gid, shell => $shell, homedir => $homedir);
		push @users, \%new_user;
	}

	# Create a layer that adds a group to the container
	method add_group($name, $gid) {
		$name =~ s/[^a-z]//ig;
		$gid =~ s/[^\d]//g;
		die "Conflicting with existing group\n" if grep {$_->{name} eq $name || $_->{gid} == $gid } @groups;
		my %new_group = (name => $name, gid => $gid);
		push @groups, \%new_group;
	}

	# similar to USER in Dockerfile
	method runas_user($user) {
		my $found_user = 0;
		foreach(@users) {
			$found_user = 1 if $_->{name} eq $user;
		}
		die "Cannot set the USER to $user if it's not part of the users in the container\n" if !$found_user;
		$runas = $user;
	}

	# Sets an environment variable, similar to ENV in Dockerfile
	method set_env($key, $value) {
		# TODO: probably needs some escaping for nasty value's or values with an '=', ...
		push @env, "$key=$value";
	}

	# Set entrypoint
	method set_entry(@command_str) {
		die "Entrypoint/Command list is empty\n" if !@command_str;
		push @entry, shift(@command_str);
		push @cmd, @command_str;
	}

	method set_work_dir($workdirectory) {
		$work_dir = $workdirectory;
	}

	method build {
		open(my $f, '>', $build_dir . 'oci-layout') or die "Cannot write oci-layout file\n";
		my $oci_layout = '{"imageLayoutVersion": "1.0.0"}';
		print $f $oci_layout;
		close $f;

		# Make 1 layer with all the base files
		my $tar = Container::Builder::Tar->new();

			foreach(@dirs) {
				$tar->add_dir($_->{path}, $_->{mode}, $_->{uid}, $_->{gid});
			}

			# Generate /etc/group file
			my $etcgroup = '';
			map { $etcgroup .= $_->{name} . ':x:' . $_->{gid} . ':' . $/ } @groups;
			$tar->add_file('/etc/group', $etcgroup, 0644, 0, 0);

			# Generate /etc/passwd file
			my $etcpasswd = '';
			# example line: root:x:0:0:root:/root:/bin/bash
			map { $etcpasswd .= $_->{name} . ':x:' . $_->{uid} . ':' . $_->{gid} . ':' . $_->{name} . ':' . $_->{homedir} . ':' . $_->{shell} . $/ } @users;
			$tar->add_file('/etc/passwd', $etcpasswd, 0644, 0, 0);
	
		my $tar_content = $tar->get_tar();
		unshift @layers, Container::Layer::Tar->new(blob_dir => $build_dir . 'blobs/sha256/', data => $tar_content);

		# Add all layers
		foreach(@layers) {
			my $artifact_path = $_->generate_artifact();
		}

		my $config = Container::Config->new();
		#method generate_config($user = 'root', $env = [], $entry = [], $cmd = [], $working_dir = '/', $layers = []) {
		my $config_json = $config->generate_config($runas, \@env, \@entry, \@cmd, $work_dir, \@layers);
		open($f, '>', $build_dir . 'blobs/sha256/' . $config->get_digest()) or die "Cannot open the config file for writing\n";
		print $f $config_json;
		close($f);

		my $manifest = Container::Manifest->new();
		my $manifest_json = $manifest->generate_manifest($config->get_digest(), $config->get_size(), \@layers);
		open($f, '>', $build_dir . 'blobs/sha256/' . $manifest->get_digest()) or die "Cannot open the manifest file for writing\n";
		print $f $manifest_json;
		close($f);

		my $index = Container::Index->new();
		open($f, '>', $build_dir . 'index.json') or die "Cannot open index.json for writing\n";
		print $f $index->generate_index($manifest->get_digest(), $manifest->get_size());
		close($f);

		chdir($build_dir); defer { chdir($original_dir) }
		my @filelist = ('oci-layout', 'index.json', 'blobs/', 'blobs/sha256/', 'blobs/sha256/' . $config->get_digest(), 'blobs/sha256/' . $manifest->get_digest());
		push @filelist, map { 'blobs/sha256/' . $_->get_digest() } @layers;
		Archive::Tar->create_archive('hehe.tar', 1, @filelist);

		# TODO: Move the TAR file to the local directory from where we started executing this script?
		# TODO: cleanup everything but the resulting TAR archive with the image...
	}
}

my $builder = Container::Builder->new();
$builder->create_directory('/', 0755, 0, 0);
$builder->create_directory('bin/', 0755, 0, 0);
$builder->create_directory('tmp/', 01777, 0, 0);
$builder->create_directory('root/', 0700, 0, 0);
$builder->create_directory('home/', 0755, 0, 0);
$builder->create_directory('home/larry/', 0700, 1337, 1337);
$builder->create_directory('etc/', 0755, 0, 0);
$builder->add_file('testproggie', '/bin/testproggie', 0755, 0, 0); # our executable
$builder->add_deb_package_from_file('libc-bin_2.36-9+deb12u13_amd64.deb');
$builder->add_deb_package_from_file('libc6_2.36-9+deb12u13_amd64.deb');
$builder->add_deb_package_from_file('gcc-12-base_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('libgcc-s1_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('libgomp1_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('libstdc++6_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('ca-certificates_20230311+deb12u1_all.deb');
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
$builder->set_entry('/bin/testproggie');
$builder->build();
