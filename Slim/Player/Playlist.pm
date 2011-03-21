package Slim::Player::Playlist;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use File::Spec::Functions qw(:ALL);
use Scalar::Util qw(blessed);

use Slim::Formats::Playlists::M3U;
use Slim::Player::Source;
use Slim::Player::Sync;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

if (!main::SCANNER) {
	require Slim::Control::Jive;
}

my $prefs = preferences('server');

our %validSubCommands = map { $_ => 1 } qw(play append load_done loadalbum addalbum loadtracks addtracks clear delete move sync);

our %shuffleTypes = (
	1 => 'track',
	2 => 'album',
);


#
# accessors for playlist information
#
sub count {
	my $client = shift;
	return scalar(@{playList($client)});
}

sub shuffleType {
	my $client = shift;

	my $shuffleMode = shuffle($client);

	if (defined $shuffleTypes{$shuffleMode}) {
		return $shuffleTypes{$shuffleMode};
	}

	return 'none';
}

sub song {

	my $client  = shift;
	my $index   = shift;
	my $refresh = shift || 0;

	if (count($client) == 0) {
		return;
	}

	if (!defined($index)) {
		$index = Slim::Player::Source::playingSongIndex($client);
	}

	my $objOrUrl;

	if (defined ${shuffleList($client)}[$index]) {

		$objOrUrl = ${playList($client)}[${shuffleList($client)}[$index]];

	} else {

		$objOrUrl = ${playList($client)}[$index];
	}

	if ( $objOrUrl && ($refresh || !blessed($objOrUrl)) ) {

		$objOrUrl = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => $objOrUrl,
			'create'   => 1,
			'readTags' => 1,
		});
		
		if ($refresh) {
			$objOrUrl = refreshTrack($client, $objOrUrl->url);
		}
	}

	return $objOrUrl;
}

# Refresh track(s) in a client playlist from the database
sub refreshTrack {
	my ( $client, $url ) = @_;
	
	my $track = Slim::Schema->rs('Track')->objectForUrl( {
		url      => $url,
		create   => 1,
		readTags => 1,
	} );
	
	my $i = 0;
	for my $item ( @{ playList($client) } ) {
		my $itemUrl = blessed($item) ? $item->url : $item;
		if ( $itemUrl eq $url ) {
			playList($client)->[$i] = $track;
		}
		$i++;
	}
	
	return $track;
}

sub url {
	my $objOrUrl = song( @_ );

	return ( blessed $objOrUrl ) ? $objOrUrl->url : $objOrUrl;
}

sub shuffleList {
	my ($client) = shift;
	
	$client = $client->master();
	
	return $client->shufflelist;
}

sub playList {
	my ($client) = shift;

	$client = $client->master();
	
	return $client->playlist;
}

sub shuffle {
	my $client = shift;
	my $shuffle = shift;
	
	$client = $client->master();

	if (defined($shuffle)) {
		$prefs->client($client)->set('shuffle', $shuffle);
	}
	
	# If Random Play mode is active, return 0
	if (   exists $INC{'Slim/Plugin/RandomPlay/Plugin.pm'} 
		&& Slim::Plugin::RandomPlay::Plugin::active($client)
	) {
		return 0;
	}
	
	return $prefs->client($client)->get('shuffle');
}

sub repeat {
	my $client = shift;
	my $repeat = shift;
	
	$client = $client->master();

	if (defined($repeat)) {
		$prefs->client($client)->set('repeat', $repeat);
	}
	
	return $prefs->client($client)->get('repeat');
}

sub playlistMode {
	my $client  = shift;
	my $mode    = shift;

	$client     = $client->master();

	my $currentSetting = $prefs->client($client)->get('playlistmode');

	if ( defined($mode) && $mode ne $currentSetting ) {
		$prefs->client($client)->set('playlistmode', $mode);

		my %modeStrings = (
			disabled => 'PLAYLIST_MODE_DISABLED',
			on       => 'PLAYLIST_MODE_ON',
			off      => 'PLAYLIST_MODE_OFF',
			party    => 'PARTY_MODE_ON',
		);
		$client->showBriefly({
			duration => 3,
			line     => [ "\n", $client->string($modeStrings{$mode}) ],
			jive     => {
				'type'    => 'popupplay',
				'text'    => [ $client->string($modeStrings{$mode}) ],
			}
		});
	}

	return $prefs->client($client)->get('playlistmode');

}

