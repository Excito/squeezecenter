package Slim::Schema::ResultSet::Contributor;

# $Id: Contributor.pm 21711 2008-07-13 20:00:32Z andy $

use strict;
use base qw(Slim::Schema::ResultSet::Base);

use Slim::Utils::Prefs;

sub pageBarResults {
	my $self = shift;

	my $table = $self->{'attrs'}{'alias'};
	my $name  = "$table.namesort";

	$self->search(undef, {
		'select'     => [ \"LEFT($name, 1)", { count => \"DISTINCT($table.id)" } ],
		as           => [ 'letter', 'count' ],
		group_by     => \"LEFT($name, 1)",
		result_class => 'Slim::Schema::PageBar',
	});
}

sub title {
	my $self = shift;

	return 'BROWSE_BY_ARTIST';
}

sub allTitle {
	my $self = shift;

	return 'ALL_ARTISTS';
}

sub alphaPageBar { 1 }
sub ignoreArticles { 1 }

sub searchColumn {
	my $self  = shift;

	return 'namesearch';
}

sub searchNames {
	my $self  = shift;
	my $terms = shift;
	my $attrs = shift || {};

	my @joins = ();
	my $cond  = {
		'me.namesearch' => { 'like' => $terms },
	};

	# Bug: 2479 - Don't include roles if the user has them unchecked.
	if (my $roles = Slim::Schema->artistOnlyRoles('TRACKARTIST')) {

		$cond->{'contributorAlbums.role'} = { 'in' => $roles };
		push @joins, 'contributorAlbums';
	}

	$attrs->{'order_by'} ||= 'me.namesort';
	$attrs->{'distinct'} ||= 'me.id';
	$attrs->{'join'}     ||= \@joins;

	return $self->search($cond, $attrs);
}

sub browse {
	my $self = shift;
	my $find = shift;
	my $cond = shift || {};
	my $sort = shift;

	my @joins = ();
	my $roles = Slim::Schema->artistOnlyRoles;

	# The user may not want to include all the composers / conductors
	if ($roles) {
		# Bug 7992, Don't join on contributorAlbums if this is for a genre query
		if ( !exists $cond->{'genreTracks.genre'} ) {
			$cond->{'contributorAlbums.role'} = { 'in' => $roles };
		}
	}

	if (preferences('server')->get('variousArtistAutoIdentification')) {

		$cond->{'album.compilation'} = [ { 'is' => undef }, { '=' => 0 } ];

		push @joins, { 'contributorAlbums' => 'album' };

	} elsif ($roles) {

		if ( !exists $cond->{'genreTracks.genre'} ) {
			push @joins, 'contributorAlbums';
		}
	}

	return $self->search($cond, {
		'order_by' => 'me.namesort',
		'group_by' => 'me.id',
		'join'     => \@joins,
	});
}

sub descendAlbum {
	my ($self, $find, $cond, $sort) = @_;

	# Create a clean resultset
	my $rs = $self->result_source->resultset;

	# Handle sort's from the web UI.
	if ($sort) {

		$sort = $rs->fixupSortKeys($sort);

	} else {

		$sort = "concat('0', album.titlesort), album.disc";
	}

	my $attr = {
		'order_by' => $sort,
	};

	# Bug: 4694 - if role has been specified descend using this role, otherwise descend for all artist only roles
	my $roles;

	if ($find->{'contributor.role'}) {

		if ($find->{'contributor.role'} ne 'ALL') {

			$roles = [ Slim::Schema::Contributor->typeToRole($find->{'contributor.role'}) ];
		}

	} else {

		$roles = Slim::Schema->artistOnlyRoles('TRACKARTIST');
	}

	if ($roles) {

		$cond->{'contributorAlbums.role'} = { 'in' => $roles };
	}

	# Bug: 2192 - Don't filter out compilation
	# albums at the artist level - we want to see all of them for an artist.
	my $albumCond = {};

	# Make run fixupFindKeys before trying to check/delete me.id,
	# otherwise it will be contributor.id still.
	$cond = $rs->fixupFindKeys($cond);

	if (defined $find->{'album.compilation'}) {

		if ($cond->{'me.id'} && $cond->{'me.id'} == Slim::Schema->variousArtistsObject->id && $find->{'contributor.role'} ne 'ALL') {

			delete $cond->{'me.id'};
		}

		$albumCond->{'album.compilation'} = $find->{'album.compilation'};
	}

	# Pull in the album join.
	$rs = $rs->search_related('contributorAlbums', $cond);

	# Constrain on the genre if it exists
	# but only do so if the noGenreFilter isn't set or the "All Songs" item is selected
	if ( (my $genre = $find->{'genre.id'}) && !preferences('server')->get('noGenreFilter') ) {
		$albumCond->{'genreTracks.genre'} = $genre;
		$attr->{'join'} = { 'tracks' => 'genreTracks' };
	}


	# Full on genre join will override the above if we need to search on the genre name.
	if ($sort =~ /genre\./) {

		$attr->{'join'} = { 'tracks' => { 'genreTracks' => 'genre' } };
	}

	return $rs->search_related('album', $albumCond, $attr);
}

1;
