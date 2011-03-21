package Slim::Plugin::Pandora::ProtocolHandler;

# $Id: ProtocolHandler.pm 11678 2007-03-27 14:39:22Z andy $

# Handler for pandora:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTP);

use JSON::XS::VersionOneAndTwo;

use Slim::Player::Playlist;
use Slim::Utils::Misc;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.pandora',
	'defaultLevel' => $ENV{PANDORA_DEV} ? 'DEBUG' : 'ERROR',
	'description'  => 'PLUGIN_PANDORA_MODULE_NAME',
});

# default artwork URL if an album has no art
my $defaultArtURL = 'http://www.pandora.com/images/no_album_art.jpg';

# max time player may be idle before stopping playback (8 hours)
my $MAX_IDLE_TIME = 60 * 60 * 8;

# To support remote streaming (synced players, slimp3/SB1), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};
	my $url    = $args->{url};
	
	my $track  = $client->pluginData('currentTrack') || {};
	
	$log->debug( 'Remote streaming Pandora track: ' . $track->{audioUrl} );

	return unless $track->{audioUrl};

	my $sock = $class->SUPER::new( {
		url     => $track->{audioUrl},
		client  => $client,
		bitrate => 128_000,
	} ) || return;
	
	${*$sock}{contentType} = 'audio/mpeg';

	# XXX: Time counter is not right, it starts from 0:00 as soon as next track 
	# begins streaming (slimp3/SB1 only)
	
	return $sock;
}

sub getFormatForURL () { 'mp3' }

# Don't allow looping if the tracks are short
sub shouldLoop () { 0 }

sub canSeek { 0 }

sub isRemote { 1 }

# Source for AudioScrobbler (E = Personalised recommendation except Last.fm)
sub audioScrobblerSource () { 'E' }

sub handleError {
    my ( $error, $client ) = @_;

	if ( $client ) {
		$client->unblock;
		
		Slim::Buttons::Common::pushModeLeft( $client, 'INPUT.Choice', {
			header  => '{PLUGIN_PANDORA_ERROR}',
			listRef => [ $error ],
		} );
		
		if ( main::SLIM_SERVICE ) {
			SDI::Service::EventLog->log(
				$client, 'pandora_error', $error,
			);
		}
	}
}

# Whether or not to display buffering info while a track is loading
sub showBuffering {
	my ( $class, $client, $url ) = @_;
	
	my $showBuffering = $client->pluginData('showBuffering');
	
	return ( defined $showBuffering ) ? $showBuffering : 1;
}

sub getNextTrack {
	my ( $client, $params ) = @_;
	
	# If playing and idle time has been exceeded, stop playback
	if ( $client->playmode =~ /play/ ) {
		my $lastActivity = $client->lastActivityTime();
	
		# If synced, check slave players to see if they have newer activity time
		if ( Slim::Player::Sync::isSynced($client) ) {
			# We should already be the master, but just in case...
			my $master = Slim::Player::Sync::masterOrSelf($client);
			for my $c ( $master, @{ $master->slaves } ) {
				my $slaveActivity = $c->lastActivityTime();
				if ( $slaveActivity > $lastActivity ) {
					$lastActivity = $slaveActivity;
				}
			}
		}
	
		if ( time() - $lastActivity >= $MAX_IDLE_TIME ) {
			$log->debug('Idle time reached, stopping playback');
		
			my $url = Slim::Player::Playlist::url($client);

			setCurrentTitle( $client, $url, $client->string('PLUGIN_PANDORA_IDLE_STOPPING') );
		
			$client->update();

			Slim::Player::Source::playmode( $client, 'stop' );
		
			return;
		}
	}
	
	my $stationId = $params->{stationId};
	
	# Talk to SN and get the next track to play
	my $trackURL = Slim::Networking::SqueezeNetwork->url(
		"/api/pandora/v1/playback/getNextTrack?stationId=$stationId"
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		\&gotNextTrack,
		\&gotNextTrackError,
		{
			client  => $client,
			params  => $params,
			timeout => 35,
		},
	);
	
	$log->debug("Getting next track from SqueezeNetwork");
	
	$http->get( $trackURL );
}

