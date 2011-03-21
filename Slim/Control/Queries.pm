package Slim::Control::Queries;

# $Id:  $
#
# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

################################################################################

=head1 NAME

Slim::Control::Queries

=head1 DESCRIPTION

L<Slim::Control::Queries> implements most Squeezebox Server queries and is designed to 
 be exclusively called through Request.pm and the mechanisms it defines.

 Except for subscribe-able queries (such as status and serverstatus), there are no
 important differences between the code for a query and one for
 a command. Please check the commented command in Commands.pm.

=cut

use strict;

use Data::URIEncode qw(complex_to_query);
use Storable;
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(encode_base64 decode_base64);
use Scalar::Util qw(blessed);
use URI::Escape;

use Slim::Utils::Misc qw( specified );
use Slim::Utils::Alarm;
use Slim::Utils::Log;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;
use Slim::Utils::Text;

{
	if (main::ISWINDOWS) {
		require Slim::Utils::OS::Win32;
	}
}

my $log = logger('control.queries');

my $prefs = preferences('server');

# Frequently used data can be cached in memory, such as the list of albums for Jive
my $cache = {};


sub alarmPlaylistsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['alarm'], ['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $menuMode = $request->getParam('menu') || 0;
	my $id       = $request->getParam('id');

	my $playlists      = Slim::Utils::Alarm->getPlaylists($client);
	my $alarm          = Slim::Utils::Alarm->getAlarm($client, $id) if $id;
	my $currentSetting = $alarm ? $alarm->playlist() : '';

	my @playlistChoices;
	my $loopname = 'item_loop';
	my $cnt = 0;
	
	my ($valid, $start, $end) = ( $menuMode ? (1, 0, scalar @$playlists) : $request->normalize(scalar($index), scalar($quantity), scalar @$playlists) );

	for my $typeRef (@$playlists[$start..$end]) {
		
		my $type    = $typeRef->{type};
		my @choices = ();
		my $aref    = $typeRef->{items};
		
		for my $choice (@$aref) {

			if ($menuMode) {
				my $radio = ( 
					( $currentSetting && $currentSetting eq $choice->{url} )
					|| ( !defined $choice->{url} && !defined $currentSetting )
				);

				my $subitem = {
					text    => $choice->{title},
					radio   => $radio + 0,
					nextWindow => 'refreshOrigin',
					actions => {
						do => {
							cmd    => [ 'alarm', 'update' ],
							params => {
								id          => $id,
								playlisturl => $choice->{url} || 0, # send 0 for "current playlist"
							},
						},
						preview => {
							title   => $choice->{title},
							cmd	=> [ 'playlist', 'preview' ],
							params  => {
								url	=>	$choice->{url}, 
								title	=>	$choice->{title},
							},
						},
					},
				};
				if ( ! $choice->{url} ) {
					$subitem->{actions}->{preview} = {
						cmd => [ 'play' ],
					};
				}
	
				
				if ($typeRef->{singleItem}) {
					$subitem->{'nextWindow'} = 'refresh';
				}
				
				push @choices, $subitem;
			}
			
			else {
				$request->addResultLoop($loopname, $cnt, 'category', $type);
				$request->addResultLoop($loopname, $cnt, 'title', $choice->{title});
				$request->addResultLoop($loopname, $cnt, 'url', $choice->{url});
				$request->addResultLoop($loopname, $cnt, 'singleton', $typeRef->{singleItem} ? '1' : '0');
				$cnt++;
			}
		}

		if ( scalar(@choices) ) {

			my $item = {
				text      => $type,
				offset    => 0,
				count     => scalar(@choices),
				item_loop => \@choices,
			};
			$request->setResultLoopHash($loopname, $cnt, $item);
			
			$cnt++;
		}
	}
	
	$request->addResult("offset", $start);
	$request->addResult("count", $cnt);
	$request->addResult('window', { textareaToken => 'SLIMBROWSER_ALARM_SOUND_HELP' } );
	$request->setStatusDone;
}

sub alarmsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['alarms']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $filter	 = $request->getParam('filter');
	my $alarmDOW = $request->getParam('dow');
	
	# being nice: we'll still be accepting 'defined' though this doesn't make sense any longer
	if ($request->paramNotOneOfIfDefined($filter, ['all', 'defined', 'enabled'])) {
		$request->setStatusBadParams();
		return;
	}
	
	$request->addResult('fade', $prefs->client($client)->get('alarmfadeseconds'));
	
	$filter = 'enabled' if !defined $filter;

	my @alarms = grep {
		defined $alarmDOW
			? $_->day() == $alarmDOW
			: ($filter eq 'all' || ($filter eq 'enabled' && $_->enabled()))
	} Slim::Utils::Alarm->getAlarms($client, 1);

	my $count = scalar @alarms;
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'alarms_loop';
		my $cnt = 0;
		
		for my $alarm (@alarms[$start..$end]) {

			my @dow;
			foreach (0..6) {
				push @dow, $_ if $alarm->day($_);
			}

			$request->addResultLoop($loopname, $cnt, 'id', $alarm->id());
			$request->addResultLoop($loopname, $cnt, 'dow', join(',', @dow));
			$request->addResultLoop($loopname, $cnt, 'enabled', $alarm->enabled());
			$request->addResultLoop($loopname, $cnt, 'repeat', $alarm->repeat());
			$request->addResultLoop($loopname, $cnt, 'time', $alarm->time());
			$request->addResultLoop($loopname, $cnt, 'volume', $alarm->volume());
			$request->addResultLoop($loopname, $cnt, 'url', $alarm->playlist() || 'CURRENT_PLAYLIST');
			$cnt++;
		}
	}

	$request->setStatusDone();
}

sub albumsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['albums']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}
	
	# get our parameters
	my %favorites;
	$favorites{'url'}    = $request->getParam('favorites_url');
	$favorites{'title'}  = $request->getParam('favorites_title');
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tags          = $request->getParam('tags');
	my $search        = $request->getParam('search');
	my $compilation   = $request->getParam('compilation');
	my $contributorID = $request->getParam('artist_id');
	my $genreID       = $request->getParam('genre_id');
	my $trackID       = $request->getParam('track_id');
	my $year          = $request->getParam('year');
	my $sort          = $request->getParam('sort');
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	my $to_cache      = $request->getParam('cache');
	my $party         = $request->getParam('party') || 0;
	
	if ($request->paramNotOneOfIfDefined($sort, ['new', 'album', 'artflow', 'artistalbum', 'yearalbum', 'yearartistalbum' ])) {
		$request->setStatusBadParams();
		return;
	}

	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $useContextMenu = $request->getParam('useContextMenu');
	my $partyMode = _partyModeCheck($request);
	my $allSongs = $menuMode && defined $insert && !$partyMode;
	my $insertAll = $allSongs && !$useContextMenu;

	if (!defined $tags) {
		$tags = 'l';
	}

	# get them all by default
	my $where = {};
	my $attr = {};
	
	# Normalize and add any search parameters
	if (defined $trackID) {
		$where->{'tracks.id'} = $trackID;
		push @{$attr->{'join'}}, 'tracks';
	}
	
	# ignore everything if $track_id was specified
	else {
	
		if ($sort && $sort eq 'new') {

			$attr->{'order_by'} = 'tracks.timestamp desc, tracks.disc, tracks.tracknum, tracks.titlesort';
			push @{$attr->{'join'}}, 'tracks';

		} elsif ($sort && $sort eq 'artflow') {

			$attr->{'order_by'} = Slim::Schema->rs('Album')->fixupSortKeys('contributor.namesort,album.year,album.titlesort');
			push @{$attr->{'join'}}, 'contributor';

		} elsif ($sort && $sort eq 'artistalbum') {

			$attr->{'order_by'} = Slim::Schema->rs('Album')->fixupSortKeys('contributor.namesort,album.titlesort');
			push @{$attr->{'join'}}, 'contributor';

		} elsif ($sort && $sort eq 'yearartistalbum') {

			$attr->{'order_by'} = Slim::Schema->rs('Album')->fixupSortKeys('album.year,contributor.namesort,album.titlesort');
			push @{$attr->{'join'}}, 'contributor';

		} elsif ($sort && $sort eq 'yearalbum') {

			$attr->{'order_by'} = Slim::Schema->rs('Album')->fixupSortKeys('album.year,album.titlesort');

		}

		if (specified($search)) {
			$where->{'me.titlesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
		}
		
		if (defined $year) {
			$where->{'me.year'} = $year;
		}
		
		# Manage joins
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$compilation = 1;
			}
			else {	
				$where->{'contributorAlbums.contributor'} = $contributorID;
				push @{$attr->{'join'}}, 'contributorAlbums';
				$attr->{'distinct'} = 1;
			}			
		}
	
		if (defined $genreID){
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'tracks' => 'genreTracks'};
			$attr->{'distinct'} = 1;
		}
	
		if (defined $compilation) {
			if ($compilation == 1) {
				$where->{'me.compilation'} = 1;
			}
			if ($compilation == 0) {
				$where->{'me.compilation'} = [ { 'is' => undef }, { '=' => 0 } ];
			}
		}
	}
	
	# Jive menu mode, needs contributor data and only a subset of columns
	if ( $menuMode ) {
		if ( !grep { /^contributor$/ } @{ $attr->{'join'} } ) {
			push @{ $attr->{'join'} }, 'contributor';
		}
		
		$attr->{'cols'} = [ qw(id artwork title contributor.name contributor.namesort titlesort musicmagic_mixable disc discc titlesearch) ];
	}
	
	# Flatten request for lookup in cache, only for Jive menu queries
	my $cacheKey = complex_to_query($where) . complex_to_query($attr) . $menu . $tags . (defined $insert ? $insert : '');
	if ( $menuMode ) {
		if ( my $cached = $cache->{albums}->[$party]->{$cacheKey} ) {
			my $copy = from_json( $cached );
			
			# Don't slice past the end of the array
			if ( $copy->{count} < $index + $quantity ) {
				$quantity = $copy->{count} - $index;
			}
		
			# Slice the full album result according to start and end
			$copy->{item_loop} = [ @{ $copy->{item_loop} }[ $index .. ( $index + $quantity ) - 1 ] ];
		
			# Change offset value
			$copy->{offset} = $index;
		
			$request->setRawResults( $copy );
			$request->setStatusDone();
		
			return;
		}
	}
	
	# use the browse standard additions, sort and filters, and complete with 
	# our stuff
	my $rs = Slim::Schema->rs('Album')->browse->search($where, $attr);

	my $count = $rs->count;

	if ($menuMode) {

		# Bug 5435, 8020
		# on "new music" queries, return the count as being 
		# the user setting for new music limit if available
		# then fall back to the block size if the pref doesn't exist
		if (defined $sort && $sort eq 'new') {
			if (!$prefs->get('browseagelimit')) {
				if ($count > $quantity) {
					$count = $quantity;
				}
			} else {
				if ($count > $prefs->get('browseagelimit')) {
					$count = $prefs->get('browseagelimit');
				}
			}
		}

		# decide what is the next step down
		# generally, we go to tracks after albums, so we get menu:track
		# from the tracks we'll go to trackinfo
		my $actioncmd = $menu . 's';
		my $nextMenu = 'trackinfo';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						'menu' => $nextMenu,
						'menu_all' => '1',
						'sort' => 'tracknum',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
					'nextWindow'  => 'nowPlaying',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				}		
			},
		};
		
		$base->{'actions'}{'play-hold'} = _mixerBase();
		$base->{'actions'} = _jivePresetBase($base->{'actions'});

		if ( $party || $partyMode ) {
			$base->{'actions'}->{'play'} = $base->{'actions'}->{'go'};
		}

		# adapt actions to SS preference
		if (!$prefs->get('noGenreFilter') && defined $genreID) {
			$base->{'actions'}->{'go'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'play'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'add'}->{'params'}->{'genre_id'} = $genreID;
		}	

		if ( $useContextMenu ) {
			# + is more
			$base->{'actions'}{'more'} = _contextMenuBase('album');
		}
		if ( $search ) {
			$base->{'window'}->{'text'} = $request->string('SEARCHRESULTS');
		}

		$request->addResult('base', $base);
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	# now build the result
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = $menuMode?'item_loop':'albums_loop';
	my $chunkCount = 0;
	$request->addResult('offset', $request->getParam('_index')) if $menuMode;

	if ($valid) {


		# first PLAY ALL item
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname, includeArt => 1);
		}

		# We need to know the 'No album' name so that those items
		# which have been grouped together under it do not get the
		# album art of the first album.
		# It looks silly to go to Madonna->No album and see the
		# picture of '2 Unlimited'.
		my $noAlbumName = $request->string('NO_ALBUM');

		my $artist;
		for my $eachitem ($rs->slice($start, $end)) {
			
			my $textKey = '';

			#FIXME: see if multiple char textkey is doable for year/genre sort
			if ($sort && ($sort eq 'artflow' || $sort eq 'artistalbum') ) {
				$textKey = substr($eachitem->contributor->namesort, 0, 1);
			} elsif ($sort && $sort ne 'new') {
				$textKey = substr($eachitem->titlesort, 0, 1);
			}

			# Jive result formatting
			if ($menuMode) {
				
				# we want the text to be album\nartist
				$artist  = $eachitem->contributor->name;
				my $text = $eachitem->title;
				if (defined $artist) {
					$text = $text . "\n" . $artist;
				}

				my $favorites_title = $text;
				$favorites_title =~ s/\n/ - /g;

				$request->addResultLoop($loopname, $chunkCount, 'text', $text);
				
				my $id = $eachitem->id();
				$id += 0;

				# the favorites url to be sent to jive is the album title here
				# album id would be (much) better, but that would screw up the favorite on a rescan
				# title is a really stupid thing to use, since there's no assurance it's unique
				my $url = 'db:album.titlesearch=' . URI::Escape::uri_escape_utf8( Slim::Utils::Text::ignoreCaseArticles($eachitem->titlesearch) );

				my $params = {
					'album_id'        => $id,
					'favorites_url'   => $url,
					'favorites_title' => $favorites_title,
					'textkey'         => $textKey,
				};
				
				if (defined $contributorID) {
					$params->{artist_id} = $contributorID;
				}

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
				if ($party || $partyMode) {
					$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
				}

				# artwork if we have it
				if ($eachitem->title ne $noAlbumName &&
				    defined(my $iconId = $eachitem->artwork())) {
					$iconId += 0;
					$request->addResultLoop($loopname, $chunkCount, 'icon-id', $iconId);
				}

				_mixerItemParams(request => $request, obj => $eachitem, loopname => $loopname, chunkCount => $chunkCount, params => $params);
			}
			
			# "raw" result formatting (for CLI or JSON RPC)
			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $eachitem->id);
				$tags =~ /l/ && $request->addResultLoop($loopname, $chunkCount, 'album', $eachitem->title);
				$tags =~ /y/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'year', $eachitem->year);
				$tags =~ /j/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artwork_track_id', $eachitem->artwork);
				$tags =~ /t/ && $request->addResultLoop($loopname, $chunkCount, 'title', $eachitem->rawtitle);
				$tags =~ /i/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'disc', $eachitem->disc);
				$tags =~ /q/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'disccount', $eachitem->discc);
				$tags =~ /w/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'compilation', $eachitem->compilation);
				if ($tags =~ /a/) {
					my @artists = $eachitem->artists();
					if ( blessed( $artists[0] ) ) {
						$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artist', $artists[0]->name());
					}
				}
				$tags =~ /s/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'textkey', $textKey);
			}
			
			$chunkCount++;
			
			main::idleStreams() if !($chunkCount % 5);
		}

		if ($menuMode) {
			# Add Favorites as the last item, if applicable
			my $lastChunk;
			if ( $end == $count - 1 && $chunkCount < $request->getParam('_quantity') ) {
				$lastChunk = 1;
			}
			# add an "all songs" at the bottom (artist album lists only)
			if ($allSongs && $lastChunk && defined($contributorID)) {
				my $beforeCount = $chunkCount;
				$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname, includeArt => 1, allSongs => 1, artist => $artist );
				$totalCount++ if $beforeCount != $chunkCount;
			}
			if (!$useContextMenu) {
				($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => $lastChunk, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites, includeArt => 1);
			}
		}
	}
	elsif ($totalCount > 1 && $menuMode && !$useContextMenu) {
		($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => 1, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites, includeArt => 1);	
	}

	if ($totalCount == 0 && $menuMode) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}

	# Cache data as JSON to speed up the cloning of it later, this is faster
	# than using Storable
	if ( $to_cache && $menuMode ) {
		$cache->{albums}->[$party]->{$cacheKey} = to_json( $request->getResults() );
	} elsif ( $menuMode && $search && $totalCount > 0 && $start == 0 && !$request->getParam('cached_search') ) {
		my $jiveSearchCache = {
			text        => $request->string('ALBUMS') . ": " . $search,
			actions     => {
					go => {
						cmd => [ 'albums' ],
						params => {
							search => $request->getParam('search'),
							menu_all => 1,
							cached_search => 1,
							menu   => $request->getParam('menu'),
							_searchType => $request->getParam('_searchType'),
						},
					},
			},
			window      => { menuStyle => 'album' },
		};
		Slim::Control::Jive::cacheSearch($request, $jiveSearchCache);
	}
	
	$request->setStatusDone();
}

