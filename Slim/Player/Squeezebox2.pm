package Slim::Player::Squeezebox2;

# $Id: Squeezebox2.pm 23322 2008-09-28 08:26:29Z adrian $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

use strict;
use base qw(Slim::Player::Squeezebox);

use File::Spec::Functions qw(:ALL);
use File::Temp;
use IO::Socket;
use MIME::Base64;
use Scalar::Util qw(blessed);

use Slim::Formats::Playlists;
use Slim::Player::Player;
use Slim::Player::ProtocolHandlers;
use Slim::Player::Protocols::HTTP;
use Slim::Player::Protocols::MMS;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;

my $prefs = preferences('server');

my $prefslog  = logger('prefs');
my $directlog = logger('player.streaming.direct');
my $synclog   = logger('player.sync');

our $defaultPrefs = {
	'transitionType'     => 0,
	'transitionDuration' => 10,
	'transitionSmart'    => 1,
	'replayGainMode'     => 0,
	'disableDac'         => 0,
	'minSyncAdjust'      => 10,	# ms
	'snLastSyncUp'       => -1,
	'snLastSyncDown'     => -1,
	'snSyncInterval'     => 30,
};

# Keep track of direct stream redirects
our $redirects = {};

# WMA GUIDs we want to have the player send back to us
my @WMA_FILE_PROPERTIES_OBJECT_GUID              = (0x8c, 0xab, 0xdc, 0xa1, 0xa9, 0x47, 0x11, 0xcf, 0x8e, 0xe4, 0x00, 0xc0, 0x0c, 0x20, 0x53, 0x65);
my @WMA_CONTENT_DESCRIPTION_OBJECT_GUID          = (0x75, 0xB2, 0x26, 0x33, 0x66, 0x8E, 0x11, 0xCF, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C);
my @WMA_EXTENDED_CONTENT_DESCRIPTION_OBJECT_GUID = (0xd2, 0xd0, 0xa4, 0x40, 0xe3, 0x07, 0x11, 0xd2, 0x97, 0xf0, 0x00, 0xa0, 0xc9, 0x5e, 0xa8, 0x50);
my @WMA_STREAM_BITRATE_PROPERTIES_OBJECT_GUID    = (0x7b, 0xf8, 0x75, 0xce, 0x46, 0x8d, 0x11, 0xd1, 0x8d, 0x82, 0x00, 0x60, 0x97, 0xc9, 0xa2, 0xb2);

sub initPrefs {
	my $client = shift;

	# make sure any preferences unique to this client may not have set are set to the default
	$prefs->client($client)->init($defaultPrefs);

	$client->SUPER::initPrefs();
}

sub reconnect {
	my $client = shift;
	$client->SUPER::reconnect(@_);

	$client->getPlayerSetting('playername');
	$client->getPlayerSetting('disableDac');
}

sub maxBass { 50 };
sub minBass { 50 };
sub maxTreble { 50 };
sub minTreble { 50 };
sub maxPitch { 100 };
sub minPitch { 100 };

sub model {
	return 'squeezebox2';
}
sub modelName { 'Squeezebox' }

# in order of preference based on whether we're connected via wired or wireless...
sub formats {
	my $client = shift;
	
	return qw(wma ogg flc aif wav mp3);
}

# The original Squeezebox2 firmware supported a fairly narrow volume range
# below unity gain - 129 levels on a linear scale represented by a 1.7
# fixed point number (no sign, 1 integer, 7 fractional bits).
# From FW 22 onwards, volume is sent as a 16.16 value (no sign, 16 integer,
# 16 fractional bits), significantly increasing our fractional range.
# Rather than test for the firmware level, we send both values in the 
# volume message.

# We thought about sending a dB scale volume to the client, but decided 
# against it. Sending a fixed point multiplier allows us to change 
# the mapping of UI volume settings to gain as we want, without being
# constrained by any scale other than that of the fixed point range allowed
# by the client.

