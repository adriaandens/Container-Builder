package Container::Builder::Manifest;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Crypt::Digest::SHA256 qw(sha256_hex);
use JSON;

class Container::Builder::Manifest {
	field $digest = '';
	field $size = '';

	method generate_manifest($config_digest, $config_size, $layers) {
		my @layers_arr = ();
		foreach(@$layers) {
			my %entry = (
				mediaType => $_->get_media_type(),
				digest => 'sha256:' . $_->get_digest(),
				size => $_->get_size()
			);
			push @layers_arr, \%entry;
		}
		my %config = (
			mediaType => 'application/vnd.oci.image.config.v1+json',
			digest => 'sha256:' . $config_digest,
			size => $config_size
		);
		my %manifest = (
			schemaVersion => 2,
			mediaType => 'application/vnd.oci.image.manifest.v1+json',
			config => \%config,
			layers => \@layers_arr
		);
		my $json = encode_json(\%manifest);

		$digest = Crypt::Digest::SHA256::sha256_hex($json);
		$size = length($json);
		return $json;
	}

	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

1;
