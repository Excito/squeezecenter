package Slim::Menu::TrackInfo;

# $Id: TrackInfo.pm 31824 2011-01-25 03:41:26Z agrundman $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# Provides OPML-based extensible menu for track info
# Based on a patch from Justin Fletcher <gerph@gerph.org> (Bug 6930)

=head1 NAME

Slim::Menu::TrackInfo

=head1 DESCRIPTION

Provides a dynamic OPML-based track info menu to all UIs and allows
plugins to register additional menu items.

=cut

use strict;

use base qw(Slim::Menu::Base);

use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('menu.trackinfo');

sub init {
	my $class = shift;
	$class->SUPER::init();
	
	Slim::Control::Request::addDispatch(
		[ 'trackinfo', 'items', '_index', '_quantity' ],
		[ 1, 1, 1, \&cliQuery ]
	);
	
	Slim::Control::Request::addDispatch(
		[ 'trackinfo', 'playlist', '_method' ],
		[ 1, 1, 1, \&cliPlaylistCmd ]
	);
}

sub name {
	return 'SONG_INFO';
}

##
# Register all the information providers that we provide.
# This order is defined at http://wiki.slimdevices.com/index.php/UserInterfaceHierarchy
#
sub registerDefaultInfoProviders {
	my $class = shift;
	
	$class->SUPER::registerDefaultInfoProviders();

	$class->registerInfoProvider( addtrack => (
		menuMode  => 1,
		after     => 'top',
		func      => \&addTrackEnd,
	) );

	$class->registerInfoProvider( addtracknext => (
		menuMode  => 1,
		before    => 'playitem',
		func      => \&addTrackNext,
	) );

	$class->registerInfoProvider( playitem => (
		menuMode  => 1,
		before    => 'contributors',
		func      => \&playTrack,
	) );

	$class->registerInfoProvider( artwork => (
		menuMode  => 1,
		after     => 'year',
		func      => \&showArtwork,
	) );

	$class->registerInfoProvider( contributors => (
		after => 'top',
		func  => \&infoContributors,
	) );

	if ( !main::SLIM_SERVICE ) {
		$class->registerInfoProvider( album => (
			after => 'contributors',
			func  => \&infoAlbum,
		) );

		$class->registerInfoProvider( genres => (
			after => 'album',
			func  => \&infoGenres,
		) );
	}

	$class->registerInfoProvider( remotetitle => (
		after => main::SLIM_SERVICE ? 'top' : 'album',
		func  => \&infoRemoteTitle,
	) );
	
	if ( !main::SLIM_SERVICE ) {
		$class->registerInfoProvider( year => (
			after => 'genres',
			func  => \&infoYear,
		) );

		$class->registerInfoProvider( comment => (
			after => 'year',
			func  => \&infoComment,
		) );

		$class->registerInfoProvider( lyrics => (
			after => 'comment',
			func  => \&infoLyrics,
		) );
	}
	
	$class->registerInfoProvider( moreinfo => (
		after => main::SLIM_SERVICE ? 'remotetitle' : 'comment',
		func  => \&infoMoreInfo,
	) );
	
	$class->registerInfoProvider( tracknum => (
		parent => 'moreinfo',
		after  => 'moreinfo',
		func   => \&infoTrackNum,
	) );
	
	$class->registerInfoProvider( disc => (
		parent => 'moreinfo',
		after  => 'moreinfo',
		func   => \&infoDisc,
	) );

	$class->registerInfoProvider( type => (
		parent => 'moreinfo',
		after  => 'tracknum',
		func   => \&infoContentType,
	) );

	$class->registerInfoProvider( duration => (
		parent => 'moreinfo',
		after  => 'type',
		func   => \&infoDuration,
	) );

	$class->registerInfoProvider( replaygain => (
		parent => 'moreinfo',
		after  => 'duration',
		func   => \&infoReplayGain,
	) );

	$class->registerInfoProvider( rating => (
		parent => 'moreinfo',
		after  => 'replaygain',
		func   => \&infoRating,
	) );

	$class->registerInfoProvider( bitrate => (
		parent => 'moreinfo',
		after  => 'rating',
		func   => \&infoBitrate,
	) );
	
	$class->registerInfoProvider( samplerate => (
		parent => 'moreinfo',
		after  => 'bitrate',
		func   => \&infoSampleRate,
	) );
	
	$class->registerInfoProvider( samplesize => (
		parent => 'moreinfo',
		after  => 'samplerate',
		func   => \&infoSampleSize,
	) );

	$class->registerInfoProvider( filesize => (
		parent => 'moreinfo',
		after  => 'samplesize',
		func   => \&infoFileSize,
	) );

	$class->registerInfoProvider( url => (
		parent => 'moreinfo',
		after  => 'filesize',
		func   => \&infoUrl,
	) );

	$class->registerInfoProvider( modtime => (
		parent => 'moreinfo',
		after  => 'url',
		func   => \&infoFileModTime,
	) );
	
	$class->registerInfoProvider( tagversion => (
		parent => 'moreinfo',
		after  => 'modtime',
		func   => \&infoTagVersion,
	) );
	
	$class->registerInfoProvider( tagdump => (
		parent => 'moreinfo',
		after  => 'tagversion',
		func   => \&infoTagDump,
	) );	
}

