package Slim::Plugin::RhapsodyDirect::ProtocolHandler;

# $Id: ProtocolHandler.pm 11678 2007-03-27 14:39:22Z andy $

# Rhapsody Direct handler for rhapd:// URLs.

use strict;
use warnings;

use HTML::Entities qw(encode_entities);
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(decode_base64);
use Net::IP;
use Scalar::Util qw(blessed);

use Slim::Plugin::RhapsodyDirect::RPDS;
use Slim::Networking::SqueezeNetwork;
use Slim::Utils::Cache;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use constant SN_DEBUG => 0;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.rhapsodydirect',
	'defaultLevel' => $ENV{RHAPSODY_DEV} ? 'DEBUG' : 'ERROR',
	'description'  => 'PLUGIN_RHAPSODY_DIRECT_MODULE_NAME',
});

my $prefs = preferences('server');

sub getFormatForURL { 'mp3' }

# default buffer 3 seconds of 192k audio
sub bufferThreshold { 24 * ( $prefs->get('bufferSecs') || 3 ) }

# Source for AudioScrobbler
sub audioScrobblerSource {
	my ( $class, $client, $url ) = @_;

	if ( $url =~ /\.rdr$/ ) {
		# R = Non-personalised broadcast
		return 'R';
	}

	# P = Chosen by the user
	return 'P';
}

sub isRemote { 1 }

sub canSeek { 0 }

sub handleError {
    return Slim::Plugin::RhapsodyDirect::Plugin::handleError(@_);
}

sub parseDirectHeaders {
	my ( $class, $client, $url, @headers ) = @_;
	
	my $length;
	my $rangelength;
	
	# Clear previous duration, since we're using the same URL for all tracks
	if ( $url =~ /\.rdr$/ ) {
		Slim::Music::Info::setDuration( $url, 0 );
	}

	foreach my $header (@headers) {

		$log->debug("RhapsodyDirect header: $header");

		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
		}
		elsif ( $header =~ m{^Content-Range: .+/(.*)}i ) {
			$rangelength = $1;
		}
	}
	
	if ( $rangelength ) {
		$length = $rangelength;
	}
	
	# Save length for reinit and seeking
	$client->pluginData( length => $length );

	# ($title, $bitrate, $metaint, $redir, $contentType, $length, $body)
	return (undef, 192000, 0, '', 'mp3', $length, undef);
}

# Don't allow looping if the tracks are short
sub shouldLoop { 0 }

sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;
	
	# Don't allow pause on radio
	if ( $action eq 'pause' && $url =~ /\.rdr$/ ) {
		return 0;
	}
	
	return 1;
}

# Whether or not to display buffering info while a track is loading
sub showBuffering {
	my ( $class, $client, $url ) = @_;
	
	my $showBuffering = $client->pluginData('showBuffering');
	
	return ( defined $showBuffering ) ? $showBuffering : 1;
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;
	
	$log->debug("Direct stream failed: [$response] $status_line\n");
	
	my $line1 = $client->string('PLUGIN_RHAPSODY_DIRECT_ERROR');
	my $line2 = $client->string('PLUGIN_RHAPSODY_DIRECT_STREAM_FAILED');
	
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
	
	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		SDI::Service::EventLog->log(
			$client, 'rhapsody_error', "$response - $status_line"
		);
	}
	
	# If it was a radio track, play again, we'll get a new track
	if ( $url =~ /\.rdr$/ ) {
		$log->debug('Radio track failed, restarting');
		$client->execute([ 'playlist', 'play', $url ]);
	}
	else {
		# Otherwise, skip
		my $nextsong = Slim::Player::Source::nextsong($client);
		if ( $client->playmode !~ /stop/ && defined $nextsong ) {
			$log->debug("Skipping to next track ($nextsong)");
			$client->execute([ 'playlist', 'jump', $nextsong ]);
		}
		else {
			$client->execute([ 'stop' ]);
		}
	}
}

# Only allow 3 players synced, throw an error if more are synced
sub tooManySynced {
	my $client = shift;
	
	return unless Slim::Player::Sync::isSynced($client);
	
	my @clients;
	
	my $master = Slim::Player::Sync::masterOrSelf($client);
	push @clients, $master, @{ $master->slaves };
	
	my $tooMany  = 0;
	my %accounts = ();

	if ( my $account = __PACKAGE__->getAccount($client) ) {
		for my $client ( @clients ) {
			if ( $account->{defaults} ) {
				if ( my $default = $account->{defaults}->{ $client->id } ) {
					$accounts{ $default } ||= 0;
					$accounts{ $default }++;
				}
				else {
					$accounts{ $account->{username}->[0] } ||= 0;
					$accounts{ $account->{username}->[0] }++;
				}
			}
			else {
				$accounts{ $account->{username}->[0] } ||= 0;
				$accounts{ $account->{username}->[0] }++;
			}
		}
	}
	
	# If any one account has more than 3 players on it, sync will fail
	$tooMany = grep { $_ > 3 } values %accounts;
	
	if ( $tooMany ) {
		$log->debug('Too many players synced, not playing');
		
		my $line1 = $client->string('PLUGIN_RHAPSODY_DIRECT_ERROR');
		my $line2 = $client->string('PLUGIN_RHAPSODY_DIRECT_TOO_MANY_SYNCED');
		
		# Show message on all players
		for my $client ( @clients ) {			
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
		}
		
		return 1;
	}
	
	return;
}

