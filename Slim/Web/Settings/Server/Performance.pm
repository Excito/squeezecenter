package Slim::Web::Settings::Server::Performance;

# $Id: Performance.pm 28991 2009-10-23 14:46:48Z ayoung $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PERFORMANCE_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('settings/server/performance.html');
}

sub prefs {
 	return (preferences('server'), qw(disableStatistics serverPriority scannerPriority resampleArtwork precacheArtwork maxPlaylistLength) );
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	$paramRef->{'options'} = {
		''   => 'SETUP_PRIORITY_CURRENT',
		map { $_ => {
			-16 => 'SETUP_PRIORITY_HIGH',
			 -6 => 'SETUP_PRIORITY_ABOVE_NORMAL',
			  0 => 'SETUP_PRIORITY_NORMAL',
			  5 => 'SETUP_PRIORITY_BELOW_NORMAL',
			  15 => 'SETUP_PRIORITY_LOW'
			}->{$_} } (-20 .. 20)
	};

	return $class->SUPER::handler($client, $paramRef, $pageSetup);
}

1;

__END__
