package Slim::Web::Setup;

# $Id: Setup.pm 30040 2010-02-05 19:58:44Z andy $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use Slim::Utils::Log;

sub initSetup {
	my @classes = ('Slim::Web::Settings');
	
	push @classes, map { 
		join('::', qw(Slim Web Settings Player), $_) 
	} qw(
		Alarm 
		Audio 
		Basic 
		Display 
		Menu 
		Remote 
		Synchronization
	);
	
	push @classes, map { 
		join('::', qw(Slim Web Settings Server), $_) 
	} qw(
		Basic 
		Behavior 
		Debugging 
		FileSelector 
		Index 
		Network 
		Performance 
		Plugins 
		Security 
		Software 
		SqueezeNetwork 
		Status 
		TextFormatting 
		UserInterface 
		Wizard
	);
	
	if (main::TRANSCODING) {
		push @classes, 'Slim::Web::Settings::Server::FileTypes';
	}

	for my $class (@classes) {
		eval "use $class";

		if (!$@) {

			$class->new;

		} else {

			logError ("can't load $class - $@");
		}
	}

}

1;

__END__
