package Slim::Plugin::MyApps::Plugin;

# $Id: Plugin.pm 28265 2009-08-25 19:58:11Z andy $

use strict;
use base qw(Slim::Plugin::OPMLBased);

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => Slim::Networking::SqueezeNetwork->url( '/api/myapps/v1/opml' ),
		tag    => 'myapps',
		node   => 'home',
		weight => 90,
	);
}

# Don't add this item to any menu
sub playerMenu { }

1;