sub menu {
	my ( $class, $client, $url, $track, $tags ) = @_;
	$tags ||= {};

	# If we don't have an ordering, generate one.
	# This will be triggered every time a change is made to the
	# registered information providers, but only then. After
	# that, we will have our ordering and only need to step
	# through it.
	my $infoOrdering = $class->getInfoOrdering;
	
	# Get track object if necessary
	if ( !blessed($track) ) {
		$track = Slim::Schema->objectForUrl( {
			url => $url,
		} );
		if ( !blessed($track) ) {
			$log->error( "No track object found for $url" );
			return;
		}
	}
	
	# Get plugin metadata for remote tracks
	my $remoteMeta = {};
	if ( $track->remote && blessed($client) ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ( $handler && $handler->can('getMetadataFor') ) {
			$remoteMeta = $handler->getMetadataFor( $client, $url );
		}
	}
	
	# Function to add menu items
	my $addItem = sub {
		my ( $ref, $items ) = @_;
		
		if ( defined $ref->{func} ) {
			
			my $item = eval { $ref->{func}->( $client, $url, $track, $remoteMeta, $tags ) };
			if ( $@ ) {
				$log->error( 'TrackInfo menu item "' . $ref->{name} . '" failed: ' . $@ );
				return;
			}
			
			return unless defined $item;
			
			# skip jive-only items for non-jive UIs
			return if $ref->{menuMode} && !$tags->{menuMode};
			
			# show artwork item to jive only if artwork exists
			return if $ref->{menuMode} && $tags->{menuMode} && $ref->{name} eq 'artwork' && !$track->coverArtExists;
			
			if ( ref $item eq 'ARRAY' ) {
				if ( scalar @{$item} ) {
					push @{$items}, @{$item};
				}
			}
			elsif ( ref $item eq 'HASH' ) {
				return if $ref->{menuMode} && !$tags->{menuMode};
				if ( scalar keys %{$item} ) {
					push @{$items}, $item;
				}
			}
			else {
				$log->error( 'TrackInfo menu item "' . $ref->{name} . '" failed: not an arrayref or hashref' );
			}				
		}
	};
	
	# Now run the order, which generates all the items we need
	my $items = [];
	
	for my $ref ( @{ $infoOrdering } ) {
		# Skip items with a defined parent, they are handled
		# as children below
		next if $ref->{parent};
		
		# Add the item
		$addItem->( $ref, $items );
		
		# Look for children of this item
		my @children = grep {
			$_->{parent} && $_->{parent} eq $ref->{name}
		} @{ $infoOrdering };
		
		if ( @children ) {
			my $subitems = $items->[-1]->{items} = [];
			
			for my $child ( @children ) {
				$addItem->( $child, $subitems );
			}
		}
	}
	
	return {
		name  => $track->title || Slim::Music::Info::getCurrentTitle( $client, $url, 1 ),
		type  => 'opml',
		items => $items,
		cover => $remoteMeta->{cover} || $remoteMeta->{icon} || '/music/' . $track->id . '/cover.jpg',
	};
}