sub copyPlaylist {
	my $toClient   = shift;
	my $fromClient = shift;

	@{$toClient->playlist}    = @{$fromClient->playlist};
	@{$toClient->shufflelist} = @{$fromClient->shufflelist};

	Slim::Player::Source::streamingSongIndex($toClient, Slim::Player::Source::streamingSongIndex($fromClient), 1);

	$prefs->client($toClient)->set('shuffle', $prefs->client($fromClient)->get('shuffle'));
	$prefs->client($toClient)->set('repeat',  $prefs->client($fromClient)->get('repeat'));
}

sub removeTrack {
	my $client = shift->master();
	my $tracknum = shift;
	
	my $playlistIndex = ${shuffleList($client)}[$tracknum];

	my $stopped = 0;
	my $oldMode = Slim::Player::Source::playmode($client);
	my $log     = logger('player.source');
	
	if (Slim::Player::Source::playingSongIndex($client) == $tracknum) {

		$log->info("Removing currently playing track.");

		Slim::Player::Source::playmode($client, "stop");

		$stopped = 1;

	} elsif (Slim::Player::Source::streamingSongIndex($client) == $tracknum) {

		# If we're removing the streaming song (which is different from
		# the playing song), get the client to flush out the current song
		# from its audio pipeline.
		$log->info("Removing currently streaming track.");

		Slim::Player::Source::flushStreamingSong($client);

	} else {

		my $queue = $client->currentsongqueue();

		for my $song (@$queue) {

			if ($tracknum < $song->{'index'}) {
				$song->{'index'}--;
			}
		}
	}
	
	splice(@{playList($client)}, $playlistIndex, 1);

	my @reshuffled;
	my $counter = 0;

	for my $i (@{shuffleList($client)}) {

		if ($i < $playlistIndex) {

			push @reshuffled, $i;

		} elsif ($i > $playlistIndex) {

			push @reshuffled, ($i - 1);
		}
	}


	@{$client->shufflelist} = @reshuffled;

	if ($stopped) {

		my $songcount = scalar(@{playList($client)});

		if ($tracknum >= $songcount) {
			$tracknum = $songcount - 1;
		}
		
		$client->execute([ 'playlist', 'jump', $tracknum, $oldMode ne "play" ]);
	}

	# browseplaylistindex could return a non-sensical number if we are not in playlist mode
	# this is due to it being a wrapper around $client->modeParam('listIndex')
	refreshPlaylist($client,
		Slim::Buttons::Playlist::showingNowPlaying($client) ?
			undef : 
			Slim::Buttons::Playlist::browseplaylistindex($client)
	);
}

sub removeMultipleTracks {
	my $client = shift;
	my $tracks = shift;

	my %trackEntries = ();

	if (defined($tracks) && ref($tracks) eq 'ARRAY') {

		for my $track (@$tracks) {
	
			# Handle raw file urls (from BMF, of course)
			if (ref $track) {
				$track = $track->url;
			};
			
			$trackEntries{$track} = 1;
		}
	}

	my $stopped = 0;
	my $oldMode = Slim::Player::Source::playmode($client);

	my $playingTrackPos   = ${shuffleList($client)}[Slim::Player::Source::playingSongIndex($client)];
	my $streamingTrackPos = ${shuffleList($client)}[Slim::Player::Source::streamingSongIndex($client)];

	# going to need to renumber the entries in the shuffled list
	# will need to map the old position numbers to where the track ends
	# up after all the deletes occur
	my %oldToNew = ();
	my $i        = 0;
	my $oldCount = 0;
 
	while ($i <= $#{playList($client)}) {

		#check if this file meets all criteria specified
		my $thisTrack = ${playList($client)}[$i];

		if ($trackEntries{$thisTrack->url}) {

			splice(@{playList($client)}, $i, 1);

			if ($playingTrackPos == $oldCount) {

				Slim::Player::Source::playmode($client, "stop");
				$stopped = 1;

			} elsif ($streamingTrackPos == $oldCount) {

				Slim::Player::Source::flushStreamingSong($client);
			}

		} else {

			$oldToNew{$oldCount} = $i;
			$i++;
		}

		$oldCount++;
	}
	
	my @reshuffled = ();
	my $newTrack;
	my $getNext = 0;
	my %oldToNewShuffled = ();
	my $j = 0;

	# renumber all of the entries in the shuffle list with their new
	# positions, also get an update for the current track, if the
	# currently playing track was deleted, try to play the next track in
	# the new list
	while ($j <= $#{shuffleList($client)}) {

		my $oldNum = shuffleList($client)->[$j];

		if ($oldNum == $playingTrackPos) {
			$getNext = 1;
		}

		if (exists($oldToNew{$oldNum})) { 

			push(@reshuffled,$oldToNew{$oldNum});

			$oldToNewShuffled{$j} = $#reshuffled;

			if ($getNext) {
				$newTrack = $#reshuffled;
				$getNext  = 0;
			}
		}

		$j++;
	}

	# if we never found a next, we deleted eveything after the current
	# track, wrap back to the beginning
	if ($getNext) {
		$newTrack = 0;
	}

	$client = $client->master();
	
	@{$client->shufflelist} = @reshuffled;

	if ($stopped && ($oldMode eq "play")) {

		$client->execute([ 'playlist', 'jump', $newTrack ]);

	} else {

		my $queue = $client->currentsongqueue();

		for my $song (@{$queue}) {
			$song->{'index'} = $oldToNewShuffled{$song->{'index'}} || 0;
		}
	}

	refreshPlaylist($client);
}