sub gotNextTrack {
	my $http   = shift;
	my $client = $http->params->{client};
	my $params = $http->params->{params};
	
	my $track = eval { from_json( $http->content ) };
	
	if ( $@ || $track->{error} ) {
		# We didn't get the next track to play
		if ( $log->is_warn ) {
			$log->warn( 'Pandora error getting next track: ' . ( $@ || $track->{error} ) );
		}
		
		my $url = Slim::Player::Playlist::url($client);

		setCurrentTitle( $client, $url, $track->{error} || $client->string('PLUGIN_PANDORA_NO_TRACKS') );
		
		$client->update();

		Slim::Player::Source::playmode( $client, 'stop' );
	
		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( 'Got Pandora track: ' . Data::Dump::dump($track) );
	}
	
	# Watch for playlist commands for this client only
	Slim::Control::Request::subscribe( 
		\&playlistCallback, 
		[['playlist'], ['repeat', 'newsong']],
		$client,
	);
	
	# Save existing repeat setting
	my $repeat = Slim::Player::Playlist::repeat($client);
	if ( $repeat != 2 ) {
		$log->debug( "Saving existing repeat value: $repeat" );
		$client->pluginData( oldRepeat => $repeat );
	}
	
	# Force repeating
	$client->execute(["playlist", "repeat", 2]);
	
	# Save the previous track's metadata, in case the user wants track info
	# after the next track begins buffering
	$client->pluginData( prevTrack => $client->pluginData('currentTrack') );
	
	# Save metadata for this track, and save the previous track
	$client->pluginData( currentTrack => $track );
	
	# Bug 8781, Seek if instructed by SN
	# This happens when the skip limit is reached and the station has been stopped and restarted.
	if ( $track->{startOffset} ) {
		my @clients;

		if ( Slim::Player::Sync::isSynced($client) ) {
			# if synced, save seek data for all players
			my $master = Slim::Player::Sync::masterOrSelf($client);
			push @clients, $master, @{ $master->slaves };
		}
		else {
			push @clients, $client;
		}

		for my $c ( @clients ) {
			# Save the new seek point
			$c->scanData( {
				seekdata => {
					newtime   => $track->{startOffset},
					newoffset => ( 128_000 / 8 ) * $track->{startOffset},
				},
			} );
		}
		
		# Trigger the seek after the callback
		Slim::Utils::Timers::setTimer(
			undef,
			time(),
			sub {
				Slim::Player::Source::gototime( $client, $track->{startOffset}, 1 );
				
				# Fix progress bar
				$client->streamingProgressBar( {
					url      => Slim::Player::Playlist::url($client),
					duration => $track->{secs},
				} );
			},
		);
	}
	
	my $cb = $params->{callback};
	$cb->();
}

sub gotNextTrackError {
	my $http   = shift;
	my $client = $http->params('client');
	
	handleError( $http->error, $client );
	
	# Make sure we re-enable readNextChunkOk
	$client->readNextChunkOk(1);
}

sub getSeekData {
	my ( $class, $client, $url, $newtime ) = @_;
	
	my $track = $client->pluginData('currentTrack') || return {};
	
	return {
		newoffset         => ( 128_000 / 8 ) * $newtime,
		songLengthInBytes => ( 128_000 / 8 ) * $track->{secs},
	};
}

