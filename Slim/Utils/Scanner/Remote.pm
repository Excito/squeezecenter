package Slim::Utils::Scanner::Remote;

# $Id: Remote.pm 25586 2009-03-17 15:41:44Z andy $
#
# SqueezeCenter Copyright 2001-2008 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, version 2.

=head1 NAME

Slim::Utils::Scanner::Remote

=head1 SYNOPSIS

Slim::Utils::Scanner::Remote->scanURL( $url, {
	client => $client,
	cb     => sub { ... },
} );

=head1 DESCRIPTION

This class handles anything to do with obtaining information about a remote
music source, whether that is a playlist, mp3 stream, wma stream, remote mp3 file with
ID3 tags, etc.

=head1 METHODS

=cut

# TODO
# Build a submenu of TrackInfo to select alternate streams in remote playlists?
# Duplicate playlist items sometimes get into the DB, maybe when multiple nested playlists
#   refer to the same stream (Q-91.3 http://opml.radiotime.com/StationPlaylist.axd?stationId=22200)
# Ogg broken: http://opml.radiotime.com/StationPlaylist.axd?stationId=54657

use strict;

use Audio::WMA;
use File::Temp;
use HTTP::Request;
use IO::String;
use MP3::Info;
use Scalar::Util qw(blessed);

use Slim::Formats;
use Slim::Formats::MMS;
use Slim::Formats::Playlists;
use Slim::Networking::Async::HTTP;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $log = logger('scan.scanner');

use constant MAX_DEPTH => 7;

my %ogg_quality = (
	0  => 64000,
	1  => 80000,
	2  => 96000,
	3  => 112000,
	4  => 128000,
	5  => 160000,
	6  => 192000,
	7  => 224000,
	8  => 256000,
	9  => 320000,
	10 => 500000,
);

=head2 scanURL( $url, $args );

Scan a remote URL.  When finished, calls back to $args->{cb} with a success flag
and an error string if the scan failed.

=cut

