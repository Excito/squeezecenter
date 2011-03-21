package Slim::Plugin::RadioIO::Plugin;

# $Id: Plugin.pm 7196 2006-04-28 22:00:45Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech, Vidur Apparao.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Networking::SqueezeNetwork;

sub initPlugin {
	my $class = shift;

	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr/(?:\.radioio\.com|2917.+voxel\.net:\d{4})/, 
		sub { return $class->_pluginDataFor('icon'); }
	);

	$class->SUPER::initPlugin(
		feed           => Slim::Networking::SqueezeNetwork->url('/api/radioio/v1/opml'),
		tag            => 'radioio',
		menu           => 'radios',
		weight         => 20,
	);
}

sub playerMenu () {
	return 'RADIO';
}

sub getDisplayName {
	return 'PLUGIN_RADIOIO_MODULE_NAME';
}

1;
