package Slim::Plugin::DateTime::Settings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.datetime');

$prefs->migrate(1, sub {
	$prefs->set('timeformat', Slim::Utils::Prefs::OldPrefs->get('screensaverTimeFormat') || '');
	$prefs->set('dateformat', Slim::Utils::Prefs::OldPrefs->get('screensaverDateFormat') || '');
	1;
});

$prefs->migrateClient(2, sub {
	my ($clientprefs, $client) = @_;
	$clientprefs->set('timeformat', $prefs->get('timeformat') || '');
	$clientprefs->set('dateformat', $prefs->get('dateformat') || $client->isa('Slim::Player::Boom') ? $client->string('SETUP_LONGDATEFORMAT_DEFAULT_N') : '');
	1;
});

$prefs->setChange( sub {
	my $client = $_[2];
	if ($client->isa("Slim::Player::Boom")) {
		$client->setRTCTime();
	}		
}, 'timeformat');


my $timeFormats = Slim::Utils::DateTime::timeFormats();

my $dateFormats = {
	%{Slim::Utils::DateTime::shortDateFormats()},
	%{Slim::Utils::DateTime::longDateFormats()}
};

sub name {
	return Slim::Web::HTTP::protectName('PLUGIN_SCREENSAVER_DATETIME');
}

sub page {
	return Slim::Web::HTTP::protectURI('plugins/DateTime/settings/basic.html');
}

sub prefs {
	my ($class, $client) = @_;
	return ($prefs->client($client), qw(timeformat dateformat) );
}

sub needsClient {
	return 1;
}

sub handler {
	my ($class, $client, $params) = @_;

	$params->{'timeFormats'} = $timeFormats;
	$params->{'dateFormats'} = $dateFormats;

	return $class->SUPER::handler($client, $params);
}

1;

__END__