sub artistsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['artists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $year     = $request->getParam('year');
	my $genreID  = $request->getParam('genre_id');
	my $genreString  = $request->getParam('genre_string');
	my $trackID  = $request->getParam('track_id');
	my $albumID  = $request->getParam('album_id');
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	my $to_cache = $request->getParam('cache');
	my $party    = $request->getParam('party') || 0;
	my $tags     = $request->getParam('tags') || '';
	
	my %favorites;
	$favorites{'url'} = $request->getParam('favorites_url');
	$favorites{'title'} = $request->getParam('favorites_title');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $partyMode = _partyModeCheck($request);
	my $allAlbums = defined $genreID;
	my $useContextMenu = $request->getParam('useContextMenu');
	my $insertAll = $menuMode && defined $insert && !$partyMode && !$useContextMenu;
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'order_by' => 'me.namesort',
		'distinct' => 'me.id'
	};
	
	# same for the VA search
	my $where_va = {'me.compilation' => 1};
	my $attr_va = {};

	my $rs;
	my $cacheKey;

	# Manage joins 
	if (defined $trackID) {
		$where->{'contributorTracks.track'} = $trackID;
		push @{$attr->{'join'}}, 'contributorTracks';
		
		# don't use browse here as it filters VA...
		$rs = Slim::Schema->rs('Contributor')->search($where, $attr);
	}
	else {
		if (defined $genreID) {
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'contributorTracks' => {'track' => 'genreTracks'}};
			
			$where->{'contributorTracks.role'} = { 'in' => Slim::Schema->artistOnlyRoles };
			
			$where_va->{'genreTracks.genre'} = $genreID;
			push @{$attr_va->{'join'}}, {'tracks' => 'genreTracks'};
		}
		
		if (defined $albumID || defined $year) {
		
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
				
				$where_va->{'me.id'} = $albumID;
			}
			
			if (defined $year) {
				$where->{'track.year'} = $year;
				
				$where_va->{'track.year'} = $year;
			}
			
			if (!defined $genreID) {
				# don't need to add track again if we have a genre search
				push @{$attr->{'join'}}, {'contributorTracks' => 'track'};

				# same logic for VA search
				if (defined $year) {
					push @{$attr->{'join'}}, 'track';
				}
			}
		}
		
		# Flatten request for lookup in cache, only for Jive menu queries
		$cacheKey = complex_to_query($where) . complex_to_query($attr) . $menu . (defined $insert ? $insert : '');
		if ( $menuMode ) {
			if ( my $cached = $cache->{artists}->[$party]->{$cacheKey} ) {

				my $copy = from_json( $cached );

				# Don't slice past the end of the array
				if ( $copy->{count} < $index + $quantity ) {
					$quantity = $copy->{count} - $index;
				}

				# Slice the full album result according to start and end
				$copy->{item_loop} = [ @{ $copy->{item_loop} }[ $index .. ( $index + $quantity ) - 1 ] ];

				# Change offset value
				$copy->{offset} = $index;

				$request->setRawResults( $copy );
				$request->setStatusDone();

				return;
			}
		}
		
		# use browse here
		if ($search) {
			$rs = Slim::Schema->rs('Contributor')->searchNames(Slim::Utils::Text::searchStringSplit($search), $attr);
		}
		else {
			$rs = Slim::Schema->rs('Contributor')->browse( undef, $where )->search( {}, $attr );
		}
	}
	
	my $count = $rs->count;
	my $totalCount = $count || 0;

	# Various artist handling. Don't do if pref is off, or if we're
	# searching, or if we have a track
	my $count_va = 0;

	if ($prefs->get('variousArtistAutoIdentification') &&
		!defined $search && !defined $trackID) {

		# Only show VA item if there are any
		$count_va =  Slim::Schema->rs('Album')->search($where_va, $attr_va)->count;

		# fix the index and counts if we have to include VA
		$totalCount = _fixCount($count_va, \$index, \$quantity, $count);

		# don't add the VA item on subsequent queries
		$count_va = ($count_va && !$index);
	}

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to albums after artists, so we get menu:album
		# from the albums we'll go to tracks
		my $actioncmd = $menu . 's';
		my $nextMenu = 'track';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params'
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
					'nextWindow'  => 'nowPlaying',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params'
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params'
				},
			},
			# style correctly the window that opens for the action element
			'window' => {
				'menuStyle'  => 'album',
			},
		};
		$base->{'actions'}{'play-hold'} = _mixerBase();
		$base->{'actions'} = _jivePresetBase($base->{'actions'});
		if ($partyMode || $party) {
			$base->{'actions'}->{'play'} = $base->{'actions'}->{'go'};
		}
		if (!$prefs->get('noGenreFilter') && defined $genreID) {
			$base->{'actions'}->{'go'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'play'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'add'}->{'params'}->{'genre_id'} = $genreID;
		}
		if ( $useContextMenu ) {
			# + is more
			$base->{'actions'}->{'more'} = _contextMenuBase('artist');
		}
		if ( $search ) {
			$base->{'window'}->{'text'} = $request->string('SEARCHRESULTS');
		}
		$request->addResult('base', $base);
	}


	$totalCount = _fixCount($insertAll, \$index, \$quantity, $totalCount);

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = $menuMode?'item_loop':'artists_loop';
	my $chunkCount = 0;
	$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;

	if ($valid) {

		my @data = $rs->slice($start, $end);
			
		# Various artist handling. Don't do if pref is off, or if we're
		# searching, or if we have a track
		if ($count_va) {
			my $vaObj = Slim::Schema->variousArtistsObject;
			
			# bug 15328 - get the VA name in the language requested by the client
			#             but only do so if the user isn't using a custom name
			if ( $vaObj->name eq Slim::Utils::Strings::string('VARIOUSARTISTS') ) {
				
				# we can change the name as it will be updated anyway next them the VA object is requested
				$vaObj->name( $request->string('VARIOUSARTISTS') );
			}
			
			unshift @data, $vaObj;
		}

		# first PLAY ALL item
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}


		for my $obj (@data) {

			next if !$obj;
			my $id = $obj->id();
			$id += 0;
			
			my $textKey = substr($obj->namesort, 0, 1);
			# Bug 11070: Don't display large V at beginning of browse Artists
			if ($count_va && $chunkCount == 0) {
				$textKey = " ";
			}

			if ($menuMode){
				$request->addResultLoop($loopname, $chunkCount, 'text', $obj->name);

				# the favorites url to be sent to jive is the artist name here
				my $url = 'db:contributor.namesearch=' . URI::Escape::uri_escape_utf8( Slim::Utils::Text::ignoreCaseArticles($obj->name) );

				my $params = {
					'favorites_url'   => $url,
					'favorites_title' => $obj->name,
					'artist_id' => $id, 
					'textkey' => $textKey,
				};
				_mixerItemParams(request => $request, obj => $obj, loopname => $loopname, chunkCount => $chunkCount, params => $params);
				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
				if ($party || $partyMode) {
					$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
				}
			}
			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $id);
				$request->addResultLoop($loopname, $chunkCount, 'artist', $obj->name);
				$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
			}

			$chunkCount++;
			
			main::idleStreams() if !($chunkCount % 5);
		}
		
		if ($menuMode) {
			# Add Favorites as the last item, if applicable
			my $lastChunk = 0;
			if ( $end == $count - 1 && $chunkCount < $request->getParam('_quantity') ) {
				$lastChunk = 1;
			}

			if ($allAlbums) {
				($chunkCount, $totalCount) = _jiveGenreAllAlbums(start => $start, end => $end, lastChunk => $lastChunk, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, genreID => $genreID, genreString => $genreString );
			}

			if (!$useContextMenu) {
				($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => ($lastChunk == 1), listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, favorites => \%favorites);
			}
		}
	}
	elsif ($totalCount > 1 && $menuMode && $useContextMenu) {
		($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => 1, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, favorites => \%favorites);
	}

	if ($totalCount == 0 && $menuMode) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}
	
	# Cache data as JSON to speed up the cloning of it later, this is faster
	# than using Storable
	if ( $to_cache && $menuMode ) {
		$cache->{artists}->[$party]->{$cacheKey} = to_json( $request->getResults() );
	} elsif ( $menuMode && $search && $totalCount > 0 && $start == 0 && !$request->getParam('cached_search') ) {
		my $jiveSearchCache = {
			text        => $request->string('ARTISTS') . ": " . $search,
			actions     => {
					go => {
						cmd => [ 'artists' ],
						params => {
							search => $request->getParam('search'),
							menu   => $request->getParam('menu'),
							menu_all => 1,
							cached_search => 1,
							_searchType => $request->getParam('_searchType'),
						},
					},
			},
		};
		Slim::Control::Jive::cacheSearch($request, $jiveSearchCache);
	}
	$request->setStatusDone();
}


sub cursonginfoQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['duration', 'artist', 'album', 'title', 'genre',
			'path', 'remote', 'current_title']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $client = $request->client();

	# get the query
	my $method = $request->getRequest(0);
	my $url = Slim::Player::Playlist::url($client);
	
	if (defined $url) {

		if ($method eq 'path') {
			
			$request->addResult("_$method", $url);

		} elsif ($method eq 'remote') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::isRemoteURL($url));
			
		} elsif ($method eq 'current_title') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::getCurrentTitle($client, $url));

		} else {

			my $songData = _songData(
				$request,
				$url,
				'dalg',			# tags needed for our entities
			);
			
			if (defined $songData->{$method}) {
				$request->addResult("_$method", $songData->{$method});
			}

		}
	}

	$request->setStatusDone();
}


sub connectedQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['connected']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	$request->addResult('_connected', $client->connected() || 0);
	
	$request->setStatusDone();
}


sub debugQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['debug']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $category = $request->getParam('_debugflag');

	if ( !defined $category || !Slim::Utils::Log->isValidCategory($category) ) {

		$request->setStatusBadParams();
		return;
	}

	my $categories = Slim::Utils::Log->allCategories;
	
	if (defined $categories->{$category}) {
	
		$request->addResult('_value', $categories->{$category});
		
		$request->setStatusDone();

	} else {

		$request->setStatusBadParams();
	}
}


sub displayQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['display']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	my $parsed = $client->curLines();

	$request->addResult('_line1', $parsed->{line}[0] || '');
	$request->addResult('_line2', $parsed->{line}[1] || '');
		
	$request->setStatusDone();
}


sub displaynowQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['displaynow']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_line1', $client->prevline1());
	$request->addResult('_line2', $client->prevline2());
		
	$request->setStatusDone();
}


sub displaystatusQuery_filter {
	my $self = shift;
	my $request = shift;

	# we only listen to display messages
	return 0 if !$request->isCommand([['displaynotify']]);

	# retrieve the clientid, abort if not about us
	my $clientid   = $request->clientid() || return 0;
	my $myclientid = $self->clientid() || return 0; 
	return 0 if $clientid ne $myclientid;

	my $subs  = $self->getParam('subscribe');
	my $type  = $request->getParam('_type');
	my $parts = $request->getParam('_parts');

	# check displaynotify type against subscription ('showbriefly', 'update', 'bits', 'all')
	if ($subs eq $type || ($subs eq 'bits' && $type ne 'showbriefly') || $subs eq 'all') {

		my $pd = $self->privateData;

		# display forwarding is suppressed for this subscriber source
		return 0 if exists $parts->{ $pd->{'format'} } && !$parts->{ $pd->{'format'} };

		# don't send updates if there is no change
		return 0 if ($type eq 'update' && !$self->client->display->renderCache->{'screen1'}->{'changed'});

		# store display info in subscription request so it can be accessed by displaystatusQuery
		$pd->{'type'}  = $type;
		$pd->{'parts'} = $parts;

		# execute the query immediately
		$self->__autoexecute;
	}

	return 0;
}

sub displaystatusQuery {
	my $request = shift;
	
	main::DEBUGLOG && $log->debug("displaystatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['displaystatus']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $subs  = $request->getParam('subscribe');

	# return any previously stored display info from displaynotify
	if (my $pd = $request->privateData) {

		my $client= $request->client;
		my $format= $pd->{'format'};
		my $type  = $pd->{'type'};
		my $parts = $type eq 'showbriefly' ? $pd->{'parts'} : $client->display->renderCache;

		$request->addResult('type', $type);

		# return screen1 info if more than one screen
		$parts = $parts->{'screen1'} if $parts->{'screen1'};

		if ($subs eq 'bits' && $parts->{'bitsref'}) {
			
			# send the display bitmap if it exists (graphics display)
			use bytes;

			my $bits = ${$parts->{'bitsref'}};
			if ($parts->{'scroll'}) {
				$bits |= substr(${$parts->{'scrollbitsref'}}, 0, $parts->{'overlaystart'}[$parts->{'scrollline'}]);
			}

			$request->addResult('bits', MIME::Base64::encode_base64($bits) );
			$request->addResult('ext', $parts->{'extent'});

		} elsif ($format eq 'cli') {

			# format display for cli
			for my $c (keys %$parts) {
				next unless $c =~ /^(line|center|overlay)$/;
				for my $l (0..$#{$parts->{$c}}) {
					$request->addResult("$c$l", $parts->{$c}[$l]) if ($parts->{$c}[$l] ne '');
				}
			}

		} elsif ($format eq 'jive') {

			# send display to jive from one of the following components
			if (my $ref = $parts->{'jive'} && ref $parts->{'jive'}) {
				if ($ref eq 'CODE') {
					$request->addResult('display', $parts->{'jive'}->() );
				} elsif($ref eq 'ARRAY') {
					$request->addResult('display', { 'text' => $parts->{'jive'} });
				} else {
					$request->addResult('display', $parts->{'jive'} );
				}
			} else {
				$request->addResult('display', { 'text' => $parts->{'line'} || $parts->{'center'} });
			}
		}

	} elsif ($subs =~ /showbriefly|update|bits|all/) {
		# new subscription request - add subscription, assume cli or jive format for the moment
		$request->privateData({ 'format' => $request->source eq 'CLI' ? 'cli' : 'jive' }); 

		my $client = $request->client;

		main::DEBUGLOG && $log->debug("adding displaystatus subscription $subs");

		if ($subs eq 'bits') {

			if ($client->display->isa('Slim::Display::NoDisplay')) {
				# there is currently no display class, we need an emulated display to generate bits
				Slim::bootstrap::tryModuleLoad('Slim::Display::EmulatedSqueezebox2');
				if ($@) {
					$log->logBacktrace;
					logError("Couldn't load Slim::Display::EmulatedSqueezebox2: [$@]");

				} else {
					# swap to emulated display
					$client->display->forgetDisplay();
					$client->display( Slim::Display::EmulatedSqueezebox2->new($client) );
					$client->display->init;				
					# register ourselves for execution and a cleanup function to swap the display class back
					$request->registerAutoExecute(0, \&displaystatusQuery_filter, \&_displaystatusCleanupEmulated);
				}

			} elsif ($client->display->isa('Slim::Display::EmulatedSqueezebox2')) {
				# register ourselves for execution and a cleanup function to swap the display class back
				$request->registerAutoExecute(0, \&displaystatusQuery_filter, \&_displaystatusCleanupEmulated);

			} else {
				# register ourselves for execution and a cleanup function to clear width override when subscription ends
				$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
					$client->display->widthOverride(1, undef);
					if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
						main::INFOLOG && $log->info("last listener - suppressing display notify");
						$client->display->notifyLevel(0);
					}
					$client->update;
				});
			}

			# override width for new subscription
			$client->display->widthOverride(1, $request->getParam('width'));

		} else {
			$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
				if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
					main::INFOLOG && $log->info("last listener - suppressing display notify");
					$client->display->notifyLevel(0);
				}
			});
		}

		if ($subs eq 'showbriefly') {
			$client->display->notifyLevel(1);
		} else {
			$client->display->notifyLevel(2);
			$client->update;
		}
	}
	
	$request->setStatusDone();
}

# cleanup function to disable display emulation.  This is a named sub so that it can be suppressed when resubscribing.
sub _displaystatusCleanupEmulated {
	my $request = shift;
	my $client  = $request->client;

	if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
		main::INFOLOG && $log->info("last listener - swapping back to NoDisplay class");
		$client->display->forgetDisplay();
		$client->display( Slim::Display::NoDisplay->new($client) );
		$client->display->init;
	}
}


