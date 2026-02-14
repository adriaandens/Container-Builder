package Container::Builder::Layer;

use v5.40;
use feature 'class';
no warnings 'experimental::class';

class Container::Builder::Layer {
	field $comment :param = '';

	# This method is called in the builder to generate the artifact (bytes on disk) that will be put in the container image
	method generate_artifact() { }

	# These three methods are used by the manifest to generate the layers array
	method get_comment() { $comment }
	method get_media_type() { }
	method get_digest() { }
	method get_size() { }
}

1;