sub refreshPlaylist {
	my $client = shift;
	my $index = shift;

	# make sure we're displaying the new current song in the playlist view.
	for my $everybuddy ($client->syncGroupActiveMembers()) {
		if ($everybuddy->isPlayer()) {
			Slim::Buttons::Playlist::jump($everybuddy,$index);
		}
	}
}

sub moveSong {
	my $client = shift;
	my $src = shift;
	my $dest = shift;
	my $size = shift;
	my $listref;
	
	$client = $client->master();
	
	if (!defined($size)) {
		$size = 1;
	}

	if (defined $dest && $dest =~ /^[\+-]/) {
		$dest = $src + $dest;
	}

	if (defined $src && defined $dest && 
		$src < count($client) && 
		$dest < count($client) && $src >= 0 && $dest >= 0) {

		if (shuffle($client)) {
			$listref = shuffleList($client);
		} else {
			$listref = playList($client);
		}

		if (defined $listref) {		

			my @item = splice @{$listref},$src, $size;

			splice @{$listref},$dest, 0, @item;	

			my $playingIndex = Slim::Player::Source::playingSongIndex($client);
			my $streamingIndex = Slim::Player::Source::streamingSongIndex($client);
			# If we're streaming a different song than we're playing and
			# moving either to or from the streaming song position, flush
			# the streaming song, because it's no longer relevant.
			if (($playingIndex != $streamingIndex) &&
				(($streamingIndex == $src) || ($streamingIndex == $dest) ||
				 ($playingIndex == $src) || ($playingIndex == $dest))) {
				Slim::Player::Source::flushStreamingSong($client);
			}

			my $queue = $client->currentsongqueue();

			for my $song (@$queue) {
				my $index = $song->{index};
				if ($src == $index) {
					$song->{index} = $dest;
				}
				elsif (($dest == $index) || (($src < $index) != ($dest < $index))) {
					$song->{index} = ($dest>$src)? $index - 1 : $index + 1;
				}
			}

			refreshPlaylist($client);
		}
	}
}

sub clear {
	my $client = shift;

	@{playList($client)} = ();
	$client->currentPlaylist(undef);

	reshuffle($client);
}