sub infoContributors {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	
	my $items = [];
	
	if ( $remoteMeta->{artist} ) {
		push @{$items}, {
			type => 'text',
			name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $remoteMeta->{artist},

			web  => {
				type  => 'contributor',
				group => 'ARTIST',
				value => $remoteMeta->{artist},
			},
		};
	}
	else {
		return if main::SLIM_SERVICE;
		
		# Loop through the contributor types and append
		for my $role ( sort $track->contributorRoles ) {
			for my $contributor ( $track->contributorsOfType($role) ) {
				my $id = $contributor->id;
				
				my $db = {   
					hierarchy         => 'contributor,album,track',
					level             => 1,
					findCriteria      => {
						'contributor.id'   => $id,
						'contributor.role' => $role,
					},
					selectionCriteria => {
						'track.id'       => $track->id,
						'album.id'       => $track->albumid,
						'contributor.id' => $id,
					},
				};

				# XXX: Ideally this would point to another OPML provider like
				# Slim::Menu::Library::Contributor
				my $item = {
					type => 'redirect',
					name => cstring($client,  uc $role) . cstring($client, 'COLON') . ' ' . $contributor->name,

					db   => $db,

					player => {
						mode  => 'browsedb',
						modeParams => $db,
					},

					web  => {
						url   => "browsedb.html?hierarchy=$db->{hierarchy}&amp;level=$db->{level}" . _findDBCriteria($db),
						type  => 'contributor',
						group => uc($role),
						value => $contributor->name,
					},

					jive => {
						actions => {
							go => {
								cmd    => [ 'albums' ],
								params => {
									menu      => 'track',
									menu_all  => 1,
									artist_id => $id,
								},
							},
							play => {
								player => 0,
								cmd    => [ 'playlistcontrol' ],
								params => {
									cmd       => 'load',
									artist_id => $id,
								},
							},
							add => {
								player => 0,
								cmd    => [ 'playlistcontrol' ],
								params => {
									cmd       => 'add',
									artist_id => $id,
								},
							},
							'add-hold' => {
								player => 0,
								cmd    => [ 'playlistcontrol' ],
								params => {
									cmd       => 'insert',
									artist_id => $id,
								},
							},
						},
						window => {
							titleStyle => 'artists',
							menuStyle  => 'album',
							text       => $contributor->name,
						},
					},
				};
				$item->{'jive'}{'actions'}{'play-hold'} = _mixerItemHandler(obj => $contributor, 'obj_param' => 'artist_id' );
				push @{$items}, $item;
			}
		}
	}
	
	return $items;
}

sub showArtwork {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;
	my $items = [];
	my $jive;
	my $actions = {
		do => {
			cmd => [ 'artwork', $track->id ],
		},
	};
	$jive->{actions} = $actions;
	$jive->{showBigArtwork} = 1;

	push @{$items}, {
		type => 'text',
		name => cstring($client, 'SHOW_ARTWORK_SINGLE'),
		jive => $jive, 
	};
	
	return $items;
}

sub playTrack {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;
	my $items = [];
	my $jive;
	
	my $play_string = cstring($client, 'PLAY');

	my $actions;

	# "Play Song" in current playlist context is 'jump'
	if ( $tags->{menuContext} eq 'playlist' ) {
		$actions = {
			go => {
				player => 0,
				cmd => [ 'playlist', 'jump', $tags->{playlistIndex} ],
				nextWindow => 'parent',
			},
		};
		# play, add and add-hold all have the same behavior for this item
		$actions->{play} = $actions->{go};
		$actions->{add} = $actions->{go};
		$actions->{'add-hold'} = $actions->{go};

	# typical "Play Song" item
	} else {

		$actions = {
			go => {
				player => 0,
				cmd => [ 'playlistcontrol' ],
				params => {
					cmd => 'load',
					track_id => $track->id,
				},
				nextWindow => 'nowPlaying',
			},
			add => {
				player => 0,
				cmd => [ 'playlistcontrol' ],
				params => {
					cmd => 'add',
					track_id => $track->id,
				},
				nextWindow => 'parent',
			},
			'add-hold' => {
				player => 0,
				cmd => [ 'playlistcontrol' ],
				params => {
					cmd => 'insert',
					track_id => $track->id,
				},
				nextWindow => 'parent',
			},
		};
		# play is go
		$actions->{play} = $actions->{go};
	}

	$jive->{actions} = $actions;
	$jive->{style} = 'itemplay';

	push @{$items}, {
		type => 'text',
		name => $play_string,
		jive => $jive, 
	};
	
	return $items;
}

sub addTrackNext {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;
	my $string = cstring($client, 'PLAY_NEXT');
	my $cmd = 'insert';
	if ( $tags->{menuContext} eq 'playlist' ) {
		$cmd = 'playlistnext';
	}
	
	return addTrack( $client, $url, $track, $remoteMeta, $tags, $string, $cmd );
}

sub addTrackEnd {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $string = cstring($client, 'ADD_TO_END');
	my $cmd = 'add';

	# "Add Song" in current playlist context is 'delete'
	if ( $tags->{menuContext} eq 'playlist' ) {
		$string = cstring($client, 'REMOVE_FROM_PLAYLIST');
		$cmd = 'delete';
	}
	
	return addTrack( $client, $url, $track, $remoteMeta, $tags, $string, $cmd );
}

