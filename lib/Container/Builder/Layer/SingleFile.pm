package Container::Builder::Layer::SingleFile;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Container::Builder::Layer;
use Container::Builder::Tar;
use Crypt::Digest::SHA256 qw(sha256_hex);

class Container::Builder::Layer::SingleFile :isa(Container::Builder::Layer) {
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


1;