sub scanURL {
	my ( $class, $url, $args ) = @_;
	
	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];
	
	$args->{depth} ||= 0;
	
	$log->is_debug && $log->debug( "Scanning remote stream $url" );
	
	if ( !$url ) {
		return $cb->( undef, 'SCANNER_REMOTE_NO_URL_PROVIDED', @{$pt} );
	}

	if ( !Slim::Music::Info::isRemoteURL($url) ) {
		return $cb->( undef, 'SCANNER_REMOTE_INVALID_URL', @{$pt} );
	}

	# Refuse to scan too deep in a nested playlist
	if ( $args->{depth} >= MAX_DEPTH ) {
		return $cb->( undef, 'SCANNER_REMOTE_NESTED_TOO_DEEP', @{$pt} );
	}
	
	# Get/Create a track object for this URL
	my $track = Slim::Schema->rs('Track')->updateOrCreate( {
		url => $url,
	} );
	
	# Make sure it has a title
	if ( !$track->title ) {
		$track = Slim::Music::Info::setTitle( $url, $url );
	}

	# Check if the protocol handler has a custom scanning method
	# This is used to allow plugins to add scanning routines for exteral stream types
	my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
	if ($handler && $handler->can('scanStream') ) {
		$log->is_debug && $log->debug( "Scanning remote stream $url using protocol hander $handler" );
		
		# Allow protocol hander to scan the stream and then call the callback
		$handler->scanStream($url, $track, $args);

		return;
	}
	
	# In some cases, a remote protocol may always be audio and not need scanning
	# This is not used by any core code, but some plugins require it
	my $isAudio = Slim::Music::Info::isAudioURL($url);
	
	if ( main::SLIM_SERVICE ) {
		# We use a special fragment in the URL starting with #slim to force certain things:
		# noscan - don't scan the URL, needed for UK-only stations
		# aid=N  - when not scanning, we won't know what audio stream to use, so aid will force
		#          a specific stream to use, needed for BBC which uses stream 2 for 48kbps
		#
		# Example: mms://wmlive-acl.bbc.co.uk/wms/radio1/radio1_nb_e1s1#slim:noscan=1,aid=2
		if ( $url =~ /#slim:(.+)$/ ) {
			my $opts   = $1;
			my $params = {};
			
			$url =~ s/#slim:.+$//;
			
			# XXX: may create duplicate track entries
			$track->url( $url );
			$track->update;

			for my $p ( split /,/, $opts ) {
				my ($key, $value) = split /=/, $p;
				$params->{$key} = $value;
			}
			
			if ( $params->{noscan} ) {
				$isAudio = 1;
			}
			
			if ( $params->{aid} ) {
				my $song = $args->{song};
				$song->{scanData} ||= {}; 
				$song->{scanData}->{$url} = {
					streamNum => $params->{aid},
					metadata  => undef,
					headers   => undef,
				};
			}
		}
	}
	
	if ( $isAudio ) { 	 
		$log->is_debug && $log->debug( "Remote stream $url known to be audio" ); 	 

		# Set this track's content type from protocol handler getFormatForURL method 	 
		my $type = Slim::Music::Info::typeFromPath($url);
		if ( $type eq 'unk' ) {
			$type = 'mp3';
		}
		
		$log->is_debug && $log->debug( "Content-type of $url - $type" );
		
		$track->content_type( $type );
		$track->update;

		# Success, done scanning 	 
		return $cb->( $track, undef, @{$pt} );
	}
	
	# Bug 4522, if user has disabled native WMA decoding to get MMS support, don't scan MMS URLs
	if ( $url =~ /^mms/i ) {
		
		# XXX This test will not be good enough when we get WMA proxied streaming
		if ( ! Slim::Player::TranscodingHelper::isEnabled('wma-wma-*-*') ) {
			$log->is_debug && $log->debug('Not scanning MMS URL because direct streaming disabled.');

			$track->content_type( 'wma' );

			return $cb->( $track, undef, @{$pt} );
		}
	}
	
	# Connect to the remote URL and figure out what it is
	my $request = HTTP::Request->new( GET => $url );
	
	$log->is_debug && $log->debug("Scanning remote URL $url");
	
	# Use WMP headers for MMS protocol URLs or ASF/ASX/WMA URLs
	if ( $url =~ /(?:^mms|\.asf|\.asx|\.wma)/i ) {
		addWMAHeaders( $request );
	}
	
	if ( main::SLIM_SERVICE && $url =~ /radiotime/ ) {
		# Add real client IP for Radiotime so they can do proper geo-location
		$request->header( 'X-Forwarded-For' => $client->ip );
	}
	
	my $timeout = preferences('server')->get('remotestreamtimeout') || 10;
	
	my $send = sub {
		my $http = Slim::Networking::Async::HTTP->new;
		$http->send_request( {
			request     => $request,
			onRedirect  => \&handleRedirect,
			onHeaders   => \&readRemoteHeaders,
			onError     => sub {
				my ( $http, $error ) = @_;

				logError("Can't connect to remote server to retrieve playlist: $error.");
			
				if ( main::SLIM_SERVICE ) {
					$client->logStreamEvent( 'failed-scan', { error => $error } );
				}

				return $cb->( undef, $error, @{$pt} );
			},
			passthrough => [ $track, $args ],
			Timeout     => $timeout,
		} );
	};
	
	if ( $args->{delay} ) {
		Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + $args->{delay}, $send );
	}
	else {
		$send->();
	}
}

=head2 addWMAHeaders( $request )

Adds Windows Media Player headers to the HTTP request to make it a valid 'Describe' request.
See Microsoft HTTP streaming spec for details:
http://msdn2.microsoft.com/en-us/library/cc251059.aspx

=cut

sub addWMAHeaders {
	my $request = shift;
	
	my $url = $request->uri->as_string;
	$url =~ s/^mms/http/;
	
	$request->uri( $url );
	
	my $h = $request->headers;
	$h->header( 'User-Agent' => 'NSPlayer/8.0.0.3802' );
	$h->header( Pragma => [
		'xClientGUID={' . Slim::Formats::MMS::randomGUID(). '}',
		'no-cache',
	] );
	$h->header( Connection => 'close' );
}