sub addTrack {
	my ( $client, $url, $track, $remoteMeta, $tags , $string, $cmd ) = @_;

	my $items = [];
	my $jive;
	
	my $actions;
	# remove from playlist
	if ( $cmd eq 'delete' ) {
		$string  = cstring($client, 'REMOVE_FROM_PLAYLIST');
		$actions = {
			go => {
				player     => 0,
				cmd        => [ 'playlist', 'delete', $tags->{playlistIndex} ],
				nextWindow => 'parent',
			},
		};
		# play, add and add-hold all have the same behavior for this item
		$actions->{play} = $actions->{go};
		$actions->{add} = $actions->{go};
		$actions->{'add-hold'} = $actions->{go};

	# play next in the playlist context
	} elsif ( $cmd eq 'playlistnext' ) {
		my $moveTo = Slim::Player::Source::playingSongIndex($client) || 0;
		if ( $tags->{playlistIndex} > $moveTo ) {
			$moveTo = $moveTo + 1;
		}
		$actions = {
			go => {
				player     => 0,
				cmd        => [ 'playlist', 'move', $tags->{playlistIndex}, $moveTo ],
				nextWindow => 'parent',
			},
		};
		# play, add and add-hold all have the same behavior for this item
		$actions->{play} = $actions->{go};
		$actions->{add} = $actions->{go};
		$actions->{'add-hold'} = $actions->{go};


	# typical "Add Song" item
	} else {

		$actions = {
			add => {
				player => 0,
				cmd => [ 'playlistcontrol' ],
				params => {
					cmd => $cmd,
					track_id => $track->id,
				},
				nextWindow => 'parent',
			},
		};
		# play and go have same behavior as go here
		$actions->{play} = $actions->{add};
		$actions->{go} = $actions->{add};
	}

	$jive->{actions} = $actions;

	push @{$items}, {
		type => 'text',
		name => $string,
		jive => $jive, 
	};
	
	return $items;
}

sub infoAlbum {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	
	my $item;
	
	if ( $remoteMeta->{album} ) {
		$item = {
			type => 'text',
			name => cstring($client, 'ALBUM') . cstring($client, 'COLON') . ' ' . $remoteMeta->{album},

			web  => {
				group => 'album',
				value => $remoteMeta->{album},
			},
		};
	}
	elsif ( my $album = $track->album ) {
		my $id = $album->id;
		my $artist = $track->artist;

		my $db = {
			hierarchy         => 'album,track',
			level             => 1,
			findCriteria      => { 
				'album.id'       => $id,
				'contributor.id' => ( blessed $artist ) ? $artist->id : undef,
			},
			selectionCriteria => {
				'track.id'       => $track->id,
				'album.id'       => $id,
				'contributor.id' => ( blessed $artist ) ? $artist->id : undef,
			},
		};
		
		$item = {
			type => 'redirect',
			name => cstring($client, 'ALBUM') . cstring($client, 'COLON') . ' ' . $album->name,

			db   => $db,

			player => {
				mode  => 'browsedb',
				modeParams => $db,
			},

			web  => {
				url   => "browsedb.html?hierarchy=$db->{hierarchy}&amp;level=$db->{level}" . _findDBCriteria($db),
				group => 'album',
				value => $album->name,
			},

			jive => {
				actions => {
					go => {
						cmd    => [ 'tracks' ],
						params => {
							menu     => 'songinfo',
							menu_all => 1,
							album_id => $id,
							sort     => 'tracknum',
						},
					},
					play => {
						player => 0,
						cmd    => [ 'playlistcontrol' ],
						params => {
							cmd      => 'load',
							album_id => $id,
						},
					},
					add => {
						player => 0,
						cmd    => [ 'playlistcontrol' ],
						params => {
							cmd      => 'add',
							album_id => $id,
						},
					},
					'add-hold' => {
						player => 0,
						cmd    => [ 'playlistcontrol' ],
						params => {
							cmd      => 'insert',
							album_id => $id,
						},
					},
				},
				window => {
					titleStyle => 'album',
					'icon-id'  => $track->id,
					text       => $album->name,
				},
			},
		};

		$item->{'jive'}{'actions'}{'play-hold'} = _mixerItemHandler(obj => $album, 'obj_param' => 'album_id' );

	}
	
	return $item;
}

