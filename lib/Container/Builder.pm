package Container::Builder;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Cwd;
use LWP::Simple;
use IO::Uncompress::Gunzip qw(gunzip);
use DPKG::Packages::Parser;

use Container::Builder::Tar;
use Container::Builder::Config;
use Container::Builder::Manifest;
use Container::Builder::Index;

use Container::Builder::Layer;
use Container::Builder::Layer::DebianPackageFile;
use Container::Builder::Layer::Tar;
use Container::Builder::Layer::SingleFile;

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
	field %deb_packages = ();
	field @dirs = ();
	field @users = ();
	field @groups = ();
	field $packages; 

	method parse_packages(@fields) {
		if(!-r 'Packages') {
			say "[+] Downloading Debian Packages";
			my $packagesgz = LWP::Simple::get("https://debian.inf.tu-dresden.de/debian/dists/bookworm/main/binary-amd64/Packages.gz");
			IO::Uncompress::Gunzip::gunzip(\$packagesgz => 'Packages');
		}
		$packages = DPKG::Packages::Parser->new('file' => 'Packages');
		$packages->parse(@fields);
	}

	method _get_deb_package($package_name) {
		if(-r 'artifacts/' . $package_name . '.deb') {
			local $/ = undef;
			open(my $deb, '<', 'artifacts/' . $package_name . '.deb') or die "Cannot open artifacts/$package_name.deb\n";
			my $deb_content = <$deb>;
			close($deb);
			return $deb_content;
		}

		$self->parse_packages('Filename', 'Depends') if !$packages; # lazy load on first call
		my $pkg = $packages->get_package($package_name);
		return 0 if !$pkg;

		my $filepath = $pkg->{Filename};
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
		return 0 if $deb_packages{$package_name};
		my $package_content = $self->_get_deb_package($package_name);
		return 0 if ! $package_content;
		# TODO: Writing packages to disk for caching should be optional (if you're doing 1 build, caching files is useless)
		if(!-r 'artifacts/' . $package_name . '.deb') {
			open(my $f, '>', 'artifacts/' . $package_name . '.deb') or die "cannot open $package_name.deb\n";
			print $f $package_content;
			close($f);
		}

		# Before adding the package as a layer, get the dependencies and add those
		$deb_packages{$package_name} = 1;
		$self->parse_packages('Filename', 'Depends') if !$packages; # lazy load on first call
		my $pkg = $packages->get_package($package_name);
		say "$package_name depends on:";
		foreach(@{$pkg->{Depends}}) {
			if(ref eq 'ARRAY') {
				foreach(@$_) {
					say "\tOR Dependency: $_->{name}";
				}
				# TODO: there's no way we can make an intelligent decision here, we can check if any of these have already been added or not. If one of the options was already added, we can skip choosing; if none was already added, take the first one.
				$self->add_deb_package(${$_}[0]->{name});
			} elsif(ref eq 'HASH') {
				say "\tDependency: " . $_->{name};
				$self->add_deb_package($_->{name});
			}
		}

		
		# TODO: need to be able to pass a memory buffer here so we can skip writing to disk
		say "Actually adding deb package: $package_name";
		push @layers, Container::Builder::Layer::DebianPackageFile->new(file => 'artifacts/' . $package_name . '.deb', compress => 0);
	}

	# Create a layer that adds a package to the container
	method add_deb_package_from_file($filepath_deb) {
		die "Unable to read $filepath_deb\n" if !-r $filepath_deb;
		push @layers, Container::Builder::Layer::DebianPackageFile->new(file => $filepath_deb, compress => 0);
	}

	method extract_from_deb($package_name, $files_to_extract) {
		my $deb_archive = $self->_get_deb_package($package_name);
		if($deb_archive) {
			# Read the tar -> with our own class because Archive::Tar doesn't read from a string...
			my $deb = Container::Builder::Layer::DebianPackageFile->new(data => $deb_archive, compress => 0);
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
			push @layers, Container::Builder::Layer::Tar->new(data => $result_tar);
		} else {
			die "Did not find deb package with name $package_name\n";
		}
	}

	# Create a layer that has one file
	method add_file($file_on_disk, $location_in_ctr, $mode, $user, $group) {
		die "Cannot read file at $file_on_disk\n" if !-r $file_on_disk;
		push @layers, Container::Builder::Layer::SingleFile->new(file => $file_on_disk, dest => $location_in_ctr, mode => $mode, user => $user, group => $group);
	}

	method add_file_from_string($data, $location_in_ctr, $mode, $user, $group) {
		push @layers, Container::Builder::Layer::SingleFile->new(data => $data, dest => $location_in_ctr, mode => $mode, user => $user, group => $group);
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

	method build($filename_result) {

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
		unshift @layers, Container::Builder::Layer::Tar->new(data => $tar_content);

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
		my $config = Container::Builder::Config->new();
		my $config_json = $config->generate_config($runas, \@env, \@entry, \@cmd, $work_dir, \@layers);
		$tar->add_file('blobs/sha256/' . $config->get_digest(), $config_json, 0644, 0, 0);

		my $manifest = Container::Builder::Manifest->new();
		my $manifest_json = $manifest->generate_manifest($config->get_digest(), $config->get_size(), \@layers);
		$tar->add_file('blobs/sha256/' . $manifest->get_digest(), $manifest_json, 0644, 0, 0);

		my $oci_layout = '{"imageLayoutVersion": "1.0.0"}';
		$tar->add_file('oci-layout', '{"imageLayoutVersion": "1.0.0"}', 0644, 0, 0);
		my $index = Container::Builder::Index->new();
		$tar->add_file('index.json', $index->generate_index($manifest->get_digest(), $manifest->get_size()), 0644, 0, 0);

		open(my $o, '>', $filename_result) or die "cannot open $filename_result\n";
		print $o $tar->get_tar();
		close($o);
	}
}

1;