# Handle normal advances to the next track
sub onDecoderUnderrun {
	my ( $class, $client, $nextURL, $callback ) = @_;
	
	# Special handling needed when synced
	if ( Slim::Player::Sync::isSynced($client) ) {
		if ( !Slim::Player::Sync::isMaster($client) ) {
			# Only the master needs to fetch next track info
			$log->debug('Letting sync master fetch next Pandora track');
			return;
		}
	}

	# Flag that we don't want any buffering messages while loading the next track,
	$client->pluginData( showBuffering => 0 );
	
	# Get next track
	my ($stationId) = $nextURL =~ m{^pandora://([^.]+)\.mp3};
	
	getNextTrack( $client, {
		stationId => $stationId,
		callback  => $callback,
	} );
	
	return;
}

# On skip, load the next track before playback
sub onJump {
    my ( $class, $client, $nextURL, $callback ) = @_;

	# Display buffering info on loading the next track
	# unless we shouldn't (when rating down)
	if ( $client->pluginData('banMode') ) {
		$client->pluginData( showBuffering => 0 );
		$client->pluginData( banMode => 0 );
	}
	else {
		$client->pluginData( showBuffering => 1 );
	}
	
	# If synced and we already fetched a track in onDecoderUnderrun,
	# just callback, don't fetch another track.  Checks prevTrack to
	# make sure there is actually a track ready to be played.
	if ( Slim::Player::Sync::isSynced($client) && $client->pluginData('prevTrack') ) {
		$log->debug( 'onJump while synced, but already got the next track to play' );
		$callback->();
		return;
	}
	
	# Get next track
	my ($stationId) = $nextURL =~ m{^pandora://([^.]+)\.mp3};
	
	getNextTrack( $client, {
		stationId => $stationId,
		callback  => $callback,
	} );
	
	return;
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;
	
	my $bitrate     = 128_000;
	my $contentType = 'mp3';
	
	# Clear previous duration, since we're using the same URL for all tracks
	Slim::Music::Info::setDuration( $url, 0 );
	
	# Grab content-length for progress bar
	my $length;
	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
			last;
		}
	}
	
	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;
	
	$log->info("Direct stream failed: [$response] $status_line");
	
	my $line1 = $client->string('PLUGIN_PANDORA_ERROR');
	my $line2 = $client->string('PLUGIN_PANDORA_STREAM_FAILED');
	
	$client->showBriefly( {
		line1 => $line1,
		line2 => $line2,
		jive  => {
			type => 'popupplay',
			text => [ $line1, $line2 ],
		},
	},
	{
		block  => 1,
		scroll => 1,
	} );
	
	# Report the audio failure to Pandora
	my ($stationId)  = $url =~ m{^pandora://([^.]+)\.mp3};
	my $currentTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	my $snURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/pandora/v1/opml/playback/audioError?stationId=' . $stationId 
		. '&trackId=' . $currentTrack->{trackToken}
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		sub {},
		sub {},
		{
			client  => $client,
			timeout => 35,
		},
	);
	
	$http->get( $snURL );
	
	if ( main::SLIM_SERVICE ) {
		SDI::Service::EventLog->log(
			$client, 'pandora_error', "[$response] $status_line",
		);
	}
	
	# XXX: Stop after a certain number of errors in a row
	
	$client->execute([ 'playlist', 'play', $url ]);
}

# Check if player is allowed to skip, using canSkip value from SN
sub canSkip {
	my $client = shift;
	
	my $track = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	if ( $track ) {
		return $track->{canSkip};
	}
	
	return 1;
}	

# Disallow skips after the limit is reached
sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;
	
	if ( $action eq 'stop' && !canSkip($client) ) {
		# Is skip allowed?
		$log->debug("Pandora: Skip limit exceeded, disallowing skip");
		
		my $track = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
		return 0 if $track->{ad};
		
		my $line1 = $client->string('PLUGIN_PANDORA_ERROR');
		my $line2 = $client->string('PLUGIN_PANDORA_SKIPS_EXCEEDED');
		
		$client->showBriefly( {
			line1 => $line1,
			line2 => $line2,
			jive  => {
				type => 'popupplay',
				text => [ $line1, $line2 ],
			},
		},
		{
			block  => 1,
			scroll => 1,
		} );
				
		return 0;
	}
	
	return 1;
}