sub infoGenres {
	my ( $client, $url, $track ) = @_;
	
	my $items = [];
	
	for my $genre ( $track->genres ) {
		my $id = $genre->id;
		
		my $db = {
			hierarchy         => 'genre,contributor,album,track',
			level             => 1,
			findCriteria      => {
				'genre.id' => $id,
			},
			selectionCriteria => {
				'track.id'       => $track->id,
				'album.id'       => $track->albumid,
				'contributor.id' => $track->artistid,
			},
		};
		
		my $item = {
			type => 'redirect',
			name => cstring($client, 'GENRE') . cstring($client, 'COLON') . ' ' . $genre->name,

			db   => $db,

			player => {
				mode  => 'browsedb',
				modeParams => $db,
			},

			web  => {
				url   => "browsedb.html?hierarchy=$db->{hierarchy}&amp;level=$db->{level}" . _findDBCriteria($db),
				group => 'genre',
				value => $genre->name,
			},

			jive => {
				actions => {
					go => {
						cmd    => [ 'artists' ],
						params => {
							menu     => 'album',
							menu_all => 1,
							genre_id => $id,
						},
					},
					play => {
						player => 0,
						cmd    => [ 'playlistcontrol' ],
						params => {
							cmd      => 'load',
							genre_id => $id,
						},
					},
					add => {
						player => 0,
						cmd    => [ 'playlistcontrol' ],
						params => {
							cmd      => 'add',
							genre_id => $id,
						},
					},
				},
				window => {
					titleStyle => 'genres',
					text       => $genre->name,
				}, 
			},
		};
		$item->{'jive'}{'actions'}{'play-hold'} = _mixerItemHandler(obj => $genre, 'obj_param' => 'genre_id' );
		push @{$items}, $item;
	}
	
	return $items;
}

sub infoYear {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $year = $track->year ) {
		
		my $db = {
			hierarchy         => 'year,album,track',
			level             => 1,
			findCriteria      => {
				'year.id' => $year,
			},
			selectionCriteria => {
				'track.id'       => $track->id,
				'album.id'       => $track->albumid,
				'contributor.id' => $track->artistid,
			},
		};

		$item = {
			type => 'redirect',
			name => cstring($client, 'YEAR') . cstring($client, 'COLON') . " $year",

			db   => $db,

			player => {
				mode  => 'browsedb',
				modeParams => $db,
			},

			web  => {
				url   => "browsedb.html?hierarchy=$db->{hierarchy}&amp;level=$db->{level}" . _findDBCriteria($db),
				group => 'year',
				value => $year,
			},

			jive => {
				actions => {
					go => {
						cmd         => [ 'albums' ],
						itemsParams => 'params',
						params => {
							year     => $year,
							menu     => 'track',
							menu_all => 1,
						},
					},
					play => {
						player      => 0,
						itemsParams => 'params',
						cmd         => [ 'playlistcontrol' ],
						params      => {
							year => $year,
							cmd  => 'load',
						},
					},
					add => {
						player      => 0,
						itemsParams => 'params',
						cmd         => [ 'playlistcontrol' ],
						params      => {
							year => $year,
							cmd  => 'add',
						},
					},
					'add-hold' => {
						player      => 0,
						itemsParams => 'params',
						cmd         => [ 'playlistcontrol' ],
						params      => {
							year => $year,
							cmd  => 'insert',
						},
					},
				},
				window => {
					menuStyle  => 'album',
					titleStyle => 'years',
				},
			},
		};
	}
	
	return $item;
}

sub infoComment {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	my $comment;

	# make urls in comments into links
	for my $c ($track->comment) {

		next unless defined $c && $c !~ /^\s*$/;

		if (!($c =~ s!\b(http://[A-Za-z0-9\-_\.\!~*'();/?:@&=+$,]+)!<a href=\"$1\" target=\"_blank\">$1</a>!igo)) {

			# handle emusic-type urls which don't have http://
			$c =~ s!\b(www\.[A-Za-z0-9\-_\.\!~*'();/?:@&=+$,]+)!<a href=\"http://$1\" target=\"_blank\">$1</a>!igo;
		}

		$comment .= $c;
	}
	
	if ( $comment ) {

		$comment =~ s/\r\n/\n/g;
		$comment =~ s/\r/\n/g;
		$comment =~ s/\n\n+/\n\n/g;

		$item = {
			name  => cstring($client, 'COMMENT'),
			items => [
				{
					type => 'text',
					wrap => 1,
					name => cstring($client, 'COMMENT') . cstring($client, 'COLON') . " $comment",
				},
			],
			
			web   => {
				group  => 'comment',
				unfold => 1,
			}
		};
	}
	
	return $item;
}

sub infoLyrics {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $lyrics = $track->lyrics ) {

		$lyrics =~ s/\r\n/\n/g;
		$lyrics =~ s/\r/\n/g;
		$lyrics =~ s/\n\n+/\n\n/g;

		$item = {
			name  => cstring($client, 'LYRICS'),
			items => [
				{
					type => 'text',
					wrap => 1,
					name => cstring($client, 'LYRICS') . cstring($client, 'COLON') . " $lyrics",
				},
			],
			
			web   => {
				group  => 'lyrics',
				unfold => 1,
			}
		};
	}
	
	return $item;
}

sub infoMoreInfo {
	my ( $client, $url, $track ) = @_;
	
	return {
		name => cstring($client, 'MOREINFO'),
		isContextMenu => 1,
		web  => {
			group  => 'moreinfo',
			unfold => 1,
		},

	};
}

sub infoTrackNum {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $tracknum = $track->tracknum ) {
		$item = {
			type => 'text',
			name => cstring($client, 'TRACK_NUMBER') . cstring($client, 'COLON') . " $tracknum",
		};
	}
	
	return $item;
}

sub infoDisc {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	my ($disc, $discc);
	my $album = $track->album;
	
	if ( blessed($album) && ($disc = ($track->disc || $album->disc)) && ($discc = $album->discc) ) {
		$item = {
			type => 'text',
			name => cstring($client, 'DISC') . cstring($client, 'COLON') . " $disc/$discc",
		};
	}
	
	return $item;
}

sub infoContentType {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $ct = Slim::Schema->contentType($track) ) {
		if ( blessed($client) && $track->remote && Slim::Music::Info::isPlaylist( $track, $ct ) )  {
			if ( my $url = $client->master()->currentTrackForUrl( $track->url ) ) {
				$ct = Slim::Schema->contentType($url);
			}
		}
		
		if ($ct eq 'unk' && $track->remote) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL( $url );
			if ( $handler && $handler->can('getMetadataFor') ) {
				my $meta = $handler->getMetadataFor( $client, $url );
				if ($meta && $meta->{type}) {
					$ct = $meta->{type};
				}
			}
		}

		$item = {
			type => 'text',
			name => cstring($client, 'TYPE') . cstring($client, 'COLON') . ' ' . cstring($client,  uc($ct) ),
		};
	}
	
	return $item;
}

