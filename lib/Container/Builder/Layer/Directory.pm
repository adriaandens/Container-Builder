package Container::Builder::Layer::Directory;

use Container::Builder::Layer;
use Container::Builder::Tar;

use Crypt::Digest::SHA256 qw(sha256_hex);

class Container::Builder::Layer::Directory :isa(Container::Builder::Layer) {
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

1;
