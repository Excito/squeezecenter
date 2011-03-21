package Slim::Plugin::Sounds::ProtocolHandler;

# $Id: ProtocolHandler.pm 22939 2008-08-28 16:42:33Z andy $

# Handler for forcing loop mode

use strict;
use base 'Slim::Player::Protocols::HTTP';

# No scrobbling
sub audioScrobblerSource { }

# Loop mode only works with direct streaming
sub canDirectStream {
	my ( $class, $client, $url ) = @_;
	
	return $url;
}

sub shouldLoop { 1 }

# Some sounds are small, use a small buffer threshold
sub bufferThreshold { 10 }

sub canSeek { 0 }

sub isAudioURL { 1 }

sub isRemote { 1 }

sub getMetadataFor {
	my $class = shift;
	
	my $icon = Slim::Plugin::Sounds::Plugin->_pluginDataFor('icon');
	
	return {
		cover    => $icon,
		icon     => $icon,
		bitrate  => '128k CBR',
		type     => 'MP3 (Sounds & Effects)',
	};
}

1;