package Slim::Plugin::Favorites::OpmlFavorites;

# An opml based favorites handler

# $Id: OpmlFavorites.pm 22935 2008-08-28 15:00:49Z andy $

use strict;

use base qw(Slim::Plugin::Favorites::Opml);

use File::Spec::Functions qw(:ALL);
use Scalar::Util qw(blessed);

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $log = logger('favorites');

my $prefsServer = preferences('server');

my $favs; # single instance for all callers

sub new {
	return $favs if $favs;

	my $class  = shift;
	my $client = shift; # ignored for this version as favorites are shared by all clients

	$favs = $class->SUPER::new;

	if (-r $favs->filename) {

		$favs->load({ 'url' => $favs->filename });

	} else {

		$favs->_loadOldFavorites;
	}

	Slim::Control::Request::subscribe(sub {
		my $request = shift;

		if ($request->getRequestString() eq 'rescan done'){
			$favs->_urlindex;
		}
		
	}, [['rescan', 'done']]);

	return $favs;
}

sub filename {
	my $class = shift;

	my $dir = $prefsServer->get('playlistdir');

	if (!-w $dir) {

		$dir = $prefsServer->get('cachedir');
	}

	return catdir($dir, "favorites.opml");
}

sub icon {
	my $class = shift;
	my $url = shift;

	return Slim::Player::ProtocolHandlers->iconForURL($url) || 'html/images/favorites.png';
}

sub load {
	my $class = shift;

	$class->SUPER::load(@_);
	$class->_urlindex;
}

sub save {
	my $class = shift;

	$class->SUPER::save(@_);
	$class->_urlindex;

	Slim::Control::Request::notifyFromArray(undef, ['favorites', 'changed']);
}

sub _urlindex {
	my $class = shift;
	my $level = shift;
	my $index = shift || '';

	unless (defined $level) {
		$class->{'url-index'} = {};
		$class->{'hotkey-index'} = {};
		$class->{'hotkey-title'} = {};
		$class->{'url-hotkey'} = {};
		$level = $class->toplevel;
	}

	my $i = 0;

	for my $entry (@{$level}) {

		if ($entry->{'URL'} || $entry->{'url'}) {
			$class->{'url-index'}->{ $entry->{'URL'} || $entry->{'url'} } = $index . $i;
		}

		if (defined $entry->{'hotkey'}) {
			$class->{'hotkey-index'}->{ $entry->{'hotkey'} } = $index . $i;
			$class->{'hotkey-title'}->{ $entry->{'hotkey'} } = $entry->{'text'};
			$class->{'url-hotkey'}->{ $entry->{'URL'} || $entry->{'url'} } = $entry->{'hotkey'};
		}

		# look up icon if not defined or an album or track (can change during rescan)
		if (!$entry->{'icon'} || $entry->{'URL'} =~ /^db:album/ || $entry->{'URL'} =~ /^file:/) {
			$entry->{'icon'} = $class->icon($entry->{'URL'});
		}

		if ($entry->{'outline'}) {
			$class->_urlindex($entry->{'outline'}, $index."$i.");
		}

		$i++;
	}
}

sub _loadOldFavorites {
	my $class = shift;

	my $toplevel = $class->toplevel;

	$log->info("No opml favorites file found - loading old favorites");

	my @urls   = @{Slim::Utils::Prefs::OldPrefs->get('favorite_urls')   || []};
	my @titles = @{Slim::Utils::Prefs::OldPrefs->get('favorite_titles') || []} ;
	my @hotkeys= (1..9, 0);

	while (@urls) {

		my $entry = {
			'text'   => shift @titles,
			'URL'    => shift @urls,
			'type'   => 'audio',
		};

		if (@hotkeys) {
			$entry->{'hotkey'} = shift @hotkeys;
		}

		$entry->{'icon'} = $class->icon($entry->{'url'});

		push @$toplevel, $entry;
	}

	$class->title(string('FAVORITES'));

	$class->save;
}

sub xmlbrowser {
	my $class = shift;

	$class->SUPER::xmlbrowser;

	$class->{'xmlhash'}->{'favorites'} = 1;

	return $class->{'xmlhash'};
}

sub all {
	my $class  = shift;
	my $typeRE = shift || qr/audio|playlist/;
	my $level  = shift || $class->toplevel;
	my $return = shift || [];

	for my $entry (@{$level}) {

		if ($entry->{'type'} && $entry->{'type'} =~ /$typeRE/) {
			push @$return, {
				'title' => $entry->{'text' },
				'url'   => $entry->{'URL'} || $entry->{'url'},
			}
		}

		if ($entry->{'outline'}) {
			$class->all($typeRE, $entry->{'outline'}, $return);
		}
	}

	return $return;
}

