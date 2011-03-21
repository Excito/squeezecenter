package Slim::Schema::ContributorTrack;

# $Id: ContributorTrack.pm 8353 2006-07-10 19:23:51Z dsully $
#
# Contributor to track mapping class

use strict;
use base 'Slim::Schema::DBI';

{
	my $class = __PACKAGE__;

	$class->table('contributor_track');

	$class->add_columns(qw/role contributor track/);

	$class->set_primary_key(qw/role contributor track/);
	$class->add_unique_constraint('role_contributor_track' => [qw/role contributor track/]);

	$class->belongs_to('contributor' => 'Slim::Schema::Contributor');
	$class->belongs_to('track'       => 'Slim::Schema::Track');
}

1;

__END__
