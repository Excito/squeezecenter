package Slim::Schema::PlaylistTrack;

# $Id: PlaylistTrack.pm 27975 2009-08-01 03:28:30Z andy $
#
# Playlist to track mapping class

use strict;
use base 'Slim::Schema::DBI';

use Slim::Schema::ResultSet::PlaylistTrack;

{
	my $class = __PACKAGE__;

	$class->table('playlist_track');

	$class->add_columns(qw(id position playlist track));

	$class->set_primary_key('id');

	$class->belongs_to(playlist => 'Slim::Schema::Track');

	$class->resultset_class('Slim::Schema::ResultSet::PlaylistTrack');
}

# The relationskip to the Track objects is done here

sub inflate_result {
	my ($class, $source, $me, $prefetch) = @_;
	
	return Slim::Schema->objectForUrl({
				'url'      => $me->{track},
				'create'   => 1,
				'readTags' => 1,
			});
}

1;

__END__