sub add {
	my $class  = shift;
	my $url    = shift;
	my $title  = shift;
	my $type   = shift;
	my $parser = shift;
	my $hotkey = shift; # pick next available hotkey for this url
	my $icon   = shift;

	if (!$url) {
		logWarning("No url passed! Skipping.");
		return undef;
	}

	if (blessed($url) && $url->can('url')) {
		$url = $url->url;
	}

	$url =~ s/\?sessionid.+//i;	# Bug 3362, ignore sessionID's within URLs (Live365)

	if ( $log->is_info ) {
		$log->info(sprintf("url: %s title: %s type: %s parser: %s hotkey: %s icon: %s", $url, $title, $type, $parser, $hotkey, $icon));
	}

	# if it is already a favorite, don't add it again return the existing entry
	if ($class->hasUrl($url)) {

		my $index = $class->{'url-index'}->{ $url };
		my $entry = $class->entry($index);

		$log->info("Url already exists in favorites as index $index");

		return wantarray ? ($index, $entry->{'hotkey'}) : $index;
	}

	my $entry = {
		'text' => $title,
		'URL'  => $url,
		'type' => $type || 'audio',
	};

	if ($parser) {
		$entry->{'parser'} = $parser;
	}
	
	if ( $url =~ /\.opml$/ ) {
		delete $entry->{'type'};
	}

	if ($hotkey) {
		for my $i (1..9, 0) {
			if (!defined $class->{'hotkey-index'}->{ $i }) {
				$entry->{'hotkey'} = $i;
				last;
			}
		}
	}

	$entry->{'icon'} = $icon || $class->icon($url);

	# add it to end of top level
	push @{$class->toplevel}, $entry;

	$class->save;

	return wantarray ? (scalar @{$class->toplevel} - 1, $entry->{'hotkey'}) : scalar @{$class->toplevel} - 1;
}

sub hasUrl {
	my $class = shift;
	my $url   = shift;

	return (defined $class->{'url-index'}->{ $url });
}

sub findUrl {
	my $class  = shift;
	my $url    = shift;

	$url =~ s/\?sessionid.+//i;	# Bug 3362, ignore sessionID's within URLs (Live365)

	my $index = $class->{'url-index'}->{ $url };
	my $hotkey = $class->{'url-hotkey'}->{ $url };

	if (defined $index) {

		$log->info("Match $url at index $index");

		return wantarray ? ($index, $hotkey) : $index;
	}

	$log->info("No match for $url");

	return undef;
}

sub deleteUrl {
	my $class  = shift;
	my $url    = shift;

	if (blessed($url) && $url->can('url')) {
		$url = $url->url;
	}

	$url =~ s/\?sessionid.+//i;	# Bug 3362, ignore sessionID's within URLs (Live365)

	if (exists $class->{'url-index'}->{ $url }) {

		$class->deleteIndex($class->{'url-index'}->{ $url });

	} else {

		$log->warn("Can't delete $url index does not exist");
	}
}

sub deleteIndex {
	my $class  = shift;
	my $index  = shift;

	my ($pos, $i) = $class->level($index, 'contains');

	if (ref @{$pos}[ $i ] eq 'HASH') {

		splice @{$pos}, $i, 1;

		$log->info("Removed entry at index $index");

		$class->save;
	}
}

sub hotkeys {
	my $class = shift;

	my @keys;

	for my $key (1..9,0) {
		push @keys, {
			'key'   => $key,
			'used'  => $class->{'hotkey-index'}->{ $key } ? 1 : 0,
			'title' => $class->{'hotkey-title'}->{ $key },
		};
	}

	return \@keys;
}

sub hasHotkey {
	my $class = shift;
	my $key   = shift;

	return $class->{'hotkey-index'}->{ $key };
}

sub setHotkey {
	my $class = shift;
	my $index = shift;
	my $key   = shift;

	if (defined $key && $class->{'hotkey-index'}->{ $key }) {

		$log->warn("Hotkey $key already used - not setting");
		return;
	}

	my ($pos, $i) = $class->level($index, 'contains');

	if (ref @{$pos}[ $i ] eq 'HASH') {

		if (defined $key) {
			
			@{$pos}[ $i ]->{'hotkey'} = $key;

			$log->info("Setting hotkey $key for index $index");

		} else {

			delete @{$pos}[ $i ]->{'hotkey'};

			$log->info("Deleting hotkey for index $index");
		}

		$class->save;
	}
}

1;
