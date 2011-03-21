package Slim::Plugin::InfoBrowser::Plugin;

# InfoBrowser - an extensible information parser for SqueezeCenter 7.0
#
# $Id: Plugin.pm 22935 2008-08-28 15:00:49Z andy $
#
# InfoBrowser provides a framework to use SqueezeCenter's xmlbrowser to fetch remote content and convert it into a format
# which can be displayed via the SqueezeCenter web interface, cli for jive or another cli client or via the player display.
#
# The top level menu is defined by an opml file stored in playlistdir or cachedir.  It is created dynamically from any opml
# files found in the plugin dir (Slim/Plugin/InfoBrowser) and the Addon dir (Plugins/InfoBrowserAddons) and any of their subdirs.
# This allows addition of third party addons defining new information sources.
#
# Simple menu entries for feeds which are parsed natively by Slim::Formats::XML are of the form:
#
# <outline text="BBC News World" URL="http://news.bbc.co.uk/rss/newsonline_world_edition/front_page/rss.xml" />
#
# Menu entries which use additional perl scripts to parse the response into a format understood by xmlbrowser are of the form:
#
# <outline text="Menu text" URL="url to fetch" parser="Plugins::InfoBrowserAddons::Folder::File" />
#
# In this case when the content of the remote url has been fetched it is passed to the perl function
# Plugins::InfoBrowserAddons::Folder::File::parser to parse the content into a hash which xmlbrowser will understand.
# This allows arbitary web pages to be parsed by adding the appropriate perl parser files.  The perl module will be dynamically loaded. 
#
# The parser may be passed a parameter string by including it after ? in the parser specification.  The parser definition is split
# on either side of the ? to specify the perl module to load and a string to pass as third param to its parse method. 
#
# <outline text="Menu text" URL="url to fetch" parser="Plugins::InfoBrowserAddons::Folder::File?param1=1&param2=2" />
#
# In this case Plugins::InfoBrowserAddons::parse gets called with ( $class, $html, $paramstring ).
#
# Addons are stored in Plugins/InfoBrowserAddons.  It is suggested that each addon is a separate directory within this top level
# directory containing the opml menu and any associated parser files.  InfoBrowser will search this entire directory tree for
# opml files and add them to the main information browser menu.
#
# Users may remove or reorder menu entries in the top level opml menu via settings.  They may also reset the menu which will reimport all
# default and Addon opml files.
# 
# Authors are encouraged to publish their addons on the following wiki page:
#   http://wiki.slimdevices.com/index.php/InformationBrowser
#

use strict;

use base qw(Slim::Plugin::Base);

use File::Spec::Functions qw(:ALL);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use Slim::Plugin::Favorites::Opml;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.infobrowser',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

if ( !main::SLIM_SERVICE ) {
 	require Slim::Plugin::InfoBrowser::Settings;
}

my $prefsServer = preferences('server');

my $menuUrl;    # menu fileurl location
my @searchDirs; # search directories for menu opml files

sub initPlugin {
	my $class = shift;

	if ( !main::SLIM_SERVICE ) {
		Slim::Plugin::InfoBrowser::Settings->new($class);
	}

	$class->SUPER::initPlugin;

	if ( !main::SLIM_SERVICE ) {
		$menuUrl    = $class->_menuUrl;
		@searchDirs = $class->_searchDirs;
		
		Slim::Plugin::InfoBrowser::Settings->importNewMenuFiles;
	}
	

	Slim::Control::Request::addDispatch(['infobrowser', 'items', '_index', '_quantity'],
		[0, 1, 1, \&cliQuery]);
}

sub getDisplayName { 'PLUGIN_INFOBROWSER' };

sub setMode {
	my $class  = shift;
    my $client = shift;
    my $method = shift;

    if ( $method eq 'pop' ) {
        Slim::Buttons::Common::popMode($client);
        return;
    }

	my %params = (
		modeName => 'InfoBrowser',
		url      => $menuUrl,
		title    => getDisplayName(),
	);

	Slim::Buttons::Common::pushMode($client, 'xmlbrowser', \%params);

	# we'll handle the push in a callback
	$client->modeParam('handledTransition',1)
}

sub webPages {
	my $class = shift;

	my $title = getDisplayName();
	my $url   = 'plugins/Favorites/index.html?new=' . $class->_menuUrl() . '&autosave';

	Slim::Web::Pages->addPageLinks('plugins', { $title => $url });
}

sub cliQuery {
	my $request = shift;
	
	if ( main::SLIM_SERVICE ) {
		my $client = $request->client;
		
		use Slim::Networking::SqueezeNetwork;
		my $url = Slim::Networking::SqueezeNetwork->url( '/public/opml/' . $client->playerData->userid->emailHash . '/rss.opml' );
		
		Slim::Buttons::XMLBrowser::cliQuery('infobrowser', $url, $request);
		return;
	}

	Slim::Buttons::XMLBrowser::cliQuery('infobrowser', $menuUrl, $request);
}

sub searchDirs {
	return @searchDirs;
}

sub menuUrl {
	return $menuUrl;
}

sub _menuUrl {
	my $class = shift;

	my $dir = $prefsServer->get('playlistdir');

	if (!$dir || !-w $dir) {
		$dir = $prefsServer->get('cachedir');
	}

	my $file = catdir($dir, "infobrowser.opml");

	my $menuUrl = Slim::Utils::Misc::fileURLFromPath($file);

	if (-r $file) {

		if (-w $file) {
			$log->info("infobrowser menu file: $file");

		} else {
			$log->warn("unable to write to infobrowser menu file: $file");
		}

	} else {

		$log->info("creating infobrowser menu file: $file");

		my $newopml = Slim::Plugin::Favorites::Opml->new;
		$newopml->title(Slim::Utils::Strings::string('PLUGIN_INFOBROWSER'));
		$newopml->save($file);

		Slim::Plugin::InfoBrowser::Settings->importNewMenuFiles('clear');
	}

	return $menuUrl;
}

sub _searchDirs {
	my $class = shift;

	my @searchDirs;
	
	push @searchDirs, $class->_pluginDataFor('basedir');

	# find location of Addons dir and add this to the path searched for opml menus
	my @pluginDirs = Slim::Utils::OSDetect::dirsFor('Plugins');
	for my $dir (@pluginDirs) {
		my $addonDir = catdir($dir, 'InfoBrowserAddons');
		if (-r $addonDir) {
			push @searchDirs, $addonDir;
		}
	}

	return @searchDirs;
}


1;