# Old style volume:
# we only have 129 levels to work with now, and within 100 range,
# that's pretty tight.
# this table is optimized for 40 steps (like we have in the current player UI.
my @volume_map = ( 
0, 1, 1, 1, 2, 2, 2, 3,  3,  4, 
5, 5, 6, 6, 7, 8, 9, 9, 10, 11, 
12, 13, 14, 15, 16, 16, 17, 18, 19, 20, 
22, 23, 24, 25, 26, 27, 28, 29, 30, 32, 
33, 34, 35, 37, 38, 39, 40, 42, 43, 44, 
46, 47, 48, 50, 51, 53, 54, 56, 57, 59, 
60, 61, 63, 65, 66, 68, 69, 71, 72, 74, 
75, 77, 79, 80, 82, 84, 85, 87, 89, 90, 
92, 94, 96, 97, 99, 101, 103, 104, 106, 108, 110, 
112, 113, 115, 117, 119, 121, 123, 125, 127, 128
 );

sub dBToFixed {
	my $client = shift;
	my $db = shift;

	# Map a floating point dB value to a 16.16 fixed point value to
	# send as a new style volume to SB2 (FW 22+).
	my $floatmult = 10 ** ($db/20);
	
	# use 8 bits of accuracy for dB values greater than -30dB to avoid rounding errors
	if ($db >= -30 && $db <= 0) {
		return int($floatmult * (1 << 8) + 0.5) * (1 << 8);
	}
	else {
		return int(($floatmult * (1 << 16)) + 0.5);
	}
}
sub getVolumeParameters
{
	# A negative stepPoint ensures that the alternate (low level) ramp never kicks in.
	my $params = 
	{
		totalVolumeRange => -50,    # dB
		stepPoint        => -1,    # Number of steps, up from the bottom, where a 2nd volume ramp kicks in.
		stepFraction     => 1      # fraction of totalVolumeRange where alternate volume ramp kicks in.
	};
	return $params;
}

sub getVolume
{
	my ($client, $volume, $volume_parameters) = @_;
	my $totalVolumeRange  = $volume_parameters->{totalVolumeRange};
	my $stepPoint         = $volume_parameters->{stepPoint};
	my $stepdB            = $volume_parameters->{totalVolumeRange} * $volume_parameters->{stepFraction};

	my $maxVolumedB = (defined $volume_parameters->{maximumVolume}) ? $volume_parameters->{maximumVolume} : 0;
	
	# Equation for a line:  
	# y = mx+b
	# y1 = mx1+b, y2 = mx2+b.  
	# y2-y1 = m(x2 - x1)
	# y2 = m(x2 - x1) + y1
	my $slope_high = ($maxVolumedB-$stepdB)/(100-$stepPoint) ;
	my $slope_low  = ($stepdB-$totalVolumeRange)/($stepPoint-0);
	
	my $x2 = $volume;
	my $m  = undef;
	my $x1 = undef;
	my $y1 = undef;
	if ($x2 > $stepPoint) {
		$m  = $slope_high;
		$x1 = 100;
		$y1 = $maxVolumedB;;
	} else {
		$m  = $slope_low;
		$x1 = 0;
		$y1 = $totalVolumeRange;
	}
	my $y2 = $m * ($x2 - $x1) + $y1;
	# print "$m, ($x1, $y1), ($x2, $y2)\n";
	return $y2;
	
}

sub volume {
	my $client = shift;
	my $newvolume = shift;

	my $volume = $client->Slim::Player::Client::volume($newvolume, @_);
	my $preamp = 255 - int(2 * $prefs->client($client)->get('preampVolumeControl'));

	if (defined($newvolume)) {
		# Old style volume:
		my $oldGain = $volume_map[int($volume)];
		
		my $newGain;
		if ($volume == 0) {
			$newGain = 0;
		}
		else {
			my $db = $client->getVolume($volume, $client->getVolumeParameters());
			$newGain = $client->dBToFixed($db);
		}

		my $data = pack('NNCCNN', $oldGain, $oldGain, $prefs->client($client)->get('digitalVolumeControl'), $preamp, $newGain, $newGain);
		$client->sendFrame('audg', \$data);
	}
	return $volume;
}

