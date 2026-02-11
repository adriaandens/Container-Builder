package Container::Builder::Index;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use JSON;

# https://specs.opencontainers.org/image-spec/image-index/?v=v1.1.1
class Container::Builder::Index {
	method generate_index($manifest_digest, $manifest_size) {
		my %manifest = (
			mediaType => 'application/vnd.oci.image.manifest.v1+json',
			digest => 'sha256:' . $manifest_digest,
			size => $manifest_size
		);
		my @manifests = (\%manifest);
		my %index = (
			schemaVersion => 2,
			manifests => \@manifests
		);
		my $json = encode_json(\%index);
		# TODO: you can annotate and pass the container name
		return '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:' . $manifest_digest . '","size":' . $manifest_size . '}]}'
	}
}

1;