sub canDirectStream {
	my ( $class, $client, $url ) = @_;
	
	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	my $base = $class->SUPER::canDirectStream( $client, $url );
	if ( !$base ) {
		return 0;
	}
	
	my $track = $client->pluginData('currentTrack') || {};
	
	return $track->{audioUrl} || 0;
}

sub playlistCallback {
	my $request = shift;
	my $client  = $request->client();
	my $cmd     = $request->getRequest(0);
	my $p1      = $request->getRequest(1);
	
	return unless defined $client;
	
	# ignore if user is not using Pandora
	my $url = Slim::Player::Playlist::url($client);
	
	if ( !$url || $url !~ /^pandora/ ) {
		# User stopped playing Pandora, reset old repeat setting if any
		my $repeat = $client->pluginData('oldRepeat');
		if ( defined $repeat ) {
			$log->debug( "Stopped Pandora, restoring old repeat setting: $repeat" );
			$client->execute(["playlist", "repeat", $repeat]);
		}
		
		$log->debug( "Stopped Pandora, unsubscribing from playlistCallback" );
		Slim::Control::Request::unsubscribe( \&playlistCallback, $client );
		
		return;
	}
	
	$log->debug("Got playlist event: $p1");
	
	# The user has changed the repeat setting.  Pandora requires a repeat
	# setting of '2' (repeat all) to work properly, or it will cause the
	# "stops after every song" bug
	if ( $p1 eq 'repeat' ) {
		if ( $request->getParam('_newvalue') != 2 ) {
			$log->debug("User changed repeat setting, forcing back to 2");
		
			$client->execute(["playlist", "repeat", 2]);
		
			if ( $client->playmode =~ /playout/ ) {
				$client->playmode( 'playout-play' );
			}
		}
	}
	elsif ( $p1 eq 'newsong' ) {
		# A new song has started playing.  We use this to change titles
		my $track = $client->pluginData('currentTrack');
		
		my $title 
			= $track->{songName} . ' ' . $client->string('BY') . ' '
			. $track->{artistName} . ' ' . $client->string('FROM') . ' '
			. $track->{albumName};
		
		setCurrentTitle( $client, $url, $title );
		
		# Remove the previous track metadata
		$client->pluginData( prevTrack => 0 );
	}
}

# Override replaygain to always use the supplied gain value
sub trackGain {
	my ( $class, $client, $url ) = @_;
	
	my $currentTrack = $client->pluginData('currentTrack');
	
	my $gain = $currentTrack->{trackGain} || 0;
	
	$log->info("Using replaygain value of $gain for Pandora track");
	
	return $gain;
}

# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;
	
	my $url = $track->url;

	my ($stationId) = $url =~ m{^pandora://([^.]+)\.mp3};
	
	# Get the current track
	my $currentTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	# SN URL to fetch track info menu
	my $trackInfoURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/pandora/v1/opml/trackinfo?stationId=' . $stationId 
		. '&trackId=' . $currentTrack->{trackToken}
	);
	
	# let XMLBrowser handle all our display
	my %params = (
		header   => 'PLUGIN_PANDORA_GETTING_TRACK_DETAILS',
		modeName => 'Pandora Now Playing',
		title    => Slim::Music::Info::getCurrentTitle( $client, $url ),
		url      => $trackInfoURL,
		remember => 0,
		timeout  => 35,
	);

	Slim::Buttons::Common::pushMode( $client, 'xmlbrowser', \%params );
	
	$client->modeParam( 'handledTransition', 1 );
}

# URL used for CLI trackinfo queries
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;

	my ($stationId) = $url =~ m{^pandora://([^.]+)\.mp3};
	
	# Get the current track
	my $currentTrack = $client->pluginData('prevTrack') || $client->pluginData('currentTrack');
	
	# SN URL to fetch track info menu
	my $trackInfoURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/pandora/v1/opml/trackinfo?stationId=' . $stationId 
		. '&trackId=' . $currentTrack->{trackToken}
	);
	
	return $trackInfoURL;
}

