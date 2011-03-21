package Slim::Plugin::Mediafly::Plugin;

# $Id: Plugin.pm 25038 2009-02-17 14:03:15Z andy $

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Plugin::Mediafly::ProtocolHandler;
use Slim::Networking::SqueezeNetwork;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.mediafly',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_MEDIAFLY_MODULE_NAME',
} );

sub initPlugin {
	my $class = shift;

	Slim::Player::ProtocolHandlers->registerHandler(
		mediafly => 'Slim::Plugin::Mediafly::ProtocolHandler'
	);
	
	$class->SUPER::initPlugin(
		feed   => Slim::Networking::SqueezeNetwork->url('/api/mediafly/v1/opml'),
		tag    => 'mediafly',
		menu   => 'music_services',
		weight => 55,
	);
	
	# Commands init
	Slim::Control::Request::addDispatch(['mediafly', 'skipTrack'],
		[0, 1, 1, \&skipTrack]);
	
	if ( !main::SLIM_SERVICE ) {
		# Add a function to view trackinfo in the web
		Slim::Web::HTTP::addPageFunction( 
			'plugins/mediafly/trackinfo.html',
			sub {
				my $client = $_[0];
				
				my $url = Slim::Player::Playlist::url($client);
				
				Slim::Web::XMLBrowser->handleWebIndex( {
					client  => $client,
					feed    => Slim::Plugin::Mediafly::ProtocolHandler->trackInfoURL( $client, $url ),
					path    => 'plugins/mediafly/trackinfo.html',
					title   => 'Mediafly Track Info',
					timeout => 35,
					args    => \@_
				} );
			},
		);
	}
}

sub getDisplayName () {
	return 'PLUGIN_MEDIAFLY_MODULE_NAME';
}

sub skipTrack {
	my $request = shift;
	my $client  = $request->client();
	
	return unless defined $client;
	
	# ignore if user is not using Pandora
	my $song = $client->playingSong() || return;
	my $url = $song->currentTrack()->url;
	return unless $url =~ /^mediafly/;
		
	$log->debug("Mediafly: Skip requested");
		
	$client->execute( [ "playlist", "jump", "+1" ] );
	
	$request->setStatusDone();
}

1;