sub infoDuration {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $duration = $track->duration ) {
		$item = {
			type => 'text',
			name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . " $duration",
		};
	}
	
	return $item;
}

sub infoReplayGain {
	my ( $client, $url, $track ) = @_;
	
	my $items = [];
	
	my $album = $track->album;
	
	if ( my $replaygain = $track->replay_gain ) {
		my $noclip = Slim::Player::ReplayGain::preventClipping( $replaygain, $track->replay_peak );
		if ( $noclip < $replaygain ) {
			# Gain was reduced to avoid clipping
			push @{$items}, {
				type => 'text',
				name => cstring($client, 'REPLAYGAIN') . cstring($client, 'COLON') . ' ' 
					. sprintf( "%2.2f", $replaygain ) . ' dB (' 
					. cstring( $client, 'REDUCED_TO_PREVENT_CLIPPING', sprintf( "%2.2f dB", $noclip ) ) . ')',
			};
		}
		else {
			push @{$items}, {
				type => 'text',
				name => cstring($client, 'REPLAYGAIN') . cstring($client, 'COLON') . ' ' . sprintf( "%2.2f", $replaygain ) . ' dB',
			};
		}
	}
	
	if ( blessed($album) && $album->can('replay_gain') ) {
		if ( my $albumreplaygain = $album->replay_gain ) {
			my $noclip = Slim::Player::ReplayGain::preventClipping( $albumreplaygain, $album->replay_peak );
			if ( $noclip < $albumreplaygain ) {
				# Gain was reduced to avoid clipping
				push @{$items}, {
					type => 'text',
					name => cstring($client, 'ALBUMREPLAYGAIN') . cstring($client, 'COLON') . ' ' 
						. sprintf( "%2.2f", $albumreplaygain ) . ' dB (' 
						. cstring( $client, 'REDUCED_TO_PREVENT_CLIPPING', sprintf( "%2.2f dB", $noclip ) ) . ')',
				};
			}
			else {
				push @{$items}, {
					type => 'text',
					name => cstring($client, 'ALBUMREPLAYGAIN') . cstring($client, 'COLON') . ' ' . sprintf( "%2.2f", $albumreplaygain ) . ' dB',
				};
			}
		}
	}
	
	return $items;
}

sub infoRating {
	my ( $client, $url, $track ) = @_;
	
	if ( main::SLIM_SERVICE ) {
		return;
	}
	
	my $item;
	
	if ( my $rating = Slim::Schema->rating($track) ) {
		$item = {
			type => 'text',
			name => cstring($client, 'RATING') . cstring($client, 'COLON') . ' ' . $rating,
		};
	}
	
	return $item;
}