sub setCurrentTitle {
	my ( $client, $url, $title ) = @_;
	
	# We can't use the normal getCurrentTitle method because it would cause multiple
	# players playing the same station to get the same titles
	$client->pluginData( currentTitle => $title );
	
	# Call the normal setCurrentTitle method anyway, so it triggers callbacks to
	# update the display
	Slim::Music::Info::setCurrentTitle( $url, $title );
}

sub getCurrentTitle {
	my ( $class, $client, $url ) = @_;
	
	return $client->pluginData('currentTitle');
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url, $forceCurrent ) = @_;
	
	my $track;
	
	if ( $forceCurrent ) {
		$track = $client->pluginData('currentTrack');
	}
	else {
		$track = $client->pluginData('prevTrack') || $client->pluginData('currentTrack')
	}
	
	my $icon = $class->getIcon();
	
	if ( $track ) {
		return {
			artist      => $track->{artistName},
			album       => $track->{albumName},
			title       => $track->{songName},
			cover       => $track->{albumArtUrl} || $defaultArtURL,
			icon        => $icon,
			replay_gain => $track->{trackGain},
			duration    => $track->{secs},
			bitrate     => '128k CBR',
			type        => 'MP3 (Pandora)',
			info_link   => 'plugins/pandora/trackinfo.html',
			buttons     => {
				# disable REW/Previous button
				rew => 0,

				# replace repeat with Thumbs Up
				repeat  => {
					icon    => 'html/images/btn_thumbs_up.gif',
					tooltip => Slim::Utils::Strings::string('PLUGIN_PANDORA_I_LIKE'),
					command => [ 'pandora', 'rate', 1 ],
				},

				# replace shuffle with Thumbs Down
				shuffle => {
					icon    => 'html/images/btn_thumbs_down.gif',
					tooltip => Slim::Utils::Strings::string('PLUGIN_PANDORA_I_DONT_LIKE'),
					command => [ 'pandora', 'rate', 0 ],
				},
			}
		};
	}
	else {
		return {
			icon    => $icon,
			cover   => $icon,
			bitrate => '128k CBR',
			type    => 'MP3 (Pandora)',
		};
	}
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Slim::Plugin::Pandora::Plugin->_pluginDataFor('icon');
}

# SN only
# Re-init Pandora when a player reconnects
sub reinit {
	my ( $class, $client, $playlist ) = @_;
	
	my $url = $playlist->[0];
	
	if ( my $track = $client->pluginData('currentTrack') ) {
		# We have previous data about the currently-playing song
		
		$log->debug("Re-init Pandora");
		
		# Re-add playlist item
		$client->execute( [ 'playlist', 'add', $url ] );
	
		# Reset track title
		my $title = $track->{songName}   . ' ' . $client->string('BY')   . ' '
				  . $track->{artistName} . ' ' . $client->string('FROM') . ' '
				  . $track->{albumName};
				
		setCurrentTitle( $client, $url, $title );
		
		# Back to Now Playing
		Slim::Buttons::Common::pushMode( $client, 'playlist' );
		
		# Reset song duration/progress bar
		if ( $track->{secs} ) {
			# On a timer because $client->currentsongqueue does not exist yet
			Slim::Utils::Timers::setTimer(
				$client,
				Time::HiRes::time(),
				sub {
					my $client = shift;
					
					$client->streamingProgressBar( {
						url      => $url,
						duration => $track->{secs},
					} );
				},
			);
		}
	}
	else {
		# No data, just restart the current station
		$log->debug("No data about playing track, restarting station");

		$client->execute( [ 'playlist', 'play', $url ] );
	}
	
	return 1;
}

1;