sub upgradeFirmware {
	my $client = shift;

	my $to_version = $client->needsUpgrade();
	my $log        = logger('player.firmware');

	if (!$to_version) {

		$to_version = $client->revision;

		$log->warn("upgrading to same rev: $to_version");
	}

	my $file = catdir( Slim::Utils::OSDetect::dirsFor('Firmware'), $client->model . "_$to_version.bin" );

	if (!-f $file) {

		logWarning("File does not exist: $file");

		# display an error message
		$client->showBriefly( {
			'line' => [ $client->string( 'FIRMWARE_MISSING' ), $client->string( 'FIRMWARE_MISSING_DESC' ) ]
		},
		{ 
			'block'     => 1,
			'scroll'    => 1,
			'firstline' => 1,
			'callback'  => sub {
				# send upgrade done when the error message is done being displayed.  updn causes the
				# player to disconnect and reconnect, so if we do this too early the message gets lost
				$client->sendFrame('updn',\(' '));
			},
		} );

		return(0);
	}
	
	$client->stop();

	$log->info("Using new update mechanism: $file");
	
	$client->isUpgrading(1);
	
	# Notify about firmware upgrade starting
	Slim::Control::Request::notifyFromArray( $client, [ 'firmware_upgrade' ] );

	my $err = $client->upgradeFirmware_SDK5($file);

	if (defined($err)) {

		logWarning("Upgrade failed: $err");
	}
}

sub maxTransitionDuration {
	return 10;
}

sub reportsTrackStart {
	return 1;
}

sub requestStatus {
	shift->stream('t');
}

sub stop {
	my $client = shift;
	$client->SUPER::stop(@_);
	# Preemptively set the following state variables
	# to 0, since we rely on them for time display and may
	# have to wait to get a status message with the correct
	# values.
	$client->songElapsedSeconds(0);
	$client->outputBufferFullness(0);

	# update pending pref changes in the firmware
	foreach my $pref (keys %{$client->pendingPrefChanges()}) {

	    $client->setPlayerSetting($pref, $prefs->client($client)->get($pref));

	}
}

sub songElapsedSeconds {
	my $client = shift;

	# Ignore values sent by the client if we're in the stopped
	# state, since they may be out of sync.
	if (defined($_[0]) && 
	    Slim::Player::Source::playmode($client) eq 'stop') {
		$client->SUPER::songElapsedSeconds(0);
	}

	return $client->SUPER::songElapsedSeconds(@_);
}

sub canDirectStream {
	my $client = shift;
	my $url = shift;

	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

	if ($handler && $handler->can("canDirectStream")) {
		return $handler->canDirectStream($client, $url);
	}

	return undef;
}
	
