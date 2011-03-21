package Slim::Schema::Age;

# $Id: Age.pm 27975 2009-08-01 03:28:30Z andy $

use strict;
use base 'Slim::Schema::Album';

use Slim::Schema::ResultSet::Age;

use Slim::Utils::Misc;

{
	my $class = __PACKAGE__;

	# Magic to create a ResultSource for this inherited class.
	$class->table($class->table);

	$class->resultset_class('Slim::Schema::ResultSet::Age');
}

1;

__END__
