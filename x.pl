use v5.40;
use feature 'class';
no warnings 'experimental::class';

# Big TODO:
# * Instead of concatenating a JSON string (many issues with escaping characters, injections, ...) make an object and let a Perl module handle this.
# * Be more flexible in what it can generate (currently fixed debian, amd64, ...)
# * Do a lot more input checking on input from the User like the environment variables, CMD, username that runs, ...

use Archive::Tar;
use DateTime;
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

class Container::Layer::TarGzip :isa(Container::Layer) {}

class Container::Layer::SingleFile :isa(Container::Layer) {
	field $file :param;
	field $generated_artifact = 0;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		die "Unable to read file $file\n" if !-r $file;
		# TODO: Probably need to make the directory where we put TARs configurable
		my $shasum = Crypt::Digest::SHA256::sha256_file_hex($file);
		my $success = Archive::Tar->create_archive( $self->get_blob_dir() . $shasum, 1, $file ); # the number controls gzip compression
		if(!$success) {
			die "Unable to make TAR file from $file\n";
		}
		$digest = 'sha256:' . $shasum;
		$size = (stat($self->get_blob_dir() . $shasum))[7];
		
		$generated_artifact = 1;
		return $self->get_blob_dir() . $shasum;
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar+gzip" }
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Layer::DebianPackage :isa(Container::Layer) { }

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
        $json .= '"WorkingDir": "' . $working_dir . '",';
		$json .= '},';
		$json .= '"rootfs": {';
        $json .= '"type": "layers",';
        $json .= '"diff_ids": [';
		$json .= join(',', map { '"' . $_->get_digest() . '"' } @$layers);
        $json .= ']}}';

		$digest = 'sha256:' . Crypt::Digest::SHA256::sha256_hex($json);
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
		my $json = '{ "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": "' . $config_digest . '", "size": ' . $config_size .' }, "layers": [';
		$json .= join(',', map { '{ "mediaType": "' . $_->get_media_type() . '", "digest": "' . $_->get_digest() . '", "size": ' . $_->get_size() . ' }' } @$layers);
		$json .= ' ], "annotations": { "generator": "Container::Builder vX.Y", "generator_url": "a link to (meta)cpan" } }';

		$digest = 'sha256:' . Crypt::Digest::SHA256::sha256_hex($json);
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
		return '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"' . $manifest_digest . '","size":' . $manifest_size . '}}]}'
	}
}

class Container::Builder {
	field $os = 'debian';
	field $arch = 'x86_64';
	field $os_version = 'bookworm';
	field @layers = ();
	field $build_dir :param = '/tmp';

	ADJUST {
		$build_dir .= '/ctrbuilder_' . time() . '/';
		my $success = mkdir($build_dir, 0700);
		die "Unable to create build dir $build_dir\n" if !$success;
		$success = mkdir($build_dir . 'blobs/', 0700);
		die "Unable to create build dir $build_dir/blobs\n" if !$success;
		$success = mkdir($build_dir . 'blobs/' . 'sha256/', 0700);
		die "Unable to create build dir $build_dir/blobs/sha256\n" if !$success;
	}

	# Create a layer that adds a package to the container
	method add_package {

	}

	# Create a layer that has one file
	method add_file($filepath) {
		die "Cannot read file at $filepath\n" if !-r $filepath;
		my $file_layer = Container::Layer::SingleFile->new(blob_dir => $build_dir . 'blobs/sha256/', file => $filepath);
		push @layers, $file_layer;
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
		my $config_json = $config->generate_config('root',[], [], '/', \@layers);
		my $manifest = Container::Manifest->new();

		my $index = Container::Index->new();
		open($f, '>', $build_dir . 'index.json') or die "Cannot open index.json for writing\n";
		print $f $index->generate_index($manifest->get_digest(), $manifest->get_size());
		close($f);
	}
}

my $builder = Container::Builder->new();
$builder->add_file('README.md');
$builder->build();