sub directHeaders {
	my $client = shift;
	my $headers = shift;

	$directlog->is_info && $directlog->info("Processing headers for direct streaming:\n$headers");

	my $url = $client->directURL || return;
	
	# We involve the protocol handler in the header parsing process.
	# The current iteration of the firmware only knows about HTTP 
	# headers. Specifically, it returns headers after finding a 
	# CRLF pair in the stream. In the future, we could tell the firmware
	# to return a specific number of bytes or look for a specific 
	# byte sequence and make this less HTTP specific. For now, we only
	# support this type of direct streaming for HTTP-esque protocols.
	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);	

	# Trim embedded nulls 
	$headers =~ s/[\0]*$//;

	$headers =~ s/\r/\n/g;
	$headers =~ s/\n\n/\n/g;

	my @headers = split "\n", $headers;

	chomp(@headers);
	
	my $response = shift @headers;
	
	if (!$response || $response !~ m/ (\d\d\d)/) {

		$directlog->warn("Invalid response code ($response) from remote stream $url");

		$client->failedDirectStream($response);

	} else {
	
		my $status_line = $response;
		$response = $1;
		
		if (($response < 200) || $response > 399) {

			$directlog->warn("Invalid response code ($response) from remote stream $url");

			if ($handler && $handler->can("handleDirectError")) {

				$handler->handleDirectError($client, $url, $response, $status_line);
			}
			else {
				$client->failedDirectStream($status_line);
			}

		} else {
			my $redir = '';
			my $metaint = 0;
			my @guids = ();
			my $guids_length = 0;
			my $length;
			my $title;
			my $contentType = "audio/mpeg";  # assume it's audio.  Some servers don't send a content type.
			my $bitrate;
			my $body;

			if ( $directlog->is_info ) {
				$directlog->info("Processing " . scalar(@headers) . " headers");
			}

			if ($handler && $handler->can("parseDirectHeaders")) {
				# Could use a hash ref for header parameters
				($title, $bitrate, $metaint, $redir, $contentType, $length, $body) = $handler->parseDirectHeaders($client, $url, @headers);
			}

			# update bitrate, content-type title for this URL...
			Slim::Music::Info::setContentType($url, $contentType) if $contentType;
			Slim::Music::Info::setBitrate($url, $bitrate) if $bitrate;
			
			# Always prefer the title returned in the headers of a radio station
			if ( $title ) {
				$directlog->is_info && $directlog->info( "Setting new title for $url, $title" );
				Slim::Music::Info::setCurrentTitle( $url, $title );
				
				# Bug 7979, Only update the database title if this item doesn't already have a title
				my $curTitle = Slim::Music::Info::title($url);
				if ( !$curTitle || $curTitle =~ /^(?:http|mms)/ ) {
					Slim::Music::Info::setTitle( $url, $title );
				}
			}
			
			# Bitrate may have been set in Scanner by reading the mp3 stream
			if ( !$bitrate ) {
				$bitrate = Slim::Music::Info::getBitrate( $url );
			}
			
			# WMA handles duration based on metadata
			if ( $contentType ne 'wma' ) {
				
				# See if we have an existing track object with duration info for this stream.
				if ( my $secs = Slim::Music::Info::getDuration($url) ) {
				
					# Display progress bar
					$client->streamingProgressBar( {
						'url'      => $redirects->{ $url } || $url,
						'duration' => $secs,
					} );
				}
				else {
			
					if ( $bitrate && $length && $bitrate > 0 && $length > 0 && !$client->shouldLoop($length) ) {
						# if we know the bitrate and length of a stream, display a progress bar
						if ( $bitrate < 1000 ) {
							$bitrate *= 1000;
						}
						$client->streamingProgressBar( {
							'url'     => $redirects->{ $url } || $url,
							'bitrate' => $bitrate,
							'length'  => $length,
						} );
					}
				}
			}

			$directlog->is_info && $directlog->info("Got a stream type: $contentType bitrate: $bitrate title: $title");

			if ($contentType eq 'wma') {
				push @guids, @WMA_FILE_PROPERTIES_OBJECT_GUID;
				push @guids, @WMA_CONTENT_DESCRIPTION_OBJECT_GUID;
				push @guids, @WMA_EXTENDED_CONTENT_DESCRIPTION_OBJECT_GUID;
				push @guids, @WMA_STREAM_BITRATE_PROPERTIES_OBJECT_GUID;

			    $guids_length = scalar @guids;

			    # sending a length of -1 will return all wma header objects
			    # for debugging
			    ##@guids = ();
			    ##$guids_length = -1;
			}

			if ($redir) {

				$directlog->is_info && $directlog->info("Redirecting to: $redir");
				
				# Store the old URL so we can update its bitrate/content-type/etc
				$redirects->{ $redir } = $url;			
				
				$client->stop();

				$client->play({
					'paused' => Slim::Player::Sync::isSynced($client), 
					'format' => ($client->masterOrSelf())->streamformat(), 
					'url'    => $redir,
				});

			} elsif ($body || Slim::Music::Info::isList($url)) {

				$directlog->info("Direct stream is list, get body to explode");

				$client->directBody(undef);

				# we've got a playlist in all likelyhood, have the player send it to us
				$client->sendFrame('body', \(pack('N', $length)));

			} elsif ($client->contentTypeSupported($contentType)) {
				
				# If we redirected (Live365), update the original URL with the metadata from the real URL
				if ( my $oldURL = delete $redirects->{ $url } ) {
					Slim::Music::Info::setContentType( $oldURL, $contentType ) if $contentType;
					Slim::Music::Info::setBitrate( $oldURL, $bitrate ) if $bitrate;
					
					# carry the original title forward to the new URL
					my $title = Slim::Music::Info::title( $oldURL );
					Slim::Music::Info::setTitle( $url, $title ) if $title;
				}

				$directlog->is_info && $directlog->info("Beginning direct stream!");

				my $loop = $client->shouldLoop($length);
				
				# Some looping sounds are too short and mess up the buffer secs
				# This will let quickstart avoid buffering these tracks too long
				if ( $loop ) {
					Slim::Music::Info::setDuration( $url, 0 );
					
					$directlog->info('Using infinite loop mode');
				}

				$client->streamformat($contentType);
				$client->sendFrame('cont', \(pack('NCnC*',$metaint, $loop, $guids_length, @guids)));

			} else {

				$directlog->warn("Direct stream failed for url: [$url]");

				$client->failedDirectStream();
			}
			
			# Bug 6482, refresh the cached Track object in the client playlist from the database
			# so it picks up any changed data such as title, bitrate, etc
			Slim::Player::Playlist::refreshTrack( $client, $url );
		}
	}
}

