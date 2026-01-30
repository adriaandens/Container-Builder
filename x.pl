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
use IO::Uncompress::Gunzip qw(gunzip); # Recompress as GZIP (supported by OCI spec)
use Cwd;
use DateTime;
use File::Copy;
use Crypt::Digest::SHA256 qw(sha256_hex sha256_file_hex);
use LWP::Protocol::https;
use LWP::Simple;
use LWP::UserAgent;
use DPKG::Parse::Packages;
use DPKG::Parse::Entry;

class Container::Layer {
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
		return $data;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar" }
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
		return $tar_content;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Layer::DebianPackageFile :isa(Container::Layer) { 
	field $file :param = "";
	field $data :param = "";
	field $compress :param = 1;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		my $ar;
		if($file) {
			die "Unable to read file $file\n" if !-r $file;
			$ar = Archive::Ar->new($file);
		} elsif($data) {
			$ar = Archive::Ar->new();
			my $result = $ar->read_memory($data);
			die "Couldn't read Ar archive from memory\n" if(!defined($result));
		} else {
			die "No file or data passed to DebianPackageFile\n";
		}
		## TODO: support data.tar, data.tar.gz, data.tgz, ...
		die "Unable to find data.tar.xz inside deb package\n" if !$ar->contains_file('data.tar.xz');
		my $xz_data = $ar->get_data('data.tar.xz');
		my $unxz_data;
		IO::Uncompress::UnXz::unxz(\$xz_data => \$unxz_data) or die "Unable to extract data using unxz\n";
		if($compress) {
			my $gunzip_compressed_data;
			IO::Compress::Gzip::gzip(\$unxz_data => \$gunzip_compressed_data) or die "Unable to gunzip the unxz data\n";
			$size = length($gunzip_compressed_data);
			$digest = Crypt::Digest::SHA256::sha256_hex($gunzip_compressed_data);
			return $gunzip_compressed_data;
		} else {
			$size = length($unxz_data);
			$digest = Crypt::Digest::SHA256::sha256_hex($unxz_data);
			return $unxz_data;
		}
	}

	method get_media_type() { 
		my $s = "application/vnd.oci.image.layer.v1.tar";
		$s .= '+gzip' if $compress;
		return $s;
	}
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
		$tar .= sprintf("%011o", 566833020) . "\x00"; #  char mtime[12];               /* 136 */
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
		$tar .= sprintf("%011o", 566833020) . "\x00"; #  char mtime[12];               /* 136 */
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
		$tar =~ s/^(.{148}).{7}/$1.$checksum_str."\x00"/e; # Overwrite checksum bytes

		$tar .= "\x00" x 12; # create a block of 512, the header is 500 bytes.

		$tar .= $data;
		my $remainder = length($data) % 512;
		$tar .= "\x00" x (512 - $remainder) if $remainder > 0;

