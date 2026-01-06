use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Archive::Tar;
use Crypt::Digest::SHA256 qw(sha256_file_hex);

class Container::Layer {
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
		my $success = Archive::Tar->create_archive( '/tmp/out.tgz', 1, $file );
		if(!$success) {
			die "Unable to make TAR file from $file\n";
		}
		$digest = 'sha256:' . Crypt::Digest::SHA256::sha256_file_hex('/tmp/out.tgz');
		$size = (stat('/tmp/out.tgz'))[7];
		
		$generated_artifact = 1;
		return '/tmp/out.tgz';
	}

	method get_media_type() { return "application/vnd.oci.image.layer.v1.tar+gzip" }
	method get_digest() { return $digest }
	method get_size() { return $size }
}

class Container::Layer::DebianPackage :isa(Container::Layer) { }

class Container::Layer::Dir :isa(Container::Layer) { }

class Container::Manifest {
	method generate_manifest($digest, $size, @layers) {
		my $json = '{ "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": "' . $digest . '", "size": ' . $size .' }, "layers": [';
		my @layer_strings = ();
		foreach(@layers) {
			push @layer_strings, '{ "mediaType": "' . $_->get_media_type() . '", "digest": "' . $_->get_digest() . '", "size": ' . $_->get_size() . ' }';
		}
		$json .= join(',', @layer_strings);
		$json .= ' ], "annotations": { "generator": "Container::Builder vX.Y", "generator_url": "a link to (meta)cpan" } }';
		return $json;
	}
}

class Container::Builder {
	field $os = 'debian';
	field $arch = 'x86_64';
	field $os_version = 'bookworm';
	field @layers = ();

	# Create a layer that adds a package to the container
	method add_package {

	}

	# Create a layer that has one file
	method add_file($filepath) {
		die "Cannot read file at $filepath\n" if !-r $filepath;
		my $file_layer = Container::Layer::SingleFile->new(file => $filepath);
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
		foreach(@layers) {
			my $artifact_path = $_->generate_artifact();
		}
	}
}

my $builder = Container::Builder->new();
$builder->add_file('README.md');
$builder->build();