sub directBodyFrame {
	my $client  = shift;
	my $body    = shift;
	
	my $isInfo = $directlog->is_info;

	my $url     = $client->directURL();
	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
	my $done    = 0;

	$isInfo && $directlog->info("Got some body from the player, length " . length($body));
	
	if (length($body)) {

		$isInfo && $directlog->info("Saving away that body message until we get an empty body");

		if ($handler && $handler->can('handleBodyFrame')) {

			$done = $handler->handleBodyFrame($client, $body);

			if ($done) {
				$client->stop();
			}
		}
		else {
			# save direct body to a temporary file
			if ( !blessed $client->directBody ) {

				my $fh = File::Temp->new();
				$client->directBody( $fh );

				$isInfo && $directlog->info("directBodyFrame: Saving to temp file: " . $fh->filename);
			}
			
			$client->directBody->write( $body, length($body) );
		}

	} else {

		$isInfo && $directlog->info("Empty body means we should parse what we have for " . $client->directURL);

		$done = 1;
	}

	if ($done) {

		if ( defined $client->directBody ) {
			
			# seek back to the front of the file
			seek $client->directBody, 0, 0;

			my @items = ();

			# done getting body of playlist, let's parse it!
			# If the protocol handler knows how to parse it, give
			# it a chance, else we parse based on the type we know
			# already.
			if ( $handler && $handler->can('parseDirectBody') ) {
				@items = $handler->parseDirectBody( $client, $url, $client->directBody );
			}
			else {
				@items = Slim::Formats::Playlists->parseList( $url, $client->directBody );
			}
	
			if ( scalar @items ) { 

				Slim::Player::Source::explodeSong($client, \@items);
				Slim::Player::Source::playmode($client, 'play');

			} else {

				$directlog->warn("Body had no parsable items in it.");

				$client->failedDirectStream( $client->string('PLAYLIST_NO_ITEMS_FOUND') );
			}

			# Will also remove the temporary file
			$client->directBody(undef);

		} else {

			$directlog->warn("Actually, the body was empty. Got nobody...");
		}
	}
}

sub directMetadata {
	my $client = shift;
	my $metadata = shift;
	
	my $url = $client->directURL;
	my $type = Slim::Music::Info::contentType($url);
	
	if ( $type eq 'wma' ) {
		Slim::Player::Protocols::MMS::parseMetadata( $client, $url, $metadata );
	}
	else {
		Slim::Player::Protocols::HTTP::parseMetadata( $client, Slim::Player::Playlist::url($client), $metadata );
	}
	
	# new song, so reset counters
	$client->songBytes(0);
}

