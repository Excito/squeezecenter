package Slim::Web::Settings::Server::Debugging;

# $Id: Debugging.pm 23246 2008-09-23 13:33:50Z mherger $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

sub name {
	return Slim::Web::HTTP::protectName('DEBUGGING_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::protectURI('settings/server/debugging.html');
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup) = @_;

	# If this is a settings update
	if ($paramRef->{'saveSettings'}) {

		my $categories = Slim::Utils::Log->allCategories;

		if ($paramRef->{'logging_group'}) {

			my $levels = Slim::Utils::Log->logLevels($paramRef->{'logging_group'});
			
			for my $category (keys %{$categories}) {
				
				Slim::Utils::Log->setLogLevelForCategory(
					$category, $levels->{$category} || 'ERROR'
				);
			}
			
		}

		else {

			for my $category (keys %{$categories}) {
	
				Slim::Utils::Log->setLogLevelForCategory(
					$category, $paramRef->{$category}
				);
			}
		}

		Slim::Utils::Log->persist($paramRef->{'persist'} ? 1 : 0);

		# $paramRef might have the overwriteCustomConfig flag.
		Slim::Utils::Log->reInit($paramRef);
	}

	# Pull in the dynamic debugging levels.
	my $debugCategories = Slim::Utils::Log->allCategories;
	my @validLogLevels  = Slim::Utils::Log->validLevels;
	my @categories      = (); 

	for my $debugCategory (sort keys %{$debugCategories}) {

		my $string = Slim::Utils::Log->descriptionForCategory($debugCategory);

		push @categories, {
			'label'   => Slim::Utils::Strings::getString($string),
			'name'    => $debugCategory,
			'current' => $debugCategories->{$debugCategory},
		};
	}
	
	$paramRef->{'logging_groups'} = Slim::Utils::Log->logGroups();

	$paramRef->{'categories'} = \@categories;
	$paramRef->{'logLevels'}  = \@validLogLevels;
	$paramRef->{'persist'}    = Slim::Utils::Log->persist;

	$paramRef->{'logs'} = getLogs();

	return $class->SUPER::handler($client, $paramRef, $pageSetup);
}

sub getLogs {
	return [
		{SERVER  => Slim::Utils::Log->serverLogFile},
		{SCANNER => Slim::Utils::Log->scannerLogFile},
		{PERFMON => ($::perfmon ? Slim::Utils::Log->perfmonLogFile : undef )},
	]
}

1;

__END__