sub getAccount {
	my ( $class, $client ) = @_;
	
	# Always pull account info directly from the database on SN
	if ( main::SLIM_SERVICE ) {
		my @username = $prefs->client($client)->get('plugin_rhapsody_direct_username');
		my @password = $prefs->client($client)->get('plugin_rhapsody_direct_password');
		my $defaults = {};
		
		if ( scalar @username > 1 ) {
			if ( my $default = $prefs->client($client)->get('plugin_rhapsody_direct_account') ) {
				$defaults->{ $client->id } = $default;
			}
		}
		
		my $clientType = 'squeezebox3.logitech';
		my $deviceid   = $client->deviceid;
		
		if ( $deviceid == 5 ) {
			$clientType = 'transporter.logitech';
		}
		elsif ( $deviceid == 7 ) {
			$clientType = 'receiver.logitech';
		}
		elsif ( $deviceid == 10 ) {
			$clientType = 'boom.logitech';
		}
		elsif ( $deviceid == 9 ) {
			$clientType = 'squeezeplay.logitech';
		}
		
		my $account = {
			username   => \@username,
			password   => \@password,
			defaults   => $defaults,
			cobrandId  => 40134,
			clientType => $clientType,
		};
		
		return $account;
	}
	
	my $account = $client->pluginData('account');
	
	return $account;
}

sub getPlaybackSession {
	my ( $client, $data, $url, $callback, $sentip ) = @_;
	
	if ( !$sentip ) {
		# Lookup the correct address for secure-direct and inform the players
		# The firmware has a hardcoded address but it may change
		my $dns = Slim::Networking::Async->new;
		$dns->open( {
			Host    => 'secure-direct.rhapsody.com',
			onDNS   => sub {
				my $ip = shift;
				
				$log->debug( "Found IP for secure-direct.rhapsody.com: $ip" );
				
				$ip = Net::IP->new($ip);
				
				rpds( $client, {
					data        => pack( 'cNn', 0, $ip->intip, 443 ),
					_noresponse => 1,
				} );
				
				getPlaybackSession( $client, $data, $url, $callback, 1 );
			},
			onError => sub {
				handleError( $client->string('PLUGIN_RHAPSODY_DIRECT_DNS_ERROR'), $client );
			},
		} );
		
		return;
	}
	
	# Always get a new playback session
	if ( $log->is_debug ) {
		$log->debug( $client->id, ' Requesting new playback session...');
	}
	
	# Update the 'Connecting...' text
	$client->suppressStatus(1);
	displayStatus( $client, $url, 'PLUGIN_RHAPSODY_DIRECT_GETTING_TRACK_INFO', 30 );
	
	# Clear old radio data if any
	$client->pluginData( radioTrackURL => 0 );
	
	# Display buffering info on loading the next track
	$client->pluginData( showBuffering => 1 );
	
	# Get login info
	my $account = __PACKAGE__->getAccount($client);
	
	# Choose the correct account to use for this player's session
	my $username = $account->{username}->[0];
	my $password = $account->{password}->[0];
	
	if ( $account->{defaults} ) {
		if ( my $default = $account->{defaults}->{ $client->id } ) {
			$log->debug( $client->id, " Using default account $default" );
			
			my $i = 0;
			for my $user ( @{ $account->{username} } ) {
				if ( $default eq $user ) {
					$username = $account->{username}->[ $i ];
					$password = $account->{password}->[ $i ];
					last;
				}
				$i++;
			}
		}
	}
	
	my $packet = pack 'cC/a*C/a*C/a*C/a*', 
		2,
		encode_entities( $username ),
		$account->{cobrandId}, 
		encode_entities( decode_base64( $password ) ), 
		$account->{clientType};
	
	# When synced, all players will make this request to get a new playback session
	
	rpds( $client, {
		data        => $packet,
		callback    => \&getNextTrackInfo,
		onError     => \&handleError,
		passthrough => [ $url, $callback ],
	} );
}

sub gotAccount {
	my $http  = shift;
	my $params = $http->params;
	my $client = $params->{client};
	
	my $account = eval { from_json( $http->content ) };
	
	if ( ref $account eq 'HASH' ) {
		$client->pluginData( account => $account );
		
		if ( $log->is_debug ) {
			$log->debug( "Got Rhapsody account info from SN" );
		}
		
		$params->{cb}->();
	}
	else {
		$params->{ecb}->($@);
	}
}

sub gotAccountError {
	my $http   = shift;
	my $params = $http->params;
	
	$params->{ecb}->( $http->error );
}

