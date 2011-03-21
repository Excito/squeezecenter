package Slim::Plugin::MusicMagic::ClientSettings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.musicip',
	'defaultLevel' => 'ERROR',
});

my $prefs = preferences('plugin.musicip');

$prefs->migrateClient(1, sub {
	my ($clientprefs, $client) = @_;
	
	$clientprefs->set('mix_filter',  Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMFilter')     );
	$clientprefs->set('reject_size', Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMRejectSize') );
	$clientprefs->set('reject_type', Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMRejectType') );
	$clientprefs->set('mix_genre',   Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMMixGenre')   );
	$clientprefs->set('mix_variety', Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMVariety')    );
	$clientprefs->set('mix_style',   Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMStyle')      );
	$clientprefs->set('mix_type',    Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMMixType')    );
	$clientprefs->set('mix_size',    Slim::Utils::Prefs::OldPrefs->clientGet($client, 'MMMSize')       );
	1;
});

$prefs->migrateClient(2, sub {
	my ($clientprefs, $client) = @_;
	
	my $oldPrefs = preferences('plugin.musicmagic');
	$clientprefs->set('mix_filter',  $oldPrefs->client($client)->get($client, 'mix_filter')  );
	$clientprefs->set('reject_size', $oldPrefs->client($client)->get($client, 'reject_size') );
	$clientprefs->set('reject_type', $oldPrefs->client($client)->get($client, 'reject_type') );
	$clientprefs->set('mix_genre',   $oldPrefs->client($client)->get($client, 'mix_genre')   );
	$clientprefs->set('mix_variety', $oldPrefs->client($client)->get($client, 'mix_variety') );
	$clientprefs->set('mix_style',   $oldPrefs->client($client)->get($client, 'mix_style')   );
	$clientprefs->set('mix_type',    $oldPrefs->client($client)->get($client, 'mix_type')    );
	$clientprefs->set('mix_size',    $oldPrefs->client($client)->get($client, 'mix_size')    );
	1;
});

sub name {
	return 'MUSICMAGIC';
}

sub page {
	return 'plugins/MusicMagic/settings/mipclient.html';
}

sub prefs {
	my ($class,$client) = @_;
	
	return ($prefs->client($client), qw(mix_filter reject_size reject_type mix_genre mix_variety mix_style mix_type mix_size));
}

sub needsClient {
	return 1;
}

sub handler {
	my ($class, $client, $params) = @_;

	$params->{'filters'}  = Slim::Plugin::MusicMagic::Settings::grabFilters();

	return $class->SUPER::handler($client, $params);
}

1;

__END__