=head2 handleRedirect( $http, $track, $args )

Callback when Async::HTTP encounters a redirect.  If a server
redirects to an mms:// protocol URL we need to rewrite the link and set proper headers.

=cut

sub handleRedirect {
	my ( $request, $track, $args ) = @_;
	
	$log->is_debug && $log->debug( 'Server redirected to ' . $request->uri );
	
	if ( $request->uri =~ /^mms/ ) {

		if ( $log->is_debug ) {
			$log->debug("Server redirected to MMS URL: " . $request->uri . ", adding WMA headers");
		}
		
		addWMAHeaders( $request );
	}
	
	# Maintain title across redirects
	# XXX: not sure we want to do this anymore
=pod
	my $title = Slim::Music::Info::title( $track->url );
	Slim::Music::Info::setTitle( $request->uri->as_string, $title );

	if ( $log->is_debug ) {
		$log->debug( "Server redirected, copying title $title from " . $track->url . " to " . $request->uri );
	}
=cut
	
	return $request;
}

=head2 readRemoteHeaders( $http, $track, $args )

Async callback from scanURL.  The remote headers are read to determine the content-type.

=cut

sub readRemoteHeaders {
	my ( $http, $track, $args ) = @_;
	
	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];

	# $track is the track object for the original URL we scanned
	# $url is the final URL, may be different due to a redirect
	
	my $url = $http->request->uri->as_string;
	
	if ( $log->is_debug ) {
		$log->debug( "Headers for $url are " . Data::Dump::dump( $http->response->headers ) );
	}

	# Make sure the content type of the track is correct
	my $type = $http->response->content_type;

	# Content-Type may have multiple elements, i.e. audio/x-mpegurl; charset=ISO-8859-1
	if ( ref $type eq 'ARRAY' ) {
		$type = $type->[0];
	}
	
	$type = Slim::Music::Info::mimeToType($type) || $type;
	
	# Handle some special cases
	
	# Bug 3396, some m4a audio is incorrectly served as audio/mpeg.
	# In this case, prefer the file extension to the content-type
	if ( $url =~ /(m4a|aac)$/i && $type eq 'mp3' ) {
		$type = 'mov';
	}
	
	# Some Shoutcast/Icecast servers don't send content-type
	if ( !$type && $http->response->header('icy-name') ) {
		$type = 'mp3';
	}
	
	# Seen some ASX playlists served with text/plain content-type
	if ( $url =~ /\.asx$/i && $type eq 'txt' ) {
		$type = 'asx';
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Content-type for $url detected as $type (" . $http->response->content_type . ")" );
	}
	
	# Set content-type for original URL and redirected URL
	$log->is_debug && $log->debug( 'Updating content-type for ' . $track->url . " to $type" );
	$track = Slim::Music::Info::setContentType( $track->url, $type );
	
	if ( $track->url ne $url ) {
		my $update;
		
		# Don't create a duplicate object if the only difference is http:// instead of mms://
		if ( $track->url =~ m{^mms://(.+)} ) {
			if ( $url ne "http://$1" ) {
				$update = 1;
			}
		}
		else {
			$update = 1;
		}
		
		if ( $update ) {
			$log->is_debug && $log->debug( "Updating redirected URL $url" );
			
			# Get/create a new entry for the redirected track
			my $redirTrack = Slim::Schema->rs('Track')->updateOrCreate( {
				url => $url,
			} );
			
			# Copy values from original track
			$redirTrack->title( $track->title );
			$redirTrack->content_type( $track->content_type );
			$redirTrack->bitrate( $track->bitrate );
			
			$redirTrack->update;
			
			# Delete original track
			$track->delete;
			
			$track = $redirTrack;
		}
	}

	# Is this an audio stream or a playlist?
	if ( Slim::Music::Info::isSong( $track, $type ) ) {
		$log->is_info && $log->info("This URL is an audio stream [$type]: " . $track->url);
		
		if ( $type eq 'wma' ) {
			# WMA streams require extra processing, we must parse the Describe header info
			
			$log->is_debug && $log->debug('Reading WMA header');
			
			# Read the rest of the header and pass it on to parseWMAHeader
			$http->read_body( {
				readLimit   => 128 * 1024,
				onBody      => \&parseWMAHeader,
				passthrough => [ $track, $args ],
			} );
		}
		else {
			# If URL was mms but content-type is not wma, change URL
			if ( $track->url =~ /^mms/i ) {
				# XXX: may create duplicate track entries
				my $httpURL = $track->url;
				$httpURL =~ s/^mms/http/i;
				$track->url( $httpURL );
				$track->update;
			}
			
			my $bitrate;
			my $vbr = 0;
			
			# Look for Icecast info header and determine bitrate from this
			if ( my $audioinfo = $http->response->header('ice-audio-info') ) {
				($bitrate) = $audioinfo =~ /ice-(?:bitrate|quality)=([^;]+)/i;
				if ( $bitrate =~ /(\d+)/ ) {
					if ( $bitrate <= 10 ) {
						# Ogg quality, may be fractional
						my $quality = sprintf "%d", $1;
						$bitrate = $ogg_quality{$quality};
						$vbr = 1;
					
						$log->is_debug && $log->debug("Found bitrate from Ogg quality header: $bitrate");
					}
					else {					
						$log->is_debug && $log->debug("Found bitrate from ice-audio-info header: $bitrate");
					}
				}
			}
			
			# Look for bitrate information in header indicating it's an Icy stream
			elsif ( $bitrate = ( $http->response->header('icy-br') || $http->response->header('x-audiocast-bitrate') ) * 1000 ) {
				$log->is_debug && $log->debug("Found bitrate in Icy header: $bitrate");
			}
			
			if ( $bitrate ) {
				if ( $bitrate < 1000 ) {
					$bitrate *= 1000;
				}
							
				$track = Slim::Music::Info::setBitrate( $track->url, $bitrate, $vbr );
				
				if ( $track->url ne $url ) {
					Slim::Music::Info::setBitrate( $url, $bitrate, $vbr );
				}
			
				# We don't need to read any more data from this stream
				$http->disconnect;
				
				# All done
				
				# Bug 11001, if the URL uses basic authentication, it may be an Icecast
				# server that allows only 1 connection per user.  Delay this callback for a second
				# to avoid the chance of getting a 401 error when trying to stream.
				if ( $track->url =~ m{http://[^:]+:[^@]+@} ) {
					$log->is_debug && $log->debug( 'Auth stream detected, waiting 1 second before streaming' );
					
					Slim::Utils::Timers::setTimer(
						undef,
						Time::HiRes::time() + 1,
						sub {
							$cb->( $track, undef, @{$pt} );
						},
					);
				}
				else {
					$cb->( $track, undef, @{$pt} );
				}
			}
			else {
				# We still need to read more info about this stream, but we can begin playing it now
				$cb->( $track, undef, @{$pt} );
				
				# Continue scanning in the background
				
				# We may be able to determine the bitrate or other tag information
				# about this remote stream/file by reading a bit of audio data
				$log->is_debug && $log->debug('Reading audio data in the background to detect bitrate and/or tags');

				# read as much as is necessary to read all ID3v2 tags and determine bitrate
				$http->read_body( {
					onStream    => \&streamAudioData,
					passthrough => [ $track, $args, $url ],
				} );
			}
		}
	}
	else {
		$log->is_debug && $log->debug('This URL is a playlist: ' . $track->url);
		
		# Read the rest of the playlist
		$http->read_body( {
			readLimit   => 128 * 1024,
			onBody      => \&parsePlaylist,
			passthrough => [ $track, $args ],
		} );
	}
}

sub parseWMAHeader {
	my ( $http, $track, $args ) = @_;
	
	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];
	
	# The header may be at the front of the file, if the remote
	# WMA file is not a live stream
	my $io  = IO::String->new( $http->response->content_ref );
	my $wma = Audio::WMA->new( $io, length( $http->response->content ) );
	
	if ( !$wma || !ref $wma->stream ) {
		
		# it's probably a live stream, the WMA header is offset
		my $header    = $http->response->content;
		my $chunkType = unpack 'v', substr( $header, 0, 2 );
		if ( $chunkType != 0x4824 ) {
			$log->is_debug && $log->debug("WMA header does not start with 0x4824");
			
			# Delete bad item
			$track->delete;
			
			return $cb->( undef, 'ASF_UNABLE_TO_PARSE', @{$pt} );
		}
	
		# skip to the body data
		my $body = substr $header, 12;
		$io->open( \$body );
		$wma = Audio::WMA->new( $io, length($body) );
	
		if ( !$wma ) {
			$log->is_debug && $log->debug('Unable to parse WMA header');
			
			# Delete bad item
			$track->delete;
			
			return $cb->( undef, 'ASF_UNABLE_TO_PARSE', @{$pt} );
		}
	}
	
	if ( $log->is_debug ) {
		$log->debug( 'WMA header data for ' . $track->url . ': ' . Data::Dump::dump($wma) );
	}
	
	my $streamNum = 1;
	
	# Some ASF streams appear to have no stream objects (mms://ms1.capitalinteractive.co.uk/fm_high)
	# I think it's safe to just assume stream #1 in this case
	if ( ref $wma->stream ) {
		
		# Look through all available streams and select the one with the highest bitrate still below
		# the user's preferred max bitrate
		my $max = preferences('server')->get('maxWMArate') || 9999;
	
		my $bitrate = 0;
		my $valid   = 0;
		
		for my $stream ( @{ $wma->stream } ) {
			next unless defined $stream->{streamNumber};
			
			my $streamBitrate = int( $stream->{bitrate} / 1000 );
			
			# If stream is ASF_Command_Media, it may contain metadata, so let's get it
			if ( $stream->{stream_type_guid} eq '59DACFC0-59E6-11D0-A3AC-00A0C90348F6' ) {
				$log->is_debug && $log->debug( "Possible ASF_Command_Media metadata stream: \#$stream->{streamNumber}, $streamBitrate kbps" );
				$args->{song}->{wmaMetadataStream} = $stream->{streamNumber};
				next;
			}

			# Skip non-audio streams or audio codecs we can't play
			# The firmware supports 2 codecs:
			# Windows Media Audio V7 / V8 / V9 (0x0161)
			# Windows Media Audio 9 Voice (0x000A)
			next unless $stream->{audio} && (
				$stream->{audio}->{codec} eq 'Windows Media Audio V7 / V8 / V9'
				||
				$stream->{audio}->{codec} eq 'Windows Media Audio 9 Voice'
			);
		
			$log->is_debug && $log->debug( "Available stream: \#$stream->{streamNumber}, $streamBitrate kbps" );

			if ( $stream->{bitrate} > $bitrate && $max >= $streamBitrate ) {
				$streamNum = $stream->{streamNumber};
				$bitrate   = $stream->{bitrate};
			}
			
			$valid++;
		}
		
		# If we saw no valid streams, such as a stream with only MP3 codec, give up
		if ( !$valid ) {
			$log->is_debug && $log->debug('WMA contains no valid audio streams');
			
			# Delete bad item
			$track->delete;
			
			return $cb->( undef, 'ASF_UNABLE_TO_PARSE', @{$pt} );
		}
	
		if ( !$bitrate && ref $wma->stream(0) ) {
			# maybe we couldn't parse bitrate information, so just use the first stream
			$streamNum = $wma->stream(0)->{streamNumber};
		}
		
		if ( $bitrate ) {
			$track = Slim::Music::Info::setBitrate( $track->url, $bitrate );
		}

		if ( $log->is_debug ) {
			$log->debug( sprintf( "Will play stream #%d, bitrate: %s kbps",
				$streamNum,
				$bitrate ? int( $bitrate / 1000 ) : 'unknown',
			) );
		}
	}
	
	# Set duration if available and this is not a broadcast stream
	if ( my $secs = $wma->info('playtime_seconds') ) {
		if ( $secs > 0 && !( $wma->info('flags') && $wma->info('flags')->{'broadcast'} == 1 ) ) {
			$track= Slim::Music::Info::setDuration( $track->url, $secs );
		}
	}
	
	# Save this metadata for the MMS protocol handler to use
	if ( my $song = $args->{'song'} ) {
		$song->{'scanData'} ||= {}; 
		$song->{'scanData'}->{$track->url} = {
			streamNum => $streamNum,
			metadata  => $wma,
			headers   => $http->response->headers,
		};
	}
	
	# All done
	$cb->( $track, undef, @{$pt} );
}

