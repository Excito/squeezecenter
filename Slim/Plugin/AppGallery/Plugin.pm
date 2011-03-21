package Slim::Plugin::AppGallery::Plugin;

# $Id: Plugin.pm 28265 2009-08-25 19:58:11Z andy $

use strict;
use base qw(Slim::Plugin::OPMLBased);

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => Slim::Networking::SqueezeNetwork->url( '/api/appgallery/v1/opml' ),
		tag    => 'appgallery',
		node   => 'home',
		weight => 80,
	);
}

# Don't add this item to any menu
sub playerMenu { }

1;
