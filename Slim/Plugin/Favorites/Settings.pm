package Slim::Plugin::Favorites::Settings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.favorites');

sub name {
	return Slim::Web::HTTP::protectName('FAVORITES');
}

sub page {
	return Slim::Web::HTTP::protectURI('plugins/Favorites/settings/basic.html');
}

sub prefs {
	return ($prefs, 'opmleditor');
}

sub handler {
	my ($class, $client, $params) = @_;

	my $ret = $class->SUPER::handler($client, $params);

	if ($params->{'saveSettings'}) {

		Slim::Plugin::Favorites::Plugin::addEditLink();
	}

	return $ret;
}

1;

__END__
