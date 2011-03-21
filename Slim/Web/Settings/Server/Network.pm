package Slim::Web::Settings::Server::Network;

# $Id: Network.pm 22966 2008-08-29 19:41:57Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $prefs = preferences('server');

sub name {
	return Slim::Web::HTTP::protectName('NETWORK_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::protectURI('settings/server/networking.html');
}

sub prefs {
	my @prefs = qw(webproxy httpport bufferSecs remotestreamtimeout maxWMArate noupnp);

	# Bug 2724 - only show the mDNS settings if we have a binary for it.
	if (Slim::Utils::Misc::findbin('mDNSResponderPosix')) {
		push @prefs, 'mDNSname';
	}

	# only show following for SLIMP3
	if ($Slim::Player::SLIMP3::SLIMP3Connected) {
		push @prefs, 'udpChunkSize';
	}
	
	# only show following if we have multiple players
	if (Slim::Player::Client::clients() > 1) {
		push @prefs, 'syncStartDelay';
	}

	return ($prefs, @prefs);
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	if ($paramRef->{'saveSettings'} && $paramRef->{'pref_httpport'} ne $prefs->get('httpport')) {

		my (undef, $ok) = $prefs->set('httpport', $paramRef->{'pref_httpport'});

		if ($ok) {
			my $homeURL = Slim::Utils::Prefs::homeURL();

			$paramRef->{'warning'} .= join('',
				string("SETUP_HTTPPORT_OK"),
				'<blockquote><a target="_top" href="',
				$homeURL,
				'">',
				$homeURL,
				"</a></blockquote><br>"
			);
		}
		# warning for invalid value created by base class
	}
	
	if ( defined $paramRef->{'pref_noupnp'} && $paramRef->{'pref_noupnp'} ne $prefs->get('noupnp') ) {
		require Slim::Utils::UPnPMediaServer;

		# Shut down all UPnP activity
		Slim::Utils::UPnPMediaServer::shutdown();
		
		# Start it up again if the user enabled it
		if ( !$paramRef->{'pref_noupnp'} ) {
			Slim::Utils::UPnPMediaServer::init();
		}
	}

	return $class->SUPER::handler($client, $paramRef, $pageSetup);
}

1;

__END__
