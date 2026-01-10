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

class Container::Layer::Tar :isa(Container::Layer) {}

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
	field $file :param;
	field $generated_artifact = 0;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		die "Unable to read file $file\n" if !-r $file;
		# TODO: Probably need to make the directory where we put TARs configurable
		$digest = Crypt::Digest::SHA256::sha256_file_hex($file);
		my $success = Archive::Tar->create_archive( $self->get_blob_dir() . $digest, 1, $file ); # the number controls gzip compression
		if(!$success) {
			die "Unable to make TAR file from $file\n";
		}
		$size = (stat($self->get_blob_dir() . $digest))[7];
		
		$generated_artifact = 1;
		return $self->get_blob_dir() . $digest;
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

class Container::Layer::Dir :isa(Container::Layer) { }

class Container::Config {
	field $digest = '';
	field $size = '';

	method generate_config($user = 'root', $env = [], $cmd = [], $working_dir = '/', $layers = []) {
		# TODO: if we want to make deterministic oci images, we should remove these create dates so it's gonna be byte-per-byte the same no matter when you make the image.
		my $json = ' { "created": "' . DateTime->now() . 'Z", ';# Optional https://datatracker.ietf.org/doc/html/rfc3339#section-5.6
		$json .= '"architecture": "amd64",'; # required, see https://go.dev/doc/install/source#environment for values TODO: make as parameter
		$json .= '"os": "linux",'; # required, TODO: make as parameter
		$json .= '"config": {';
		$json .= '"User": "' . $user . '",';
		$json .= '"Env": [';
		$json .= join(',', map { '"' . $_ . '"' } @$env);
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
	method add_file($filepath) {
		die "Cannot read file at $filepath\n" if !-r $filepath;
		push @layers, Container::Layer::SingleFile->new(blob_dir => $build_dir . 'blobs/sha256/', file => $filepath);
	}

	# Create a layer that creates a directory in the container
	method create_directory {

	}

	# Create a layer that adds a user to the container
	# this is a wrapper to make a change to passwd?
	method add_user {

	}

	# Create a layer that adds a group to the container
	method add_group {

	}

	# similar to USER in Dockerfile
	method runas_user {

	}

	# Sets an environment variable, similar to ENV in Dockerfile
	method set_env {

	}

	# Set entrypoint
	method set_entry {

	}

	method build {
		open(my $f, '>', $build_dir . 'oci-layout') or die "Cannot write oci-layout file\n";
		print $f '{"imageLayoutVersion": "1.0.0"}';
		close $f;

		foreach(@layers) {
			my $artifact_path = $_->generate_artifact();
			say "Artifact size: " . $_->get_size();
			say "Artifact digest: " . $_->get_digest();
		}
		my $config = Container::Config->new();
		my $config_json = $config->generate_config('adri', [], [], '/', \@layers);
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
		my @filelist = ('oci-layout', 'index.json', 'blobs', 'blobs/sha256', 'blobs/sha256/' . $config->get_digest(), 'blobs/sha256/' . $manifest->get_digest());
		push @filelist, map { 'blobs/sha256/' . $_->get_digest() } @layers;
		Archive::Tar->create_archive('hehe.tar', 1, @filelist);

		# TODO: Move the TAR file to the local directory from where we started executing this script?
		# TODO: cleanup everything but the resulting TAR archive with the image...
	}
}

my $builder = Container::Builder->new();
$builder->add_file('README.md');
$builder->add_deb_package_from_file('zlib1g_1.2.13.dfsg-1_amd64.deb');
$builder->build();
