package Slim::Schema::PlaylistTrack;

# $Id: PlaylistTrack.pm 8499 2006-07-19 02:14:39Z dsully $
#
# Playlist to track mapping class

use strict;
use base 'Slim::Schema::DBI';

{
	my $class = __PACKAGE__;

	$class->table('playlist_track');

	$class->add_columns(qw(id position playlist track));

	$class->set_primary_key('id');

	$class->belongs_to(playlist => 'Slim::Schema::Track');
	$class->belongs_to(track => 'Slim::Schema::Track');

	$class->resultset_class('Slim::Schema::ResultSet::PlaylistTrack');
}

1;

__END__
