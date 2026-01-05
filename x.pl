use v5.40;

class Container::Layer {

}



class Container::Builder {
	field $os = 'debian'
	field $arch = 'x86_64'
	field $os_version = 'bookworm'
	field @layers = ()

	# Create a layer that adds a package to the container
	method add_package {

	}

	# Create a layer that creates a directory in the container
	method create_directory {

	}

	# Create a layer that adds a user to the container
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

	}
}
