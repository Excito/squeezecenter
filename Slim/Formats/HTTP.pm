package Slim::Formats::HTTP;

# $Id: HTTP.pm 24414 2008-12-24 08:55:59Z awy $

# SqueezeCenter Copyright 2001-2007 Logitech.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.  

=head1 NAME

Slim::Formats::HTTP

=head1 DESCRIPTION

This is a base class for remote stream formats to pull their metadata.

=head1 METHODS

=cut

use strict;
use base qw(Slim::Formats::RemoteStream);

use HTTP::Request;
use IO::Socket qw(:crlf);
use MIME::Base64;

use Slim::Utils::Log;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;

use constant DEFAULT_TYPE => 'mp3';

my $prefs = preferences('server');

=head2 getTag( $url )

Class constructor for just reading metadata from the stream / remote playlist.

=cut

sub getTag {
	my $class = shift;
	my $url   = shift || return {};

	my $args  = {
		'url'      => $url,
		'readTags' => 1,
	};

	my $self = $class->SUPER::open($args);

	# We might have redirected - be sure to return that object.
	return $self->request($args);
}

=head2 getFormatForURL()

Returns the type of of stream we are checking (mp3, wma, etc)

=cut

sub getFormatForURL {
	my $class = shift;

	return DEFAULT_TYPE;
}

=head2 requestString( $client, $url, [ $post, [ $seekdata ] ] )

Generate a HTTP request string suitable for sending to a HTTP server.

=cut

sub requestString {
	my $self   = shift;
	my $client = shift;
	my $url    = shift;
	my $post   = shift;
	my $seekdata = shift;

	my ($server, $port, $path, $user, $password) = Slim::Utils::Misc::crackURL($url);
 
	# Use full path for proxy servers
	my $proxy;
	
	if ( main::SLIM_SERVICE ) {
		# Let user specify their own proxy to use
		$proxy = $prefs->client($client)->get('webproxy');
	}
	else {
		$proxy = $prefs->get('webproxy');
	}
	
	if ( $proxy && $server !~ /(?:localhost|127.0.0.1)/ ) {
		$path = "http://$server:$port$path";
	}

	my $type = $post ? 'POST' : 'GET';

	# Although the port can be part of the Host: header, some hosts (such
	# as online.wsj.com don't like it, and will infinitely redirect.
	# According to the spec, http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html
	# The port is optional if it's 80, so follow that rule.
	my $host = $port == 80 ? $server : "$server:$port";
	
	# Special case, for the fallback-alarm, disable Icy Metadata, or our own
	# server will try and send it
	my $want_icy = 1;
	if ( $path =~ m{/slim-backup-alarm.mp3$} ) {
		$want_icy = 0;
	}

	# make the request
	my $request = join($CRLF, (
		"$type $path HTTP/1.0",
		"Accept: */*",
		"Cache-Control: no-cache",
		"User-Agent: " . Slim::Utils::Misc::userAgentString(),
		"Icy-MetaData: $want_icy",
		"Connection: close",
		"Host: $host",
	));
	
	if (defined($user) && defined($password)) {
		$request .= $CRLF . "Authorization: Basic " . MIME::Base64::encode_base64($user . ":" . $password,'');
	}
	
	# If seeking, add Range header
	if ($client && $seekdata) {
		$request .= $CRLF . 'Range: bytes=' . int( $seekdata->{sourceStreamOffset} ) . '-';
		
		if (defined $seekdata->{timeOffset}) {
			# Fix progress bar
			$client->master()->currentsongqueue()->[-1]->{startOffset} = $seekdata->{timeOffset};
			$client->master()->remoteStreamStartTime( Time::HiRes::time() - $seekdata->{timeOffset} );
		}
	}

	# Send additional information if we're POSTing
	if ($post) {

		$request .= $CRLF . "Content-Type: application/x-www-form-urlencoded";
		$request .= $CRLF . sprintf("Content-Length: %d", length($post));
		$request .= $CRLF . $CRLF . $post . $CRLF;

	} else {
		$request .= $CRLF . $CRLF;
	}
	
	# Bug 5858, add cookies to the request
	if ( !main::SLIM_SERVICE ) {
		my $request_object = HTTP::Request->parse($request);
		$request_object->uri($url);
		Slim::Networking::Async::HTTP::cookie_jar->add_cookie_header( $request_object );
		$request_object->uri($path);
			
		# Bug 9709, strip long cookies from the request
		$request_object->headers->scan( sub {
			if ( $_[0] eq 'Cookie' ) {
				if ( length($_[1]) > 512 ) {
					$request_object->headers->remove_header('Cookie');
				}
			}
		} );
		
		$request = $request_object->as_string( $CRLF );				
	}

	return $request;
}