sub genresQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['genres']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}
	
	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $search        = $request->getParam('search');
	my $year          = $request->getParam('year');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $trackID       = $request->getParam('track_id');
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	my $to_cache      = $request->getParam('cache');
	my $party         = $request->getParam('party') || 0;
	my $tags          = $request->getParam('tags') || '';
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $partyMode = _partyModeCheck($request);
	my $useContextMenu = $request->getParam('useContextMenu');
	my $insertAll = $menuMode && defined $insert && !$partyMode && $useContextMenu;
		
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	# Normalize and add any search parameters
	if (specified($search)) {

		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
	}

	# Manage joins
	if (defined $trackID) {
			$where->{'genreTracks.track'} = $trackID;
			push @{$attr->{'join'}}, 'genreTracks';
	}
	else {
		# ignore those if we have a track. 
		
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$where->{'album.compilation'} = 1;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'album'}};
			}
			else {	
				$where->{'contributorTracks.contributor'} = $contributorID;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'contributorTracks'}};
			}
		}
	
		if (defined $albumID || defined $year){
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
			}
			if (defined $year) {
				$where->{'track.year'} = $year;
			}
			push @{$attr->{'join'}}, {'genreTracks' => 'track'};
		}
	}
	
	# Flatten request for lookup in cache, only for Jive menu queries
	my $cacheKey = complex_to_query($where) . complex_to_query($attr) . $menu . (defined $insert ? $insert : '');
	if ( $menuMode ) {
		if ( my $cached = $cache->{genres}->[$party]->{$cacheKey} ) {
			my $copy = from_json( $cached );

			# Don't slice past the end of the array
			if ( $copy->{count} < $index + $quantity ) {
				$quantity = $copy->{count} - $index;
			}

			# Slice the full album result according to start and end
			$copy->{item_loop} = [ @{ $copy->{item_loop} }[ $index .. ( $index + $quantity ) - 1 ] ];

			# Change offset value
			$copy->{offset} = $index;

			$request->setRawResults( $copy );
			$request->setStatusDone();

			return;
		}
	}

	my $rs = Slim::Schema->rs('Genre')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to artists after genres, so we get menu:artist
		# from the artists we'll go to albums
		my $actioncmd = $menu . 's';
		my $nextMenu = 'album';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
					'nextWindow'  => 'nowPlaying',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
		};
		$base->{'actions'}{'play-hold'} = _mixerBase();
		$base->{'actions'} = _jivePresetBase($base->{'actions'});
		if ($party || $partyMode) {
			$base->{'actions'}->{'play'} = $base->{'actions'}->{'go'};
		}
		if ($useContextMenu) {
			# + is more
			$base->{'actions'}{'more'} = _contextMenuBase('genre');
		}
		if ( $search ) {
			$base->{'window'}->{'text'} = $request->string('SEARCHRESULTS');
		}
		$request->addResult('base', $base);

	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'genres_loop';
		my $chunkCount = 0;
		$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;
		
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}
		for my $eachitem ($rs->slice($start, $end)) {
			
			my $id = $eachitem->id();
			$id += 0;
			
			my $textKey = substr($eachitem->namesort, 0, 1);
				
			if ($menuMode) {
				$request->addResultLoop($loopname, $chunkCount, 'text', $eachitem->name);
				
				# here the url is the genre name
				my $url = 'db:genre.namesearch=' . URI::Escape::uri_escape_utf8( Slim::Utils::Text::ignoreCaseArticles($eachitem->name) );
				my $params = {
					'genre_id'        => $id,
					'genre_string'    => $eachitem->name,
					'textkey'         => $textKey,
					'favorites_url'   => $url,
					'favorites_title' => $eachitem->name,
				};

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
				_mixerItemParams(request => $request, obj => $eachitem, loopname => $loopname, chunkCount => $chunkCount, params => $params);
				if ($party || $partyMode) {
					$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
				}
			}
			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $id);
				$request->addResultLoop($loopname, $chunkCount, 'genre', $eachitem->name);
				$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
			}
			$chunkCount++;
			
			main::idleStreams() if !($chunkCount % 5);
		}
	}

	if ($totalCount == 0 && $menuMode) {
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}
	
	# Cache data as JSON to speed up the cloning of it later, this is faster
	# than using Storable
	if ( $to_cache && $menuMode ) {
		$cache->{genres}->[$party]->{$cacheKey} = to_json( $request->getResults() );
	}

	$request->setStatusDone();
}


sub getStringQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['getstring']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $tokenlist = $request->getParam('_tokens');

	foreach my $token (split /,/, $tokenlist) {
		
		# check whether string exists or not, to prevent stack dumps if
		# client queries inexistent string
		if (Slim::Utils::Strings::stringExists($token)) {
			
			$request->addResult($token, $request->string($token));
		}
		
		else {
			
			$request->addResult($token, '');
		}
	}
	
	$request->setStatusDone();
}


sub infoTotalQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['info'], ['total'], ['genres', 'artists', 'albums', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}
	
	my $totals = Slim::Schema->totals;
	
	# get our parameters
	my $entity = $request->getRequest(2);

	if ($entity eq 'albums') {
		$request->addResult("_$entity", $totals->{album});
	}
	elsif ($entity eq 'artists') {
		$request->addResult("_$entity", $totals->{contributor});
	}
	elsif ($entity eq 'genres') {
		$request->addResult("_$entity", $totals->{genre});
	}
	elsif ($entity eq 'songs') {
		$request->addResult("_$entity", $totals->{track});
	}
	
	$request->setStatusDone();
}


sub irenableQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['irenable']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_irenable', $client->irenable());
	
	$request->setStatusDone();
}


sub linesperscreenQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['linesperscreen']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_linesperscreen', $client->linesPerScreen());
	
	$request->setStatusDone();
}


sub mixerQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);

	if ($entity eq 'muting') {
		$request->addResult("_$entity", $prefs->client($client)->get("mute"));
	}
	elsif ($entity eq 'volume') {
		$request->addResult("_$entity", $prefs->client($client)->get("volume"));
	} else {
		$request->addResult("_$entity", $client->$entity());
	}
	
	$request->setStatusDone();
}


sub modeQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['mode']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_mode', Slim::Player::Source::playmode($client));
	
	$request->setStatusDone();
}


sub musicfolderQuery {
	my $request = shift;
	
	main::INFOLOG && $log->info("musicfolderQuery()");

	# check this is the correct query.
	if ($request->isNotQuery([['musicfolder']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $folderId = $request->getParam('folder_id');
	my $url      = $request->getParam('url');
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	my $party    = $request->getParam('party') || 0;
	my $tags     = $request->getParam('tags') || '';
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $partyMode = _partyModeCheck($request);
	my $useContextMenu = $request->getParam('useContextMenu');
	my $insertAll = $menuMode && defined $insert && !$partyMode;
	
	# url overrides any folderId
	my $params = ();
	
	if (defined $url) {
		$params->{'url'} = $url;
	} else {
		# findAndScanDirectory sorts it out if $folderId is undef
		$params->{'id'} = $folderId;
	}
	
	# Pull the directory list, which will be used for looping.
	my ($topLevelObj, $items, $count);

	# if this is a follow up query ($index > 0), try to read from the cache
	if ($index > 0 && $cache->{bmf}->[$party]
		&& $cache->{bmf}->[$party]->{id} eq ($params->{url} || $params->{id}) 
		&& $cache->{bmf}->[$party]->{ttl} > time()) {
			
		$items       = $cache->{bmf}->[$party]->{items};
		$topLevelObj = $cache->{bmf}->[$party]->{topLevelObj};
		$count       = $cache->{bmf}->[$party]->{count};
	}
	else {
		
		($topLevelObj, $items, $count) = Slim::Utils::Misc::findAndScanDirectoryTree($params);
	}

	# create filtered data
	
	my $topPath = $topLevelObj->path;

	# now build the result

	my $playalbum;
	if ( $request->client ) {
		$playalbum = $prefs->client($request->client)->get('playtrackalbum');
	}

	# if player pref for playtrack album is not set, get the old server pref.
	if ( !defined $playalbum ) { 
		$playalbum = $prefs->get('playtrackalbum'); 
	}

	if ($menuMode) {

		# decide what is the next step down
		# assume we have a folder, for other types we will override in the item
		# we go to musicfolder from musicfolder :)

		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ["musicfolder"],
					'params' => {
						menu     => 'musicfolder',
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
					nextWindow => 'nowPlaying',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
		};

		if ($party || $partyMode) {
			$base->{'actions'}->{'play'} = $base->{'actions'}->{'go'};
		}

		if ($useContextMenu) {
			# + is more
			$base->{'actions'}{'more'} = _contextMenuBase('folder');
		}
		
		$request->addResult('base', $base);

		$request->addResult('window', { text => $topLevelObj->title } ) if $topLevelObj->title;
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname =  $menuMode ? 'item_loop' : 'folder_loop';
		my $chunkCount = 0;
		$request->addResult( 'offset', $index ) if $menuMode;
		
		my $listIndex = 0;

		for my $filename (@$items[$start..$end]) {

			my $url = Slim::Utils::Misc::fixPath($filename, $topPath) || next;
			my $realName;

			# Amazingly, this just works. :)
			# Do the cheap compare for osName first - so non-windows users
			# won't take the penalty for the lookup.
			if (main::ISWINDOWS && Slim::Music::Info::isWinShortcut($url)) {

				($realName, $url) = Slim::Utils::OS::Win32->getShortcut($url);
			}
			
			elsif (main::ISMAC) {
				if ( my $alias = Slim::Utils::Misc::pathFromMacAlias($url) ) {
					$url = $alias;
				}
			}
	
			my $item = Slim::Schema->objectForUrl({
				'url'      => $url,
				'create'   => 1,
				'readTags' => 1,
			});
	
			if (!blessed($item) || !$item->can('content_type')) {
	
				next;
			}

			my $id = $item->id();
			$id += 0;
			
			$filename = $realName || Slim::Music::Info::fileName($url);

			my $textKey = uc(substr($filename, 0, 1));
			
			if ($menuMode) {
				$request->addResultLoop($loopname, $chunkCount, 'text', $filename);

				my $params = {
					'textkey' => $textKey,
				};
				
				# each item is different, but most items are folders
				# the base assumes so above, we override it here

				# assumed case, folder
				if (Slim::Music::Info::isDir($item)) {

					$params->{'folder_id'} = $id;

					if ($partyMode || $party) {
						$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
					}
					# Bug 13855: there is no Slim::Menu::Folderinfo so no context menu is available here
				# song
				} elsif (Slim::Music::Info::isSong($item)) {
					
					my $actions = {
						'go' => {
							'cmd' => ['trackinfo', 'items'],
							'params' => {
								'menu' => 'nowhere',
								'track_id' => $id,
								isContextMenu => 1,
							},
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'track_id' => $id,
							},
							nextWindow => 'nowPlaying',
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
								'track_id' => $id,
							},
						},
						'add-hold' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'insert',
								'track_id' => $id,
							},
						},
					};
					
					if ( $playalbum && ! $partyMode ) {
						$actions->{'play'} = {
							player => 0,
							cmd    => ['jiveplaytrackalbum'],
							params => {
								list_index => $index + $listIndex,
								folder     => $topPath,
							},
							nextWindow => 'nowPlaying',
						};
					}
					if ($useContextMenu) {
						$actions->{'more'} = $actions->{'go'};
						$actions->{'go'} = $actions->{'play'};
						$request->addResultLoop($loopname, $chunkCount, 'style', 'itemplay');
					}
					$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);

					$listIndex++;

				# playlist
				} elsif (Slim::Music::Info::isPlaylist($item)) {
					
					my $actions = {
						'go' => {
							'cmd' => ['playlists', 'tracks'],
							'params' => {
								menu        => 'trackinfo',
								menu_all    => '1',
								playlist_id => $id,
							},
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'playlist_id' => $id,
							},
							nextWindow => 'nowPlaying',
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
								'playlist_id' => $id,
							},
						},
						'add-hold' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'insert',
								'playlist_id' => $id,
							},
						},
					};
					$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
					if ($partyMode || $party) {
						$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
					}
					if ($useContextMenu) {
						$actions->{'more'} = $actions->{'go'};
						$actions->{'go'} = $actions->{'play'};
						$request->addResultLoop($loopname, $chunkCount, 'style', 'itemplay');
					}
				# not sure
				} else {
					
					# don't know what that is, abort!
					my $actions = {
						'go' => {
							'cmd' => ["musicfolder"],
							'params' => {
								'menu' => 'musicfolder',
							},
							'itemsParams' => 'params',
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
							},
							'nextWindow' => 'nowPlaying',
							'itemsParams' => 'params',
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
							},
							'itemsParams' => 'params',
						},
						'add-hold' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'insert',
							},
							'itemsParams' => 'params',
						},
					};
					if ($partyMode || $party) {
						$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
					}
					$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
				}

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			}

			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $id);
				$request->addResultLoop($loopname, $chunkCount, 'filename', $filename);
			
				if (Slim::Music::Info::isDir($item)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'folder');
				} elsif (Slim::Music::Info::isPlaylist($item)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'playlist');
				} elsif (Slim::Music::Info::isSong($item)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'track');
				} elsif (-d Slim::Utils::Misc::pathFromMacAlias($url)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'folder');
				} else {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'unknown');
				}

				$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
			}
			$chunkCount++;
		}
	}

	if ($count == 0 && $menuMode) {
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $count);
	}

	# cache results in case the same folder is queried again shortly 
	# should speed up Jive BMF, as only the first chunk needs to run the full loop above
	$cache->{bmf}->[$party] = {
		id          => ($params->{url} || $params->{id}),
		ttl         => (time() + 15),
		items       => $items,
		topLevelObj => $topLevelObj,
		count       => $count,
	};

	# we might have changed - flush to the db to be in sync.
	$topLevelObj->update;
	
	$request->setStatusDone();
}


sub nameQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['name']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult("_value", $client->name());
	
	$request->setStatusDone();
}


sub playerXQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['player'], ['count', 'name', 'address', 'ip', 'id', 'model', 'displaytype', 'isplayer', 'canpoweroff', 'uuid']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity;
	$entity      = $request->getRequest(1);
	# if element 1 is 'player', that means next element is the entity
	$entity      = $request->getRequest(2) if $entity eq 'player';  
	my $clientparam = $request->getParam('_IDorIndex');
	
	if ($entity eq 'count') {
		$request->addResult("_$entity", Slim::Player::Client::clientCount());

	} else {	
		my $client;
		
		# were we passed an ID?
		if (defined $clientparam && Slim::Utils::Misc::validMacAddress($clientparam)) {

			$client = Slim::Player::Client::getClient($clientparam);

		} else {
		
			# otherwise, try for an index
			my @clients = Slim::Player::Client::clients();

			if (defined $clientparam && defined $clients[$clientparam]) {
				$client = $clients[$clientparam];
			}
		}

		# brute force attempt using eg. player's IP address (web clients)
		if (!defined $client) {
			$client = Slim::Player::Client::getClient($clientparam);
		}

		if (defined $client) {

			if ($entity eq "name") {
				$request->addResult("_$entity", $client->name());
			} elsif ($entity eq "address" || $entity eq "id") {
				$request->addResult("_$entity", $client->id());
			} elsif ($entity eq "ip") {
				$request->addResult("_$entity", $client->ipport());
			} elsif ($entity eq "model") {
				$request->addResult("_$entity", $client->model());
			} elsif ($entity eq "isplayer") {
				$request->addResult("_$entity", $client->isPlayer());
			} elsif ($entity eq "displaytype") {
				$request->addResult("_$entity", $client->vfdmodel());
			} elsif ($entity eq "canpoweroff") {
				$request->addResult("_$entity", $client->canPowerOff());
			} elsif ($entity eq "uuid") {
                                $request->addResult("_$entity", $client->uuid());
                        }
		}
	}
	
	$request->setStatusDone();
}

sub playersQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['players']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	
	my @prefs;
	
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		@prefs = split(/,/, $pref_list);
	}
	
	my $count = Slim::Player::Client::clientCount();
	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	$request->addResult('count', $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerindex', $idx);
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
                                $request->addResultLoop('players_loop', $cnt,
                                        'uuid', $eachclient->uuid());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model(1));
				$request->addResultLoop('players_loop', $cnt, 
					'isplayer', $eachclient->isPlayer());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'canpoweroff', $eachclient->canPowerOff());
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));

				for my $pref (@prefs) {
					if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$idx++;
				$cnt++;
			}	
		}
	}
	
	$request->setStatusDone();
}


sub playlistPlaylistsinfoQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['playlistsinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $playlistObj = $client->currentPlaylist();
	
	if (blessed($playlistObj)) {
		if ($playlistObj->can('id')) {
			$request->addResult("id", $playlistObj->id());
		}

		$request->addResult("name", $playlistObj->title());
				
		$request->addResult("modified", $client->currentPlaylistModified());

		$request->addResult("url", $playlistObj->url());
	}
	
	$request->setStatusDone();
}


sub playlistXQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['name', 'url', 'modified', 
			'tracks', 'duration', 'artist', 'album', 'title', 'genre', 'path', 
			'repeat', 'shuffle', 'index', 'jump', 'remote']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);
	my $index  = $request->getParam('_index');
		
	if ($entity eq 'repeat') {
		$request->addResult("_$entity", Slim::Player::Playlist::repeat($client));

	} elsif ($entity eq 'shuffle') {
		$request->addResult("_$entity", Slim::Player::Playlist::shuffle($client));

	} elsif ($entity eq 'index' || $entity eq 'jump') {
		$request->addResult("_$entity", Slim::Player::Source::playingSongIndex($client));

	} elsif ($entity eq 'name' && defined(my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("_$entity", Slim::Music::Info::standardTitle($client, $playlistObj));

	} elsif ($entity eq 'url') {
		my $result = $client->currentPlaylist();
		$request->addResult("_$entity", $result);

	} elsif ($entity eq 'modified') {
		$request->addResult("_$entity", $client->currentPlaylistModified());

	} elsif ($entity eq 'tracks') {
		$request->addResult("_$entity", Slim::Player::Playlist::count($client));

	} elsif ($entity eq 'path') {
		my $result = Slim::Player::Playlist::url($client, $index);
		$request->addResult("_$entity",  $result || 0);

	} elsif ($entity eq 'remote') {
		if (defined (my $url = Slim::Player::Playlist::url($client, $index))) {
			$request->addResult("_$entity", Slim::Music::Info::isRemoteURL($url));
		}
		
	} elsif ($entity =~ /(duration|artist|album|title|genre|name)/) {

		my $songData = _songData(
			$request,
			Slim::Player::Playlist::song($client, $index),
			'dalgN',			# tags needed for our entities
		);
		
		if (defined $songData->{$entity}) {
			$request->addResult("_$entity", $songData->{$entity});
		}
		elsif ($entity eq 'name' && defined $songData->{remote_title}) {
			$request->addResult("_$entity", $songData->{remote_title});
		}
	}
	
	$request->setStatusDone();
}


