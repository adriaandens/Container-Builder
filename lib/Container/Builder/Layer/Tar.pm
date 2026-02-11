package Container::Builder::Layer::Tar;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Crypt::Digest::SHA256 qw(sha256_hex);

use Container::Builder::Layer;

class Container::Builder::Layer::Tar :isa(Container::Builder::Layer) {
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

1;