sub infoBitrate {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $bitrate = ( Slim::Music::Info::getCurrentBitrate($track->url) || $track->prettyBitRate ) ) {
		
		# A bitrate of -1 is set by Scanner::scanBitrate or Formats::*::scanBitrate when the
		# bitrate of a remote stream can't be determined
		if ( $bitrate && $bitrate ne '-1' ) {
			
			my ($song, $sourcebitrate, $streambitrate);
			my $convert = '';
			
			if (blessed($client) && ($song = $client->currentSongForUrl($track->url))
				&& ($sourcebitrate = $song->bitrate())
				&& ($streambitrate = $song->streambitrate())
				&& $sourcebitrate != $streambitrate)
			{
					$convert = sprintf( ' (%s %s%s %s)', 
						cstring($client, 'CONVERTED_TO'), 
						sprintf( "%d", $streambitrate / 1000 ),
						cstring($client, 'KBPS'),
						cstring($client, $song->streamformat())
					); 
			}
			
			$item = {
				type => 'text',
				name => sprintf( "%s: %s%s",
					cstring($client, 'BITRATE'), $bitrate, $convert,
				),
			};
		}
	}
	
	return $item;
}

sub infoSampleRate {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( $track->samplerate ) {
		$item = {
			type => 'text',
			name => cstring($client, 'SAMPLERATE') . cstring($client, 'COLON') . ' ' . $track->prettySampleRate,
		};
	}
	
	return $item;
}

# XXX: never stored??
sub infoSampleSize {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $samplesize = $track->samplesize ) {
		$item = {
			type => 'text',
			name => cstring($client, 'SAMPLESIZE') . cstring($client, 'COLON') . " $samplesize " . cstring($client, 'BITS'),
		};
	}
	
	return $item;
}

sub infoFileSize {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $len = $track->filesize ) {
		$item = {
			type => 'text',
			name => cstring($client, 'FILELENGTH') . cstring($client, 'COLON') . ' ' . Slim::Utils::Misc::delimitThousands($len),
		};
	}
	
	return $item;
}

sub infoRemoteTitle {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	
	my $item;
	
	if ( $track->remote && $remoteMeta->{title} ) {
		$item = {
			type => 'text',
			name => cstring($client, 'TITLE') . cstring($client, 'COLON') . ' ' . $remoteMeta->{title},

			web  => {
				group => 'title',
				value => $remoteMeta->{title},
			},
		};
	}
	
	return $item;
}

sub infoUrl {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $turl = $track->url ) {
		$item = {
			type => 'text',
			name => $track->isRemoteURL($turl)
				? cstring($client, 'URL') . cstring($client, 'COLON') . ' ' . Slim::Utils::Misc::unescape($turl)
				: cstring($client, 'LOCATION') . cstring($client, 'COLON') . ' ' . Slim::Utils::Unicode::utf8decode( Slim::Utils::Misc::pathFromFileURL($turl) ),
				
			weblink => $track->isRemoteURL($turl)
				? undef
				: '/music/' . $track->id . '/download',
		};
	}
	
	return $item;
}

sub infoFileModTime {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( !$track->remote ) {
		if ( my $age = $track->modificationTime ) {
			$item = {
				type => 'text',
				name => cstring($client, 'MODTIME') . cstring($client, 'COLON') . " $age",
			};
		}
	}
	
	return $item;
}

sub infoTagVersion {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( my $ver = $track->tagversion ) {
		$item = {
			type => 'text',
			name => cstring($client, 'TAGVERSION') . cstring($client, 'COLON') . " $ver",
		};
	}
	
	return $item;
}

sub infoTagDump {
	my ( $client, $url, $track ) = @_;
	
	my $item;
	
	if ( $track->audio ) {
		$item = {
			name        => cstring($client, 'VIEW_TAGS'),
			url         => \&tagDump,
			passthrough => [ $track->path ],
		};
	}
	
	return $item;
}

sub tagDump {
	my ( $client, $callback, $path ) = @_;
	
	my $menu = [];
	
	require Audio::Scan;
	my $s = eval { Audio::Scan->scan_tags($path) };
	
	if ( $@ ) {
		$menu = {
			type => 'text',
			name => $@,
		};
	}
	else {	
		my $tags = $s->{tags};
		
		# Recursive handler for array-based tags
		my $array_tag;
		$array_tag = sub {
			my $tag = shift;
			
			my @array;
			
			for my $x ( @{$tag} ) {
				if ( ref $x eq 'ARRAY' ) {
					my $a = $array_tag->($x);
					$x = '[ ' . join( ', ', @{$a} ) . ' ]';
				}
				
				if ( length($x) > 256 ) {
					$x = '(' . length($x) . ' ' . cstring($client, 'BYTES') . ')';
				}
				
				push @array, $x;
			}
			
			return \@array;
		};
	
		for my $k ( sort keys %{$tags} ) {
			my $v = $tags->{$k};
		
			if ( ref $v eq 'ARRAY' ) {
				my $a = $array_tag->($v);
							
				push @{$menu}, {
					type => 'text',
					name => $k . ': [ ' . join( ', ', @{$a} ) . ' ]',
				};
			}
			else {
				if ( length($v) > 256 ) {
					$v = '(' . length($v) . ' ' . cstring($client, 'BYTES') . ')';
				}
			
				push @{$menu}, {
					type => 'text',
					name => $k . ': ' . $v,
				};
			}
		}
	
		if ( !scalar @{$menu} ) {
			$menu = {
				type => 'text',
				name => cstring($client, 'NO_TAGS_FOUND'),
			};
		}
	}
	
	$callback->( $menu );
}

