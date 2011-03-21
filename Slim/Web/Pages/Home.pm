package Slim::Web::Pages::Home;

# $Id: Home.pm 22935 2008-08-28 15:00:49Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use POSIX ();
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use base qw(Slim::Web::Pages);

use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Networking::Discovery::Server;
use Slim::Networking::SqueezeNetwork;

my $prefs = preferences('server');

sub init {
	my $class = shift;
	
	Slim::Web::HTTP::addPageFunction(qr/^$/, sub {$class->home(@_)});
	Slim::Web::HTTP::addPageFunction(qr/^home\.(?:htm|xml)/, sub {$class->home(@_)});
	Slim::Web::HTTP::addPageFunction(qr/^index\.(?:htm|xml)/, sub {$class->home(@_)});
	Slim::Web::HTTP::addPageFunction(qr/^switchserver\.(?:htm|xml)/, sub {$class->switchServer(@_)});

	$class->addPageLinks("help", { 'HELP_REMOTE' => "html/docs/remote.html"});
	$class->addPageLinks("help", { 'REMOTE_STREAMING' => "html/docs/remotestreaming.html"});
	$class->addPageLinks("help", { 'FAQ' => "http://faq.slimdevices.com/"},1);
	$class->addPageLinks("help", { 'TECHNICAL_INFORMATION' => "html/docs/index.html"});
	$class->addPageLinks("help", { 'COMMUNITY_FORUM' =>	"http://forums.slimdevices.com"});

	$class->addPageLinks("plugins", { 'SOFTSQUEEZE' => "html/softsqueeze/index.html"});
	$class->addPageLinks("plugins", { 'MUSICSOURCE' => "switchserver.html"});

	$class->addPageLinks('icons', { 'MUSICSOURCE' => 'html/images/ServiceProviders/squeezenetwork.png' });
	$class->addPageLinks('icons', { 'RADIO_TUNEIN' => 'html/images/ServiceProviders/tuneinurl.png' });
	$class->addPageLinks('icons', { 'SOFTSQUEEZE' => 'html/images/softsqueeze.png' });
	$class->addPageLinks('icons', { 'BROWSE_BY_ARTIST' => 'html/images/artists.png'} );
	$class->addPageLinks('icons', { 'BROWSE_BY_GENRE'  => 'html/images/genres.png'} );
	$class->addPageLinks('icons', { 'BROWSE_BY_ALBUM'  => 'html/images/albums.png'} );
	$class->addPageLinks('icons', { 'BROWSE_BY_YEAR'   => 'html/images/years.png'} );
	$class->addPageLinks('icons', { 'BROWSE_NEW_MUSIC' => 'html/images/newmusic.png'} );
	$class->addPageLinks('icons', { 'SEARCHMUSIC' => 'html/images/search.png'} );
	$class->addPageLinks('icons', { 'BROWSE_MUSIC_FOLDER' => 'html/images/musicfolder.png'} );
	$class->addPageLinks('icons', { 'SAVED_PLAYLISTS' => 'html/images/playlists.png'} );
}