# Handle normal advances to the next track
sub onDecoderUnderrun {
	my ( $class, $client, $nextURL, $callback ) = @_;

	# Flag that we don't want any buffering messages while loading the next track
	$client->pluginData( showBuffering => 0 );

	# For decoder underrun, we log the full play time of the song
	my $playtime = Slim::Player::Source::playingSongDuration($client);
	
	if ( $playtime > 0 ) {
		$log->debug("End of track, logging usage info ($playtime seconds)...");
	
		my $url = Slim::Player::Playlist::url($client);
		
		sendLogging( $client, $url, $playtime );
	}
	
	# Clear radio data if any, so we always get a new radio track
	$client->pluginData( radioTrackURL => 0 );
	
	# Go to the next track
	if ( Slim::Player::Sync::isSynced($client) ) {
		$callback->();
	}
	else {
		getNextTrackInfo( $client, undef, $nextURL, $callback );
	}
}

# On skip, load the next track before playback
sub onJump {
	my ( $class, $client, $nextURL, $callback ) = @_;
	
	if ( $log->is_debug ) {
		$log->debug( 'Handling command "jump", playmode: ' . $client->playmode );
	}
	
	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		SDI::Service::EventLog->log(
			$client, 'rhapsody_jump', "-> $nextURL",
		);
	}
	
	if ( main::SLIM_SERVICE ) {
		# Fail if firmware doesn't support mp3
		my $old;
		
		my $deviceid = $client->deviceid;
		my $rev      = $client->revision;
		
		if ( $deviceid == 4 && $rev < 97 ) {
			$old = 1;
		}
		elsif ( $deviceid == 5 && $rev < 45 ) {
			$old = 1;
		}
		elsif ( $deviceid == 7 && $rev < 32 ) {
			$old = 1;
		}
		
		if ( $old ) {
			handleError( $client->string('PLUGIN_RHAPSODY_DIRECT_FIRMWARE_UPGRADE_REQUIRED'), $client );
			return;
		}
	}
	
	# Get login info from SN if we don't already have it
	my $account = $class->getAccount($client);
	
	if ( !$account ) {
		my $accountURL = Slim::Networking::SqueezeNetwork->url( '/api/rhapsody/v1/account' );
		
		my $http = Slim::Networking::SqueezeNetwork->new(
			\&gotAccount,
			\&gotAccountError,
			{
				client => $client,
				cb     => sub {
					$class->onJump( $client, $nextURL, $callback );
				},
				ecb    => sub {
					my $error = shift;
					$error = $client->string('PLUGIN_RHAPSODY_DIRECT_ERROR_ACCOUNT') . ": $error";
					handleError( $error, $client );
				},
			},
		);
		
		$log->debug("Getting Rhapsody account from SqueezeNetwork");
		
		$http->get( $accountURL );
		
		return;
	}
	
	return if tooManySynced($client);
	
	# Clear any previous outstanding rpds queries
	cancel_rpds($client);

	# Update the 'Connecting...' text
	$client->suppressStatus(1);
	displayStatus( $client, $nextURL, 'PLUGIN_RHAPSODY_DIRECT_GETTING_TRACK_INFO', 30 );
	
	# Display buffering info on loading the next track
	$client->pluginData( showBuffering => 1 );
	
	my @clients;

	if ( Slim::Player::Sync::isSynced($client) ) {
		# if synced, send this packet to all slave players
		my $master = $client->masterOrSelf;
		push @clients, $master, @{ $master->slaves };
	}
	else {
		push @clients, $client;
	}
	
	my $url = Slim::Player::Playlist::url($client);
	
	# If user was not previously playing Rhapsody, get a new playback session first
	# XXX: it's not possible to get the previously playing track here, the playlist
	# is updated before we're called
	if ( $url !~ /^rhapd/ || $client->playmode !~ /play/ ) {
		$log->debug("Ending any previous playback session");

		for my $client ( @clients ) {
			# Clear any previous outstanding rpds queries
			cancel_rpds($client);
			
			# Clear radio data if any, so we always get a new radio track
			$client->pluginData( radioTrackURL => 0 );

			# Sometimes while changing tracks we get a 'playlist clear' after
			# this runs, so set a flag to ignore this
			$client->pluginData( trackStarting => 1 );
			
			rpds( $client, {
				data        => pack( 'c', 6 ),
				callback    => \&getPlaybackSession,
				onError     => sub {
					getPlaybackSession( $client, undef, $nextURL, $callback );
				},
				passthrough => [ $nextURL, $callback ],
			} );
		}
		
		return;
	}
	
	# For a skip use only the amount of time we've played the song
	my $songtime = Slim::Player::Source::songTime($client);

	if ( $client->playmode =~ /play/ && $songtime > 0 && !$client->pluginData('syncUnderrun') ) {

		# logMeteringInfo, param is playtime in seconds
		
		$log->debug("Track skip, logging usage info ($songtime seconds)...");
		
		my $url = Slim::Player::Playlist::url($client);

		sendLogging( $client, $url, $songtime );
	}
	
	# Clear radio data if any, so we always get a new radio track
	$client->pluginData( radioTrackURL => 0 );

	# Get the next track info
	for my $c ( @clients ) {
		getNextTrackInfo( $c, undef, $nextURL, $callback );
	}
}