sub playlistsTracksQuery {
	my $request = shift;
	
	# check this is the correct query.
	# "playlisttracks" is deprecated (July 06).
	if ($request->isNotQuery([['playlisttracks']]) &&
		$request->isNotQuery([['playlists'], ['tracks']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $tags       = 'gald';
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $tagsprm    = $request->getParam('tags');
	my $playlistID = $request->getParam('playlist_id');

	if (!defined $playlistID) {
		$request->setStatusBadParams();
		return;
	}
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	my $useContextMenu = $request->getParam('useContextMenu');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert && !$useContextMenu;
		
	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	my $iterator;
	my @tracks;

	my $playlistObj = Slim::Schema->find('Playlist', $playlistID);

	if (blessed($playlistObj) && $playlistObj->can('tracks')) {
		$iterator = $playlistObj->tracks();
	}

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to songingo after playlists tracks, so we get menu:trackinfo
		# from the artists we'll go to albums

		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['trackinfo', 'items'],
					'params' => {
						'menu' => 'nowhere',
						'useContextMenu' => 1,
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['jiveplaytrackplaylist'],
					'params' => {
						'cmd' => 'load',
						'playlist_id' => $playlistID,
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
		};
		if ( $useContextMenu ) {
			# go is play
			$base->{'actions'}{'go'} = $base->{'actions'}{'play'};
			# + is more
			$base->{'actions'}{'more'} = _contextMenuBase('track');
		}
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $iterator) {

		my $count = $iterator->count();
		$count += 0;
		my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);
		
		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $totalCount);

		if ($valid || $start == $end) {


			my $format = $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];
			my $cur = $start;
			my $loopname = $menuMode?'item_loop':'playlisttracks_loop';
			my $chunkCount = 0;
			$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;
			
			if ( $insertAll && !$useContextMenu ) {
				$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
			}

			my $list_index = 0;
			for my $eachitem ($iterator->slice($start, $end)) {

				if ($menuMode) {
					
					my $text = Slim::Music::TitleFormatter::infoFormat($eachitem, $format, 'TITLE');
					$request->addResultLoop($loopname, $chunkCount, 'text', $text);
					$request->addResultLoop($loopname, $chunkCount, 'nextWindow', 'nowPlaying');
					my $id = $eachitem->id();
					$id += 0;
					my $params = {
						'track_id' =>  $id, 
						'list_index' => $list_index,
					};
					$list_index++;
					$request->addResultLoop($loopname, $chunkCount, 'params', $params);
					if ( $useContextMenu ) {
						$request->addResultLoop($loopname, $chunkCount, 'style', 'itemplay');
					}
				}
				else {
					_addSong($request, $loopname, $chunkCount, $eachitem, $tags, 
							"playlist index", $cur);
				}
				
				$cur++;
				$chunkCount++;
				
				main::idleStreams() if !($chunkCount % 5);
			}

			my $lastChunk;
			if ( $end == $totalCount - 1 && $chunkCount < $request->getParam('_quantity') || $start == $end) {
				$lastChunk = 1;
			}

			# add a favorites link below play/add links
			#Add another to result count
			my %favorites;
			$favorites{'title'} = $playlistObj->name;
			$favorites{'url'} = $playlistObj->url;

			if ($menuMode) {
				($chunkCount, $totalCount) = _jiveDeletePlaylist(start => $start, end => $end, lastChunk => $lastChunk, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, playlistURL => $playlistObj->url, playlistID => $playlistID, playlistTitle => $playlistObj->name );
				
				if ($valid) {
					($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => $lastChunk, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites);
				}
			}
			
		}
		$request->addResult("count", $totalCount);

	} else {

		$request->addResult("count", 0);
	}

	$request->setStatusDone();	
}


sub playlistsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $tags     = $request->getParam('tags') || '';
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	my $useContextMenu = $request->getParam('useContextMenu');

	# Normalize any search parameters
	if (defined $search) {
		$search = Slim::Utils::Text::searchStringSplit($search);
	}

	my $rs = Slim::Schema->rs('Playlist')->getPlaylists('all', $search);

	# now build the result
	my $count = $rs->count;
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to playlists tracks after playlists, so we get menu:track
		# from the tracks we'll go to trackinfo
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['playlists', 'tracks'],
					'params' => {
						menu     => 'trackinfo',
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
					'nextWindow'  => 'nowPlaying',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
		};
		$base->{'actions'}{'play-hold'} = _mixerBase();
		$base->{'actions'} = _jivePresetBase($base->{'actions'});

		if ($useContextMenu) {
			# context menu for 'more' action
			$base->{'actions'}{'more'} = _contextMenuBase('playlist');
		}
		if ( $search ) {
			$base->{'window'}->{'text'} = $request->string('SEARCHRESULTS');
		}
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $rs) {

		$count += 0;
		my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);
		
		my ($valid, $start, $end) = $request->normalize(
			scalar($index), scalar($quantity), $count);

		if ($valid) {
			
			my $loopname = $menuMode?'item_loop':'playlists_loop';
			my $chunkCount = 0;
			$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;

			if ($insertAll) {
				$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
			}

			for my $eachitem ($rs->slice($start, $end)) {

				my $id = $eachitem->id();
				$id += 0;
				
				my $textKey = substr($eachitem->namesort, 0, 1);

				if ($menuMode) {
					$request->addResultLoop($loopname, $chunkCount, 'text', $eachitem->title);
					my $params = {
						'playlist_id' =>  $id, 
						'textkey' => $textKey,
						'favorites_url'   => $eachitem->url,
						'favorites_title' => $eachitem->name,
					};

					_mixerItemParams(request => $request, obj => $eachitem, loopname => $loopname, chunkCount => $chunkCount, params => $params);
					$request->addResultLoop($loopname, $chunkCount, 'params', $params);
				} else {
					$request->addResultLoop($loopname, $chunkCount, "id", $id);
					$request->addResultLoop($loopname, $chunkCount, "playlist", $eachitem->title);
					$tags =~ /u/ && $request->addResultLoop($loopname, $chunkCount, "url", $eachitem->url);
					$tags =~ /s/ && $request->addResultLoop($loopname, $chunkCount, 'textkey', $textKey);
				}
				$chunkCount++;
				
				main::idleStreams() if !($chunkCount % 5);
			}
		}
		if ($totalCount == 0 && $menuMode) {
			_jiveNoResults($request);
		} else {
			$request->addResult("count", $totalCount);
		}

		if ( $menuMode && $search && $totalCount > 0 && $start == 0 && !$request->getParam('cached_search') ) {
			my $jiveSearchCache = {
				text        => $request->string('PLAYLISTS') . ": " . $search,
				actions     => {
						go => {
							cmd => [ 'playlists' ],
							params => {
								search => $request->getParam('search'),
								menu   => $request->getParam('menu'),
								menu_all => 1,
								cached_search => 1,
								_searchType => $request->getParam('_searchType'),
							},
						},
				},
			};
			Slim::Control::Jive::cacheSearch($request, $jiveSearchCache);
		}
	
	} else {
		$request->addResult("count", 0);
	}
	$request->setStatusDone();
}


sub powerQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['power']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_power', $client->power());
	
	$request->setStatusDone();
}


sub prefQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['pref']]) && $request->isNotQuery([['playerpref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $client;

	if ($request->isQuery([['playerpref']])) {
		
		$client = $request->client();
		
		unless ($client) {			
			$request->setStatusBadDispatch();
			return;
		}
	}

	# get the parameters
	my $prefName = $request->getParam('_prefname');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*?):(.+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', $client
		? preferences($namespace)->client($client)->get($prefName)
		: preferences($namespace)->get($prefName)
	);
	
	$request->setStatusDone();
}


sub prefValidateQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['pref'], ['validate']]) && $request->isNotQuery([['playerpref'], ['validate']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $client = $request->client();

	# get our parameters
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*?):(.+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace || !defined $newValue) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('valid', 
		($client
			? preferences($namespace)->client($client)->validate($prefName, $newValue)
			: preferences($namespace)->validate($prefName, $newValue)
		) 
		? 1 : 0
	);
	
	$request->setStatusDone();
}


sub readDirectoryQuery {
	my $request = shift;

	main::INFOLOG && $log->info("readDirectoryQuery");

	# check this is the correct query.
	if ($request->isNotQuery([['readdirectory']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $folder     = $request->getParam('folder');
	my $filter     = $request->getParam('filter');

	use File::Spec::Functions qw(catdir);
	my @fsitems;		# raw list of items 
	my %fsitems;		# meta data cache

	if (main::ISWINDOWS && $folder eq '/') {
		@fsitems = sort map {
			$fsitems{"$_"} = {
				d => 1,
				f => 0
			};
			"$_"; 
		} Slim::Utils::OS::Win32->getDrives();
		$folder = '';
	}
	else {
		$filter ||= '';

		my $filterRE = qr/./ unless ($filter eq 'musicfiles');

		# get file system items in $folder
		@fsitems = Slim::Utils::Misc::readDirectory(catdir($folder), $filterRE);
		map { 
			$fsitems{$_} = {
				d => -d catdir($folder, $_),
				f => -f _
			}
		} @fsitems;
	}

	if ($filter eq 'foldersonly') {
		@fsitems = grep { $fsitems{$_}->{d} } @fsitems;
	}

	elsif ($filter eq 'filesonly') {
		@fsitems = grep { $fsitems{$_}->{f} } @fsitems;
	}

	# return all folders plus files of type
	elsif ($filter =~ /^filetype:(.*)/) {
		my $filterRE = qr/(?:\.$1)$/i;
		@fsitems = grep { $fsitems{$_}->{d} || $_ =~ $filterRE } @fsitems;
	}

	# search anywhere within path/filename
	elsif ($filter && $filter !~ /^(?:filename|filetype):/) {
		@fsitems = grep { catdir($folder, $_) =~ /$filter/i } @fsitems;
	}

	my $count = @fsitems;
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;

		if (scalar(@fsitems)) {
			# sort folders < files
			@fsitems = sort { 
				if ($fsitems{$a}->{d}) {
					if ($fsitems{$b}->{d}) { uc($a) cmp uc($b) }
					else { -1 }
				}
				else {
					if ($fsitems{$b}->{d}) { 1 }
					else { uc($a) cmp uc($b) }
				}
			} @fsitems;

			my $path;
			for my $item (@fsitems[$start..$end]) {
				$path = ($folder ? catdir($folder, $item) : $item);

				my $name = $item;

				# display full name if we got a Windows 8.3 file name
				if (main::ISWINDOWS && $name =~ /~\d/) {
					$name = Slim::Music::Info::fileName($path);
				}

				$request->addResultLoop('fsitems_loop', $cnt, 'path', Slim::Utils::Unicode::utf8decode_locale($path));
				$request->addResultLoop('fsitems_loop', $cnt, 'name', Slim::Utils::Unicode::utf8decode_locale($name));
				
				$request->addResultLoop('fsitems_loop', $cnt, 'isfolder', $fsitems{$item}->{d});

				$idx++;
				$cnt++;
			}	
		}
	}

	$request->setStatusDone();	
}


sub rescanQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['rescan']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescan query

	$request->addResult('_rescan', Slim::Music::Import->stillScanning() ? 1 : 0);
	
	$request->setStatusDone();
}


sub rescanprogressQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['rescanprogress']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescanprogress query

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);

		# get progress from DB
		my $args = {
			'type' => 'importer',
		};

		my @progress = Slim::Schema->rs('Progress')->search( $args, { 'order_by' => 'start,id' } )->all;

		# calculate total elapsed time
		# and indicate % completion for all importers
		my $total_time = 0;
		my @steps;

		for my $p (@progress) {

			my $percComplete = $p->finish ? 100 : $p->total ? $p->done / $p->total * 100 : -1;
			$request->addResult($p->name(), int($percComplete));
			
			push @steps, $p->name();

			$total_time += ($p->finish || time()) - $p->start;
			
			if ($p->active && $p->info) {

				$request->addResult('info', $p->info);

			}
		}
		
		$request->addResult('steps', join(',', @steps)) if @steps;

		# report it
		my $hrs  = int($total_time / 3600);
		my $mins = int(($total_time - $hrs * 60)/60);
		my $sec  = $total_time - 3600 * $hrs - 60 * $mins;
		$request->addResult('totaltime', sprintf("%02d:%02d:%02d", $hrs, $mins, $sec));
	
	# if we're not scanning, just say so...
	} else {
		$request->addResult('rescan', 0);

		if (Slim::Schema::hasLibrary()) {
			# inform if the scan has failed
			if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'name' => 'failure' })->first) {
				_scanFailed($request, $p->info);
			}
		}
	}

	$request->setStatusDone();
}


sub searchQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['search']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $query    = $request->getParam('term');

	# transliterate umlauts and accented characters
	# http://bugs.slimdevices.com/show_bug.cgi?id=8585
	$query = Slim::Utils::Text::matchCase($query);

	if (!defined $query || $query eq '') {
		$request->setStatusBadParams();
		return;
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);
	}

	my $totalCount = 0;
	my $search     = Slim::Utils::Text::searchStringSplit($query);
	my %results    = ();
	my @types      = Slim::Schema->searchTypes;

	# Ugh - we need two loops here, as "count" needs to come first.
	
	if (Slim::Schema::hasLibrary()) {
		for my $type (@types) {

			my $rs      = Slim::Schema->rs($type)->searchNames($search);
			my $count   = $rs->count || 0;
	
			$results{$type}->{'rs'}    = $rs;
			$results{$type}->{'count'} = $count;
	
			$totalCount += $count;
			
			main::idleStreams();
		}
	}

	$totalCount += 0;
	$request->addResult('count', $totalCount);

	if (Slim::Schema::hasLibrary()) {
		for my $type (@types) {
	
			my $count = $results{$type}->{'count'};
	
			$count += 0;
	
			my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	
			if ($valid) {
				$request->addResult("${type}s_count", $count);
		
				my $loopName  = "${type}s_loop";
				my $loopCount = 0;
		
				for my $result ($results{$type}->{'rs'}->slice($start, $end)) {
		
					# add result to loop
					$request->addResultLoop($loopName, $loopCount, "${type}_id", $result->id);
					$request->addResultLoop($loopName, $loopCount, $type, $result->name);
		
					$loopCount++;
					
					main::idleStreams() if !($loopCount % 5);
				}
			}
		}
	}
	
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the serverstatus
# query must be re-executed.
sub serverstatusQuery_filter {
	my $self = shift;
	my $request = shift;
	
	# we want to know about clients going away as soon as possible
	if ($request->isCommand([['client'], ['forget']]) || $request->isCommand([['connect']])) {
		return 1;
	}
	
	# we want to know about rescan and all client notifs, as well as power on/off
	# FIXME: wipecache and rescan are synonyms...
	if ($request->isCommand([['wipecache', 'rescan', 'client', 'power']])) {
		return 1.3;
	}
	
	# FIXME: prefset???
	# we want to know about any pref in our array
	if (defined(my $prefsPtr = $self->privateData()->{'server'})) {
		if ($request->isCommand([['pref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if (defined(my $prefsPtr = $self->privateData()->{'player'})) {
		if ($request->isCommand([['playerpref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if ($request->isCommand([['name']])) {
		return 1.3;
	}
	
	return 0;
}


sub serverstatusQuery {
	my $request = shift;
	
	main::INFOLOG && $log->debug("serverstatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['serverstatus']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	if (Slim::Schema::hasLibrary()) {
		if (Slim::Music::Import->stillScanning()) {
			$request->addResult('rescan', "1");
			if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'active' => 1 })->first) {
	
				$request->addResult('progressname', $request->string($p->name."_PROGRESS"));
				$request->addResult('progressdone', $p->done);
				$request->addResult('progresstotal', $p->total);
			}
		}
	
		elsif (my @p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer' }, { 'order_by' => 'start,id' })->all) {
			
			$request->addResult('lastscan', $p[-1]->finish);
			
			if ($p[-1]->name eq 'failure') {
				_scanFailed($request, $p[-1]->info);
			}
		}
	}
	
	# add version
	$request->addResult('version', $::VERSION);

	# add server_uuid
	$request->addResult('uuid', $prefs->get('server_uuid'));

	if (Slim::Schema::hasLibrary()) {
		# add totals
		my $totals = Slim::Schema->totals;
		
		$request->addResult("info total albums", $totals->{album});
		$request->addResult("info total artists", $totals->{contributor});
		$request->addResult("info total genres", $totals->{genre});
		$request->addResult("info total songs", $totals->{track});
	}

	my %savePrefs;
	if (defined(my $pref_list = $request->getParam('prefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'server'} = \@prefs;
	
		for my $pref (@{$savePrefs{'server'}}) {
			if (defined(my $value = $prefs->get($pref))) {
				$request->addResult($pref, $value);
			}
		}
	}
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'player'} = \@prefs;
		
	}


	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');

	my $count = Slim::Player::Client::clientCount();
	$count += 0;

	$request->addResult('player count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
				$request->addResultLoop('players_loop', $cnt,
					'uuid', $eachclient->uuid());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				if (defined $eachclient->sequenceNumber()) {
					$request->addResultLoop('players_loop', $cnt,
						'seq_no', $eachclient->sequenceNumber());
				}
				$request->addResultLoop('players_loop', $cnt,
					'model', $eachclient->model(1));
				$request->addResultLoop('players_loop', $cnt, 
					'power', $eachclient->power());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'canpoweroff', $eachclient->canPowerOff());
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));
				$request->addResultLoop('players_loop', $cnt, 
					'isplayer', ($eachclient->isPlayer() || 0));
				$request->addResultLoop('players_loop', $cnt, 
					'player_needs_upgrade', "1")
					if ($eachclient->needsUpgrade());
				$request->addResultLoop('players_loop', $cnt,
					'player_is_upgrading', "1")
					if ($eachclient->isUpgrading());

				for my $pref (@{$savePrefs{'player'}}) {
					if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$cnt++;
			}
		}

	}

	# return list of players connected to SN
	my @sn_players = Slim::Networking::SqueezeNetwork::Players->get_players();

	$count = scalar @sn_players || 0;

	$request->addResult('sn player count', $count);

	($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $sn_cnt = 0;
			
		for my $player ( @sn_players ) {
			$request->addResultLoop(
				'sn_players_loop', $sn_cnt, 'id', $player->{id}
			);
			
			$request->addResultLoop( 
				'sn_players_loop', $sn_cnt, 'name', $player->{name}
			);
			
			$request->addResultLoop(
				'sn_players_loop', $sn_cnt, 'playerid', $player->{mac}
			);
			
			$request->addResultLoop(
				'sn_players_loop', $sn_cnt, 'model', $player->{model}
			);
				
			$sn_cnt++;
		}
	}

	# return list of players connected to other servers
	my $other_players = Slim::Networking::Discovery::Players::getPlayerList();

	$count = scalar keys %{$other_players} || 0;

	$request->addResult('other player count', $count);

	($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $other_cnt = 0;
			
		for my $player ( keys %{$other_players} ) {
			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'playerid', $player
			);

			$request->addResultLoop( 
				'other_players_loop', $other_cnt, 'name', $other_players->{$player}->{name}
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'model', $other_players->{$player}->{model}
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'server', $other_players->{$player}->{server}
			);

			$request->addResultLoop(
				'other_players_loop', $other_cnt, 'serverurl', 
					Slim::Networking::Discovery::Server::getWebHostAddress($other_players->{$player}->{server})
			);

			$other_cnt++;
		}
	}
	
	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
	
		# store the prefs array as private data so our filter above can find it back
		$request->privateData(\%savePrefs);
		
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&serverstatusQuery_filter);
	}
	
	$request->setStatusDone();
}


