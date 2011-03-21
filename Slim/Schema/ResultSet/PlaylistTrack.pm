package Slim::Schema::ResultSet::PlaylistTrack;

# $Id: PlaylistTrack.pm 7655 2006-05-25 20:03:40Z dsully $

use strict;
use base qw(Slim::Schema::ResultSet::Track);

sub alphaPageBar   { 0 }
sub ignoreArticles { 0 }

sub browseBodyTemplate {
	return 'browse_playlist.html';
}

1;