		$full_tar .= $tar;
	}

	method extract_file($tar, $filepath) {
		# TODO
		my $blocks_read = 0;
		my $filename = $self->_get_filename($tar, $blocks_read);
		my $filesize = $self->_get_filesize($tar, $blocks_read);
		while($filename ne $filepath && $filename && length($tar) > $blocks_read * 512) {
			$blocks_read++; # skip header block
			# jump the amount of blocks to the next header.
			my $block_count = int($filesize / 512); 
			$block_count++ if $filesize % 512; # the remainder is another block unless there's no remainder bytes (file neatly fits a block, no remainder)
			$blocks_read += $block_count;
			# read header
			$filename = $self->_get_filename($tar, $blocks_read);
			$filesize = $self->_get_filesize($tar, $blocks_read);
		}
		# extract data from our file and return
		if($filename eq $filepath) {
			say "Found the file!!!!";
			if($filesize == 0) { # probably a directory... Only return the header
				my $header = substr($tar, $blocks_read*512, 512);
				return $header;
			} else {
				my $bytes_to_read = 512; # header size
				$bytes_to_read += 512 * int($filesize / 512);
				$bytes_to_read += 512 if $filesize % 512;
				say "reading $bytes_to_read...";
				my $file = substr($tar, $blocks_read*512, $bytes_to_read); 
				return $file;
			}
		} else {
			say "did not find the file :'(";
			return '';
		}
	}

	method extract_wildcard_files($tar, $filepath) {
		chop($filepath); # remove wildcard *
		my $prefix_length = length($filepath);
		my $blocks_read = 0;
		my $filename = $self->_get_filename($tar, $blocks_read);
		my $filesize = $self->_get_filesize($tar, $blocks_read);
		my $tarfile = '';
		while($filename && length($tar) > $blocks_read * 512) {
			$blocks_read++; # skip header block
			if(substr($filename, 0, $prefix_length) eq $filepath && $filesize > 0 && substr($filename, $prefix_length) !~ /\//) {
				say "$filename matched wildcard $filepath";
				my $bytes_to_read = 512; # header size
				$bytes_to_read += 512 * int($filesize / 512);
				$bytes_to_read += 512 if $filesize % 512;
				my $file = substr($tar, ($blocks_read-1)*512, $bytes_to_read); 
				$tarfile .= $file;
			}
			# jump the amount of blocks to the next header.
			my $block_count = int($filesize / 512); 
			$block_count++ if $filesize % 512; # the remainder is another block unless there's no remainder bytes (file neatly fits a block, no remainder)
			$blocks_read += $block_count;
			# read header
			$filename = $self->_get_filename($tar, $blocks_read);
			$filesize = $self->_get_filesize($tar, $blocks_read);
		}
		return $tarfile;
	}

	method _get_filesize($tar, $blocks_read) {
		my $header = substr($tar, $blocks_read * 512, 512);
		my @header_bytes = split //, $header;
		my @size = splice(@header_bytes, 124, 11);
		my $size_str = join('', @size);
		my $actual_size = oct($size_str);
		say "Size file: $actual_size";
		return $actual_size;
	}

	method _get_filename($tar, $blocks_read) {
		my $header = substr($tar, $blocks_read * 512, 512);
		my $filename = '';
		my @header_bytes = split //, $header;
		my $i = 0;
		while($header_bytes[$i] ne "\x00") {
			$filename .= $header_bytes[$i++];
		}
		say "Filename from header: $filename";
		return $filename;
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
		return $tar_content;
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
		$json .= '"history": [';
		$json .= join(',', map { '{ "created": "0001-01-01T00:00:00Z" }' } @$layers);
		$json .= '],';
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
	field $original_dir = Cwd::getcwd();
	field $runas = 'root';
	field $work_dir = '/';
	field @entry = ();
	field @cmd = ();
	field @env = ();
	field @dirs = ();
	field @users = ();
	field @groups = ();
	field $packages; 

	method parse_packages() {
		if(!-r 'Packages') {
			say "[+] Downloading Debian Packages";
			my $packagesgz = LWP::Simple::get("https://debian.inf.tu-dresden.de/debian/dists/bookworm/main/binary-amd64/Packages.gz");
			IO::Uncompress::Gunzip::gunzip(\$packagesgz => 'Packages');
		}
		$packages = DPKG::Parse::Packages->new('filename' => 'Packages');
		$packages->parse();
	}

	method _get_deb_package($package_name) {
		$self->parse_packages() if !$packages; # lazy load on first call
		my $pkg = $packages->get_package('name' => $package_name);
		return 0 if !$pkg;

		my $filepath = $pkg->filename;
		my ($filename) = $filepath =~ m/([^\/]+)$/;
		say "filename is $filename";
		say "Filepath for package $package_name is $filepath";
		my $url = "https://debian.inf.tu-dresden.de/debian/" . $filepath;
		say $url;
		my $lwp = LWP::UserAgent->new();
		my $response = $lwp->get($url);
		if(!$response->is_success) { # Added because my base perl LWP didn't have the https package to support https...
			die "Call to Debian package repo failed: " . $response->status_line;
		}
		my $package_content = $response->decoded_content;
		die "unable to get package content with LWP::Simple" if !$package_content;
		return $package_content;
	}

	method add_deb_package($package_name) {
		my $package_content = $self->_get_deb_package($package_name);
		# TODO: Writing packages to disk for caching should be optional (if you're doing 1 build, caching files is useless)
		if(!-r $package_name . '.deb') {
			open(my $f, '>', $package_name . '.deb') or die "cannot open $package_name.deb\n";
			print $f $package_content;
			close($f);
		}
		# TODO: need to be able to pass a memory buffer here so we can skip writing to disk
		push @layers, Container::Layer::DebianPackageFile->new(file => $package_name . '.deb');
	}

	# Create a layer that adds a package to the container
	method add_deb_package_from_file($filepath_deb) {
		die "Unable to read $filepath_deb\n" if !-r $filepath_deb;
		push @layers, Container::Layer::DebianPackageFile->new(file => $filepath_deb);
	}

	method extract_from_deb($package_name, $files_to_extract) {
		my $deb_archive = $self->_get_deb_package($package_name);
		if($deb_archive) {
			# Read the tar -> with our own class because Archive::Tar doesn't read from a string...
			my $deb = Container::Layer::DebianPackageFile->new(data => $deb_archive, compress => 0);
			my $tar = $deb->generate_artifact();
			my $tar_builder = Container::Builder::Tar->new();
			my $result_tar = '';
			foreach(@$files_to_extract) {
				my $tar_file = '';
				if($_ =~ /\*$/) {
					$tar_file = $tar_builder->extract_wildcard_files($tar, $_);
				} else {
					$tar_file = $tar_builder->extract_file($tar, $_);
				}
				say "[-] Did not find $_ in TAR file to extract" if !$tar_file;
				$result_tar .= $tar_file;
			}
			$result_tar .= "\x00" x 1024; # two empty blocks
			open(my $f , '>ghehe.tar') or die 'cannot write ghehe.tar';
			print $f $result_tar;
			close($f);
			push @layers, Container::Layer::Tar->new(data => $result_tar);
		} else {
			die "Did not find deb package with name $package_name\n";
		}
	}

	# Create a layer that has one file
	method add_file($file_on_disk, $location_in_ctr, $mode, $user, $group) {
		die "Cannot read file at $file_on_disk\n" if !-r $file_on_disk;
		push @layers, Container::Layer::SingleFile->new(file => $file_on_disk, dest => $location_in_ctr, mode => $mode, user => $user, group => $group);
	}

	method add_file_from_string($data, $location_in_ctr, $mode, $user, $group) {
		push @layers, Container::Layer::SingleFile->new(data => $data, dest => $location_in_ctr, mode => $mode, user => $user, group => $group);
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
		unshift @layers, Container::Layer::Tar->new(data => $tar_content);

		$tar = Container::Builder::Tar->new();
		$tar->add_dir('blobs/', 0755, 0, 0);
		$tar->add_dir('blobs/sha256/', 0755, 0, 0);
		# Add all layers
		foreach(@layers) {
			my $data = $_->generate_artifact();
			my $digest = $_->get_digest();
			$tar->add_file('blobs/sha256/' . $digest, $data, 0644, 0, 0);
		}

		# We need to generate our artifacts before we can call the Config, because we need the sizes and digests of the layers...
		my $config = Container::Config->new();
		my $config_json = $config->generate_config($runas, \@env, \@entry, \@cmd, $work_dir, \@layers);
		$tar->add_file('blobs/sha256/' . $config->get_digest(), $config_json, 0644, 0, 0);

		my $manifest = Container::Manifest->new();
		my $manifest_json = $manifest->generate_manifest($config->get_digest(), $config->get_size(), \@layers);
		$tar->add_file('blobs/sha256/' . $manifest->get_digest(), $manifest_json, 0644, 0, 0);

		my $oci_layout = '{"imageLayoutVersion": "1.0.0"}';
		$tar->add_file('oci-layout', '{"imageLayoutVersion": "1.0.0"}', 0644, 0, 0);
		my $index = Container::Index->new();
		$tar->add_file('index.json', $index->generate_index($manifest->get_digest(), $manifest->get_size()), 0644, 0, 0);

		open(my $o, '>', 'hehe.tar') or die "cannot open hehe.tar\n";
		print $o $tar->get_tar();
		close($o);
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
$builder->create_directory('app/', 0755, 1337, 1337);
# C dependencies (to run a compiled executable)
$builder->add_deb_package_from_file('libc-bin_2.36-9+deb12u13_amd64.deb');
$builder->add_deb_package_from_file('libc6_2.36-9+deb12u13_amd64.deb');
$builder->add_deb_package_from_file('gcc-12-base_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('libgcc-s1_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('libgomp1_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('libstdc++6_12.2.0-14+deb12u1_amd64.deb');
$builder->add_deb_package_from_file('ca-certificates_20230311+deb12u1_all.deb');
# SSL support
$builder->add_deb_package('libssl3');
# Perl dependencies (to run a basic Perl program)
$builder->add_deb_package('libcrypt1');
$builder->add_deb_package('perl-base');
# CPM dependencies
#$builder->add_deb_package('libbz2-1.0');
#$builder->add_deb_package('libdb5.3');
#$builder->add_deb_package('libgdbm6');
#$builder->add_deb_package('libgdbm-compat4');
#$builder->add_deb_package('zlib1g');
#$builder->add_deb_package('perl-modules-5.36');
#$builder->add_deb_package('libperl5.36');
# TODO: cpm now fails with an error of no valid https transport
# Using CPANMinus
$builder->add_deb_package('perl-modules-5.36');
$builder->add_deb_package('libperl5.36');
$builder->add_deb_package('perl');
# cpanm deps from Packages file...
#$builder->add_deb_package('libcpan-distnameinfo-perl');
#$builder->add_deb_package('libcpan-meta-check-perl');
#$builder->add_deb_package('libcpan-meta-requirements-perl');
#$builder->add_deb_package('libcpan-meta-yaml-perl');
#$builder->add_deb_package('libfile-pushd-perl');
#$builder->add_deb_package('libhttp-tiny-perl');
#$builder->add_deb_package('libjson-pp-perl');
#$builder->add_deb_package('liblocal-lib-perl');
#$builder->add_deb_package('libmodule-cpanfile-perl');
#$builder->add_deb_package('libmodule-metadata-perl');
#$builder->add_deb_package('libparse-pmfile-perl');
#$builder->add_deb_package('libstring-shellquote-perl');
#$builder->add_deb_package('libversion-perl');
# cpanm deps from errors i received
#$builder->add_deb_package('gzip'); # cpanm executes gzip commands!
#$builder->add_deb_package('make');
#$builder->add_deb_package('cpanminus');
#my @files_to_extract = ('./', './usr/', './usr/share/', './usr/share/perl', './usr/share/perl/5.36.0', './usr/share/perl/5.36', './usr/share/perl/5.36.0/CPAN/Meta/', './usr/share/perl/5.36.0/CPAN/Meta/Converter.pm', './usr/share/perl/5.36.0/CPAN/Meta/Feature.pm', './usr/share/perl/5.36.0/CPAN/Meta/History/', './usr/share/perl/5.36.0/CPAN/Meta/History/Meta_1_0.pod', './usr/share/perl/5.36.0/CPAN/Meta/History/Meta_1_1.pod', './usr/share/perl/5.36.0/CPAN/Meta/History/Meta_1_2.pod', './usr/share/perl/5.36.0/CPAN/Meta/History/Meta_1_3.pod', './usr/share/perl/5.36.0/CPAN/Meta/History/Meta_1_4.pod', './usr/share/perl/5.36.0/CPAN/Meta/History.pm', './usr/share/perl/5.36.0/CPAN/Meta/Merge.pm', './usr/share/perl/5.36.0/CPAN/Meta/Prereqs.pm', './usr/share/perl/5.36.0/CPAN/Meta/Requirements.pm', './usr/share/perl/5.36.0/CPAN/Meta/Spec.pm', './usr/share/perl/5.36.0/CPAN/Meta/Validator.pm', './usr/share/perl/5.36.0/CPAN/Meta/YAML.pm', './usr/share/perl/5.36.0/CPAN/Meta.pm', './usr/share/perl/5.36.0/*', './usr/share/perl/5.36.0/version/', './usr/share/perl/5.36.0/version/Internals.pod', './usr/share/perl/5.36.0/version/regex.pm', './usr/share/perl/5.36.0/warnings/', './usr/share/perl/5.36.0/warnings/register.pm');
#$builder->extract_from_deb('perl-modules-5.36', \@files_to_extract);
$builder->add_deb_package('libtry-tiny-perl');
$builder->add_deb_package('libdevel-stacktrace-perl');
$builder->add_deb_package('libdevel-stacktrace-ashtml-perl');
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
#$builder->add_file('cpm', '/bin/cpm', 0755, 0, 0); # CPAN Package Manager
#$builder->add_file('testproggie.pl', '/home/larry/testproggie.pl', 0644, 1337, 1337); # our program
$builder->build();
