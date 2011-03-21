package Slim::Plugin::Sirius::Plugin;

# $Id: Plugin.pm 23921 2008-11-13 18:39:10Z andy $

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Plugin::Sirius::ProtocolHandler;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.sirius',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_SIRIUS_MODULE_NAME',
} );

sub initPlugin {
	my $class = shift;

	Slim::Player::ProtocolHandlers->registerHandler(
		sirius => 'Slim::Plugin::Sirius::ProtocolHandler'
	);
}

sub getDisplayName () {
	return 'PLUGIN_SIRIUS_MODULE_NAME';
}

sub playerMenu { undef }

1;