sub failedDirectStream {
	my $client = shift;
	my $error  = shift;

	my $url    = $client->directURL();

	$directlog->warn("Oh, well failed to do a direct stream for: $url [$error]");

	$client->directURL(undef);
	$client->directBody(undef);

	Slim::Player::Source::errorOpening( $client, $error || $client->string("PROBLEM_CONNECTING") );

	# Similar to an underrun, but only continue if we're not at the
	# end of a playlist (irrespective of the repeat mode).
	if ($client->playmode eq 'playout-play' &&
		Slim::Player::Source::streamingSongIndex($client) != (Slim::Player::Playlist::count($client) - 1)) {

		Slim::Player::Source::skipahead($client);

	} else {

		Slim::Player::Source::playmode($client, 'stop');
	}

	# 6.3 Rhapsody code added this, why?
	# 1 means underrun due to error
	# Slim::Player::Source::underrun($client, 1);
}

# Should we use the inifinite looping option that some players
# (Squeezebox2) have as an optimization?
sub shouldLoop {
	my $client     = shift;
	my $audio_size = shift;
	
	# Ask the client if the track is small enough for this
	return 0 unless ( $audio_size && $client->canLoop($audio_size) );
	
	# Check with the protocol handler
	my $url = Slim::Player::Playlist::url($client);
	
	if ( Slim::Music::Info::isRemoteURL($url) ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ( $handler && $handler->can('shouldLoop') ) {
			return $handler->shouldLoop( $client, $audio_size, $url );
		}
	}

	return 0;
}

sub canLoop {
	my $client = shift;
	my $length = shift;

	if ($length < 3*1024*1024) {
	    return 1;
	}

	return 0;
}

sub canDoReplayGain {
	my $client = shift;
	my $replay_gain = shift;

	if (defined($replay_gain)) {
		return $client->dBToFixed($replay_gain);
	}

	return 0;
}

sub hasPreAmp {
	return 1;
}

sub hasDisableDac() {
	return 1;
}

sub hasServ {
	return 1;
}

# SN only, this checks that the player's firmware version supports compression
sub hasCompression {
	return shift->revision >= 80;
}

sub audio_outputs_enable { 
	my $client = shift;
	my $enabled = shift;

	# spdif enable / dac enable
	my $data = pack('CC', $enabled, $enabled);
	$client->sendFrame('aude', \$data);
}


# The following settings are sync'd between the player firmware and SqueezeCenter
our $pref_settings = {
	'playername' => {
		firmwareid => 0,
		pack => 'Z*',
	},
	'digitalOutputEncoding' => {
		firmwareid => 1,
		pack => 'C',
	},
	'wordClockOutput' => {
		firmwareid => 2,
		pack => 'C',
	},
	'powerOffDac' => { # (Transporter only)
		firmwareid => 3,
		pack => 'C',
	},
	'disableDac' => { # (Squezebox2/3 only)
		firmwareid => 4,
		pack => 'C',
	},
	'fxloopSource' => { # (Transporter only)
		firmwareid => 5,
		pack => 'C',
	},
	'fxloopClock' => { # (Transporter only)
		firmwareid => 6,
		pack => 'C',
	},
};

$prefs->setChange( sub { my ($pref, $val, $client) = @_; $client->setPlayerSetting($pref, $val); }, keys %{$pref_settings});

# Request a pref from the player firmware
sub getPlayerSetting {
	my $client = shift;
	my $pref   = shift;

	$prefslog->is_info && $prefslog->info("Getting pref: [$pref]");

	my $currpref = $pref_settings->{$pref};

	my $data = pack('C', $currpref->{firmwareid} || 0);
	$client->sendFrame('setd', \$data);
}

