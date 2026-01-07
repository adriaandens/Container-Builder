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
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

class Container::Layer::DebianPackage :isa(Container::Layer) { }

class Container::Layer::Dir :isa(Container::Layer) { }

class Container::Config {
	method generate_config() {
		return '{"a json file": "containing the commands etc..."}'
	}
}

class Container::Manifest {
	method generate_manifest($config_digest, $config_size, @layers) {
		my $json = '{ "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": { "mediaType": "application/vnd.oci.image.config.v1+json", "digest": "' . $config_digest . '", "size": ' . $config_size .' }, "layers": [';
		my @layer_strings = ();
		foreach(@layers) {
			push @layer_strings, '{ "mediaType": "' . $_->get_media_type() . '", "digest": "' . $_->get_digest() . '", "size": ' . $_->get_size() . ' }';
		}
		$json .= join(',', @layer_strings);
		$json .= ' ], "annotations": { "generator": "Container::Builder vX.Y", "generator_url": "a link to (meta)cpan" } }';
		return $json;
	}
}

# https://specs.opencontainers.org/image-spec/image-index/?v=v1.1.1
class Container::Index {
	method generate_index() {
		return '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:335a1c878c387eaa18b9a94db4e08a617075192d152258e168a90e09d01e62bc","size":2310,"annotations":{"org.opencontainers.image.ref.name":"localhost/kribbel:naive"}}]}'
	}
}

class Container::Builder {
	field $os = 'debian';
	field $arch = 'x86_64';
	field $os_version = 'bookworm';
	field @layers = ();
	field $build_dir :param = '/tmp';

	ADJUST {
		$build_dir .= '/ctrbuilder_' . time();
		my $success = mkdir($build_dir, 0700);
		die "Unable to create build dir $build_dir\n" if !$success;
	}

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
		open(my $f, '>', 'oci-layout') or die "Cannot write oci-layout file\n";
		print $f '{"imageLayoutVersion": "1.0.0"}';
		close $f;

		foreach(@layers) {
			my $artifact_path = $_->generate_artifact();
			say "Artifact size: " . $_->get_size();
			say "Artifact digest: " . $_->get_digest();
		}
		my $config = Container::Config->new();
		my $manifest = Container::Manifest->new();
	}
}

my $builder = Container::Builder->new();
$builder->add_file('README.md');
$builder->build();
