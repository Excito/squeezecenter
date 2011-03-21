package Slim::Plugin::xPL::Settings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.xpl');

$prefs->migrate(1, sub {
	$prefs->set('interval', Slim::Utils::Prefs::OldPrefs->get('xplinterval') || 5);
	$prefs->set('ir', Slim::Utils::Prefs::OldPrefs->get('xplir') || 'none');
	1;
});

sub name {
	return Slim::Web::HTTP::protectName('PLUGIN_XPL');
}

sub page {
	return Slim::Web::HTTP::protectURI('plugins/xPL/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(interval ir) );
}

1;

__END__