# Update a pref in the player firmware
sub setPlayerSetting {
	my $client = shift;
	my $pref   = shift;
	my $value  = shift;

	return unless defined $value;
	
	my $isInfo = $prefslog->is_info;

	$isInfo && $prefslog->info("Setting pref: [$pref] to [$value]");

	my $currpref = $pref_settings->{$pref};

	if ($client->playmode() eq 'stop') {

		my $data = pack('C'.$currpref->{pack}, $currpref->{firmwareid}, $value);
		$client->sendFrame('setd', \$data);
		
		delete $client->pendingPrefChanges()->{$pref};
	}
	else {

		# we can't update the pref's while playing, cache this change for later
		$isInfo && $prefslog->info("Pending change for $pref");

		$client->pendingPrefChanges()->{$pref} = 1;
	}
}

# Allow the firmware to update a pref in SqueezeCenter
sub playerSettingsFrame {
	my $client   = shift;
	my $data_ref = shift;
	
	my $isInfo = $prefslog->is_info;

	my $id = unpack('C', $$data_ref);

	while (my ($pref, $currpref) = each %$pref_settings) {

		if ($currpref->{'firmwareid'} != $id) {
			next;
		}

		my $value = (unpack('C'.$currpref->{pack}, $$data_ref))[1];

		if (length($value) == 0) {

			$value = undef;
		}

		$isInfo && $prefslog->info(sprintf("Pref [%s] = [%s]", $pref, (defined $value ? $value : 'undef')));

		if ( !defined $value ) {
			# Only send the value to the firmware if we actually have one
			$value = $prefs->client($client)->get($pref);
			if ( defined $value ) {
				$client->setPlayerSetting( $pref, $value );
			}
		}
		else {
			$value = Slim::Utils::Unicode::utf8on($value) if $pref eq 'playername'; 
			$prefs->client($client)->set( $pref, $value );
		}
	}
}

sub resetPrefs {
	my $client = shift;

	# clear reset client prefs to default
	$client->SUPER::resetPrefs;

	# reset prefs stored on player to new values
	for my $pref (keys %$pref_settings) {
		my $value = $prefs->client($client)->get($pref);
		$client->setPlayerSetting($pref, $value);
	}
}

sub pcm_sample_rates {
	my $client = shift;
	my $track = shift;

    	my %pcm_sample_rates = ( 8000 => '5',
				 11025 => '0',
				 12000 => '6',
				 22050 => '1',
				 24000 => '8',
				 32000 => '2',
				 44100 => '3',
				 48000 => '4',
				 16000 => '7',
				 88200 => ':',
				 96000 => '9',
				 );

	my $rate = $pcm_sample_rates{$track->samplerate()};

	return defined $rate ? $rate : '3';
}

sub playPoint {
	my $client = shift;

	my ($jiffies, $elapsedMilliseconds) = Slim::Networking::Slimproto::getPlayPointData($client);

	return unless $elapsedMilliseconds;

	my $statusTime = $client->jiffiesToTimestamp($jiffies);
	my $apparentStreamStartTime = $statusTime - ($elapsedMilliseconds / 1000);

	0 && logger('player.sync')->debug($client->id() . " playPoint: jiffies=$jiffies, epoch="
		. ($client->jiffiesEpoch) . ", statusTime=$statusTime, elapsedMilliseconds=$elapsedMilliseconds");

	return [$statusTime, $apparentStreamStartTime];
}

sub startAt {
	my ($client, $at) = @_;
	
	$synclog->is_debug && $synclog->debug( $client->id, ' startAt: ' . int(($at - $client->jiffiesEpoch()) * 1000) );

	$client->stream( 'u', { 'interval' => int(($at - $client->jiffiesEpoch()) * 1000) } );
	return 1;
}

sub pauseForInterval {
	my $client   = shift;
	my $interval = shift;

	$client->stream( 'p', { 'interval' => $interval } );
	return 1;
}

sub skipAhead {
	my $client   = shift;
	my $interval = shift;

	$client->stream( 'a', { 'interval' => $interval } );
	return 1;
}

sub packetLatency {
	my $client = shift;
	my $latency = Slim::Networking::Slimproto::getLatency($client);
	return (
		defined $latency ? $latency / 1000 : $client->SUPER::packetLatency()
	);
}

1;
