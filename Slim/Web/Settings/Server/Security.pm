package Slim::Web::Settings::Server::Security;

# $Id: Security.pm 22939 2008-08-28 16:42:33Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('server');

sub name {
	return Slim::Web::HTTP::protectName('SECURITY_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::protectURI('settings/server/security.html');
}

sub prefs {
	return (preferences('server'), qw(filterHosts allowedHosts csrfProtectionLevel authorize username) );
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	# disable authorization if no username is set
	$paramRef->{'authorize'} = 0 unless $paramRef->{'username'};

	# pre-process password to avoid saving clear text
	if ($paramRef->{'saveSettings'} && $paramRef->{'pref_password'}) {

		my $val = $paramRef->{'pref_password'};

		if ($val ne $paramRef->{'pref_password_repeat'}) {

			$paramRef->{'warning'} .= Slim::Utils::Strings::string('SETUP_PASSWORD_MISMATCH');

		}

		else {

			my $currentPassword = preferences('server')->get('password');
			my $salt = substr($currentPassword, 0, 2);
		
			if (defined($val) && $val ne '' && ($currentPassword eq '' || crypt($val, $salt) ne $currentPassword)) {
				srand (time());
				my $randletter = "(int (rand (26)) + (int (rand (1) + .5) % 2 ? 65 : 97))";
				my $salt = sprintf ("%c%c", eval $randletter, eval $randletter);
				$prefs->set('password', crypt($val, $salt));
			}
			
		}
	}

	return $class->SUPER::handler($client, $paramRef, $pageSetup);
}


1;

__END__