sub signalstrengthQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['signalstrength']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_signalstrength', $client->signalStrength() || 0);
	
	$request->setStatusDone();
}


sub sleepQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['sleep']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $isValue = $client->sleepTime() - Time::HiRes::time();
	if ($isValue < 0) {
		$isValue = 0;
	}
	
	$request->addResult('_sleep', $isValue);
	
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the status
# query must be re-executed.
sub statusQuery_filter {
	my $self = shift;
	my $request = shift;
	
	# retrieve the clientid, abort if not about us
	my $clientid   = $request->clientid() || return 0;
	my $myclientid = $self->clientid() || return 0;
	
	# Bug 10064: playlist notifications get sent to everyone in the sync-group
	if ($request->isCommand([['playlist', 'newmetadata']]) && (my $client = $request->client)) {
		return 0 if !grep($_->id eq $myclientid, $client->syncGroupActiveMembers());
	} else {
		return 0 if $clientid ne $myclientid;
	}
	
	# ignore most prefset commands, but e.g. alarmSnoozeSeconds needs to generate a playerstatus update
	if ( $request->isCommand( [ ['prefset'] ] ) ) {
		my $prefname = $request->getParam('_prefname');
		if ( defined($prefname) && $prefname eq 'alarmSnoozeSeconds' ) {
			# this needs to pass through the filter
		}
		else {
			return 0;
		}
	}

	# commands we ignore
	return 0 if $request->isCommand([['ir', 'button', 'debug', 'pref', 'display', 'playerpref']]);

	# special case: the client is gone!
	if ($request->isCommand([['client'], ['forget']])) {
		
		# pretend we do not need a client, otherwise execute() fails
		# and validate() deletes the client info!
		$self->needClient(0);
		
		# we'll unsubscribe above if there is no client
		return 1;
	}

	# suppress frequent updates during volume changes
	if ($request->isCommand([['mixer'], ['volume']])) {

		return 3;
	}

	# give it a tad more time for muting to leave room for the fade to finish
	# see bug 5255
	if ($request->isCommand([['mixer'], ['muting']])) {

		return 1.4;
	}

	# give it more time for stop as this is often followed by a new play
	# command (for example, with track skip), and the new status may be delayed
	if ($request->isCommand([['playlist'],['stop']])) {
		return 2.0;
	}

	# This is quite likely about to be followed by a 'playlist newsong' so
	# we only want to generate this if the newsong is delayed, as can be
	# the case with remote tracks.
	# Note that the 1.5s here and the 1s from 'playlist stop' above could
	# accumulate in the worst case.
	if ($request->isCommand([['playlist'], ['open', 'jump']])) {
		return 2.5;
	}

	# send every other notif with a small delay to accomodate
	# bursts of commands
	return 1.3;
}


sub statusQuery {
	my $request = shift;
	
	main::DEBUGLOG && $log->debug("statusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['status']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the initial parameters
	my $client = $request->client();
	my $menu = $request->getParam('menu');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $useContextMenu = $request->getParam('useContextMenu');

	# accomodate the fact we can be called automatically when the client is gone
	if (!defined($client)) {
		$request->addResult('error', "invalid player");
		$request->registerAutoExecute('-');
		$request->setStatusDone();
		return;
	}
	
	my $connected    = $client->connected() || 0;
	my $power        = $client->power();
	my $ip           = $client->ipport();
	my $repeat       = Slim::Player::Playlist::repeat($client);
	my $shuffle      = Slim::Player::Playlist::shuffle($client);
	my $songCount    = Slim::Player::Playlist::count($client);
	my $playlistMode = Slim::Player::Playlist::playlistMode($client);

	my $idx = 0;


	# now add the data...

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
	}

	if ($client->needsUpgrade()) {
		$request->addResult('player_needs_upgrade', "1");
	}
	
	if ($client->isUpgrading()) {
		$request->addResult('player_is_upgrading', "1");
	}
	
	# add player info...
	$request->addResult("player_name", $client->name());
	$request->addResult("player_connected", $connected);
	$request->addResult("player_ip", $ip);

	# add showBriefly info
	if ($client->display->renderCache->{showBriefly}
		&& $client->display->renderCache->{showBriefly}->{line}
		&& $client->display->renderCache->{showBriefly}->{ttl} > time()) {
		$request->addResult('showBriefly', $client->display->renderCache->{showBriefly}->{line});
	}

	if ($client->isPlayer()) {
		$power += 0;
		$request->addResult("power", $power);
	}
	
	if ($client->isa('Slim::Player::Squeezebox')) {
		$request->addResult("signalstrength", ($client->signalStrength() || 0));
	}
	
	my $playlist_cur_index;
	
	$request->addResult('mode', Slim::Player::Source::playmode($client));
	if ($client->isPlaying() && !$client->isPlaying('really')) {
		$request->addResult('waitingToPlay', 1);	
	}

	if (my $song = $client->playingSong()) {

		if ($song->isRemote()) {
			$request->addResult('remote', 1);
			$request->addResult('current_title', 
				Slim::Music::Info::getCurrentTitle($client, $song->currentTrack()->url));
		}
			
		$request->addResult('time', 
			Slim::Player::Source::songTime($client));

		# This is just here for backward compatibility with older SBC firmware
		$request->addResult('rate', 1);
			
		if (my $dur = $song->duration()) {
			$dur += 0;
			$request->addResult('duration', $dur);
		}
			
		my $canSeek = Slim::Music::Info::canSeek($client, $song);
		if ($canSeek) {
			$request->addResult('can_seek', 1);
		}
	}
		
	if ($client->currentSleepTime()) {

		my $sleep = $client->sleepTime() - Time::HiRes::time();
		$request->addResult('sleep', $client->currentSleepTime() * 60);
		$request->addResult('will_sleep_in', ($sleep < 0 ? 0 : $sleep));
	}
		
	if ($client->isSynced()) {

		my $master = $client->master();

		$request->addResult('sync_master', $master->id());

		my @slaves = Slim::Player::Sync::slaves($master);
		my @sync_slaves = map { $_->id } @slaves;

		$request->addResult('sync_slaves', join(",", @sync_slaves));
	}
	
	if ($client->hasVolumeControl()) {
		# undefined for remote streams
		my $vol = $prefs->client($client)->get('volume');
		$vol += 0;
		$request->addResult("mixer volume", $vol);
	}
		
	if ($client->model() =~ /^(?:squeezebox|slimp3)$/) {
		$request->addResult("mixer treble", $client->treble());
		$request->addResult("mixer bass", $client->bass());
	}

	if ($client->model() eq 'squeezebox') {
		$request->addResult("mixer pitch", $client->pitch());
	}

	$repeat += 0;
	$request->addResult("playlist repeat", $repeat);
	$shuffle += 0;
	$request->addResult("playlist shuffle", $shuffle); 

	$request->addResult("playlist mode", $playlistMode);

	if (defined $client->sequenceNumber()) {
		$request->addResult("seq_no", $client->sequenceNumber());
	}

	if (defined (my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("playlist_id", $playlistObj->id());
		$request->addResult("playlist_name", $playlistObj->title());
		$request->addResult("playlist_modified", $client->currentPlaylistModified());
	}

	if ($songCount > 0) {
		$playlist_cur_index = Slim::Player::Source::playingSongIndex($client);
		$request->addResult(
			"playlist_cur_index", 
			$playlist_cur_index
		);
		$request->addResult("playlist_timestamp", $client->currentPlaylistUpdateTime())
	}

	$request->addResult("playlist_tracks", $songCount);
	
	# give a count in menu mode no matter what
	if ($menuMode) {
		# send information about the alarm state to SP
		my $alarmNext    = Slim::Utils::Alarm->alarmInNextDay($client);
		my $alarmComing  = $alarmNext ? 'set' : 'none';
		my $alarmCurrent = Slim::Utils::Alarm->getCurrentAlarm($client);
		# alarm_state
		# 'active': means alarm currently going off
		# 'set':    alarm set to go off in next 24h on this player
		# 'none':   alarm set to go off in next 24h on this player
		# 'snooze': alarm is active but currently snoozing
		if (defined($alarmCurrent)) {
			my $snoozing     = $alarmCurrent->snoozeActive();
			if ($snoozing) {
				$request->addResult('alarm_state', 'snooze');
				$request->addResult('alarm_next', 0);
			} else {
				$request->addResult('alarm_state', 'active');
				$request->addResult('alarm_next', 0);
			}
		} else {
			$request->addResult('alarm_state', $alarmComing);
			$request->addResult('alarm_next', defined $alarmNext ? $alarmNext + 0 : 0);
		}

		# send client pref for alarm snooze
		my $alarm_snooze_seconds = $prefs->client($client)->get('alarmSnoozeSeconds');
		$request->addResult('alarm_snooze_seconds', defined $alarm_snooze_seconds ? $alarm_snooze_seconds + 0 : 540);

		# send client pref for alarm timeout
		my $alarm_timeout_seconds = $prefs->client($client)->get('alarmTimeoutSeconds');
		$request->addResult('alarm_timeout_seconds', defined $alarm_timeout_seconds ? $alarm_timeout_seconds + 0 : 300);

		# send which presets are defined
		my $presets = $prefs->client($client)->get('presets');
		my $presetLoop;
		for my $i (0..9) {
			if (defined $presets->[$i] ) {
				$presetLoop->[$i] = 1;
			} else {
				$presetLoop->[$i] = 0;
			}
		}
		$request->addResult('preset_loop', $presetLoop);

		main::DEBUGLOG && $log->debug("statusQuery(): setup base for jive");
		$songCount += 0;
		# add two for playlist save/clear to the count if the playlist is non-empty
		my $menuCount = $songCount?$songCount+2:0;
			
		if ( main::SLIM_SERVICE ) {
			# Bug 7437, No Playlist Save on SN
			$menuCount--;
		}
		
		$request->addResult("count", $menuCount);
		
		my $base;
		if ( $useContextMenu ) {
			# context menu for 'more' action
			$base->{'actions'}{'more'} = _contextMenuBase('track');
			# this is the current playlist, so tell SC the context of this menu
			$base->{'actions'}{'more'}{'params'}{'context'} = 'playlist';
		} else {
			$base = {
				actions => {
					go => {
						cmd => ['trackinfo', 'items'],
						params => {
							menu => 'nowhere', 
							useContextMenu => 1,
							context => 'playlist',
						},
						itemsParams => 'params',
					},
				},
			};
		}
		$request->addResult('base', $base);
	}
	
	if ($songCount > 0) {
	
		main::DEBUGLOG && $log->debug("statusQuery(): setup non-zero player response");
		# get the other parameters
		my $tags     = $request->getParam('tags');
		my $index    = $request->getParam('_index');
		my $quantity = $request->getParam('_quantity');
	
		$tags = 'gald' if !defined $tags;
		my $loop = $menuMode ? 'item_loop' : 'playlist_loop';

		# we can return playlist data.
		# which mode are we in?
		my $modecurrent = 0;

		if (defined($index) && ($index eq "-")) {
			$modecurrent = 1;
		}
		
		# bug 9132: rating might have changed
		# we need to be sure we have the latest data from the DB if ratings are requested
		my $refreshTrack = $tags =~ /R/;
		
		my $track = Slim::Player::Playlist::song($client, $playlist_cur_index, $refreshTrack);

		if ($track->remote) {
			$tags .= "B"; # include button remapping
			my $metadata = _songData($request, $track, $tags);
			$request->addResult('remoteMeta', $metadata);
		}

		# if repeat is 1 (song) and modecurrent, then show the current song
		if ($modecurrent && ($repeat == 1) && $quantity) {

			$request->addResult('offset', $playlist_cur_index) if $menuMode;

			if ($menuMode) {
				_addJiveSong($request, $loop, 0, 1, $track);
			}
			else {
				_addSong($request, $loop, 0, 
					$track, $tags,
					'playlist index', $playlist_cur_index
				);
			}
			
		} else {

			my ($valid, $start, $end);
			
			if ($modecurrent) {
				($valid, $start, $end) = $request->normalize($playlist_cur_index, scalar($quantity), $songCount);
			} else {
				($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $songCount);
			}

			if ($valid) {
				my $count = 0;
				$start += 0;
				$request->addResult('offset', $request->getParam('_index')) if $menuMode;
				
				for ($idx = $start; $idx <= $end; $idx++) {
					
					my $track = Slim::Player::Playlist::song($client, $idx, $refreshTrack);
					my $current = ($idx == $playlist_cur_index);

					if ($menuMode) {
						_addJiveSong($request, $loop, $count, $current, $track);
						# add clear and save playlist items at the bottom
						if ( ($idx+1)  == $songCount) {
							_addJivePlaylistControls($request, $loop, $count);
						}
					}
					else {
						_addSong(	$request, $loop, $count, 
									$track, $tags,
									'playlist index', $idx
								);
					}

					$count++;
					
					# give peace a chance...
					main::idleStreams() if !($count % 5);
				}
				
				#we don't do that in menu mode!
				if (!$menuMode) {
				
					my $repShuffle = $prefs->get('reshuffleOnRepeat');
					my $canPredictFuture = ($repeat == 2)  			# we're repeating all
											&& 						# and
											(	($shuffle == 0)		# either we're not shuffling
												||					# or
												(!$repShuffle));	# we don't reshuffle
				
					if ($modecurrent && $canPredictFuture && ($count < scalar($quantity))) {

						# wrap around the playlist...
						($valid, $start, $end) = $request->normalize(0, (scalar($quantity) - $count), $songCount);		

						if ($valid) {

							for ($idx = $start; $idx <= $end; $idx++){

								_addSong($request, $loop, $count, 
									Slim::Player::Playlist::song($client, $idx, $refreshTrack), $tags,
									'playlist index', $idx
								);

								$count++;
								main::idleStreams() if !($count % 5);
							}
						}
					}

				}
			}
		}
	}


	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
		main::DEBUGLOG && $log->debug("statusQuery(): setting up subscription");
	
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&statusQuery_filter);
	}
	
	$request->setStatusDone();
}

sub songinfoQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['songinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags  = 'abcdefghijJklmnopqrstvwxyzBCDEFHIJKLMNOQRTUVWXYZ'; # all letter EXCEPT u, A & S, G & P
	my $track;

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $url	     = $request->getParam('url');
	my $trackID  = $request->getParam('track_id');
	my $tagsprm  = $request->getParam('tags');
	
	if (!defined $trackID && !defined $url) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	# find the track
	if (defined $trackID){

		$track = Slim::Schema->find('Track', $trackID);

	} else {

		if ( defined $url ){

			$track = Slim::Schema->objectForUrl($url);
		}
	}
	
	# now build the result
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (blessed($track) && $track->can('id')) {

		my $trackId = $track->id();
		$trackId += 0;

		my $hashRef = _songData($request, $track, $tags);
		my $count = scalar (keys %{$hashRef});

		$count += 0;

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		my $loopname = 'songinfo_loop';
		my $chunkCount = 0;

		if ($valid) {

			# this is where we construct the nowplaying menu
			my $idx = 0;
	
			while (my ($key, $val) = each %{$hashRef}) {
				if ($idx >= $start && $idx <= $end) {
	
					$request->addResultLoop($loopname, $chunkCount, $key, $val);
	
					$chunkCount++;					
				}
				$idx++;
			}
		}
	}

	$request->setStatusDone();
}


