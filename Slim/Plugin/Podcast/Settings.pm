package Slim::Plugin::Podcast::Settings;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Networking::SqueezeNetwork;

my $log   = logger('plugin.podcast');
my $prefs = preferences('plugin.podcast');

use constant FEED_VERSION => 2; # bump this number when changing the defaults below

sub DEFAULT_FEEDS {
	[
	{
		name  => 'Odeo',
		value => 'http://'
			. Slim::Networking::SqueezeNetwork->get_server("content")
			. '/opml/odeo.opml',
	},
	{
		name  => 'PodcastAlley Top 50',
		value => 'http://podcastalley.com/PodcastAlleyTop50.opml'
	},
	{
		name  => 'PodcastAlley 10 Newest',
		value => 'http://podcastalley.com/PodcastAlley10Newest.opml'
	},
	];
}

# migrate old prefs across
$prefs->migrate(1, sub {
	my @names  = @{Slim::Utils::Prefs::OldPrefs->get('plugin_podcast_names') || [] };
	my @values = @{Slim::Utils::Prefs::OldPrefs->get('plugin_podcast_feeds') || [] };
	my @feeds;

	for my $name (@names) {
		push @feeds, { 'name' => $name, 'value' => shift @values };
	}

	if (@feeds) {
		$prefs->set('feeds', \@feeds);
		$prefs->set('modified', 1);
	}

	1;
});

# migrate to latest version of default feeds if they have not been modified
$prefs->migrate(FEED_VERSION, sub {
	$prefs->set('feeds', DEFAULT_FEEDS()) unless $prefs->get('modified');
	1;
});

sub name {
	return Slim::Web::HTTP::protectName('PLUGIN_PODCAST');
}

sub page {
	return Slim::Web::HTTP::protectURI('plugins/Podcast/settings/basic.html');
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	if ( $params->{reset} ) {

		$prefs->set( feeds => DEFAULT_FEEDS() );
		$prefs->set( modified => 0 );

		Slim::Plugin::Podcast::Plugin::updateOPMLCache(DEFAULT_FEEDS());
	}
	
	my @feeds = @{ $prefs->get('feeds') };

	if ( $params->{saveSettings} ) {

		if ( my $newFeedUrl  = $params->{newfeed} ) {
			validateFeed( $newFeedUrl, {
				cb  => sub {
					my $newFeedName = shift;
				
					push @feeds, {
						name  => $newFeedName,
						value => $newFeedUrl,
					};
				
					my $body = $class->saveSettings( $client, \@feeds, $params );
					$callback->( $client, $params, $body, @args );
				},
				ecb => sub {
					my $error = shift;
				
					$params->{warning}   .= Slim::Utils::Strings::string( 'SETUP_PLUGIN_PODCAST_INVALID_FEED', $error );
					$params->{newfeedval} = $params->{newfeed};
				
					my $body = $class->saveSettings( $client, \@feeds, $params );
					$callback->( $client, $params, $body, @args );
				},
			} );
		
			return;
		}
	}

	return $class->saveSettings( $client, \@feeds, $params );
}

sub saveSettings {
	my ( $class, $client, $feeds, $params ) = @_;
	
	my @delete = @{ ref $params->{delete} eq 'ARRAY' ? $params->{delete} : [ $params->{delete} ] };

	for my $deleteItem  (@delete ) {
		my $i = 0;
		while ( $i < scalar @{$feeds} ) {
			if ( $deleteItem eq $feeds->[$i]->{value} ) {
				splice @{$feeds}, $i, 1;
				next;
			}
			$i++;
		}
	}

	$prefs->set( feeds => $feeds );
	$prefs->set( modified => 1 );

	Slim::Plugin::Podcast::Plugin::updateOPMLCache($feeds);
	
	for my $feed ( @{$feeds} ) {
		push @{ $params->{prefs} }, [ $feed->{value}, $feed->{name} ];
	}
	
	return $class->SUPER::handler($client, $params);
}

sub validateFeed {
	my ( $url, $args ) = @_;

	$log->info("validating $url...");

	Slim::Formats::XML->getFeedAsync(
		\&_validateDone,
		\&_validateError,
		{
			url     => $url,
			timeout => 10,
			cb      => $args->{cb},
			ecb     => $args->{ecb},
		}
	);
}

sub _validateDone {
	my ( $feed, $params ) = @_;
	
	my $title = $feed->{title} || $params->{url};
	
	$log->info( "Verified feed $params->{url}, title: $title" );
		
	$params->{cb}->( $title );
}

sub _validateError {
	my ( $error, $params ) = @_;
	
	$log->error( "Error validating feed $params->{url}: $error" );
	
	$params->{ecb}->( $error );
}

1;

__END__
