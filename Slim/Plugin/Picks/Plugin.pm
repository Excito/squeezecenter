package Slim::Plugin::Picks::Plugin;

# $Id$

# Load Picks via an OPML file - so we can ride on top of the Podcast Browser

use strict;
use base qw(Slim::Plugin::OPMLBased);

sub initPlugin {
	my $class = shift;

	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr/(?:squeezenetwork|slimdevices)\.com.*\/picks\//, 
		sub { return $class->_pluginDataFor('icon'); }
	);

	$class->SUPER::initPlugin(
		feed   => 'http://www.slimdevices.com/picks/split/picks.opml',
		tag    => 'picks',
		menu   => 'radios',
		weight => 10,
	);
}

sub getDisplayName {
	return 'PLUGIN_PICKS_MODULE_NAME';
}

1;