sub streamAudioData {
	my ( $http, $dataref, $track, $args, $url ) = @_;
	
	my $first;
	
	# Buffer data to a temp file, 128K of data by default
	my $fh = $track->{_scanbuf};
	if ( !$fh ) {
		$fh = File::Temp->new();
		$track->{_scanbuf} = $fh;
		$track->{_scanlen} = 128 * 1024;
		$first = 1;
		$log->is_debug && $log->debug( $track->url . ' Buffering audio stream data to temp file ' . $fh->filename );
	}
	
	my $len = length($$dataref);
	$fh->write( $$dataref, $len );
	
	if ( $first ) {
		if ( $$dataref =~ /^ID3/ ) {
			# Look for ID3v2 data, determine how much data to read
			my $v2h = eval { MP3::Info::_get_v2head($fh) };
			if ( $@ ) {
				$log->error( "Unable to read ID3v2 data from remote file: $@" );
			}
			else {
				if ( $v2h->{tag_size} ) {
					# Read the full ID3v2 tag + some audio frames for bitrate
					$track->{_scanlen} = $v2h->{tag_size} + (16 * 1024);
					
					$log->is_debug && $log->debug( 'ID3v2 tag detected, will read ' . $track->{_scanlen} . ' bytes' );
				}
			}
		}
		
		# XXX: other tag types may need more than 128K too

		# Reset fh back to the end
		$fh->seek( 0, 2 );
	}
	
	$track->{_scanlen} -= $len;
	
	if ( $track->{_scanlen} > 0 ) {
		# Read more data
		#$log->is_debug && $log->debug( $track->url . ' Bytes left: ' . $track->{_scanlen} );
		
		return 1;
	}
	
	# Parse tags and bitrate
	my $bitrate = -1;
	my $vbr;
	
	my $cl          = $http->response->content_length;
	my $type        = $track->content_type;
	my $formatClass = Slim::Formats->classForFormat($type);
	
	if ( $formatClass && Slim::Formats->loadTagFormatForType($type) && $formatClass->can('scanBitrate') ) {
		($bitrate, $vbr) = $formatClass->scanBitrate( $fh, $track->url );
		
		if ( $bitrate > 0 ) {
			$track = Slim::Music::Info::setBitrate( $track->url, $bitrate, $vbr );
			if ($cl) {
				$track = Slim::Music::Info::setDuration( $track->url, ( $cl * 8 ) / $bitrate );
			}	
			
			# Copy bitrate to redirected URL
			if ( $track->url ne $url ) {
				Slim::Music::Info::setBitrate( $url, $bitrate );
				if ($cl) {
					Slim::Music::Info::setDuration( $url, ( $cl * 8 ) / $bitrate );
				}	
			}
		}
	}
	else {
		$log->is_debug && $log->debug("Unable to parse audio data for $type file");
	}
	
	# Update filesize with Content-Length
	if ( $cl ) {
		$track->filesize( $cl );
		$track->update;
		
		# Copy size to redirected URL
		if ( $track->url ne $url ) {
			my $redir = Slim::Schema->rs('Track')->updateOrCreate( {
				url => $url,
			} );
			$redir->filesize( $cl );
			$redir->update;
		}
	}
	
	# Delete temp file and other data
	$fh->close;
	unlink $fh->filename if -e $fh->filename;
	delete $track->{_scanbuf};
	delete $track->{_scanlen};
	
	# Disconnect
	return 0;
}