sub syncQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['sync']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	if ($client->isSynced()) {
	
		my @sync_buddies = map { $_->id() } $client->syncedWith();

		$request->addResult('_sync', join(",", @sync_buddies));
	} else {
	
		$request->addResult('_sync', '-');
	}
	
	$request->setStatusDone();
}


sub syncGroupsQuery {
	my $request = shift;

	# check this is the correct query
	if ($request->isNotQuery([['syncgroups']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	
	my $cnt      = 0;
	my @players  = Slim::Player::Client::clients();
	my $loopname = 'syncgroups_loop'; 

	if (scalar(@players) > 0) {

		for my $eachclient (@players) {
			
			# create a group if $eachclient is a master
			if ($eachclient->isSynced() && Slim::Player::Sync::isMaster($eachclient)) {
				my @sync_buddies = map { $_->id() } $eachclient->syncedWith();
				my @sync_names   = map { $_->name() } $eachclient->syncedWith();
		
				$request->addResultLoop($loopname, $cnt, 'sync_members', join(",", $eachclient->id, @sync_buddies));				
				$request->addResultLoop($loopname, $cnt, 'sync_member_names', join(",", $eachclient->name, @sync_names));				
				
				$cnt++;
			}
		}
	}
	
	$request->setStatusDone();
}


sub timeQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['time', 'gototime']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_time', Slim::Player::Source::songTime($client));
	
	$request->setStatusDone();
}

# this query is to provide a list of tracks for a given artist/album etc.

sub titlesQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['titles', 'tracks', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# Bug 6889, exclude remote tracks from these queries
	my $where  = { 'me.remote' => { '!=' => 1 } };
	my $attr   = {};

	my $tags   = 'gald';

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tagsprm       = $request->getParam('tags');
	my $sort          = $request->getParam('sort');
	my $search        = $request->getParam('search');
	my $genreID       = $request->getParam('genre_id');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $year          = $request->getParam('year');
	my $menuStyle     = $request->getParam('menuStyle') || 'item';

	my $useContextMenu = $request->getParam('useContextMenu');

	my %favorites;
	$favorites{'url'} = $request->getParam('favorites_url');
	$favorites{'title'} = $request->getParam('favorites_title');
	
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $partyMode = _partyModeCheck($request);
	my $insertAll = $menuMode && defined $insert && !$partyMode;

	if ($request->paramNotOneOfIfDefined($sort, ['title', 'tracknum'])) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	# note that this is not equivalent to 
	# $val = $param || $default;
	# since when $default eq '' -> $val eq $param
	$tags = $tagsprm if defined $tagsprm;

	# Normalize any search parameters
	if (specified($search)) {
		$where->{'me.titlesearch'} = {'like' => Slim::Utils::Text::searchStringSplit($search)};
	}

	if (defined $albumID){
		$where->{'me.album'} = $albumID;
	}

	if (defined $year) {
		$where->{'me.year'} = $year;
	}

	# we don't want client playlists (Now playing), transporter sources,
	# directories, or playlists.
	$where->{'me.content_type'} = [ -and => {'!=', 'cpl'},  {'!=', 'src'},  {'!=', 'ssp'}, {'!=', 'dir'} ];

	# Manage joins
	if (defined $genreID) {

		$where->{'genreTracks.genre'} = $genreID;

		push @{$attr->{'join'}}, 'genreTracks';
#		$attr->{'distinct'} = 1;
	}

	if (defined $contributorID) {
	
		# handle the case where we're asked for the VA id => return compilations
		if ($contributorID == Slim::Schema->variousArtistsObject->id) {
			$where->{'album.compilation'} = 1;
			push @{$attr->{'join'}}, 'album';
		}
		else {	
			$where->{'contributorTracks.contributor'} = $contributorID;
			push @{$attr->{'join'}}, 'contributorTracks';
		}
	}

	if ($sort && $sort eq "tracknum") {

		if (!($tags =~ /t/)) {
			$tags = $tags . "t";
		}

		my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();
		
		$attr->{'order_by'} =  "me.disc, me.tracknum, " . $sqlHelperClass->prepend0('me.titlesort');
	}
	else {
		$attr->{'order_by'} =  "me.titlesort";
	}

	my $rs = Slim::Schema->rs('Track')->search($where, $attr)->distinct;

	my $count = $rs->count;

	my $playalbum;
	if ( $request->client ) {
		$playalbum = $prefs->client($request->client)->get('playtrackalbum');
	}

	# if player pref for playtrack album is not set, get the old server pref.
	if ( !defined $playalbum ) { 
		$playalbum = $prefs->get('playtrackalbum'); 
	}

	# now build the result
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to songinfo after albums, so we get menu:track
		# from songinfo we go nowhere...
		my $nextMenu = 'nowhere';
		
		# build the base element
		my $base = {
			actions => {
				go => {
					cmd => [ 'trackinfo', 'items', ],
						params => {
							menu => $nextMenu,
							useContextMenu => 1,
						},
					itemsParams => 'params',
				},
				more => {
					cmd => [ 'trackinfo', 'items', ],
						params => {
							menu => $nextMenu,
							useContextMenu => 1,
						},
					itemsParams => 'params',
				},
				play => {
					player => 0,
					cmd => ['playlistcontrol'],
					params => {
						cmd => 'load',
					},
					itemsParams => 'params',
					nextWindow => 'nowPlaying',
				},
				add => {
					player => 0,
					cmd => ['playlistcontrol'],
					params => {
						cmd => 'add',
					},
					itemsParams => 'params',
				},
				'add-hold' => {
					player => 0,
					cmd => ['playlistcontrol'],
					params => {
						cmd => 'insert',
					},
					itemsParams => 'params',
				},
			},
		};
		$base->{'actions'}{'play-hold'} = _mixerBase();
		$base->{'actions'} = _jivePresetBase($base->{'actions'});
		
		# Bug 5981
		# special play handler for "play all tracks in album
		# ignore this setting when in party mode
		if ( $playalbum && $albumID && ! $partyMode ) {
			$base->{'actions'}{'play'} = {
				player => 0,
				cmd    => ['jiveplaytrackalbum'],
				itemsParams => 'params',
				nextWindow => 'nowPlaying',
			};
		}

		if ( $useContextMenu ) {
			# go is play
			$base->{'actions'}{'go'} = $base->{'actions'}{'play'};
			# + is more
			$base->{'actions'}{'more'} = _contextMenuBase('track');
		}
		if ( $search ) {
			$base->{'window'}->{'text'} = $request->string('SEARCHRESULTS');
		}


		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult("rescan", 1);
	}

	$count += 0;

	# we only change the count if we're going to insert the play all item
	my $addPlayAllItem = $search && $insertAll;

	my $totalCount = _fixCount($addPlayAllItem, \$index, \$quantity, $count);
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = $menuMode?'item_loop':'titles_loop';
	# this is the count of items in this part of the request (e.g., menu 100 200)
	# not to be confused with $count, which is the count of the entire list
	my $chunkCount = 0;
	$request->addResult('offset', $request->getParam('_index')) if $menuMode;

	if ($valid) {
		
		my $format = $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];

		# PLAY ALL item for search results
		if ( $addPlayAllItem ) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname, includeArt => ( $menuStyle eq 'album' ) );
		}

		my $listIndex = 0;

		for my $item ($rs->slice($start, $end)) {


			# jive formatting
			if ($menuMode) {
				
				my $id = $item->id();
				$id += 0;
				my $params = {
					track_id      =>  $id, 
				};
				if ( $playalbum && $albumID ) {
					$params->{'album_id'}   = $albumID;
					$params->{'list_index'} = $listIndex;
					if ($contributorID) {
						$params->{'artist_id'}   = $contributorID;
					}
				}
				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			
				if ($useContextMenu) {
					$request->addResultLoop($loopname, $chunkCount, 'style', 'itemplay');
				}
			
				# open a window with icon etc...
			

				my $text = $item->title;
				my $album;
				my $albumObj = $item->album();
				
				# Bug 7443, check for a track cover before using the album cover
				my $iconId = $item->coverArtExists ? $id : 0;
				
				if(defined($albumObj)) {
					$album = $albumObj->title();
					$iconId ||= $albumObj->artwork();
				}
				
				my $oneLineTrackTitle = Slim::Music::TitleFormatter::infoFormat($item, $format, 'TITLE');
				my $window = {
					'text' => $oneLineTrackTitle,
				};
				if ($menuStyle eq 'album') {
					if ($useContextMenu) {
						# press to play
						$request->addResultLoop($loopname, $chunkCount, 'style', 'itemplay');
					}

					# format second line as 'artist - album'
					my @secondLine = ();
					if (defined(my $artistName = $item->artistName())) {
						push @secondLine, $artistName;
					}
					if (defined($album)) {
						push @secondLine, $album;
					}
					my $secondLine = join(' - ', @secondLine);
					$text = $text . "\n" . $secondLine;
					$request->addResultLoop($loopname, $chunkCount, 'text', $text);

				} elsif ($menuStyle eq 'allSongs') {
					$request->addResultLoop($loopname, $chunkCount, 'text', $item->title);
				} else {
					$request->addResultLoop($loopname, $chunkCount, 'text', $oneLineTrackTitle);
				}
			
				if (defined($iconId)) {
					$window->{'icon-id'} = $iconId;
					# show icon if we're doing press-to-play behavior
					if ($menuStyle eq 'album' && $useContextMenu) {
						$request->addResultLoop($loopname, $chunkCount, 'icon-id', $iconId);
					}
				}

				$request->addResultLoop($loopname, $chunkCount, 'window', $window);
				 _mixerItemParams(request => $request, obj => $item, loopname => $loopname, chunkCount => $chunkCount, params => $params);
			
			}
			
			# regular formatting
			else {
				_addSong($request, $loopname, $chunkCount, $item, $tags);
			}
			
			$chunkCount++;
			$listIndex++;
			
			# give peace a chance...
			main::idleStreams() if !($chunkCount % 5);
		}

	}

	if ($totalCount == 0 && $menuMode) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}

	if ( $menuMode && $search && $count > 0 && $start == 0 && !$request->getParam('cached_search') ) {
		my $jiveSearchCache = {
			text        => $request->string('SONGS') . ": " . $search,
			actions     => {
					go => {
						cmd => [ 'tracks' ],
						params => {
							search => $request->getParam('search'),
							menu   => $request->getParam('menu'),
							menu_all => 1,
							cached_search => 1,
							_searchType => $request->getParam('_searchType'),
						},
					},
			},
			window       => { menuStyle => 'album' },
		};
		Slim::Control::Jive::cacheSearch($request, $jiveSearchCache);
	}
	
	$request->setStatusDone();
}


sub versionQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the version query

	$request->addResult('_version', $::VERSION);
	
	$request->setStatusDone();
}


sub yearsQuery {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['years']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!Slim::Schema::hasLibrary()) {
		$request->setStatusNotDispatchable();
		return;
	}
	
	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');	
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	my $party         = $request->getParam('party') || 0;
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $partyMode = _partyModeCheck($request);
	my $useContextMenu = $request->getParam('useContextMenu');
	my $insertAll = $menuMode && defined $insert && !$partyMode;
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	my $rs = Slim::Schema->rs('Year')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to albums after years, so we get menu:album
		# from the albums we'll go to tracks
		my $actioncmd = $menu . 's';
		my $nextMenu = 'track';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
					'nextWindow'  => 'nowPlaying',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				menuStyle   => 'album',
			}
		};
		# sort by artist, year, album when sending the albums query
		if ($actioncmd eq 'albums') {
			$base->{'actions'}{'go'}{'params'}{'sort'} = 'artistalbum';
		}
		if ($party || $partyMode) {
			$base->{'actions'}->{'play'} = $base->{'actions'}->{'go'};
		}
		$base->{'actions'}{'play-hold'} = _mixerBase();
		$base->{'actions'} = _jivePresetBase($base->{'actions'});
		if ($useContextMenu) {
			# + is more
			$base->{'actions'}{'more'} = _contextMenuBase('year');
		}
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'years_loop';
		my $chunkCount = 0;
		$request->addResult('offset', $request->getParam('_index')) if $menuMode;

		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}

		for my $eachitem ($rs->slice($start, $end)) {


			my $id = $eachitem->id();
			$id += 0;

			my $url = $eachitem->id() ? 'db:year.id=' . $eachitem->id() : 0;

			if ($menuMode) {
				$request->addResultLoop($loopname, $chunkCount, 'text', $eachitem->name);

				my $params = {
					'year'            => $id,
					# bug 6781: can't add a year to favorites
					'favorites_url'   => $url,
					'favorites_title' => $id,
				};

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
				_mixerItemParams(request => $request, obj => $eachitem, loopname => $loopname, chunkCount => $chunkCount, params => $params);
				if ($party || $partyMode) {
					$request->addResultLoop($loopname, $chunkCount, 'playAction', 'go');
				}
			}
			else {
				$request->addResultLoop($loopname, $chunkCount, 'year', $id);
			}
			$chunkCount++;
			
			main::idleStreams() if !($chunkCount % 5);
		}
	}

	if ($totalCount == 0 && $menuMode) {
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}

	$request->setStatusDone();
}

################################################################################
# Special queries
################################################################################

=head2 dynamicAutoQuery( $request, $query, $funcptr, $data )

 This function is a helper function for any query that needs to poll enabled
 plugins. In particular, this is used to implement the CLI radios query,
 that returns all enabled radios plugins. This function is best understood
 by looking as well in the code used in the plugins.
 
 Each plugins does in initPlugin (edited for clarity):
 
    $funcptr = addDispatch(['radios'], [0, 1, 1, \&cli_radiosQuery]);
 
 For the first plugin, $funcptr will be undef. For all the subsequent ones
 $funcptr will point to the preceding plugin cli_radiosQuery() function.
 
 The cli_radiosQuery function looks like:
 
    sub cli_radiosQuery {
      my $request = shift;
      
      my $data = {
         #...
      };
 
      dynamicAutoQuery($request, 'radios', $funcptr, $data);
    }
 
 The plugin only defines a hash with its own data and calls dynamicAutoQuery.
 
 dynamicAutoQuery will call each plugin function recursively and add the
 data to the request results. It checks $funcptr for undefined to know if
 more plugins are to be called or not.
 
=cut

sub dynamicAutoQuery {
	my $request = shift;                       # the request we're handling
	my $query   = shift || return;             # query name
	my $funcptr = shift;                       # data returned by addDispatch
	my $data    = shift || return;             # data to add to results

	# check this is the correct query.
	if ($request->isNotQuery([[$query]])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity') || 0;
	my $sort     = $request->getParam('sort');
	my $menu     = $request->getParam('menu');

	my $menuMode = defined $menu;

	# we have multiple times the same resultset, so we need a loop, named
	# after the query name (this is never printed, it's just used to distinguish
	# loops in the same request results.
	my $loop = $menuMode?'item_loop':$query . 's_loop';

	# if the caller asked for results in the query ("radios 0 0" returns 
	# immediately)
	if ($quantity) {

		# add the data to the results
		my $cnt = $request->getResultLoopCount($loop) || 0;
		
		if ( ref $data eq 'HASH' && scalar keys %{$data} ) {
			$data->{weight} = $data->{weight} || 1000;
			$request->setResultLoopHash($loop, $cnt, $data);
		}
		
		# more to jump to?
		# note we carefully check $funcptr is not a lemon
		if (defined $funcptr && ref($funcptr) eq 'CODE') {
			
			eval { &{$funcptr}($request) };
	
			# arrange for some useful logging if we fail
			if ($@) {

				logError("While trying to run function coderef: [$@]");
				$request->setStatusBadDispatch();
				$request->dump('Request');
				
				if ( main::SLIM_SERVICE ) {
					my $name = Slim::Utils::PerlRunTime::realNameForCodeRef($funcptr);
					$@ =~ s/"/'/g;
					SDI::Util::Syslog::error("service=SS-Queries method=${name} error=\"$@\"");
				}
			}
		}
		
		# $funcptr is undefined, we have everybody, now slice & count
		else {
			
			# sort if requested to do so
			if ($sort) {
				$request->sortResultLoop($loop, $sort);
			}
			
			# slice as needed
			my $count = $request->getResultLoopCount($loop);
			$request->sliceResultLoop($loop, $index, $quantity);
			$request->addResult('offset', $request->getParam('_index')) if $menuMode;
			$count += 0;
			$request->setResultFirst('count', $count);
			
			# don't forget to call that to trigger notifications, if any
			$request->setStatusDone();
		}
	}
	else {
		$request->setStatusDone();
	}
}

################################################################################
# Helper functions
################################################################################

sub _addSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $index     = shift; # loop index
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $prefixKey = shift; # prefix key, if any
	my $prefixVal = shift; # prefix value, if any   

	# get the hash with the data	
	my $hashRef = _songData($request, $pathOrObj, $tags);
	
	# add the prefix in the first position, use a fancy feature of
	# Tie::LLHash
	if (defined $prefixKey) {
		(tied %{$hashRef})->Unshift($prefixKey => $prefixVal);
	}
	
	# add it directly to the result loop
	$request->setResultLoopHash($loop, $index, $hashRef);
}

