package Container::Builder::Layer::DebianPackageFile;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Archive::Ar;
use IO::Uncompress::UnXz qw(unxz);
use IO::Compress::Gzip qw(gzip);
use Crypt::Digest::SHA256 qw(sha256_hex);

use Container::Builder::Layer;

class Container::Builder::Layer::DebianPackageFile :isa(Container::Builder::Layer) { 
	field $file :param = "";
	field $data :param = "";
	field $compress :param = 1;
	field $size = 0;
	field $digest = 0;

	method generate_artifact() {
		my $ar;
		if($file) {
			die "Unable to read file $file\n" if !-r $file;
			$ar = Archive::Ar->new($file);
		} elsif($data) {
			$ar = Archive::Ar->new();
			my $result = $ar->read_memory($data);
			die "Couldn't read Ar archive from memory\n" if(!defined($result));
		} else {
			die "No file or data passed to DebianPackageFile\n";
		}
		## TODO: support data.tar, data.tar.gz, data.tgz, ...
		die "Unable to find data.tar.xz inside deb package\n" if !$ar->contains_file('data.tar.xz');
		my $xz_data = $ar->get_data('data.tar.xz');
		my $unxz_data;
		IO::Uncompress::UnXz::unxz(\$xz_data => \$unxz_data) or die "Unable to extract data using unxz\n";
		if($compress) {
			my $gunzip_compressed_data;
			IO::Compress::Gzip::gzip(\$unxz_data => \$gunzip_compressed_data) or die "Unable to gunzip the unxz data\n";
			$size = length($gunzip_compressed_data);
			$digest = Crypt::Digest::SHA256::sha256_hex($gunzip_compressed_data);
			return $gunzip_compressed_data;
		} else {
			$size = length($unxz_data);
			$digest = Crypt::Digest::SHA256::sha256_hex($unxz_data);
			return $unxz_data;
		}
	}

	method get_media_type() { 
		my $s = "application/vnd.oci.image.layer.v1.tar";
		$s .= '+gzip' if $compress;
		return $s;
	}
	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

1;
