package Slim::Schema::MetaInformation;

# $Id: MetaInformation.pm 7670 2006-05-26 21:18:44Z dsully $

use strict;
use base 'Slim::Schema::DBI';

{
	my $class = __PACKAGE__;

	$class->table('metainformation');

	$class->add_columns(qw/name value/);

	$class->set_primary_key(qw/name/);
}

1;

__END__