sub parsePlaylist {
	my ( $http, $playlist, $args ) = @_;
	
	my $client = $args->{client};
	my $cb     = $args->{cb} || sub {};
	my $pt     = $args->{pt} || [];
	
	my @results;
	
	my $type = $playlist->content_type;
	
	my $formatClass = Slim::Formats->classForFormat($type);

	if ( $formatClass && Slim::Formats->loadTagFormatForType($type) && $formatClass->can('read') ) {
		my $fh = IO::String->new( $http->response->content_ref );
		@results = eval { $formatClass->read( $fh, '', $playlist->url ) };
	}
	
	if ( !scalar @results ) {
		$log->is_debug && $log->debug( "Unable to parse playlist for content-type $type $@" );
		
		# delete bad playlist
		$playlist->delete;
		
		return $cb->( undef, 'PLAYLIST_NO_ITEMS_FOUND', @{$pt} );
	}
	
	# Convert the track to a playlist object
	$playlist = Slim::Schema->rs('Playlist')->objectForUrl( {
		url => $playlist->url,
	} );
	
	# Link the found tracks with the playlist
	$playlist->setTracks( \@results );
	
	if ( $log->is_info ) {
		$log->info( 'Found ' . scalar( @results ) . ' items in playlist ' . $playlist->url );
		$log->debug( map { $_->url . "\n" } @results );
	}
	
	# Scan all URLs in the playlist concurrently
	my $delay   = 0;
	my $ready   = 0;
	my $scanned = 0;
	my $total   = scalar @results;
	
	for my $entry ( @results ) {
		if ( !blessed($entry) ) {
			$total--;
			next;
		}
		
		__PACKAGE__->scanURL( $entry->url, {
			client => $client,
			song   => $args->{song},
			depth  => $args->{depth} + 1,
			delay  => $delay,
			cb     => sub {
				my ( $result, $error ) = @_;
				
				# Bug 10208: If resulting track is not the same as entry (due to redirect),
				# we need to adjust the playlist
				if ( blessed($result) && $result->id != $entry->id ) {
					$log->is_debug && $log->debug('Scanned track changed, updating playlist');
					
					my $i = 0;
					for my $e ( @results ) {
						if ( $e->id == $entry->id ) {
							splice @results, $i, 1, $result;
							last;
						}
						$i++;
					}
					
					# Get the $playlist object again, as it may have changed
					$playlist = Slim::Schema->rs('Playlist')->objectForUrl( {
						url => $playlist->url,
					} );
					
					$playlist->setTracks( \@results );
				}
				
				$scanned++;
				
				$log->is_debug && $log->debug("Scanned $scanned/$total items in playlist");
				
				if ( !$ready ) {
					# As soon as we find an audio URL, start playing it and continue scanning the rest
					# of the playlist in the background
					if ( my $entry = $playlist->getNextEntry ) {
					
						if ( $entry->bitrate ) {
							# Copy bitrate to playlist
							Slim::Music::Info::setBitrate( $playlist->url, $entry->bitrate, $entry->vbr_scale );
						}
					
						# Copy title if the playlist is untitled or a URL
						# If entry doesn't have a title either, use the playlist URL
						if ( !$playlist->title || $playlist->title =~ /^(?:http|mms)/i ) {
							$playlist = Slim::Music::Info::setTitle( $playlist->url, $entry->title || $playlist->url );
						}
					
						$log->is_debug && $log->debug('Found at least one audio URL in playlist');
						
						$ready = 1;
					
						$cb->( $playlist, undef, @{$pt} );
					}
				}
				
				if ( $scanned == $total ) {
					$log->is_debug && $log->debug( 'Playlist scan of ' . $playlist->url . ' finished' );
					
					# If we scanned everything and are still not ready, fail
					if ( !$ready ) {
						$log->is_debug && $log->debug( 'No audio tracks found in playlist' );
						
						# Delete bad playlist
						$playlist->delete;
						
						$cb->( undef, 'PLAYLIST_NO_ITEMS_FOUND', @{$pt} );
					}
				}
			},
		} );
		
		# Stagger playlist scanning by a small amount so we prefer the first item
		
		# XXX: This can be a problem if a playlist file contains 'backup' streams or files
		# we would not want to play these if any of the real streams in the playlist are valid.
		$delay += 1;
	}
}

1;