=head2 parseHeaders( @headers )

Parse the response headers from an HTTP request, and set instance variables
based on items in the response, eg: bitrate, content type.

Updates the client's streamingProgressBar with the correct duration.

=cut

sub parseHeaders {
	my $self    = shift;
	my @headers = @_;

	my $log = logger('player.streaming.remote');
	
	my $client = $self->client;
	my $url    = $self->url;

	for my $header (@headers) {

		$log->info("Header: $header");

		if ($header =~ /^(?:ic[ey]-name|x-audiocast-name):\s*(.+)$CRLF$/i) {

			${*$self}{'title'} = Slim::Utils::Unicode::utf8decode_guess($1, 'iso-8859-1');

			if (!defined ${*$self}{'create'} || ${*$self}{'create'} != 0) {

				# Always prefer the title returned in the headers of a radio station
				$log->info( "Setting new title for $url, " . ${*$self}{'title'} );
				Slim::Music::Info::setTitle( $url, ${*$self}{'title'} );
				Slim::Music::Info::setCurrentTitle( $url, ${*$self}{'title'} );
			}
		}

		elsif ($header =~ /^(?:icy-br|x-audiocast-bitrate):\s*(.+)$CRLF$/i) {

			${*$self}{'bitrate'} = $1 * 1000;

			if (!defined ${*$self}{'create'} || ${*$self}{'create'} != 0) {

				Slim::Music::Info::setBitrate( $self->infoUrl, $self->bitrate );
			}
			
			if ( $log->is_info ) {
				$log->info(sprintf("Bitrate for %s set to %d",
					$self->infoUrl,
					$self->bitrate,
				));
			}
		}
		
		elsif ($header =~ /^icy-metaint:\s*(.+)$CRLF$/) {

			${*$self}{'metaInterval'} = $1;
			${*$self}{'metaPointer'}  = 0;
		}
		
		elsif ($header =~ /^Location:\s*(.*)$CRLF$/i) {

			${*$self}{'redirect'} = $1;
		}

		elsif ($header =~ /^Content-Type:\s*(.*)$CRLF$/i) {

			my $contentType = $1;

			if (($contentType =~ /text/i) && !($contentType =~ /text\/xml/i)) {
				# webservers often lie about playlists.  This will
				# make it guess from the suffix.  (unless text/xml)
				$contentType = '';
			}
			
			${*$self}{'contentType'} = $contentType;

			# If create => 0 was passed, don't set the CT.
			if (!defined ${*$self}{'create'} || ${*$self}{'create'} != 0) {

				Slim::Music::Info::setContentType( $self->url, $self->contentType );
			}
		}
		
		elsif ($header =~ /^Content-Length:\s*(.*)$CRLF$/i) {

			${*$self}{'contentLength'} = $1;
		}

		elsif ($header eq $CRLF) { 

			$log->info("Recieved final blank line...");
			last; 
		}
		
		# mp3tunes metadata, this is a bit of hack but creating
		# an mp3tunes protocol handler is overkill
		elsif ( $client && $url =~ /mp3tunes\.com/ && $header =~ /^X-Locker-Info:\s*(.+)/i ) {
			Slim::Plugin::MP3tunes::Plugin->setLockerInfo( $client, $url, $1 );
		}
	}
	
	# Bitrate may have been set in Scanner by reading the mp3 stream
	if ( !$self->bitrate ) {
		${*$self}{'bitrate'} = Slim::Music::Info::getBitrate( $self->url );
	}
	
	return unless $client;
	
	# See if we have an existing track object with duration info for this stream.
	if ( my $secs = Slim::Music::Info::getDuration( $self->url ) ) {
		
		# Display progress bar
		$client->streamingProgressBar( {
			'url'      => $self->url,
			'duration' => $secs,
		} );
	}
	else {
	
		if ( $self->bitrate > 0 && $self->contentLength > 0 ) {
			# if we know the bitrate and length of a stream, display a progress bar
			if ( $self->bitrate < 1000 ) {
				${*$self}{'bitrate'} *= 1000;
			}
			$client->streamingProgressBar( {
				'url'     => $self->url,
				'bitrate' => $self->bitrate,
				'length'  => $self->contentLength,
			} );
		}
	}
		
	# Bug 6482, refresh the cached Track object in the client playlist from the database
	# so it picks up any changed data such as title, bitrate, etc
	Slim::Player::Playlist::refreshTrack( $client, $self->url );
}

=head1 SEE ALSO

L<Slim::Formats::RemoteStream>

=cut

1;

__END__