sub fischer_yates_shuffle {
	my ($listRef) = @_;

	if ($#$listRef == -1 || $#$listRef == 0) {
		return;
	}

	for (my $i = ($#$listRef + 1); --$i;) {
		# swap each item with a random item;
		my $a = int(rand($i + 1));
		@$listRef[$i,$a] = @$listRef[$a,$i];
	}
}

#reshuffle - every time the playlist is modified, the shufflelist should be updated
#		We also invalidate the htmlplaylist at this point
sub reshuffle {
	my $client = shift->master();

	my $dontpreservecurrsong = shift;
  
	my $songcount = count($client);
	my $listRef   = shuffleList($client);
	my $log       = logger('player.playlist');

	if (!$songcount) {

		@{$listRef} = ();

		refreshPlaylist($client);

		return;
	}

	my $realsong = ${$listRef}[Slim::Player::Source::playingSongIndex($client)];

	if (!defined($realsong) || $dontpreservecurrsong) {
		$realsong = -1;
	} elsif ($realsong > $songcount) {
		$realsong = $songcount;
	}
	
	if ( $log->is_info ) {
		$log->info(sprintf("Reshuffling, current song index: %d, preserve song? %s",
			$realsong,
			$dontpreservecurrsong ? 'no' : 'yes',
		));
	}

	my @realqueue = ();
	my $queue     = $client->currentsongqueue();

	for my $song (@$queue) {

		push @realqueue, $listRef->[$song->{'index'}];
	}

	@{$listRef} = (0 .. ($songcount - 1));

	# 1 is shuffle by song
	# 2 is shuffle by album
	if (shuffle($client) == 1) {

		fischer_yates_shuffle($listRef);

		# If we're preserving the current song
		# this places it at the top of the playlist
		if ( $realsong > -1 ) {
			for (my $i = 0; $i < $songcount; $i++) {

				if ($listRef->[$i] == $realsong) {

					if (shuffle($client)) {
					
						my $temp = $listRef->[$i];
						$listRef->[$i] = $listRef->[0];
						$listRef->[0] = $temp;
						$i = 0;
					}

					last;
				}
			}
		}

	} elsif (shuffle($client) == 2) {

		my %albumTracks     = ();
		my %trackToPosition = ();
		my $i  = 0;

		my $defaultAlbumTitle = Slim::Utils::Text::matchCase($client->string('NO_ALBUM'));

		# Because the playList might consist of objects - we can avoid doing an extra objectForUrl call.
		for my $track (@{playList($client)}) {

			# Can't shuffle remote URLs - as they most likely
			# won't have distinct album names.
			next if Slim::Music::Info::isRemoteURL($track);

			my $trackObj = $track;

			if (!blessed($trackObj) || !$trackObj->can('albumid')) {

				$log->info("Track: $track isn't an object - fetching");

				$trackObj = Slim::Schema->rs('Track')->objectForUrl($track);
			}

			# Pull out the album id, and accumulate all of the
			# tracks for that album into a hash. Also map that
			# object to a poisition in the playlist.
			if (blessed($trackObj) && $trackObj->can('albumid')) {

				my $albumid = $trackObj->albumid() || 0;

				push @{$albumTracks{$albumid}}, $trackObj;

				$trackToPosition{$trackObj} = $i++;

			} else {

				logBacktrace("Couldn't find an object for url: $track");
			}
		}

		# Not quite sure what this is doing - not changing the current song?
		if ($realsong == -1 && !$dontpreservecurrsong) {

			my $index = $prefs->client($client)->get('currentSong');

			if (defined $index && defined $listRef->[$index]) {
				$realsong = $listRef->[$index];
			}
		}

		my $currentTrack = ${playList($client)}[$realsong];
		my $currentAlbum = 0;

		# This shouldn't happen - but just in case.
		if (!blessed($currentTrack) || !$currentTrack->can('albumid')) {
			$currentTrack = Slim::Schema->rs('Track')->objectForUrl($currentTrack);
		}

		if (blessed($currentTrack) && $currentTrack->can('albumid')) {
			$currentAlbum = $currentTrack->albumid() || 0;
		}

		# @albums is now a list of Album names. Shuffle that list.
		my @albums = keys %albumTracks;

		fischer_yates_shuffle(\@albums);

		# Put the album for the currently playing track at the beginning of the list.
		for (my $i = 0; $i <= $#albums && $realsong != -1; $i++) {

			if ($albums[$i] eq $currentAlbum) {

				my $album = splice(@albums, $i, 1);

				unshift(@albums, $album);

				last;
			}
		}

		# Clear out the list ref - we'll be reordering it.
		@{$listRef} = ();

		for my $album (@albums) {

			for my $track (@{$albumTracks{$album}}) {
				push @{$listRef}, $trackToPosition{$track};
			}
		}
	}

	for (my $i = 0; $i < $songcount; $i++) {

		for (my $j = 0; $j <= $#$queue; $j++) {

			if (defined($realqueue[$j]) && defined $listRef->[$i] && $realqueue[$j] == $listRef->[$i]) {

				$queue->[$j]->{'index'} = $i;
			}
		}
	}

	for my $song (@$queue) {
		if ($song->{'index'} >= $songcount) {
			$song->{'index'} = 0;
		}
	}

	# If we just changed order in the reshuffle and we're already streaming
	# the next song, flush the streaming song since it's probably not next.
	if (shuffle($client) && 
		Slim::Player::Source::playingSongIndex($client) != Slim::Player::Source::streamingSongIndex($client)) {

		Slim::Player::Source::flushStreamingSong($client);
	}

	refreshPlaylist($client);
}

sub scheduleWriteOfPlaylist {
	my ($client, $playlistObj) = @_;

	# This should proably be more configurable / have writeM3U or a
	# wrapper know about the scheduler, so we can write out a file at a time.
	#
	# Need to fork!
	#
	# This can happen if the user removes the
	# playlist - because this is a closure, we get
	# a bogus object back)
	if (!blessed($playlistObj) || !$playlistObj->can('tracks') || !$prefs->get('playlistdir')) {

		return 0;
	}

	if ($playlistObj->title eq Slim::Utils::Strings::string('UNTITLED')) {

		logger('player.playlist')->warn("Not writing out untitled playlist.");

		return 0;
	}

	Slim::Formats::Playlists::M3U->write( 
		[ $playlistObj->tracks ],
		undef,
		$playlistObj->path,
		1,
		defined($client) ? Slim::Player::Source::playingSongIndex($client) : 0,
	);
}

sub removePlaylistFromDisk {
	my $playlistObj = shift;

	if (!$playlistObj->can('path')) {
		return;
	}

	my $path = $playlistObj->path;

	if (-e $path) {

		unlink $path;

	} else {

		unlink catfile($prefs->get('playlistdir'), $playlistObj->title . '.m3u');
	}
}


sub newSongPlaylist {
	my $client = shift || return;
	my $reset = shift;
	
	logger('player.playlist')->debug("Begin function - reset: " . $reset);

	return if Slim::Player::Playlist::shuffle($client);
	return if !$prefs->get('playlistdir');
	
	my $playlist = '';

	if ($client->currentPlaylist && blessed($client->currentPlaylist)) {

		$playlist = $client->currentPlaylist->path;

	} else {

		$playlist = $client->currentPlaylist;
	}

	return if Slim::Music::Info::isRemoteURL($playlist);

	logger('player.playlist')->info("Calling writeCurTrackForM3U()");

	Slim::Formats::Playlists::M3U->writeCurTrackForM3U(
		$playlist,
		$reset ? 0 : Slim::Player::Source::playingSongIndex($client)
	);
}


sub newSongPlaylistCallback {
	my $request = shift;

	logger('player.playlist')->debug("Begin function");

	my $client = $request->client() || return;
	
	newSongPlaylist($client)
}


sub modifyPlaylistCallback {
	my $request = shift;
	
	my $client  = $request->client();
	my $log     = logger('player.playlist');

	$log->info("Checking if persistPlaylists is set..");

	if ( !$client || !$prefs->get('persistPlaylists') ) {
		$log->debug("no client or persistPlaylists not set, not saving playlist");
		return;
	}
	
	# If Random Play mode is active, we don't save the playlist
	if (   exists $INC{'Slim/Plugin/RandomPlay/Plugin.pm'} 
		&& Slim::Plugin::RandomPlay::Plugin::active($client)
	) {
		$log->debug("Random play mode active, not saving playlist");
		return;
	}

	my $savePlaylist = $request->isCommand([['playlist'], [keys %validSubCommands]]);

	# Did the playlist or the current song change?
	my $saveCurrentSong = 
		$savePlaylist || 
		$request->isCommand([['playlist'], ['open']]) || 
		($request->isCommand([['playlist'], ['jump', 'index', 'shuffle']]));

	if (!$saveCurrentSong) {

		$log->info("saveCurrentSong not set. returing.");

		return;
	}

	$log->info("saveCurrentSong is: [$saveCurrentSong]");

	my @syncedclients = ($client->controller()->allPlayers());

	my $playlist = Slim::Player::Playlist::playList($client);
	my $currsong = (Slim::Player::Playlist::shuffleList($client))->[Slim::Player::Source::playingSongIndex($client)];

	$client->currentPlaylistChangeTime(Time::HiRes::time());

	for my $eachclient (@syncedclients) {

		# Don't save all the tracks again if we're just starting up!
		if (!$eachclient->startupPlaylistLoading && $savePlaylist) {

			if ( $log->is_info ) {
				$log->info("Finding client playlist for: ", $eachclient->id);
			}

			# Create a virtual track that is our pointer
			# to the list of tracks that make up this playlist.
			my $playlistObj = Slim::Schema->rs('Playlist')->updateOrCreate({

				'url'        => sprintf('clientplaylist://%s', $eachclient->id),
				'attributes' => {
					'TITLE' => sprintf('%s - %s', 
						Slim::Utils::Unicode::utf8encode($eachclient->string('NOW_PLAYING')),
						Slim::Utils::Unicode::utf8encode($eachclient->name ||  $eachclient->ip),
					),

					'CT'    => 'cpl',
				},
			});

			if (defined $playlistObj) {

				$log->info("Calling setTracks() to update playlist");

				$playlistObj->setTracks($playlist);
			}
		}

		if ($saveCurrentSong) {

			$prefs->client($eachclient)->set('currentSong', $currsong);
		}
	}

	# Because this callback is asyncronous, reset the flag here.
	# there's only one place that sets it - in Client::startup()
	if ($client->startupPlaylistLoading) {

		$log->info("Resetting startupPlaylistLoading flag.");

		$client->startupPlaylistLoading(0);
	}
}

1;

__END__


# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