sub home {
	my ($class, $client, $params, $gugus, $httpClient, $response) = @_;

	my $template = $params->{"path"} =~ /home\.(htm|xml)/ ? 'home.html' : 'index.html';

	# allow the setup wizard to be skipped in case the user's using an old browser (eg. Safari 1.x)
	if ($params->{skipWizard}) {
		$prefs->set('wizardDone', 1);
		if ($params->{skinOverride}){
			$prefs->set('skin', $params->{skinOverride});
		}
	}

	# redirect to the setup wizard if it has never been run before 
	if (!$prefs->get('wizardDone')) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => '/settings/server/wizard.html');
		return Slim::Web::HTTP::filltemplatefile($template, $params);
	}

	my %listform = %$params;

	$params->{'nosetup'}  = 1 if $::nosetup;
	$params->{'noserver'} = 1 if $::noserver;
	$params->{'newVersion'} = $::newVersion if $::newVersion;

	if (!exists $Slim::Web::Pages::additionalLinks{"browse"}) {
		$class->addPageLinks("browse", {'BROWSE_BY_ARTIST' => "browsedb.html?hierarchy=contributor,album,track&amp;level=0"});
		$class->addPageLinks("browse", {'BROWSE_BY_GENRE'  => "browsedb.html?hierarchy=genre,contributor,album,track&amp;level=0"});
		$class->addPageLinks("browse", {'BROWSE_BY_ALBUM'  => "browsedb.html?hierarchy=album,track&amp;level=0"});
		$class->addPageLinks("browse", {'BROWSE_BY_YEAR'   => "browsedb.html?hierarchy=year,album,track&amp;level=0"});
		$class->addPageLinks("browse", {'BROWSE_NEW_MUSIC' => "browsedb.html?hierarchy=age,track&amp;level=0"});
	}

	if (!exists $Slim::Web::Pages::additionalLinks{"search"}) {
		$class->addPageLinks("search", {'SEARCHMUSIC' => "livesearch.html"});
		$class->addPageLinks("search", {'ADVANCEDSEARCH' => "advanced_search.html"});
	}

	if (!exists $Slim::Web::Pages::additionalLinks{"help"}) {
		$class->addPageLinks("help", {'HELP_REMOTE' => "html/docs/remote.html"});
		$class->addPageLinks("help", {'REMOTE_STREAMING' => "html/docs/remotestreaming.html"});
		$class->addPageLinks("help", {'FAQ' => "html/docs/faq.html"});
		$class->addPageLinks("help", {'SOFTSQUEEZE' => "html/softsqueeze/index.html"});
		$class->addPageLinks("help", {'TECHNICAL_INFORMATION' => "html/docs/index.html"});
	}

	if ($prefs->get('audiodir')) {

		$class->addPageLinks("browse", {'BROWSE_MUSIC_FOLDER'   => "browsetree.html"});

	} else {

		$class->addPageLinks("browse", {'BROWSE_MUSIC_FOLDER' => undef});
		$params->{'nofolder'} = 1;
	}

	# Show playlists if any exists
	if ($prefs->get('playlistdir') || Slim::Schema->rs('Playlist')->getPlaylists->count) {

		$class->addPageLinks("browse", {'SAVED_PLAYLISTS' => "browsedb.html?hierarchy=playlist,playlistTrack&amp;level=0"});
	}

	# fill out the client setup choices
	for my $player (sort { $a->name() cmp $b->name() } Slim::Player::Client::clients()) {

		# every player gets a page.
		# next if (!$player->isPlayer());
		$listform{'playername'}   = $player->name();
		$listform{'playerid'}     = $player->id();
		$listform{'player'}       = $params->{'player'};
		$listform{'skinOverride'} = $params->{'skinOverride'};
		$params->{'player_list'} .= ${Slim::Web::HTTP::filltemplatefile("homeplayer_list.html", \%listform)};
	}

	# More leakage from the DigitalInput 'plugin'
	#
	# If our current player has digital inputs, show the menu.
	if ($client && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DigitalInput::Plugin')) {
		Slim::Plugin::DigitalInput::Plugin->webPages($client->hasDigitalIn);
	}

	# More leakage from the LineIn 'plugin'
	#
	# If our current player has line in, show the menu.
	if ($client && Slim::Utils::PluginManager->isEnabled('Slim::Plugin::LineIn::Plugin')) {
		Slim::Plugin::LineIn::Plugin->webPages($client);
	}

	if (my $favs = Slim::Utils::Favorites->new($client)) {
		$params->{'favorites'} = $favs->toplevel;
	}
	
	# Bug 4125, sort all additionalLinks submenus properly
	# XXX: non-Default templates will need to be updated to use this sort order
	$params->{additionalLinkOrder} = {};
	
	for my $menu ( keys %Slim::Web::Pages::additionalLinks ) {
		my @sorted = sort {
			( 
				( $prefs->get("rank-$b") || 0 ) <=> 
				( $prefs->get("rank-$a") || 0 )
			)
			|| 
			(
				lc( Slim::Buttons::Home::cmpString($client, $a) ) cmp
				lc( Slim::Buttons::Home::cmpString($client, $b) )
			)
		} 
		keys %{ $Slim::Web::Pages::additionalLinks{ $menu } };

		$params->{additionalLinkOrder}->{ $menu } = \@sorted;
	}
	
	$params->{additionalLinks} = \%Slim::Web::Pages::additionalLinks;

	$class->addPlayerList($client, $params);
	
	$class->addLibraryStats($params);

	return Slim::Web::HTTP::filltemplatefile($template, $params);
}

sub switchServer {
	my ($class, $client, $params) = @_;

	if (lc($params->{'switchto'}) eq 'squeezenetwork' 
		|| $params->{'switchto'} eq Slim::Utils::Strings::string('SQUEEZENETWORK')) {

		# Bug 7254, don't tell Ray to reconnect to SN
		if ( $client->deviceid != 7 ) {
			Slim::Utils::Timers::setTimer(
				$client,
				time() + 1,
				sub {
					my $client = shift;
					Slim::Buttons::Common::pushModeLeft( $client, 'squeezenetwork.connect' );
				},
			);

			$params->{'switchto'} = 'http://' . Slim::Networking::SqueezeNetwork->get_server("sn");
		}

	}

	elsif ($params->{'switchto'}) {

		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1,
			sub {

				my ($client, $server) = @_;
				$client->execute(['connect', Slim::Networking::Discovery::Server::getServerAddress($server)]);

			}, $params->{'switchto'});

		$params->{'switchto'} = Slim::Networking::Discovery::Server::getWebHostAddress($params->{'switchto'});
	}

	else {
		$params->{servers} = Slim::Networking::Discovery::Server::getServerList();

		# Bug 7254, don't tell Ray to reconnect to SN
		if ( $client->deviceid != 7 ) {
			$params->{servers}->{'SQUEEZENETWORK'} = {
				NAME => Slim::Utils::Strings::string('SQUEEZENETWORK')	
			}; 
		}
	
		my @servers = keys %{Slim::Networking::Discovery::Server::getServerList()};
		$params->{serverlist} = \@servers;
	}
	
	return Slim::Web::HTTP::filltemplatefile('switchserver.html', $params);
}

1;

__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