sub _addJivePlaylistControls {

	my ($request, $loop, $count) = @_;
	
	my $client = $request->client || return;
	
	# clear playlist
	my $text = $client->string('CLEAR_PLAYLIST');
	# add clear playlist and save playlist menu items
	$count++;
	my @clear_playlist = (
		{
			text    => $client->string('CANCEL'),
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jiveblankcommand' ],
				},
			},
			nextWindow => 'parent',
		},
		{
			text    => $client->string('CLEAR_PLAYLIST'),
			actions => {
				do => {
					player => 0,
					cmd    => ['playlist', 'clear'],
				},
			},
			nextWindow => 'home',
		},
	);
	
	my $clearicon = main::SLIM_SERVICE
		? Slim::Networking::SqueezeNetwork->url('/static/images/icons/playlistclear.png', 'external')
		: '/html/images/playlistclear.png';

	$request->addResultLoop($loop, $count, 'text', $text);
	$request->addResultLoop($loop, $count, 'icon-id', $clearicon);
	$request->addResultLoop($loop, $count, 'offset', 0);
	$request->addResultLoop($loop, $count, 'count', 2);
	$request->addResultLoop($loop, $count, 'item_loop', \@clear_playlist);
	
	if ( main::SLIM_SERVICE ) {
		# Bug 7110, move images
		use Slim::Networking::SqueezeNetwork;
		$request->addResultLoop( $loop, $count, 'icon', Slim::Networking::SqueezeNetwork->url('/static/jive/images/blank.png', 1) );
	}

	# save playlist
	my $input = {
		len          => 1,
		allowedChars => $client->string('JIVE_ALLOWEDCHARS_WITHCAPS'),
		help         => {
			text => $client->string('JIVE_SAVEPLAYLIST_HELP'),
		},
	};
	my $actions = {
		do => {
			player => 0,
			cmd    => ['playlist', 'save'],
			params => {
				playlistName => '__INPUT__',
			},
			itemsParams => 'params',
		},
	};
	$count++;

	# Bug 7437, don't display Save Playlist on SN
	if ( !main::SLIM_SERVICE ) {
		$text = $client->string('SAVE_PLAYLIST');
		$request->addResultLoop($loop, $count, 'text', $text);
		$request->addResultLoop($loop, $count, 'icon-id', '/html/images/playlistsave.png');
		$request->addResultLoop($loop, $count, 'input', $input);
		$request->addResultLoop($loop, $count, 'actions', $actions);
	}
}

# **********************************************************************
# *** This is performance-critical method ***
# Take cake to understand the performance implications of any changes.

sub _addJiveSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $count     = shift; # loop index
	my $current   = shift;
	my $track     = shift || return;
	
	my $songData  = _songData(
		$request,
		$track,
		$current ?'AalKNJ' : 'alKNJ',			# tags needed for our entities
	);
	
	$request->addResultLoop($loop, $count, 'trackType', $track->remote ? 'radio' : 'local');
	
	my $text   = $songData->{title};
	my $title  = $text;
	my $album  = $songData->{album};
	my $artist = $songData->{artist};
	
	# Bug 15779: we cannot afford to get multiple contributor roles for each track
	# in the playlist so restrict this information to just for the current track.
	# (even getting it just for the current track is pretty expensive)
	if ($current) {
		my (%artists, @artists);
		foreach ('albumartist', 'trackartist', 'artist') {
			foreach my $a ( $songData->{"arrayRef_$_"} ? @{$songData->{"arrayRef_$_"}} : $songData->{$_} ) {
				if ( $a && !$artists{$a} ) {
					push @artists, $a;
					$artists{$a} = 1;
				}
			}
		}
		$artist = join(', ', @artists);
	}
	
	if ( $track->remote && $text && $album && $artist ) {
		$request->addResult('current_title');
	}

	my @secondLine;
	if (defined $artist) {
		push @secondLine, $artist;
	}
	if (defined $album) {
		push @secondLine, $album;
	}

	# Special case for Internet Radio streams, if the track is remote, has no duration,
	# has title metadata, and has no album metadata, display the station title as line 1 of the text
	if ( $songData->{remote_title} && $songData->{remote_title} ne $title && !$album && $track->remote && !$track->secs ) {
		push @secondLine, $songData->{remote_title};
		$album = $songData->{remote_title};
		$request->addResult('current_title');
	}

	my $secondLine = join(' - ', @secondLine);
	$text .= "\n" . $secondLine;

	# Bug 7443, check for a track cover before using the album cover
	my $iconId = $songData->{artwork_track_id};
	
	if ( !defined $iconId && (my $albumObj = $track->album()) ) {
		$iconId ||= $albumObj->artwork();
	}
	
	if ( defined $iconId ) {
		$iconId += 0;
		$request->addResultLoop($loop, $count, 'icon-id', $iconId);
	}
	elsif ( defined($songData->{artwork_url}) ) {
		$request->addResultLoop( $loop, $count, 'icon', $songData->{artwork_url} );
	# send radio placeholder art for remote tracks with no art
	} 
	elsif ( $track->remote ) {
		my $radioicon = main::SLIM_SERVICE
			? Slim::Networking::SqueezeNetwork->url('/static/images/icons/radio.png', 'external')
			: '/html/images/radio.png';

		$request->addResultLoop($loop, $count, 'icon-id', $radioicon);
	}

	# split to three discrete elements for NP screen
	if ( defined($title) ) {
		$request->addResultLoop($loop, $count, 'track', $title);
	} else {
		$request->addResultLoop($loop, $count, 'track', '');
	}
	if ( defined($album) ) {
		$request->addResultLoop($loop, $count, 'album', $album);
	} else {
		$request->addResultLoop($loop, $count, 'album', '');
	}
	if ( defined($artist) ) {
		$request->addResultLoop($loop, $count, 'artist', $artist);
	} else {
		$request->addResultLoop($loop, $count, 'artist', '');
	}
	# deliver as one formatted multi-line string for NP playlist screen
	$request->addResultLoop($loop, $count, 'text', $text);

	if ( ! $track->remote ) {
		my $actions;
		$actions->{'play-hold'} = _mixerItemHandler(obj => $track, request => $request, chunkCount => $count, 'obj_param' => 'track_id', loopname => $loop );
		$request->addResultLoop( $loop, $count, 'actions', $actions );
	}

	my $id = $track->id();
	$id += 0;
	my $params = {
		'track_id' => $id, 
		'playlist_index' => $count,
	};
	$request->addResultLoop($loop, $count, 'params', $params);
	$request->addResultLoop($loop, $count, 'style', 'itemplay');
}


sub _jiveNoResults {
	my $request = shift;
	my $search = $request->getParam('search');
	$request->addResult('count', '1');
	$request->addResult('offset', 0);

	if (defined($search)) {
		$request->addResultLoop('item_loop', 0, 'text', $request->string('NO_SEARCH_RESULTS'));
	} else {
		$request->addResultLoop('item_loop', 0, 'text', $request->string('EMPTY'));
	}

	$request->addResultLoop('item_loop', 0, 'style', 'itemNoAction');
	$request->addResultLoop('item_loop', 0, 'action', 'none');
}


# sets base callbacks for presets 0-9
sub _jivePresetBase {
	my $actions = shift;
	for my $preset (0..9) {
		my $key = 'set-preset-' . $preset;
		$actions->{$key} = {
			player => 0,
			cmd    => [ 'jivefavorites', 'set_preset', "key:$preset" ],
			itemsParams => 'params',
		};
	}
	return $actions;
}

sub _jiveAddToFavorites {

	my %args       = @_;
	my $chunkCount = $args{'chunkCount'};
	my $listCount  = $args{'listCount'};
	my $loopname   = $args{'loopname'};
	my $request    = $args{'request'};
	my $favorites  = $args{'favorites'};
	my $start      = $args{'start'};
	my $lastChunk  = $args{'lastChunk'};
	my $includeArt = $args{'includeArt'};


	return ($chunkCount, $listCount) unless $loopname && $favorites;
	
	# Do nothing unless Favorites are enabled
	if ( !Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Favorites::Plugin') ) {
		return ($chunkCount, $listCount);
	}

	# we need %favorites populated or else we don't want this item
	if (!$favorites->{'title'} || !$favorites->{'url'}) {
		return ($chunkCount, $listCount);
	}
	
	# We'll add a Favorites item to this request.
	# We always bump listCount to indicate this request list will contain one more item at the end
	$listCount++;

	# Add the actual favorites item if we're in the last chunk
	if ( $lastChunk ) {
		my $action = 'add';
		my $token = 'JIVE_SAVE_TO_FAVORITES';
		# first we check to see if the URL exists in favorites already
		my $client = $request->client();
		my $favIndex = undef;
		if ( blessed($client) ) {
			my $favs = Slim::Utils::Favorites->new($client);
			$favIndex = $favs->findUrl($favorites->{'url'});
			if (defined($favIndex)) {
				$action = 'delete';
				$token = 'JIVE_DELETE_FROM_FAVORITES';
			}
		}

		$request->addResultLoop($loopname, $chunkCount, 'text', $request->string($token));
		my $actions = {
			'go' => {
				player => 0,
				cmd    => [ 'jivefavorites', $action ],
				params => {
						title   => $favorites->{'title'},
						url     => $favorites->{'url'},
				},
			},
		};
		$actions->{'go'}{'params'}{'item_id'} = $favIndex if defined($favIndex);

		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);

		if ($includeArt) {
			my $favicon = main::SLIM_SERVICE
				? Slim::Networking::SqueezeNetwork->url('/static/images/icons/favorites.png', 'external')
				: '/html/images/favorites.png';
				
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', $favicon);
		} else {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'item');
		}
	
		$chunkCount++;
	}

	return ($chunkCount, $listCount);
}

sub _jiveDeletePlaylist {

	my %args          = @_;
	my $chunkCount    = $args{'chunkCount'};
	my $listCount     = $args{'listCount'};
	my $loopname      = $args{'loopname'};
	my $request       = $args{'request'};
	my $start         = $args{'start'};
	my $end           = $args{'end'};
	my $lastChunk     = $args{'lastChunk'};
	my $playlistURL   = $args{'playlistURL'};
	my $playlistTitle = $args{'playlistTitle'};
	my $playlistID    = $args{'playlistID'};

	return ($chunkCount, $listCount) unless $loopname && $playlistURL;
	
	# Bug 10646, need to support deleting an empty playlist
	#return ($chunkCount, $listCount) if $start == 0 && $end == 0;

	# We always bump listCount to indicate this request list will contain one more item at the end
	$listCount++;

	# Add the actual favorites item if we're in the last chunk
	if ( $lastChunk ) {
		my $token = 'JIVE_DELETE_PLAYLIST';

		###
		# FIXME: bug 8670. This is the 7.1 workaround to deal with the %s in the EN string
		my $string = $request->string($token, $playlistTitle);
		$string =~ s/\\n/ /g;
		$request->addResultLoop($loopname, $chunkCount, 'text', $string);
		### 

		my $actions = {
			'go' => {
				player => 0,
				cmd    => [ 'jiveplaylists', 'delete' ],
				params => {
						url	        => $playlistURL,
						playlist_id     => $playlistID,
						title           => $playlistTitle,
						menu		=> 'track',
						menu_all	=> 1,
				},
			},
		};

		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$request->addResultLoop($loopname, $chunkCount, 'style', 'item');
		$chunkCount++;
	}

	return ($chunkCount, $listCount);
}

sub _jiveGenreAllAlbums {

	my %args       = @_;
	my $chunkCount = $args{'chunkCount'};
	my $listCount  = $args{'listCount'};
	my $loopname   = $args{'loopname'};
	my $request    = $args{'request'};
	my $start      = $args{'start'};
	my $end        = $args{'end'};
	my $lastChunk  = $args{'lastChunk'};
	my $genreID    = $args{'genreID'};
	my $genreString    = $args{'genreString'};
	my $includeArt = $args{'includeArt'};

	return ($chunkCount, $listCount) unless $loopname && $genreID;
	return ($chunkCount, $listCount) if $start == 0 && $end == 0;
	
	# We always bump listCount to indicate this request list will contain one more item at the end
	$listCount++;

	# Add the actual favorites item if we're in the last chunk
	if ( $lastChunk ) {
		my $token = 'ALL_ALBUMS';
		$request->addResultLoop($loopname, $chunkCount, 'text', $request->string($token));
		my $actions = {
			'go' => {
				player => 0,
				cmd    => [ 'albums' ],
				params => {
						genre_id	=> $genreID,
						menu		=> 'track',
						menu_all	=> 1,
				},
			},
		};

		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$request->addResultLoop($loopname, $chunkCount, 'window', { text => "$genreString" });

		if ($includeArt) {
			my $playallicon = main::SLIM_SERVICE
				? Slim::Networking::SqueezeNetwork->url('/static/images/icons/playall.png', 'external')
				: '/html/images/playall.png';
				
			$request->addResultLoop($loopname, $chunkCount, 'style', 'itemplay');
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', $playallicon);
		} else {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'item');
		}
	
		$chunkCount++;
	}

	return ($chunkCount, $listCount);
}

sub _songData {
	my $request   = shift; # current request object
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use


	# figure out the track object
	my $track     = Slim::Schema->objectForUrl($pathOrObj);

	if (!blessed($track) || !$track->can('id')) {

		logError("Called with invalid object or path: $pathOrObj!");
		
		# For some reason, $pathOrObj may be an id... try that before giving up...
		if ($pathOrObj =~ /^\d+$/) {
			$track = Slim::Schema->find('Track', $pathOrObj);
		}

		if (!blessed($track) || !$track->can('id')) {

			logError("Can't make track from: $pathOrObj!");
			return;
		}
	}
	
	# If we have a remote track, check if a plugin can provide metadata
	my $remoteMeta = {};
	if ( $track->remote ) {
		my $url = $track->url;

		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		
		if ( $handler && $handler->can('getMetadataFor') ) {
			# Don't modify source data
			$remoteMeta = Storable::dclone(
				$handler->getMetadataFor( $request->client, $url )
			);
			
			$remoteMeta->{a} = $remoteMeta->{artist};
			$remoteMeta->{A} = $remoteMeta->{artist};
			$remoteMeta->{l} = $remoteMeta->{album};
			$remoteMeta->{K} = $remoteMeta->{cover};
			$remoteMeta->{d} = ( $remoteMeta->{duration} || 0 ) + 0;
			$remoteMeta->{Y} = $remoteMeta->{replay_gain};
			$remoteMeta->{o} = $remoteMeta->{type};
			$remoteMeta->{r} = $remoteMeta->{bitrate};
			$remoteMeta->{B} = $remoteMeta->{buttons};
			$remoteMeta->{L} = $remoteMeta->{info_link};
		}
	}
	
	my $parentTrack;
	if ( $request->client ) { # Bug 13062, songinfo may be called without a client
		if (my $song = $request->client->currentSongForUrl($track->url)) {
			my $t = $song->currentTrack();
			if ($t->url ne $track->url) {
				$parentTrack = $track;
				$track = $t;
			}
		}
	}
	
	# define an ordered hash for our results
	tie (my %returnHash, "Tie::IxHash");

	$returnHash{'id'}    = $track->id;
	$returnHash{'title'} = $remoteMeta->{title} || $track->title;

	my %tagMap = (
		# Tag    Tag name             Token            Track method         Track field
		#------------------------------------------------------------------------------
		  'u' => ['url',              'LOCATION',      'url'],              #url
		  'o' => ['type',             'TYPE',          'content_type'],     #content_type
		                                                                    #titlesort 
		                                                                    #titlesearch 
		  'a' => ['artist',           'ARTIST',        'artistName'],       #->contributors
		  'e' => ['album_id',         '',              'albumid'],          #album 
		  'l' => ['album',            'ALBUM',         'albumname'],            #->album.title
		  't' => ['tracknum',         'TRACK',         'tracknum'],         #tracknum
		  'n' => ['modificationTime', 'MODTIME',       'modificationTime'], #timestamp
		  'f' => ['filesize',         'FILELENGTH',    'filesize'],         #filesize
		                                                                    #tag 
		  'i' => ['disc',             'DISC',          'disc'],             #disc
		  'j' => ['coverart',         'SHOW_ARTWORK',  'coverArtExists'],   #cover
		  'x' => ['remote',           '',              'remote'],           #remote 
		                                                                    #audio 
		                                                                    #audio_size 
		                                                                    #audio_offset
		  'y' => ['year',             'YEAR',          'year'],             #year
		  'd' => ['duration',         'LENGTH',        'secs'],             #secs
		                                                                    #vbr_scale 
		  'r' => ['bitrate',          'BITRATE',       'prettyBitRate'],    #bitrate
		  'T' => ['samplerate',       'SAMPLERATE',    'samplerate'],       #samplerate 
		  'I' => ['samplesize',       'SAMPLESIZE',    'samplesize'],       #samplesize 
		                                                                    #channels 
		                                                                    #block_alignment
		                                                                    #endian 
		  'm' => ['bpm',              'BPM',           'bpm'],              #bpm
		  'v' => ['tagversion',       'TAGVERSION',    'tagversion'],       #tagversion
		# 'z' => ['drm',              '',              'drm'],              #drm
		                                                                    #musicmagic_mixable
		                                                                    #musicbrainz_id 
		                                                                    #playcount 
		                                                                    #lastplayed 
		                                                                    #lossless 
		  'w' => ['lyrics',           'LYRICS',        'lyrics'],           #lyrics 
		  'R' => ['rating',           'RATING',        'rating'],           #rating 
		  'Y' => ['replay_gain',      'REPLAYGAIN',    'replay_gain'],      #replay_gain 
		                                                                    #replay_peak

		  'K' => ['artwork_url',      '',              'coverurl'],         # artwork URL, not in db
		  'B' => ['buttons',          '',              'buttons'],          # radio stream special buttons
		  'L' => ['info_link',        '',              'info_link'],        # special trackinfo link for i.e. Pandora
		  'N' => ['remote_title'],                                          # remote stream title


		# Tag    Tag name              Token              Relationship     Method          Track relationship
		#--------------------------------------------------------------------------------------------------
		  's' => ['artist_id',         '',                'artist',        'id'],           #->contributors
		  'A' => ['<role>',            '<ROLE>',          'contributors',  'name'],         #->contributors[role].name
		  'S' => ['<role>_ids',        '',                'contributors',  'id'],           #->contributors[role].id
                                                                            
		  'q' => ['disccount',         '',                'album',         'discc'],        #->album.discc
		  'J' => ['artwork_track_id',  'COVERART',        'album',         'artwork'],      #->album.artwork
		  'C' => ['compilation',       'COMPILATION',     'album',         'compilation'],  #->album.compilation
		  'X' => ['album_replay_gain', 'ALBUMREPLAYGAIN', 'album',         'replay_gain'],  #->album.replay_gain
                                                                            
		  'g' => ['genre',             'GENRE',           'genre',         'name'],         #->genre_track->genre.name
		  'p' => ['genre_id',          '',                'genre',         'id'],           #->genre_track->genre.id
		  'G' => ['genres',            'GENRE',           'genres',        'name'],         #->genre_track->genres.name
		  'P' => ['genre_ids',         '',                'genres',        'id'],           #->genre_track->genres.id
                                                                            
		  'k' => ['comment',           'COMMENT',         'comment'],                       #->comment_object

	);
	
	# loop so that stuff is returned in the order given...
	for my $tag (split (//, $tags)) {
		
		my $tagref = $tagMap{$tag} or next;
		
		# special case, remote stream name
		if ($tag eq 'N') {
			if ($parentTrack) {
				$returnHash{$tagref->[0]} = $parentTrack->title;
			} elsif ( $track->remote && !$track->secs && $remoteMeta->{title} && !$remoteMeta->{album} ) {
				if (my $meta = $track->title) {
					$returnHash{$tagref->[0]} = $meta;
				}
			}
		}
		
		# special case artists (tag A and S)
		elsif ($tag eq 'A' || $tag eq 'S') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{artist} = $meta;
				next;
			}
			
			if ( defined(my $submethod = $tagref->[3]) && !main::SLIM_SERVICE ) {
				
				my $postfix = ($tag eq 'S')?"_ids":"";
			
				foreach my $type (Slim::Schema::Contributor::contributorRoles()) {
						
					my $key = lc($type) . $postfix;
					my $contributors = $track->contributorsOfType($type) or next;
					my @values = map { $_ = $_->$submethod() } $contributors->all;
					my $value = join(', ', @values);
			
					if (defined $value && $value ne '') {

						# add the tag to the result
						$returnHash{$key} = $value;
						$returnHash{"arrayRef_$key"} = \@values;
					}
				}
			}
		}

		# if we have a method/relationship for the tag
		elsif (defined(my $method = $tagref->[2])) {
			
			my $value;
			my $key = $tagref->[0];
			
			# Override with remote track metadata if available
			if ( defined $remoteMeta->{$tag} ) {
				$value = $remoteMeta->{$tag};
			}
			
			elsif ($method eq '' || !$track->can($method)) {
				next;
			}

			# tag with submethod
			elsif (defined(my $submethod = $tagref->[3])) {

				# call submethod
				if (defined(my $related = $track->$method)) {
					
					# array returned/genre
					if ( blessed($related) && $related->isa('Slim::Schema::ResultSet::Genre')) {
						$value = join(', ', map { $_ = $_->$submethod() } $related->all);
					} else {
						$value = $related->$submethod();
					}
				}
			}
			
			# simple track method
			else {
				$value = $track->$method();
			}
			
			# correct values
			if (($tag eq 'R' || $tag eq 'x') && $value == 0) {
				$value = undef;
			}
			
			# if we have a value
			if (defined $value && $value ne '') {

				# add the tag to the result
				$returnHash{$key} = $value;
			}
		}
	}

	return \%returnHash;
}

