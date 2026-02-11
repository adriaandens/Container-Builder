package Container::Builder::Config;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

use Crypt::Digest::SHA256 qw(sha256_hex);
use JSON;
use DateTime;


class Container::Builder::Config {
	field $digest = '';
	field $size = '';

	method generate_config($user = 'root', $env = [], $entry = [], $cmd = [], $working_dir = '/', $layers = []) {
		my %config = (
			User => $user,
			Env => \@$env,
			Entrypoint => \@$entry,
			Cmd => \@$cmd,
			WorkingDir => $working_dir
		);
		my %rootfs = ( type => 'layers' );
		my @diff_ids = map { 'sha256:' . $_->get_digest() } @$layers;
		$rootfs{diff_ids} = \@diff_ids;
		my %history = ( created => '0001-01-01T00:00:00Z' );
		my @histories = map { \%history } @$layers;
		my %json_pp = (
			created => DateTime->now() . 'Z',
			architecture => 'amd64',
			os => 'linux'
		);
		$json_pp{history} = \@histories;
		$json_pp{config} = \%config;
		$json_pp{rootfs} = \%rootfs;

		my $json =  encode_json(\%json_pp);
		$digest = Crypt::Digest::SHA256::sha256_hex($json);
		$size = length($json);
		return $json;
	}

	method get_digest() { return lc($digest) }
	method get_size() { return $size }
}

1;