sub _findDBCriteria {
	my $db = shift;
	
	my $findCriteria = '';
	foreach (keys %{$db->{findCriteria}}) {
		$findCriteria .= "&amp;$_=" . $db->{findCriteria}->{$_};
	}
	
	return $findCriteria;
}

sub _mixers {
	my $Imports = Slim::Music::Import->importers;
	my @mixers = ();
	for my $import (keys %{$Imports}) {
		next if !$Imports->{$import}->{'mixer'};
		next if !$Imports->{$import}->{'use'};
		next if !$Imports->{$import}->{'cliBase'};
		next if !$Imports->{$import}->{'contextToken'};
		push @mixers, $import;
	}
	return ($Imports, \@mixers);
}

sub _mixerItemHandler {
	my %args       = @_;
	my $obj        = $args{'obj'};
	my $obj_param  = $args{'obj_param'};

	my ($Imports, $mixers) = _mixers();
	
	if (scalar(@$mixers) == 1 && blessed($obj)) {
		my $mixer = $mixers->[0];
		if ($mixer->can('mixable') && $mixer->mixable($obj)) {
			# pull in cliBase with Storable::dclone so we can manipulate without affecting the object itself
			my $command = Storable::dclone( $Imports->{$mixer}->{cliBase} );
			$command->{'params'}{'menu'} = 1;
			$command->{'params'}{$obj_param} = $obj->id;
			return $command;
		} else {
			return (
				{
					player => 0,
					cmd    => ['jiveunmixable'],
					params => {
						contextToken => $Imports->{$mixer}->{contextToken},
					},
				}
			);
			
		}
	} elsif ( scalar(@$mixers) && blessed($obj) ) {
		return {
			player => 0,
			cmd    => ['contextmenu'],
			params => {
				menu => 'track',
				$obj_param => $obj->id,
			},
		};
	} else {
		return undef;
	}
}

my $cachedFeed;

sub cliQuery {
	my $request = shift;
	
	my $client         = $request->client;
	my $url            = $request->getParam('url');
	my $trackId        = $request->getParam('track_id');
	my $menuMode       = $request->getParam('menu') || 0;
	my $menuContext    = $request->getParam('context') || 'normal';
	my $playlist_index = defined( $request->getParam('playlist_index') ) ?  $request->getParam('playlist_index') : undef;
	
	# special case-- playlist_index given but no trackId
	if (defined($playlist_index) && ! $trackId ) {
		my $song = Slim::Player::Playlist::song( $client, $playlist_index );
		$trackId = $song->id;
		$url     = $song->url;
		$request->addParam('track_id', $trackId);
		$request->addParam('url', $url);
	}
		
	my $tags = {
		menuMode      => $menuMode,
		menuContext   => $menuContext,
		playlistIndex => $playlist_index,
	};

	unless ( $url || $trackId ) {
		$request->setStatusBadParams();
		return;
	}
	
	my $feed;
	
	# Protocol Handlers can define their own track info OPML menus
	if ( $url ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL( $url );
		if ( $handler && $handler->can('trackInfoURL') ) {
			$feed = $handler->trackInfoURL( $client, $url );
		}
	}
	
	if ( !$feed ) {
		# Default menu
		if ( $url ) {
			$feed = Slim::Menu::TrackInfo->menu( $client, $url, undef, $tags );
		}
		else {
			my $track = Slim::Schema->find( Track => $trackId );
			$feed     = Slim::Menu::TrackInfo->menu( $client, $track->url, $track, $tags ) if $track;
		}
	}
	
	$cachedFeed = $feed if $feed;
	
	Slim::Control::XMLBrowser::cliQuery( 'trackinfo', $feed, $request );
}

sub cliPlaylistCmd {
	my $request = shift;
	
	my $client  = $request->client;
	my $method  = $request->getParam('_method');

	unless ($client && $method && $cachedFeed) {
		$request->setStatusBadParams();
		return;
	}
	
	return 	Slim::Control::XMLBrowser::cliQuery( 'trackinfo', $cachedFeed, $request );
}

1;