sub _playAll {
	my %args       = @_;
	my $start      = $args{'start'};
	my $end        = $args{'end'};
	my $chunkCount = $args{'chunkCount'};
	my $loopname   = $args{'loopname'};
	my $request    = $args{'request'};
	my $includeArt = $args{'includeArt'};
	my $allSongs   = $args{'allSongs'} || 0;
	my $artist     = $args{'artist'} || '';

	# insert first item if needed
	if ($start == 0 && $end == 0) {
		# one item list, so do not add a play all and just return
		return $chunkCount;
	} elsif ($start == 0) {
		# we're going to add a 'play all' and an 'add all'
		# init some vars for each mode for use in the two item loop below
		my %items = ( 	
			'play' => {
					'string'      => $request->string('JIVE_PLAY_ALL'),
					'style'       => 'itemplay',
					'playAction'  => 'playtracks',
					'addAction'   => 'addtracks',
					'playCmd'     => [ 'playlistcontrol' ],
					'addCmd'      => [ 'playlistcontrol' ],
					'addHoldCmd'      => [ 'playlistcontrol' ],
					'params'      => { 
						'play' =>  { cmd => 'load', },
						'add'  =>  { 'cmd' => 'add',  },
						'add-hold'  =>  { 'cmd' => 'insert',  },
					},
					'nextWindow'  => 'nowPlaying',
			},
			allSongs => { 
					string     => $request->string('JIVE_ALL_SONGS') . "\n" . $artist,
					style      => 'item',
					playAction => 'playtracks',
					addAction  => 'addtracks',
					playCmd    => [ 'playlistcontrol' ],
					addCmd     => [ 'playlistcontrol' ],
					goCmd      => [ 'tracks' ],
					addHoldCmd     => [ 'playlistcontrol' ],
					params     => { 
						go          =>  { menu => 1, menu_all => 1, sort => 'title', menuStyle => 'allSongs', },
						play        =>  { cmd => 'load', },
						add         =>  { cmd => 'add', },
						'add-hold'  =>  { cmd => 'insert',  },
					},
			},
		);

		my @items = qw/ play /;

		if ($allSongs) {
			@items = ( 'allSongs' );
		}

		for my $mode (@items) {

		$request->addResultLoop($loopname, $chunkCount, 'text', $items{$mode}{'string'});
		$request->addResultLoop($loopname, $chunkCount, 'style', $items{$mode}{'style'});

		if ($includeArt) {
			my $playallicon = main::SLIM_SERVICE
				? Slim::Networking::SqueezeNetwork->url('/static/images/icons/playall.png', 'external')
				: '/html/images/playall.png';
				
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', $playallicon);
		}

		# get all our params
		my $params = $request->getParamsCopy();
		my $searchType = $request->getParam('_searchType');
	
		# remove keys starting with _ (internal or positional) and make copies
		while (my ($key, $val) = each %{$params}) {
			if ($key =~ /^_/ || $key eq 'menu' || $key eq 'menu_all') {
				next;
			}
			# search is a special case of _playAll, which needs to fire off a different cli command
			if ($key eq 'search') {
				# we don't need a cmd: tagged param for these
				delete($items{$mode}{'params'}{'play'}{'cmd'});
				delete($items{$mode}{'params'}{'add'}{'cmd'});
				delete($items{$mode}{'params'}{'add-hold'}{'cmd'});
				my $searchParam;
				for my $button ('add', 'add-hold', 'play') {
					if ($searchType eq 'artists') {
						$searchParam = 'contributor.namesearch=' . $val;
					} elsif ($searchType eq 'albums') {
						$searchParam = 'album.titlesearch=' . $val;
					} else {
						$searchParam = 'track.titlesearch=' . $val;
					}
				}
				$items{$mode}{'playCmd'} = ['playlist', 'loadtracks', $searchParam ];
				$items{$mode}{'addCmd'}  = ['playlist', 'addtracks', $searchParam ];
				$items{$mode}{'addHoldCmd'}  = ['playlist', 'inserttracks', $searchParam ];
				$items{$mode}{'playCmd'} = $items{$mode}{'addCmd'} if $mode eq 'add';
			} else {
				$items{$mode}{'params'}{'add'}{$key}  = $val;
				$items{$mode}{'params'}{'add-hold'}{$key}  = $val;
				$items{$mode}{'params'}{'play'}{$key} = $val;
				$items{$mode}{'params'}{'go'}{$key} = $val;
			}
		}
				
		# override the actions, babe!
		my $actions = {
			'play' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'playCmd'},
				'nextWindow' => 'nowPlaying',
				'params' => $items{$mode}{'params'}{'play'},
			},
			'add' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'addCmd'},
				'params' => $items{$mode}{'params'}{'add'},
			},
			'add-hold' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'addCmd'},
				'params' => $items{$mode}{'params'}{'add-hold'},
			},
		};
		if ($items{$mode}{'goCmd'}) {
			$actions->{'go'} = {
					'player' => 0,
					'cmd'    => $items{$mode}{'goCmd'},
					'params' => $items{$mode}{'params'}{'go'},
			};
		} else {
			$actions->{'do'} = {
				'player' => 0,
				'cmd'    => $items{$mode}{'playCmd'},
				'params' => $items{$mode}{'params'}{'play'},
			};
			if ($items{$mode}{'nextWindow'}) {
				$actions->{'do'}{'nextWindow'} = $items{$mode}{'nextWindow'};
			}			
		}
		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$chunkCount++;

		}

	}

	return $chunkCount;

}

# this is a silly little sub that allows jive cover art to be rendered in a large window
sub showArtwork {

	main::INFOLOG && $log->info("Begin showArtwork Function");
	my $request = shift;

	# get our parameters
	my $id = $request->getParam('_artworkid');

	if ($id =~ /:\/\//) {
		$request->addResult('artworkUrl'  => $id);
	} else {
		$request->addResult('artworkId'  => $id);
	}

	$request->addResult('offset', 0);
	$request->setStatusDone();

}

# Wipe cached data, called after a rescan
sub wipeCaches {
	$cache = {};
}


# fix the count in case we're adding additional items
# (play all, VA etc.) to the resultset
sub _fixCount {
	my $insertItem = shift;
	my $index      = shift;
	my $quantity   = shift;
	my $count      = shift;

	my $totalCount = $count || 0;

	if ($insertItem && $count > 1) {
		$totalCount++;

		# return one less result as we only add the additional item in the first chunk
		if ( !$$index ) {
			$$quantity--;
		}

		# decrease the index in subsequent queries
		else {
			$$index--;
		}
	}

	return $totalCount;
}

sub _mixerItemParams {
	my %args       = @_;
	my $chunkCount = $args{'chunkCount'};
	my $loopname   = $args{'loopname'};
	my $params     = $args{'params'};
	my $request    = $args{'request'};
	my $obj        = $args{'obj'};

	my ($Imports, $mixers) = _mixers();

	# one enabled mixer available
	if ( scalar(@$mixers) == 1 ) {
		my $mixer = $mixers->[0];
		if ($mixer->mixable($obj)) {

		} else {
			my $unmixable = {
				player => 0,
				cmd    => ['jiveunmixable'],
				params => {
					contextToken => $Imports->{$mixer}->{contextToken},
				},
			};
			$request->addResultLoop($loopname, $chunkCount, 'actions', { 'play-hold' => $unmixable } );
		}
	} else {
		return;
	}
}

# contextMenuQuery is a wrapper for producing context menus for various objects
sub contextMenuQuery {

	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['contextmenu']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');

	my $client        = $request->client();
	my $menu          = $request->getParam('menu');

	# this subroutine is just a wrapper, so we prep the @requestParams array to pass on to another command
	my $params = $request->getParamsCopy();
	my @requestParams = ();
	for my $key (keys %$params) {
		next if $key eq '_index' || $key eq '_quantity';
		push @requestParams, $key . ':' . $params->{$key};
	}

	my $proxiedRequest;
	if (defined($menu)) {
		# send the command to *info, where * is the param given to the menu command
		my $command = $menu . 'info';
		$proxiedRequest = Slim::Control::Request::executeRequest( $client, [ $command, 'items', $index, $quantity, @requestParams ] );
		
		# Bug 13744, wrap async requests
		if ( $proxiedRequest->isStatusProcessing ) {			
			$proxiedRequest->callbackFunction( sub {
				$request->setRawResults( $_[0]->getResults );
				$request->setStatusDone();
			} );
			
			$request->setStatusProcessing();
			return;
		}
		
	# if we get here, we punt
	} else {
		$request->setStatusBadParams();
	}

	# now we have the response in $proxiedRequest that needs to get its output sent via $request
	$request->setRawResults( $proxiedRequest->getResults );

}

sub mixerMenuQuery {

	$log->debug('Begin Function');
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['mixermenu']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $trackID       = $request->getParam('track_id');
	my $genreID       = $request->getParam('genre_id');
	my $artistID      = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
				
	# look for the $obj_param first from an obj_param key, then from track_id, artist_id, album_id, genre_id
	my $obj_param     = $request->getParam('obj_param') ? $request->getParam('obj_param') :
				$trackID  ? 'track_id'  :
				$artistID ? 'artist_id' :
				$albumID  ? 'album_id'  :
				$genreID  ? 'genre_id'  :
				undef;

	# an $obj_param is necessary for this query
	if ( !defined($obj_param) ) {
		$request->setStatusBadDispatch();
		return;
	}

	my $obj_id = $request->getParam('obj_param') ? 
			$request->getParam('obj_param') :
			$request->getParam($obj_param);


	my ($Imports, $mixers) = _mixers();
	
	$request->addResult('offset', 0 );
	$request->addResult('window', { menuStyle => '' } );
	my $chunkCount = 0;

	# fetch the object
	my $obj;
	if ($obj_param eq 'track_id') {
		$obj = Slim::Schema->find('Track', $obj_id);
	} elsif ($obj_param eq 'artist_id') {
		$obj = Slim::Schema->find('Contributor', $obj_id);
	} elsif ($obj_param eq 'album_id') {
		$obj = Slim::Schema->find('Album', $obj_id);
	} elsif ($obj_param eq 'genre_id') {
		$obj = Slim::Schema->find('Genre', $obj_id);
	}

	my @mixable_mixers;
	for my $mixer (@$mixers) {
		if ( blessed($obj) && $mixer->mixable($obj) ) {
			push @mixable_mixers, $mixer;
		}
	}

	if ( scalar(@mixable_mixers) == 0 ) {
		$request->addResult('count', 1);
		$request->addResultLoop('item_loop', 0, 'text', $request->string('NO_MIXERS_AVAILABLE') );
		$request->addResultLoop('item_loop', 0, 'style', 'itemNoAction');
	} else {
		$request->addResult('count', scalar(@mixable_mixers) );
		for my $mixer ( @mixable_mixers ) {
			my $token = $Imports->{$mixer}->{'contextToken'};
			my $string = $request->string($token);
			$request->addResultLoop('item_loop', $chunkCount, 'text', $string);
			my $actions;
			my $command = Storable::dclone( $Imports->{$mixer}->{cliBase} );
			$command->{'params'}{'menu'} = 1;
			$command->{'params'}{$obj_param} = $obj->id;
			$actions->{go} = $command;
			$request->addResultLoop('item_loop', $chunkCount, 'actions', $actions);
			$chunkCount++;
		}
	}
	$request->setStatusDone();

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

sub _mixerBase {

	my ($Imports, $mixers) = _mixers();
	
	# one enabled mixer available
	if ( scalar(@$mixers) == 1 ) {
		return $Imports->{$mixers->[0]}->{'cliBase'};
	} elsif (@$mixers) {
		return {
			player => 0,
			cmd    => ['mixermenu'],
			params => {
			},
			itemsParams => 'params',
		};
	} else {
		return undef;	
	}
}

# currently this sends back a callback that is only for tracks
# to be expanded to work with artist/album/etc. later
sub _contextMenuBase {

	my $menu = shift;

	return {
		player => 0,
		cmd => ['contextmenu', ],
			'params' => {
				'menu' => $menu,
			},
		itemsParams => 'params',
		window => { 
			isContextMenu => 1, 
		},
	};

}

sub _mixerItemHandler {
	my %args       = @_;
	my $chunkCount = $args{'chunkCount'};
	my $loopname   = $args{'loopname'};
	my $obj        = $args{'obj'};
	my $obj_param  = $args{'obj_param'};
	my $request    = $args{'request'};

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
			cmd    => ['mixermenu'],
			params => {
				$obj_param => $obj->id,
			},
		};
	} else {
		return undef;
	}
}

sub _partyModeCheck {
	my $request   = shift;
	my $partyMode = 0;
	if ($request->client) {
		my $client = $request->client();
		$partyMode = Slim::Player::Playlist::playlistMode($client);
	}
	return ($partyMode eq 'party');
}


sub _scanFailed {
	my ($request, $info) = @_;
	
	if ($info && $info eq 'SCAN_ABORTED') {
		$info = $request->string($info);
	}
	elsif ($info) {
		$info = $request->string('FAILURE_PROGRESS', $request->string($info . '_PROGRESS') || '?');
	}

	$request->addResult('lastscanfailed', $info || '?');	
}

=head1 SEE ALSO

L<Slim::Control::Request.pm>

=cut

1;

__END__