sub getNextTrackInfo {
    my ( $client, undef, $nextURL, $callback ) = @_;

	# Radio mode, get next track ID
	if ( my ($stationId) = $nextURL =~ m{rhapd://(.+)\.rdr} ) {
		# Check if we've got the next track URL
		if ( my $radioTrackURL = $client->pluginData('radioTrackURL') ) {
			$nextURL = $radioTrackURL;

			$log->debug("Radio mode: Next track is $nextURL");
		}
		else {
			
			if ( Slim::Player::Sync::isSynced($client) && !Slim::Player::Sync::isMaster($client) ) {
				$log->debug('Radio mode: Letting master get next track');
			}
			else {
				# Get the next track and call us back
				$log->debug("Radio mode: Getting next track ($nextURL)...");
		
				getNextRadioTrack( $client, {
					stationId   => $stationId,
					callback    => \&getNextTrackInfo,
					passthrough => [ $client, undef, $nextURL, $callback ],
				} );
				
				return;
			}
		}
	}
	
	# If synced and we're not the last player to get here, don't do anything
	if ( Slim::Player::Sync::isSynced($client) ) {
		my $ready     = $client->pluginData('syncReady') || 1;
		my $syncCount = scalar @{ $client->masterOrSelf->slaves } + 1;
		
		if ( $ready == $syncCount ) {
			$log->debug( 'All synced players ready for track info' );
			$client->pluginData( syncReady => 0 );
		}
		else {
			$log->debug( 'Waiting for ' . ( $syncCount - $ready ) . ' more player(s) before getting track info' );
			$client->pluginData( syncReady => $ready + 1 );
			return;
		}
	}
	
	# When synced, the below code is run for only the last player to reach here
	
	# Get track URL for the next track
	my ($trackId) = $nextURL =~ m{rhapd://(.+)\.mp3};
	
	my @clients;
	
	if ( Slim::Player::Sync::isSynced($client) ) {
		# if synced, send this packet to all slave players
		my $master = $client->masterOrSelf;
		push @clients, $master, @{ $master->slaves };
	}
	else {
		push @clients, $client;
	}
	
	for my $client ( @clients ) {
		rpds( $client, {
			data        => pack( 'cC/a*', 3, $trackId ),
			callback    => \&gotTrackInfo,
			onError     => \&gotTrackError,
			passthrough => [ $nextURL, $callback ],
		} );
	}
}

# On an underrun, restart radio or skip to next track
sub onUnderrun {
	my ( $class, $client, $url, $callback ) = @_;

	if ( Slim::Player::Sync::isSynced($client) ) {
		$log->debug("Ignoring underrun while synced");
		$client->pluginData( syncUnderrun => 1 );
		$callback->();
		return;
	}

	if ( $log->is_debug ) {
		$log->debug( 'Underrun, stopping, playmode: ' . $client->playmode );
	}
	
	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		SDI::Service::EventLog->log(
			$client, 'rhapsody_underrun'
		);
	}
	
	# If it was a radio track, play again, we'll get a new track
	if ( $url =~ /\.rdr$/ ) {
		$log->debug('Radio track failed, trying to restart');
		
		# Clear radio data if any, so we always get a new radio track
		$client->pluginData( radioTrackURL => 0 );
		
		$client->execute([ 'playlist', 'play', $url ]);
	}
	else {
		# Skip to the next track if possible
		
		my $nextsong = Slim::Player::Source::nextsong($client);
		if ( $client->playmode !~ /stop/ && defined $nextsong ) {
			
			# Force playmode to playout-stop so Source doesn't try to skipahead
			$client->playmode( 'playout-stop' );
			
			# This is on a timer so the underrun callback will stop the player first
			Slim::Utils::Timers::setTimer(
				$client,
				Time::HiRes::time(),
				sub {
					my $client = shift;
					$log->debug("Skipping to next track ($nextsong)");
					$client->execute([ 'playlist', 'jump', $nextsong ]);
				},
			);
		}
	}
	
	$callback->();
}

sub gotBulkMetadata {
	my $http   = shift;
	my $client = $http->params->{client};
	
	$client->pluginData( fetchingMeta => 0 );
	
	my $info = eval { from_json( $http->content ) };
	
	if ( $@ || ref $info ne 'ARRAY' ) {
		$log->error( "Error fetching track metadata: " . ( $@ || 'Invalid JSON response' ) );
		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Caching metadata for " . scalar( @{$info} ) . " tracks" );
	}
	
	# Cache metadata
	my $cache = Slim::Utils::Cache->new;
	my $icon  = Slim::Plugin::RhapsodyDirect::Plugin->_pluginDataFor('icon');

	for my $track ( @{$info} ) {
		next unless ref $track eq 'HASH';
		
		# cache the metadata we need for display
		my $trackId = delete $track->{trackId};
		
		my $meta = {
			%{$track},
			bitrate   => '192k CBR',
			type      => 'MP3 (Rhapsody)',
			info_link => 'plugins/rhapsodydirect/trackinfo.html',
			icon      => $icon,
		};
	
		$cache->set( 'rhapsody_meta_' . $trackId, $meta, 86400 );
	}
	
	# Update the playlist time so the web will refresh, etc
	$client->currentPlaylistUpdateTime( Time::HiRes::time() );
}

sub gotBulkMetadataError {
	my $http   = shift;
	my $client = $http->params('client');
	my $error  = $http->error;
	
	$log->warn("Error getting track metadata from SN: $error");
}

sub getNextRadioTrack {
	my ( $client, $params ) = @_;
	
	my $stationId = $params->{stationId};
	
	# Talk to SN and get the next track to play
	my $radioURL = Slim::Networking::SqueezeNetwork->url(
		"/api/rhapsody/v1/radio/getNextTrack?stationId=$stationId"
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		\&gotNextRadioTrack,
		\&gotNextRadioTrackError,
		{
			client => $client,
			params => $params,
		},
	);
	
	$log->debug("Getting next radio track from SqueezeNetwork");
	
	$http->get( $radioURL );
}

sub gotNextRadioTrack {
	my $http   = shift;
	my $client = $http->params->{client};
	my $params = $http->params->{params};
	
	my $track = eval { from_json( $http->content ) };
	
	if ( $log->is_debug ) {
		$log->debug( 'Got next radio track: ' . Data::Dump::dump($track) );
	}
	
	if ( $track->{error} ) {
		# We didn't get the next track to play
		
		my $url = Slim::Player::Playlist::url($client);
		if ( $url && $url =~ /\.rdr/ ) {
			# User was already playing, display 'unable to get track' error
			Slim::Music::Info::setCurrentTitle( $url, $client->string('PLUGIN_RHAPSODY_DIRECT_NO_NEXT_TRACK') );
		
			$client->update();

			Slim::Player::Source::playmode( $client, 'stop' );
		}
		else {
			# User was just starting a radio station
			my $line1 = $client->string('PLUGIN_RHAPSODY_DIRECT_ERROR');
			my $line2 = $client->string('PLUGIN_RHAPSODY_DIRECT_NO_TRACK');
			
			$client->showBriefly( {
				line1 => $line1,
				line2 => $line2,
				jive  => {
					type => 'popupplay',
					text => [ $line1, $line2 ],
				},
			},
			{
				scroll => 1,
			} );
		}
		
		return;
	}
	
	# Save existing repeat setting
	my $repeat = Slim::Player::Playlist::repeat($client);
	if ( $repeat != 2 ) {
		$log->debug( "Saving existing repeat value: $repeat" );
		$client->pluginData( oldRepeat => $repeat );
	}
	
	# Watch for playlist commands in radio mode
	Slim::Control::Request::subscribe( 
		\&playlistCallback, 
		[['playlist'], ['repeat', 'newsong']],
		$client,
	);

	# Force repeating for Rhapsody radio
	$client->execute(["playlist", "repeat", 2]);

	# set metadata for track, will be set on playlist newsong callback
	my $url   = 'rhapd://' . $track->{trackId} . '.mp3';
	my $title = $track->{name} . ' ' . 
			$client->string('BY') . ' ' . $track->{displayArtistName} . ' ' . 
			$client->string('FROM') . ' ' . $track->{displayAlbumName};
	
	$client->pluginData( radioTrackURL => $url );
	$client->pluginData( radioTitle    => $title );
	$client->pluginData( radioTrack    => $track );
	
	# We already have the metadata for this track, so can save calling getTrack
	my $meta = {
		artist    => $track->{displayArtistName},
		album     => $track->{displayAlbumName},
		title     => $track->{name},
		cover     => $track->{cover},
		bitrate   => '192k CBR',
		type      => 'MP3 (Rhapsody)',
		info_link => 'plugins/rhapsodydirect/trackinfo.html',
		icon      => Slim::Plugin::RhapsodyDirect::Plugin->_pluginDataFor('icon'),
		buttons   => {
			# disable REW/Previous button in radio mode
			rew => 0,
		},
	};
	
	my $cache = Slim::Utils::Cache->new;
	$cache->set( 'rhapsody_meta_' . $track->{trackId}, $meta, 86400 );
	
	my $cb = $params->{callback};
	my $pt = $params->{passthrough} || [];
	$cb->( @{$pt} );
}

sub gotNextRadioTrackError {
	my $http   = shift;
	my $client = $http->params('client');
	
	handleError( $http->error, $client );
}

sub playlistCallback {
	my $request = shift;
	my $client  = $request->client();
	my $p1      = $request->getRequest(1);
	
	return unless defined $client;
	
	# check that user is still using Rhapsody Radio
	my $url = Slim::Player::Playlist::url($client) || return;
	
	if ( !$url || $url !~ /\.rdr$/ ) {
		# User stopped playing Rhapsody Radio, reset old repeat setting if any
		my $repeat = $client->pluginData('oldRepeat');
		if ( defined $repeat ) {
			$log->debug( "Stopped Rhapsody Radio, restoring old repeat setting: $repeat" );
			$client->execute(["playlist", "repeat", $repeat]);
		}

		$log->debug( "Stopped Rhapsody Radio, unsubscribing from playlistCallback" );
		Slim::Control::Request::unsubscribe( \&playlistCallback, $client );
		
		return;
	}
	
	# The user has changed the repeat setting.  Radio requires a repeat
	# setting of '2' (repeat all) to work properly
	if ( $p1 eq 'repeat' ) {
		if ( $request->getParam('_newvalue') != 2 ) {
			$log->debug("Radio mode, user changed repeat setting, forcing back to 2");
		
			$client->execute(["playlist", "repeat", 2]);
		
			if ( $client->playmode =~ /playout/ ) {
				$client->playmode( 'playout-play' );
			}
		}
	}
	elsif ( $p1 eq 'newsong' ) {
		# A new song has started playing.  We use this to change titles
		
		my $title = $client->pluginData('radioTitle');
		
		$log->debug("Setting title for radio station to $title");
		
		Slim::Music::Info::setCurrentTitle( $url, $title );
	}
}

sub gotTrackInfo {
	my ( $client, $mediaUrl, $url, $callback ) = @_;
	
	(undef, $mediaUrl) = unpack 'cn/a*', $mediaUrl;
	
	my ($trackId) = $url =~ m{rhapd://(.+)\.mp3};
	
	# Save the media URL for use in strm
	$client->pluginData( mediaUrl => $mediaUrl );
	
	# Allow status updates again
	$client->suppressStatus(0);
	
	# Clear radio error counter
	$client->pluginData( radioError => 0 );
	
	# Clear syncUnderrun flag
	$client->pluginData( syncUnderrun => 0 );
	
	# Async resolve the hostname so gethostbyname in Player::Squeezebox::stream doesn't block
	# When done, callback to Scanner, which will continue on to playback
	# This is a callback to Source::decoderUnderrun if we are loading the next track
	my $done = sub {
		my $dns = Slim::Networking::Async->new;
		$dns->open( {
			Host        => URI->new($mediaUrl)->host,
			Timeout     => 3, # Default timeout of 10 is too long, 
			                  # by the time it fails player will underrun and stop
			onDNS       => $callback,
			onError     => $callback, # even if it errors, keep going
			passthrough => [],
		} );
	};
	
	if ( !Slim::Player::Sync::isSynced($client) ) {
		$done->();
	}
	else {
		# Bug 8122, wait until all synced players have a response to rpds 3 before continuing
		my $ready     = $client->pluginData('syncReady') || 1;
		my $syncCount = scalar @{ $client->masterOrSelf->slaves } + 1;
		
		if ( $ready == $syncCount ) {
			$log->debug( 'All synced players have track info, beginning playback' );
			$client->pluginData( syncReady => 0 );
			$done->();
		}
		else {
			$log->debug( 'Waiting for ' . ( $syncCount - $ready ) . ' more player(s) to get track info' );
			$client->pluginData( syncReady => $ready + 1 );
		}
	}
	
	# Watch for stop commands for logging purposes
	Slim::Control::Request::subscribe( 
		\&stopCallback, 
		[['stop', 'playlist']],
		$client,
	);
	
	# Clear the trackStarting flag
	$client->pluginData( trackStarting => 0 );
}

sub gotTrackError {
	my ( $error, $client ) = @_;
	
	$log->debug("Error during getTrackInfo: $error");
	
	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		SDI::Service::EventLog->log(
			$client, 'rhapsody_track_error', $error
		);
	}
	
	my $url = Slim::Player::Playlist::url($client);
	
	if ( $url =~ /\.rdr$/ ) {
		# In radio mode, try to restart one time		
		# If we've already tried and get another error,
		# give up so we don't loop forever
		
		if ( $client->pluginData('radioError') ) {
			$client->execute([ 'stop' ]);
			handleError( $error, $client );
		}
		else {
			$client->pluginData( radioError => 1 );
			$client->execute([ 'playlist', 'play', $url ]);
		}
		
		return;
	}
	
	# Normal playlist mode: Skip forward 1 unless we are at the end of the playlist
	if ( Slim::Player::Source::noMoreValidTracks($client) ) {
		# Stop and display error when there are no more tracks to try
		$client->execute([ 'stop' ]);
		handleError( $error, $client );
	}
	else {
		$client->execute([ 'playlist', 'jump', '+1' ]);
		#Slim::Player::Source::jumpto( $client, '+1' );
	}
}

sub canDirectStream {
	my ( $class, $client, $url ) = @_;
	
	# Might be a radio station
	if ( my ($stationId) = $url =~ m{rhapd://(.+)\.rdr} ) {
		if ( my $radioTrackURL = $client->pluginData('radioTrackURL') ) {
			$url = $radioTrackURL;
		}
	}
	
	# Return the RAD URL here
	my ($trackId) = $url =~ m{rhapd://(.+)\.mp3};
	
	# Needed so stopCallback can have the URL after a 'playlist clear'
	$client->pluginData( lastURL => $url );
	
	my $mediaUrl = $client->pluginData('mediaUrl');

	return $mediaUrl || 0;
}

sub stopCallback {
	my $request = shift;
	my $client  = $request->client();
	my $p0      = $request->getRequest(0);
	my $p1      = $request->getRequest(1) || '';
	
	return unless defined $client;
	
	# Handle 'stop' and 'playlist clear'
	if ( $p0 eq 'stop' || $p1 eq 'clear' ) {

		# Check that the user is still playing Rhapsody
		my $url = Slim::Player::Playlist::url($client) || $client->pluginData('lastURL');

		if ( !$url || $url !~ /^rhapd/ ) {
			# stop listening for stop events
			$log->debug("No longer playing Rhapsody, ignoring (URL: $url)");
			Slim::Control::Request::unsubscribe( \&stopCallback, $client );
			return;
		}
		
		# Ignore if a new track is already starting
		if ( $client->pluginData('trackStarting') ) {
			$log->debug("Player stopped ($p0 $p1) but another track was already starting, ignoring");
			return;
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			SDI::Service::EventLog->log(
				$client, 'rhapsody_stop'
			);
		}

		my $songtime = Slim::Player::Source::songTime($client);
		
		if ( $songtime > 0 ) {	
			$log->debug("Player stopped ($p0 $p1), logging usage info ($songtime seconds)...");
			
			my $url = Slim::Player::Playlist::url($client);

			sendLogging( $client, $url, $songtime );
		}
		else {
			$log->debug("Player stopped ($p0 $p1) but songtime was $songtime, ignoring");
		}
		
		# End playback session on all synced players
		my @clients;

		if ( Slim::Player::Sync::isSynced($client) ) {
			# if synced, send this packet to all slave players
			my $master = Slim::Player::Sync::masterOrSelf($client);
			push @clients, $master, @{ $master->slaves };
		}
		else {
			push @clients, $client;
		}
		
		for my $client ( @clients ) {
			endPlaybackSession($client);
		}
	}
}

sub endPlaybackSession {
	my $client = shift;
	
	rpds( $client, {
		data        => pack( 'c', 6 ),
		callback    => sub {},
		onError     => sub {},
		passthrough => [],
	} );
}

sub displayStatus {
	my ( $client, $url, $string, $time ) = @_;
	
	my $line1 = $client->string('NOW_PLAYING') . ' (' . $client->string($string) . ')';
	my $line2 = Slim::Music::Info::title($url) || $url;
	
	if ( $client->linesPerScreen() == 1 ) {
		$line2 = $client->string($string);
	}

	$client->showBriefly( {
		line => [ $line1, $line2 ],
	}, $time );
}

# URL used for CLI trackinfo queries
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	
	my $stationId;
	
	if ( $url =~ m{rhapd://(.+)\.rdr} ) {
		# Radio mode, pull track ID from lastURL
		$url = $client->pluginData('lastURL');
		$stationId = $1;
	}

	my ($trackId) = $url =~ m{rhapd://(.+)\.mp3};
	
	# SN URL to fetch track info menu
	my $trackInfoURL = Slim::Networking::SqueezeNetwork->url(
		'/api/rhapsody/v1/opml/metadata/getTrack?trackId=' . $trackId
	);
	
	if ( $stationId ) {
		$trackInfoURL .= '&stationId=' . $stationId;
	}
	
	return $trackInfoURL;
}

# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;
	
	my $url          = $track->url;
	my $trackInfoURL = $class->trackInfoURL( $client, $url );
	
	# let XMLBrowser handle all our display
	my %params = (
		header   => 'PLUGIN_RHAPSODY_DIRECT_GETTING_TRACK_DETAILS',
		modeName => 'Rhapsody Now Playing',
		title    => Slim::Music::Info::getCurrentTitle( $client, $url ),
		url      => $trackInfoURL,
	);
	
	$log->debug( "Getting track information for $url" );

	Slim::Buttons::Common::pushMode( $client, 'xmlbrowser', \%params );
	
	$client->modeParam( 'handledTransition', 1 );
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	
	if ( $url =~ /\.rdr$/ ) {
		$url = $client->pluginData('radioTrackURL');
	}
	
	return {} unless $url;
	
	my $cache = Slim::Utils::Cache->new;
	
	# If metadata is not here, fetch it so the next poll will include the data
	my ($trackId) = $url =~ m{rhapd://(.+)\.mp3};
	
	if ( !$trackId ) {
		$log->error( "getMetadataFor for bad URL: $url" );
		return {};
	}
	
	my $meta = $cache->get( 'rhapsody_meta_' . $trackId );
	
	if ( !$meta && !$client->pluginData('fetchingMeta') ) {
		# Go fetch metadata for all tracks on the playlist without metadata
		my @need;
		
		for my $track ( @{ $client->playlist } ) {
			my $trackURL = blessed($track) ? $track->url : $track;
			if ( $trackURL =~ m{rhapd://(.+)\.mp3} ) {
				my $id = $1;
				if ( !$cache->get("rhapsody_meta_$id") ) {
					push @need, $id;
				}
			}
		}
		
		if ( $log->is_debug ) {
			$log->debug( "Need to fetch metadata for: " . join( ', ', @need ) );
		}
		
		$client->pluginData( fetchingMeta => 1 );
		
		my $url = Slim::Networking::SqueezeNetwork->url(
			"/api/rhapsody/v1/playback/getBulkMetadata"
		);
		
		my $http = Slim::Networking::SqueezeNetwork->new(
			\&gotBulkMetadata,
			\&gotBulkMetadataError,
			{
				client  => $client,
				timeout => 60,
			},
		);

		$http->post(
			$url,
			'Content-Type' => 'application/x-www-form-urlencoded',
			'trackIds=' . join( ',', @need ),
		);
	}
	
	my $icon = $class->getIcon();
	
	return $meta || {
		bitrate   => '192k CBR',
		type      => 'MP3 (Rhapsody)',
		icon      => $icon,
		cover     => $icon,
	};
}

sub getUsername {
	my $client = shift;
	
	if ( main::SLIM_SERVICE ) {
		my @username = $prefs->client($client)->get('plugin_rhapsody_direct_username');
		
		if ( scalar @username > 1 ) {
			if ( my $default = $prefs->client($client)->get('plugin_rhapsody_direct_account') ) {
				return $default;
			}
		}
		
		return $username[0];
	}
	else {
	 	my $account = $client->pluginData('account') || return;
	
		my $username = $account->{username}->[0];
	
		if ( $account->{defaults} ) {
			if ( my $default = $account->{defaults}->{ $client->id } ) {
				return $default;
			}
		}
	
		return $username;
	}
}	

sub sendLogging {
	my ( $client, $url, $playtime ) = @_;
	
	my ($trackId)   = $url =~ m{rhapd://(.+)\.mp3};
	my ($stationId) = $url =~ m{rhapd://(.+)\.rdr};
	
	if ( $stationId ) {
		my $radioURL = $client->pluginData('radioTrackURL') || return;
		($trackId) = $radioURL =~ m{rhapd://(.+)\.mp3};
	}
	else {
		$stationId = '';
	}
	
	return unless $trackId;
	
	my $logURL = Slim::Networking::SqueezeNetwork->url(
		"/api/rhapsody/v1/playback/log?stationId=$stationId&trackId=$trackId&playtime=$playtime"
	);
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		sub {
			if ( $log->is_debug ) {
				my $http = shift;
				$log->debug( "Logging returned: " . $http->content );
			}
		},
		sub {},
		{
			client => $client,
		},
	);
	
	$log->debug("Logging track playback: $playtime seconds, trackId: $trackId, stationId: $stationId");
	
	$http->get( $logURL );
}

sub getIcon {
	my ( $class, $url ) = @_;

	return Slim::Plugin::RhapsodyDirect::Plugin->_pluginDataFor('icon');
}

# SN only, re-init upon reconnection
sub reinit {
	my ( $class, $client, $playlist, $currentSong ) = @_;
	
	$log->debug('Re-init Rhapsody');
	
	SDI::Service::EventLog->log(
		$client, 'rhapsody_reconnect'
	);
	
	# If in radio mode, re-add only the single item
	if ( scalar @{$playlist} == 1 && $playlist->[0] =~ /\.rdr$/ ) {
		$client->execute([ 'playlist', 'add', $playlist->[0] ]);
	}
	else {	
		# Re-add all playlist items
		$client->execute([ 'playlist', 'addtracks', 'listref', $playlist ]);
	}
	
	# Make sure we are subscribed to stop/playlist commands
	# Watch for stop commands for logging purposes
	Slim::Control::Request::subscribe( 
		\&stopCallback, 
		[['stop', 'playlist']],
		$client,
	);
	
	# Reset song duration/progress bar
	my $currentURL = $playlist->[ $currentSong ];
	
	if ( my $length = $client->pluginData('length') ) {			
		# On a timer because $client->currentsongqueue does not exist yet
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time(),
			sub {
				my $client = shift;
				
				$client->streamingProgressBar( {
					url     => $currentURL,
					length  => $length,
					bitrate => 128000,
				} );
				
				# If it's a radio station, reset the title
				if ( my ($stationId) = $currentURL =~ m{rhapd://(.+)\.rdr} ) {
					my $title = $client->pluginData('radioTitle');

					$log->debug("Resetting title for radio station to $title");

					Slim::Music::Info::setCurrentTitle( $currentURL, $title );
				}
				
				# Back to Now Playing
				# This is within the timer because otherwise it will run before
				# addtracks adds all the tracks, and not jump to the correct playing item
				Slim::Buttons::Common::pushMode( $client, 'playlist' );
			},
		);
	}
}

1;
