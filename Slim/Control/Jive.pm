package Slim::Control::Jive;

# SqueezeCenter Copyright 2001-2007 Logitech
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use POSIX;
use Scalar::Util qw(blessed);
use File::Spec::Functions qw(:ALL);
use File::Basename;
use URI;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Player::Playlist;
use Slim::Buttons::Information;
use Slim::Buttons::Synchronize;
use Slim::Player::Sync;
use Slim::Player::Client;
#use Data::Dump;

my $prefs   = preferences("server");

=head1 NAME

Slim::Control::Jive

=head1 SYNOPSIS

CLI commands used by Jive.

=cut

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'player.jive',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

# additional top level menus registered by plugins
my %itemsToDelete      = ();
my @pluginMenus        = ();
my @recentSearches     = ();

=head1 METHODS

=head2 init()

=cut
sub init {
	my $class = shift;

	# register our functions
	
       #        |requires Client
       #        |  |is a Query
       #        |  |  |has Tags
       #        |  |  |  |Function to call
       #        C  Q  T  F

	Slim::Control::Request::addDispatch(['menu', '_index', '_quantity'], 
		[0, 1, 1, \&menuQuery]);

	Slim::Control::Request::addDispatch(['alarmsettings', '_index', '_quantity'], 
		[1, 1, 1, \&alarmSettingsQuery]);

	Slim::Control::Request::addDispatch(['jiveupdatealarm', '_index', '_quantity'], 
		[1, 1, 1, \&alarmUpdateMenu]);

	Slim::Control::Request::addDispatch(['jiveupdatealarmdays', '_index', '_quantity'], 
		[1, 1, 1, \&alarmUpdateDays]);

	Slim::Control::Request::addDispatch(['jiveupdateplaylist', '_index', '_quantity'], 
		[1, 1, 1, \&alarmUpdatePlaylistQuery]);

	Slim::Control::Request::addDispatch(['syncsettings', '_index', '_quantity'],
		[1, 1, 1, \&syncSettingsQuery]);

	Slim::Control::Request::addDispatch(['sleepsettings', '_index', '_quantity'],
		[1, 1, 1, \&sleepSettingsQuery]);

	Slim::Control::Request::addDispatch(['jivetonesettings', '_index', '_quantity'],
		[1, 1, 1, \&toneSettingsQuery]);

	Slim::Control::Request::addDispatch(['jivetoneadjust'],
		[1, 0, 1, \&toneAdjustCommand]);

	Slim::Control::Request::addDispatch(['jivestereoxl', '_index', '_quantity'],
		[1, 1, 1, \&stereoXLQuery]);

	Slim::Control::Request::addDispatch(['jivesetstereoxl'],
		[1, 0, 1, \&stereoXLCommand]);

	Slim::Control::Request::addDispatch(['jivelineout', '_index', '_quantity'],
		[1, 1, 1, \&lineOutQuery]);

	Slim::Control::Request::addDispatch(['jivesetlineout'],
		[1, 0, 1, \&lineOutCommand]);

	Slim::Control::Request::addDispatch(['crossfadesettings', '_index', '_quantity'],
		[1, 1, 1, \&crossfadeSettingsQuery]);

	Slim::Control::Request::addDispatch(['replaygainsettings', '_index', '_quantity'],
		[1, 1, 1, \&replaygainSettingsQuery]);

	Slim::Control::Request::addDispatch(['playerinformation', '_index', '_quantity'],
		[1, 1, 1, \&playerInformationQuery]);

	Slim::Control::Request::addDispatch(['jivedummycommand', '_index', '_quantity'],
		[1, 1, 1, \&jiveDummyCommand]);

	Slim::Control::Request::addDispatch(['jivefavorites', '_cmd' ],
		[1, 0, 1, \&jiveFavoritesCommand]);

	Slim::Control::Request::addDispatch(['jiveplayerbrightnesssettings', '_index', '_quantity'],
		[1, 1, 0, \&playerBrightnessMenu]);

	Slim::Control::Request::addDispatch(['jivebrightnessadjust'],
		[1, 0, 1, \&playerBrightnessAdjustCommand]);

	Slim::Control::Request::addDispatch(['jiveplayertextsettings', '_index', '_quantity'],
		[1, 1, 0, \&playerTextMenu]);

	Slim::Control::Request::addDispatch(['jivetextadjust'],
		[1, 0, 1, \&playerTextAdjustCommand]);

	Slim::Control::Request::addDispatch(['jiveunmixable'],
		[1, 1, 1, \&jiveUnmixableMessage]);

	Slim::Control::Request::addDispatch(['jivealbumsortsettings'],
		[1, 0, 1, \&albumSortSettingsMenu]);

	Slim::Control::Request::addDispatch(['jivesetalbumsort'],
		[1, 0, 1, \&jiveSetAlbumSort]);

	Slim::Control::Request::addDispatch(['jiveplaylists', '_cmd' ],
		[1, 0, 1, \&jivePlaylistsCommand]);

	Slim::Control::Request::addDispatch(['jiverecentsearches'],
		[0, 1, 0, \&jiveRecentSearchQuery]);

	Slim::Control::Request::addDispatch(['jiveplaytrackalbum'],
		[1, 0, 1, \&jivePlayTrackAlbumCommand]);

	Slim::Control::Request::addDispatch(['date'],
		[0, 1, 0, \&dateQuery]);

	Slim::Control::Request::addDispatch(['firmwareupgrade'],
		[0, 1, 1, \&firmwareUpgradeQuery]);

	Slim::Control::Request::addDispatch(['jiveapplets'],
		[0, 1, 0, \&downloadQuery]);

	Slim::Control::Request::addDispatch(['jivewallpapers'],
		[0, 1, 0, \&downloadQuery]);

	Slim::Control::Request::addDispatch(['jivesounds'],
		[0, 1, 0, \&downloadQuery]);
	
	if ( !main::SLIM_SERVICE ) {
		Slim::Web::HTTP::addRawDownload('^jive(applet|wallpaper|sound)/', \&downloadFile, 'binary');
	}

	# setup the menustatus dispatch and subscription
	Slim::Control::Request::addDispatch( ['menustatus', '_data', '_action'],
		[0, 0, 0, sub { warn "menustatus query\n" }]);
	Slim::Control::Request::subscribe( \&menuNotification, [['menustatus']] );
	
	# setup a cli command for jive that returns nothing; can be useful in some situations
	Slim::Control::Request::addDispatch( ['jiveblankcommand'],
		[0, 0, 0, sub { return 1; }]);

	if ( !main::SLIM_SERVICE ) {
		# Load memory caches to help with menu performance
		buildCaches();
	}
	
	# Re-build the caches after a rescan
	Slim::Control::Request::subscribe( \&buildCaches, [['rescan', 'done']] );
}

sub buildCaches {
	$log->info("Begin function");
	my $sort    = $prefs->get('jivealbumsort') || 'artistalbum';
	# Pre-cache albums query
	if ( my $numAlbums = Slim::Schema->rs('Album')->count ) {
		$log->debug( "Pre-caching $numAlbums album items." );
		Slim::Control::Request::executeRequest( undef, [ 'albums', 0, $numAlbums, "sort:$sort", 'menu:track', 'cache:1' ] );
	}
	
	# Artists
	if ( my $numArtists = Slim::Schema->rs('Contributor')->browse->search( {}, { distinct => 'me.id' } )->count ) {
		# Add one since we may have a VA item
		$numArtists++;
		$log->debug( "Pre-caching $numArtists artist items." );
		Slim::Control::Request::executeRequest( undef, [ 'artists', 0, $numArtists, 'menu:album', 'cache:1' ] );
	}
	
	# Genres
	if ( my $numGenres = Slim::Schema->rs('Genre')->browse->search( {}, { distinct => 'me.id' } )->count ) {
		$log->debug( "Pre-caching $numGenres genre items." );
		Slim::Control::Request::executeRequest( undef, [ 'genres', 0, $numGenres, 'menu:artist', 'cache:1' ] );
	}
}

=head2 getDisplayName()

Returns name of module

=cut
sub getDisplayName {
	return 'JIVE';
}

######
# CLI QUERIES

# handles the "menu" query
sub menuQuery {

	my $request = shift;

	$log->info("Begin menuQuery function");

	if ($request->isNotQuery([['menu']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client        = $request->client() || 0;

	# send main menu notification
	mainMenu($client);

	# a single dummy item to keep jive happy with _merge
	my $upgradeText = 
	"Please upgrade your firmware at:\n\nSettings->\nController Settings->\nAdvanced->\nSoftware Update\n\nThere have been updates to better support the communication between your remote and SqueezeCenter, and this requires a newer version of firmware.";
        my $upgradeMessage = {
		text      => 'READ ME',
		weight    => 1,
                offset    => 0,
                count     => 1,
                window    => { titleStyle => 'settings' },
                textArea =>  $upgradeText,
        };

        $request->addResult("count", 1);
	$request->addResult("offset", 0);
	$request->setResultLoopHash('item_loop', 0, $upgradeMessage);
	$request->setStatusDone();

}

sub mainMenu {

	$log->info("Begin function");
	my $client = shift;

	unless ($client->isa('Slim::Player::Client')) {
		# if this isn't a player, no menus should get sent
		return;
	}
 
	$log->info("Begin Function");
 
	# as a convention, make weights => 10 and <= 100; Jive items that want to be below all SS items
	# then just need to have a weight > 100, above SS items < 10

	# for the notification menus, we're going to send everything over "flat"
	# as a result, no item_loops, all submenus (setting, myMusic) are just elements of the big array that get sent

	my @menu = map {
		$_->{text} = $client->string($_->{stringToken}) if ($_->{stringToken});
		$_;
	}(
		{
			stringToken    => 'MY_MUSIC',
			weight         => 11,
			id             => 'myMusic',
			isANode        => 1,
			node           => 'home',
			window         => { titleStyle => 'mymusic', },
		},
		{
			stringToken    => 'FAVORITES',
			id             => 'favorites',
			node           => 'home',
			weight         => 40,
			actions => {
				go => {
					cmd => ['favorites', 'items'],
					params => {
						menu     => 'favorites',
					},
				},
			},
			window        => {
					titleStyle => 'favorites',
			},
		},

		@pluginMenus,
		@{playerPower($client, 1)},
		@{playerSettingsMenu($client, 1)},
		@{
			# The Digital Input plugin could be disabled
			if( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DigitalInput::Plugin')) {
				Slim::Plugin::DigitalInput::Plugin::digitalInputItem($client);
			} else {
				[];
			}
		},
		@{
			# The Line In plugin could be disabled
			if( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::LineIn::Plugin')) {
				Slim::Plugin::LineIn::Plugin::lineInItem($client, 0);
			} else {
				[];
			}
		},
		@{internetRadioMenu($client)},
		@{musicServicesMenu($client)},
		@{albumSortSettingsItem($client, 1)},
		@{myMusicMenu(1, $client)},
		@{recentSearchMenu($client, 1)},
	);
	
	# SN Jive Menu
	if ( main::SLIM_SERVICE ) {
		@menu = map {
			$_->{text} = $client->string($_->{stringToken}) if ($_->{stringToken});
			$_;
		} (
			{
				text           => $client->string('MY_MUSIC'),
				id             => 'myMusic',
				node           => 'home',
				weight         => 15,
				actions        => {
					go => {
						cmd => ['my_music'],
						params => {
							menu => 'my_music',
						},
					},
				},
				window        => {
					menuStyle  => 'album',
					titleStyle => 'mymusic',
				},
			},
			{
				text           => $client->string('RADIO'),
				id             => 'radio',
				node           => 'home',
				weight         => 20,
				actions        => {
					go => {
						cmd => ['radios'],
						params => {
							menu => 'radio',
						},
					},
				},
				window        => {
					menuStyle => 'album',
					titleStyle => 'internetradio',
				},
			},
			{
				text           => $client->string('MUSIC_SERVICES'),
				id             => 'ondemand',
				node           => 'home',
				weight         => 30,
				actions => {
					go => {
						cmd => ['music_services'],
						params => {
							menu => 'music_services',
						},
					},
				},
				window        => {
					menuStyle => 'album',
					titleStyle => 'internetradio',
				},
			},
			{
				text           => $client->string('FAVORITES'),
				id             => 'favorites',
				node           => 'home',
				weight         => 40,
				actions        => {
					go => {
						cmd => ['favorites', 'items'],
						params => {
							menu     => 'favorites',
						},
					},
				},
				window        => {
					titleStyle => 'favorites',
				},
			},
			@pluginMenus,
			@{playerPower($client, 1)},
			@{Slim::Plugin::DigitalInput::Plugin::digitalInputItem($client)},
			@{Slim::Plugin::LineIn::Plugin::lineInItem($client)},
			@{playerSettingsMenu($client, 1)},
		);
	}

	_notifyJive(\@menu, $client);
}

sub jiveSetAlbumSort {
	my $request = shift;
	my $client  = $request->client;
	my $sort = $request->getParam('sortMe');
	$prefs->set('jivealbumsort', $sort);
	# resend the myMusic menus with the new sort pref set
	myMusicMenu(0, $client);
	$request->setStatusDone();
}

sub albumSortSettingsMenu {
	$log->info("Begin function");
	my $request = shift;
	my $client = $request->client;
	my $sort    = $prefs->get('jivealbumsort');
	my %sortMethods = (
		artistalbum =>	'SORT_ARTISTALBUM',
		artflow =>	'SORT_ARTISTYEARALBUM',
		album =>	'ALBUM',
	);
	$request->addResult('count', scalar(keys %sortMethods));
	$request->addResult('offset', 0);
	my $i = 0;
	for my $key (sort keys %sortMethods) {
		$request->addResultLoop('item_loop', $i, 'text', $client->string($sortMethods{$key}));
		my $selected = ($sort eq $key) + 0;
		$request->addResultLoop('item_loop', $i, 'radio', $selected);
		my $actions = {
			do => {
				player => 0,
				cmd    => ['jivesetalbumsort'],
				params => {
					'sortMe' => $key,
				},
			},
		};
		$request->addResultLoop('item_loop', $i, 'actions', $actions);
		$i++;
	}
	
}

sub albumSortSettingsItem {
	$log->info("Begin function");
	my $client = shift;
	my $batch = shift;

	my @menu = ();
	push @menu,
	{
		text           => $client->string('ALBUMS_SORT_METHOD'),
		id             => 'settingsAlbumSettings',
		node           => 'advancedSettings',
		weight         => 100,
			actions        => {
			go => {
				cmd => ['jivealbumsortsettings'],
				params => {
					menu => 'radio',
				},
			},
		},
		window        => {
				titleStyle => 'settings',
		},
	};

	if ($batch) {
		return \@menu;
	} else {
		_notifyJive(\@menu, $client);
	}

}

# allow a plugin to add a node to the menu
sub registerPluginNode {
	$log->info("Begin function");
	my $nodeRef = shift;
	my $client = shift || undef;
	unless (ref($nodeRef) eq 'HASH') {
		$log->error("Incorrect data type");
		return;
	}

	$nodeRef->{'isANode'} = 1;
	$log->info("Registering node menu item from plugin");

	# notify this menu to be added
	my $id = _clientId($client);
	Slim::Control::Request::notifyFromArray( $client, [ 'menustatus', $nodeRef, 'add', $id ] );

	# but also remember this structure as part of the plugin menus
	push @pluginMenus, $nodeRef;

}

# send plugin menus array as a notification to Jive
sub refreshPluginMenus {
	$log->info("Begin function");
	my $client = shift || undef;
	_notifyJive(\@pluginMenus, $client);
}

#allow a plugin to add an array of menu entries
sub registerPluginMenu {
	my $menuArray = shift;
	my $node = shift;
	my $client = shift || undef;

	unless (ref($menuArray) eq 'ARRAY') {
		$log->error("Incorrect data type");
		return;
	}

	if ($node) {
		my @menuArray = @$menuArray;
		for my $i (0..$#menuArray) {
			if (!$menuArray->[$i]{'node'}) {
				$menuArray->[$i]{'node'} = $node;
			}
		}
	}

	$log->info("Registering menus from plugin");

	# notify this menu to be added
	my $id = _clientId($client);
	Slim::Control::Request::notifyFromArray( $client, [ 'menustatus', $menuArray, 'add', $id ] );

	# now we want all of the items in $menuArray to go into @pluginMenus, but we also
	# don't want duplicate items (specified by 'id'), 
	# so we want the ids from $menuArray to stomp on ids from @pluginMenus, 
	# thus getting the "newest" ids into the @pluginMenus array of items
	# we also do not allow any hash without an id into the array, and will log an error if that happens

	my %seen; my @new;

	for my $href (@$menuArray, reverse @pluginMenus) {
		my $id = $href->{'id'};
		my $node = $href->{'node'};
		if ($id) {
			if (!$seen{$id}) {
				$log->info("registering menuitem " . $id . " to " . $node );
				push @new, $href;
			}
			$seen{$id}++;
		} else {
			$log->error("Menu items cannot be added without an id");
		}
	}

	# @new is the new @pluginMenus
	# we do this in reverse so we get previously initialized nodes first 
	# you can't add an item to a node that doesn't exist :)
	@pluginMenus = reverse @new;

}

# allow a plugin to delete an item from the Jive menu based on the id of the menu item
sub deleteMenuItem {
	my $menuId = shift;
	my $client = shift || undef;
	return unless $menuId;
	$log->warn($menuId . " menu id slated for deletion");
	# send a notification to delete
	my @menuDelete = ( { id => $menuId } );
	my $id = _clientId($client);
	Slim::Control::Request::notifyFromArray( $client, [ 'menustatus', \@menuDelete, 'remove', $id ] );
	# but also remember that this id is not to be sent
	$itemsToDelete{$menuId}++;
}

sub _purgeMenu {
	my $menu = shift;
	my @menu = @$menu;
	my @purgedMenu = ();
	for my $i (0..$#menu) {
		my $menuId = defined($menu[$i]->{id}) ? $menu[$i]->{id} : ($menu[$i]->{stringToken} ? $menu[$i]->{stringToken} : $menu[$i]->{text});
		last unless (defined($menu[$i]));
		if ($itemsToDelete{$menuId}) {
			$log->warn("REMOVING " . $menuId . " FROM Jive menu");
		} else {
			push @purgedMenu, $menu[$i];
		}
	}
	return \@purgedMenu;
}


sub alarmSettingsQuery {

	$log->info("Begin function");
	my $request = shift;
	my $client  = $request->client();

	my @menu = ();
	return \@menu unless $client;

	# All Alarms On/Off

	my $val = $prefs->client($client)->get('alarmsEnabled');

	my @alarmStrings = ('OFF', 'ON');
	my @translatedAlarmStrings = map { ucfirst($client->string($_)) } @alarmStrings;

	my $onOff = {
		text           => $client->string("ALARM_ALL_ALARMS"),
		choiceStrings  => [ @translatedAlarmStrings ],
		selectedIndex  => $val + 1, # 1 is added to make it count like Lua
		actions        => {
			do => { 
				choices => [ 
					{
						player => 0,
						cmd    => [ 'alarm', 'disableall' ],
					},
					{
						player => 0,
						cmd    => [ 'alarm', 'enableall' ],
					},
				], 
			},
		},
	};
	push @menu, $onOff;

	my $setAlarms = getCurrentAlarms($client);

	if ( scalar(@$setAlarms) ) {
		push @menu, @$setAlarms;
	}

	my $addAlarm = {
		text           => $client->string("ALARM_ADD"),
		input   => {
			initialText  => 0, # this will need to be formatted correctly
			_inputStyle  => 'time',
			len          => 1,
			help         => {
				text => $client->string('JIVE_ALARMSET_HELP')
			},
		},
		actions => {
			do => {
				player => 0,
				cmd    => [ 'alarm', 'add' ],
				params => {
					time => '__TAGGEDINPUT__',	
					enabled => 1,
				},
			},
		},
		nextWindow => 'parent',
		window         => { titleStyle => 'settings' },
	};
	push @menu, $addAlarm;

	# Bug 9226: don't offer alarm volume setting if player is set for fixed volume
	my $digitalVolumeControl = $prefs->client($client)->get('digitalVolumeControl');
	if ( ! ( defined $digitalVolumeControl && $digitalVolumeControl == 0 ) ) {
		my $defaultVolLevel = Slim::Utils::Alarm->defaultVolume($client);
		my $defaultVolumeLevels = alarmVolumeSettings($defaultVolLevel, undef, $client->string('ALARM_VOLUME'));
		push @menu, $defaultVolumeLevels;
	}

	sliceAndShip($request, $client, \@menu);

}

sub alarmUpdateMenu {

	my $request = shift;
	my $client  = $request->client();
	my $params;

	my @tags = qw( id enabled days time playlist );
	for my $tag (@tags) {
		$params->{$tag} = $request->getParam($tag);
	}

	my $alarm = Slim::Utils::Alarm->getAlarm($client, $params->{id});
	my @menu = ();

	my $enabled = $alarm->enabled();
	my $onOff = {
		window   => { titleStyle => 'settings' },
		text     => $client->string("ALARM_ALARM_ENABLED"),
		checkbox => ($enabled == 1) + 0,
		actions  => {
			on  => {
				player => 0,
				cmd    => [ 'alarm', 'update' ],
				params => {
					id      => $params->{id},
					enabled => 1,
				},
			},
			off => {
				player => 0,
				cmd    => [ 'alarm', 'update' ],
				params => {
					id      => $params->{id},
					enabled => 0,
				},
			},
		},		
		nextWindow => 'refresh',
	};
	push @menu, $onOff;

	my $setTime = {
		text           => $client->string("ALARM_SET_TIME"),
		input   => {
			initialText  => $params->{time}, # this will need to be formatted correctly
			_inputStyle  => 'time',
			len          => 1,
			help         => {
				text => $client->string('JIVE_ALARMSET_HELP')
			},
		},
		actions => {
			do => {
				player => 0,
				cmd    => [ 'alarm', 'update' ],
				params => {
					id   => $params->{id},
					time => '__TAGGEDINPUT__',	
				},
			},
		},
		nextWindow => 'grandparent',
		window         => { titleStyle => 'settings' },
	};
	push @menu, $setTime;


	my $setDays = {
		text      => $client->string("ALARM_SET_DAYS"),
		actions   => {
			go => {
				player => 0,
				cmd    => [ 'jiveupdatealarmdays' ],
				params => {
					id => $params->{id},
				},
			},
		},
		window    => { titleStyle => 'settings' },
	};
	push @menu, $setDays;

	my $playlistChoice = {
		text      => $client->string('ALARM_SELECT_PLAYLIST'),
		actions   => {
			go => {
				player => 0,
				cmd    => [ 'jiveupdateplaylist' ],
				params => {
					id => $params->{id},
				},
			},
		},
		window    => { titleStyle => 'settings' },
	};
	push @menu, $playlistChoice;

	my $repeat = $alarm->repeat();
	my $repeatOnOff = {
		window   => { titleStyle => 'settings' },
		text     => $client->string("ALARM_ALARM_REPEAT"),
		checkbox => ($repeat == 1) + 0,
		actions  => {
			on  => {
				player => 0,
				cmd    => [ 'alarm', 'update' ],
				params => {
					id      => $params->{id},
					repeat => 1,
				},
			},
			off => {
				player => 0,
				cmd    => [ 'alarm', 'update' ],
				params => {
					id      => $params->{id},
					repeat => 0,
				},
			},
		},		
		nextWindow => 'refresh',
	};
	push @menu, $repeatOnOff;


	my @delete_menu= (
		{
			text    => $client->string('CANCEL'),
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jiveblankcommand' ],
				},
			},
			nextWindow => 'parent',
		},
		{
			text    => $client->string('ALARM_DELETE'),
			actions => {
				go => {
					player => 0,
					cmd    => ['alarm', 'delete'],
					params => {
						id => $params->{id},
					},
				},
			},
			nextWindow => 'grandparent',
		},
	);
	my $removeAlarm = {
		text      => $client->string('ALARM_DELETE'),
		count     => scalar(@delete_menu),
		offset    => 0,
		item_loop => \@delete_menu,
	};
	push @menu, $removeAlarm;

	sliceAndShip($request, $client, \@menu);
}

sub alarmUpdateDays {

	my $request = shift;
	my $client  = $request->client;

	my @params  = qw/ id /;
	my $params;
	for my $key (@params) {
		$params->{$key} = $request->getParam($key);
	}
	my $alarm = Slim::Utils::Alarm->getAlarm($client, $params->{id});

	my @days_menu = (
		{
			text => $client->string('ALARM_EVERY_DAY'),
			actions => {
				go => {
					cmd => [ 'alarm', 'update' ],
					params => {
						id => $params->{id},
						dow => '0,1,2,3,4,5,6',
					},
				},
			},
			nextWindow => 'refresh',
		},
		{
			text => $client->string('ALARM_WEEKDAYS'),
			actions => {
				go => {
					cmd => [ 'alarm', 'update' ],
					params => {
						id => $params->{id},
						dow => '1,2,3,4,5',
					},
				},
			},
			nextWindow => 'refresh',
		},
	);

	for my $day (0..6) {
		my $dayActive = $alarm->day($day);
		my $string = "ALARM_DAY$day";

		my $day = {
			text       => $client->string($string),
			checkbox   => $dayActive + 0,
			nextWindow => 'refreshOrigin',
			actions => {
				on => {
					player => 0,
					cmd    => [ 'alarm', 'update' ],
					params => {
						id => $params->{id},
						dowAdd => $day,
					},
				},
				off => {
					player => 0,
					cmd    => [ 'alarm', 'update' ],
					params => {
						id => $params->{id},
						dowDel => $day,
					},
				},
	
			},
		};
		push @days_menu, $day;
	}

	sliceAndShip($request, $client, \@days_menu);

	$request->setStatusDone();
}

sub alarmUpdatePlaylistQuery {

	my $request = shift;
	my $client  = $request->client;
	my @tags  = qw/ id /;
	my $params;
	for my $tag (@tags) {
		$params->{$tag} = $request->getParam($tag);
	}

	my $playlists      = Slim::Utils::Alarm->getPlaylists($client);
	my $alarm          = Slim::Utils::Alarm->getAlarm($client, $params->{id});
	my $currentSetting = $alarm->playlist();

	my @playlistChoices;
	for my $typeRef (@$playlists) {
		my $type = $typeRef->{type};
		my @choices = ();
		my $aref = $typeRef->{items};
		for my $choice (@$aref) {

			my $radio = 0;
			if ( 
				( $currentSetting eq $choice->{url} ) || 
				( ! defined $choice->{url} && ! defined $currentSetting )
			) { 
				$radio = 1;				
			}
			my $subitem = {
				text    => $choice->{title},
				radio   => $radio,
				nextWindow => 'refreshOrigin',
				actions => {
					do => {
						cmd    => [ 'alarm', 'update' ],
						params => {
							id          => $params->{id},
							playlisturl => $choice->{url} || 0, # send 0 for "current playlist"
						},
					},
				},
			};

			if ( defined($choice->{url}) ) {
				push @choices, $subitem;
			# use current playlist doesn't need a submenu
			} else {
				$subitem->{'nextWindow'} = 'refresh';
				push @playlistChoices, $subitem;
			}
		}

		if ( scalar(@choices) ) {
			my $item = {
				text      => $type,
				offset    => 0,
				count     => scalar(@choices),
				item_loop => \@choices,
			};
			push @playlistChoices, $item;
		}
	}

	sliceAndShip($request, $client, \@playlistChoices);
	$request->setStatusDone;
}

sub getCurrentAlarms {
	
	my $client = shift;
	my @return = ();
	my @alarms = Slim::Utils::Alarm->getAlarms($client);
	#Data::Dump::dump(@alarms);
	my $count = 1;
	for my $alarm (@alarms) {
		my @days;
		for (0..6) {
			push @days, $_ if $alarm->day($_);
		}
		my $name = $client->string('ALARM_ALARM') . " $count: " . $alarm->displayStr;
		my $daysString = join(',', @days);
		my $thisAlarm = {
			text           => $name,
			actions        => {
				go => {
					cmd    => ['jiveupdatealarm'],
					params => {
						id       => $alarm->id,
						enabled  => $alarm->enabled || 0,
						days     => $daysString,
						time     => $alarm->time || 0,
						playlist => $alarm->playlist || 0, # don't pass an undef to jive
					},
					player => 0,
				},
			},
			window         => { titleStyle => 'settings' },
		};
		push @return, $thisAlarm;
		$count++;
	}
	return \@return;
}

sub alarmVolumeSettings {

	my $current_setting = shift || 50;
	my $id              = shift || 0;
	my $string          = shift;

	my @vol_settings;

	my $slider = {
		slider      => 1,
		min         => 1,
		max         => 100,
		sliderIcons => 'volume',
		initial     => $current_setting,
		#help    => NO_HELP_STRING_YET,
		actions => {
			do => {
				player => 0,
				cmd    => [ 'alarm', 'defaultvolume' ],
				params => {
					valtag => 'volume',
				},
			},
		},
	};

	push @vol_settings, $slider;

	my $return = { 
		text      => $string,
		count     => scalar(@vol_settings),
		offset    => 0,
		item_loop => \@vol_settings,
	};
	return $return;
}

sub playerInformationQuery {
	my $request = shift;
	my $client  = $request->client();

	# information, always display
	my $playerInfoText = $client->string( 'INFORMATION_SPECIFIC_PLAYER', $client->name() );
	my $playerInfoTextArea = 
			$client->string("INFORMATION_PLAYER_NAME_ABBR") . ": " . 
			$client->name() . "\n\n" . 
			$client->string("INFORMATION_PLAYER_MODEL_ABBR") . ": " .
			Slim::Buttons::Information::playerModel($client) . "\n\n" .
			$client->string("INFORMATION_FIRMWARE_ABBR") . ": " . 
			$client->revision() . "\n\n" .
			$client->string("INFORMATION_PLAYER_IP_ABBR") . ": " .
			$client->ipport() . "\n\n" .
			$client->string("INFORMATION_PLAYER_MAC_ABBR") . ": " .
			uc($client->macaddress()) . "\n\n" .
			($client->signalStrength ? $client->string("INFORMATION_PLAYER_SIGNAL_STRENGTH") . ": " . 	 
			$client->signalStrength . "\n\n" : '') .
			($client->voltage ? $client->string("INFORMATION_PLAYER_VOLTAGE") . ": " .
			$client->voltage . "\n\n" : '');
	my @menu = (
		{
			textArea => $playerInfoTextArea,
		},
	);
	sliceAndShip($request, $client, \@menu);

	$request->setStatusDone();

	#return;
}

sub syncSettingsQuery {

	$log->info("Begin function");
	my $request           = shift;
	my $client            = $request->client();
	my $playersToSyncWith = getPlayersToSyncWith($client);

	my @menu = @$playersToSyncWith;

	sliceAndShip($request, $client, \@menu);

}

sub sleepSettingsQuery {

	$log->info("Begin function");
	my $request = shift;
	my $client  = $request->client();
	my $val     = $client->currentSleepTime();
	my @menu;

	if ($val > 0) {
		my $now = Time::HiRes::time();
		my $then = $client->sleepTime();
		my $sleepyTime = int( ($then - $now) / 60 ) + 1;
		my $sleepString = $client->string( 'SLEEPING_IN_X_MINUTES', $sleepyTime );
		push @menu, { text => $sleepString, style => 'itemNoAction' };
		push @menu, sleepInXHash($client, $val, 0);
	}
	push @menu, sleepInXHash($client, $val, 15);
	push @menu, sleepInXHash($client, $val, 30);
	push @menu, sleepInXHash($client, $val, 45);
	push @menu, sleepInXHash($client, $val, 60);
	push @menu, sleepInXHash($client, $val, 90);

	sliceAndShip($request, $client, \@menu);
}

sub stereoXLQuery {

	$log->info("Begin function");
	my $request        = shift;
	my $client         = $request->client();
	my $currentSetting = $client->stereoxl();
	my @strings = qw/ CHOICE_OFF LOW MEDIUM HIGH /;
	my @menu = ();
	for my $i (0..3) {
		my $xlSetting = {
			text    => $client->string($strings[$i]),
			radio   => ($i == $currentSetting) + 0,
			actions => {
				do => {
					player => 0,
					cmd    => [ 'jivesetstereoxl' ],
					params => {
						value  => $i,
					},
				},
			},
		};
		push @menu, $xlSetting;
	}

	sliceAndShip($request, $client, \@menu);

	$request->setStatusDone();

}

sub stereoXLCommand {

	my $request = shift;
	my $client  = $request->client();
	my $value   = $request->getParam('value');

	$client->stereoxl($value);

	$request->setStatusDone();
}

sub lineOutQuery {

	$log->info("Begin function");
	my $request        = shift;
	my $client         = $request->client();
	my $currentSetting = $prefs->client($client)->get('analogOutMode');
	my @strings = qw/ ANALOGOUTMODE_HEADPHONE ANALOGOUTMODE_SUBOUT /;
	my @menu = ();
	for my $i (0..1) {
		my $lineOutSetting = {
			text    => $client->string($strings[$i]),
			radio   => ($i == $currentSetting) + 0,
			actions => {
				do => {
					player => 0,
					cmd    => [ 'jivesetlineout' ],
					params => {
						value  => $i,
					},
				},
			},
		};
		push @menu, $lineOutSetting;
	}

	sliceAndShip($request, $client, \@menu);

	$request->setStatusDone();

}

sub lineOutCommand {

	my $request = shift;
	my $client  = $request->client();
	my $value   = $request->getParam('value');

	$client->setAnalogOutMode($value);

	$request->setStatusDone();
}

sub toneSettingsQuery {

	$log->info("Begin function");
	my $request        = shift;
	my $client         = $request->client();
	my $tone           = $request->getParam('cmd');

	my $val     = $client->$tone();

	my @menu = ();
	my $slider = {
		slider  => 1,
		min     => -23 + 0,
		max     => 23,
		adjust  => 24, # slider currently doesn't like a slider starting at or below 0
		initial => $val,
		#help    => NO_HELP_STRING_YET,
		actions => {
			do => {
				player => 0,
				cmd    => [ 'jivetoneadjust' ],
				params => {
					tone   => $tone,
					valtag => 'value',
				},
			},
		},
	};

	push @menu, $slider;

	sliceAndShip($request, $client, \@menu);

	$request->setStatusDone();
}

sub toneAdjustCommand {

	my $request = shift;
	my $client  = $request->client();
	my $tone    = $request->getParam('tone');
	my $delta   = $request->getParam('delta');
	my $newVal  = $request->getParam('value');

	my $val     = $client->$tone();

	if (!defined $newVal) {
		$newVal  = $val + $delta;
	}

	$val = $client->$tone($newVal);

	my $string = $client->string($tone) . ": " . $val;
	$client->showBriefly({
		'jive' => {
			type    => 'popupplay',
			text    => [ $string ],
		}
	});

	$request->setStatusDone();
}

sub crossfadeSettingsQuery {

	$log->info("Begin function");
	my $request = shift;
	my $client  = $request->client();
	my $val     = $prefs->client($client)->get('transitionType');
	my @strings = (
		'TRANSITION_NONE', 'TRANSITION_CROSSFADE', 
		'TRANSITION_FADE_IN', 'TRANSITION_FADE_OUT', 
		'TRANSITION_FADE_IN_OUT'
	);
	my @menu;

	push @menu, transitionHash($client, $val, $prefs, \@strings, 0);
	push @menu, transitionHash($client, $val, $prefs, \@strings, 1);
	push @menu, transitionHash($client, $val, $prefs, \@strings, 2);
	push @menu, transitionHash($client, $val, $prefs, \@strings, 3);
	push @menu, transitionHash($client, $val, $prefs, \@strings, 4);

	sliceAndShip($request, $client, \@menu);

}

sub replaygainSettingsQuery {

	$log->info("Begin function");
	my $request = shift;
	my $client  = $request->client();
	my $val     = $prefs->client($client)->get('replayGainMode');
	my @strings = (
		'REPLAYGAIN_DISABLED', 'REPLAYGAIN_TRACK_GAIN', 
		'REPLAYGAIN_ALBUM_GAIN', 'REPLAYGAIN_SMART_GAIN'
	);
	my @menu;

	push @menu, replayGainHash($client, $val, $prefs, \@strings, 0);
	push @menu, replayGainHash($client, $val, $prefs, \@strings, 1);
	push @menu, replayGainHash($client, $val, $prefs, \@strings, 2);
	push @menu, replayGainHash($client, $val, $prefs, \@strings, 3);

	sliceAndShip($request, $client, \@menu);
}


sub sliceAndShip {
	my ($request, $client, $menu) = @_;
	my $numitems = scalar(@$menu);
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');

	$request->addResult("count", $numitems);
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $numitems);

	if ($valid) {
		my $cnt = 0;
		$request->addResult('offset', $start);

		for my $eachmenu (@$menu[$start..$end]) {
			$request->setResultLoopHash('item_loop', $cnt, $eachmenu);
			$cnt++;
		}
	}
	$request->setStatusDone()
}

# returns a single item for the homeMenu if radios is a valid command
sub internetRadioMenu {
	$log->info("Begin function");
	my $client = shift;
	my @command = ('radios', 0, 200, 'menu:radio');

	my $test_request = Slim::Control::Request::executeRequest($client, \@command);
	my $validQuery = $test_request->isValidQuery();

	my @menu = ();
	
	if ($validQuery) {
		push @menu,
		{
			text           => $client->string('RADIO'),
			id             => 'radios',
			node           => 'home',
			weight         => 20,
			actions        => {
				go => {
					cmd => ['radios'],
					params => {
						menu => 'radio',
					},
				},
			},
			window        => {
					menuStyle => 'album',
					titleStyle => 'internetradio',
			},
		};
	}

	return \@menu;

}

# returns a single item for the homeMenu if music_services is a valid command
sub musicServicesMenu {
	$log->info("Begin function");
	my $client = shift;
	my @command = ('music_services', 0, 200, 'menu:music_services');

	my $test_request = Slim::Control::Request::executeRequest($client, \@command);
	my $validQuery = $test_request->isValidQuery();

	my @menu = ();
	
	if ($validQuery) {
		push @menu, 
		{
			text           => $client->string('MUSIC_SERVICES'),
			id             => 'music_services',
			node           => 'home',
			weight         => 30,
			actions => {
				go => {
					cmd => ['music_services'],
					params => {
						menu => 'music_services',
					},
				},
			},
			window        => {
					menuStyle => 'album',
					titleStyle => 'internetradio',
			},
		};
	}

	return \@menu;

}

sub playerSettingsMenu {

	$log->info("Begin function");
	my $client = shift;
	my $batch = shift;

	my @menu = ();
	return \@menu unless $client;

 	push @menu, {
		text           => $client->string('AUDIO_SETTINGS'),
		id             => 'settingsAudio',
		node           => 'settings',
		isANode        => 1,
		weight         => 35,
		window         => { titleStyle => 'settings', },
	};
	
	# always add repeat
	push @menu, repeatSettings($client, 1);

	# always add shuffle
	push @menu, shuffleSettings($client, 1);

	# add alarm only if this is a slimproto player
	if ($client->isPlayer()) {
		push @menu, {
			text           => $client->string("ALARM"),
			id             => 'settingsAlarm',
			node           => 'settings',
			weight         => 29,
			actions        => {
				go => {
					cmd    => ['alarmsettings'],
					player => 0,
				},
			},
			window         => { titleStyle => 'settings' },
		};
	}

	# bass, if available
	if ( $client->maxBass() - $client->minBass() > 0 ) {
		push @menu, {
			text           => $client->string("BASS"),
			id             => 'settingsBass',
			node           => 'settingsAudio',
			weight         => 10,
			actions        => {
				go => {
					cmd    => ['jivetonesettings'],
					player => 0,
					params => {
						'cmd' => 'bass',
					},
				},
			},
			window         => { titleStyle => 'settings' },
		};
	}

	# treble, if available
	if ( $client->maxTreble() - $client->minTreble() > 0 ) {
		push @menu, {
			text           => $client->string("TREBLE"),
			id             => 'settingsTreble',
			node           => 'settingsAudio',
			weight         => 20,
			actions        => {
				go => {
					cmd    => ['jivetonesettings'],
					player => 0,
					params => {
						'cmd' => 'treble',
					},
				},
			},
			window         => { titleStyle => 'settings' },
		};
	}

	# stereoXL, if available
	if ( $client->can('maxXL') ) {
		push @menu, {
			text           => $client->string("STEREOXL"),
			id             => 'settingsStereoXL',
			node           => 'settingsAudio',
			weight         => 90,
			actions        => {
				go => {
					cmd    => ['jivestereoxl'],
					player => 0,
				},
			},
			window         => { titleStyle => 'settings' },
		};
	}

	# lineOut, if available
	my $lineOutCapable = $prefs->client($client)->get('analogOutMode');
	if ( defined $lineOutCapable ) {
		push @menu, {
			text           => $client->string("SETUP_ANALOGOUTMODE"),
			id             => 'settingsLineOut',
			node           => 'settingsAudio',
			weight         => 80,
			actions        => {
				go => {
					cmd    => ['jivelineout'],
					player => 0,
				},
			},
			window         => { titleStyle => 'settings' },
		};
	}


	# sleep setting (always)
	push @menu, {
		text           => $client->string("PLAYER_SLEEP"),
		id             => 'settingsSleep',
		node           => 'settings',
		weight         => 40,
		actions        => {
			go => {
				cmd    => ['sleepsettings'],
				player => 0,
			},
		},
		window         => { titleStyle => 'settings' },
	};	

	# synchronization. only if numberOfPlayers > 1
	my $synchablePlayers = howManyPlayersToSyncWith($client);
	if ($synchablePlayers > 0) {
		push @menu, {
			text           => $client->string("SYNCHRONIZE"),
			id             => 'settingsSync',
			node           => 'settings',
			weight         => 70,
			actions        => {
				go => {
					cmd    => ['syncsettings'],
					player => 0,
				},
			},
			window         => { titleStyle => 'settings' },
		};	
	}

	# information, always display
	my $playerInfoText = $client->string( 'INFORMATION_SPECIFIC_PLAYER', $client->name() );
	push @menu, {
		text           => $playerInfoText,
		id             => 'settingsPlayerInformation',
		node           => 'advancedSettings',
		weight         => 4,
		window         => { titleStyle => 'settings' },
		actions        => {
				go =>	{
						# this is a dummy command...doesn't do anything but is required
						cmd    => ['playerinformation'],
						player => 0,
					},
				},
	};

	# player name change, always display
	push @menu, {
		text           => $client->string('INFORMATION_PLAYER_NAME'),
		id             => 'settingsPlayerNameChange',
		node           => 'advancedSettings',
		input          => {	
			initialText  => $client->name(),
			len          => 1, # For those that want to name their player "X"
			allowedChars => $client->string('JIVE_ALLOWEDCHARS_WITHCAPS'),
			help         => {
				           text => $client->string('JIVE_CHANGEPLAYERNAME_HELP')
			},
			softbutton1  => $client->string('INSERT'),
			softbutton2  => $client->string('DELETE'),
		},
                actions        => {
                                do =>   {
                                                cmd    => ['name'],
                                                player => 0,
						params => {
							playername => '__INPUT__',
						},
                                        },
                                  },
		window         => { titleStyle => 'settings' },
	};


	# transition only for Sb2 and beyond (aka 'crossfade')
	if ($client->isa('Slim::Player::Squeezebox2')) {
		push @menu, {
			text           => $client->string("SETUP_TRANSITIONTYPE"),
			id             => 'settingsXfade',
			node           => 'settingsAudio',
			weight         => 30,
			actions        => {
				go => {
					cmd    => ['crossfadesettings'],
					player => 0,
				},
			},
			window         => { titleStyle => 'settings' },
		};	
	}

	# replay gain (aka volume adjustment)
	if ($client->canDoReplayGain(0)) {
		push @menu, {
			text           => $client->string("REPLAYGAIN"),
			id             => 'settingsReplayGain',
			node           => 'settingsAudio',
			weight         => 40,
			actions        => {
				  go => {
					cmd    => ['replaygainsettings'],
					player => 0,
				  },
			},
			window         => { titleStyle => 'settings' },
		};	
	}

	# brightness settings for players with displays 
	if ( $client->isPlayer() && !$client->display->isa('Slim::Display::NoDisplay') ) {
		push @menu, 
		{
			stringToken    => 'DISPLAY_SETTINGS',
			weight         => 52,
			id             => 'playerDisplaySettings',
			isANode        => 1,
			node           => 'settings',
			window         => { titleStyle => 'settings', },
		},
		{
			text           => $client->string("PLAYER_BRIGHTNESS"),
			id             => 'settingsPlayerBrightness',
			node           => 'playerDisplaySettings',
			actions        => {
				  go => {
					cmd    => [ 'jiveplayerbrightnesssettings' ],
					player => 0,
				  },
			},
			window         => { titleStyle => 'settings' },
		},
		{
			text           => $client->string("TEXTSIZE"),
			id             => 'settingsPlayerTextsize',
			node           => 'playerDisplaySettings',
			actions        => {
				  go => {
					cmd    => [ 'jiveplayertextsettings' ],
					player => 0,
				  },
			},
			window         => { titleStyle => 'settings' },
		},
	}
	
	# Display Controller PIN on SN
	if ( main::SLIM_SERVICE ) {
		my $pin = $client->getControllerPIN();
		push @menu, {
			id     => 'settingsPIN',
			action => 'none',
			style  => 'itemNoAction',
			node   => 'settings',
			weight => 80,
			text   => $client->string( 'SQUEEZENETWORK_PIN', $pin ),
		};
	}

	if ($batch) {
		return \@menu;
	} else {
		_notifyJive(\@menu, $client);
	}
}

sub playerBrightnessMenu {

	my $request    = shift;
	my $client     = $request->client();

	my @menu = ();

	# WHILE ON, WHILE OFF, IDLE
	my @options = (
		{
			string => 'SETUP_POWERONBRIGHTNESS_ABBR',
			pref   => 'powerOnBrightness',
		},
		{
			string => 'SETUP_POWEROFFBRIGHTNESS_ABBR',
			pref   => 'powerOffBrightness',
		},
		{
			string => 'SETUP_IDLEBRIGHTNESS_ABBR',
			pref   => 'idleBrightness',
		},
	);

	for my $href (@options) {
		my @radios = ();
		my $currentSetting = $prefs->client($client)->get($href->{pref});

		# assemble radio buttons based on what's available for that player
		my $hash  = $client->display->getBrightnessOptions();
		for my $setting (sort { $b <=> $a } keys %$hash) {
			my $item = {
				text => $hash->{$setting},
				radio => ($currentSetting == $setting) + 0,
				actions => {
					do    => {
						cmd    => [ 'jivebrightnessadjust' ],
						player => 0,
						params => {
							value => "$setting",
							mode  => $href->{pref},
						},
					},
				},
			};
			push @radios, $item;
		}

		my $item = {
			text    => $client->string($href->{string}),
			count   => scalar(@radios),
			offset  => 0,
			item_loop => \@radios,
		};
		push @menu, $item;
	}
	sliceAndShip($request, $client, \@menu);

	$request->setStatusDone();

}

sub playerBrightnessAdjustCommand {

	my $request = shift;
	my $client  = $request->client();
	my $mode    = $request->getParam('mode');
	my $newVal  = $request->getParam('value');

	my $val = preferences('server')->client($client)->set($mode,$newVal);

	$request->setStatusDone();

}

sub playerTextMenu {

	my $request    = shift;
	my $client     = $request->client();

	my @menu = ();

	my @fonts = ();
	my $i = 0;
	for my $font ( @{ $prefs->client($client)->get('activeFont') } ) {
		push @fonts, {
				name  => $client->string($font),
				value => $i++,
		};
	}

	my $currentSetting = $prefs->client($client)->get('activeFont_curr');
	for my $font (@fonts) {
		my $item = {
			text => $font->{name},
			radio => ($font->{value} == $currentSetting) + 0,
			actions => {
				do    => {
					cmd    => [ 'jivetextadjust' ],
					player => 0,
					params => {
						value => "$font->{value}",
					},
				},
			},
		};
		push @menu, $item;
	}

	sliceAndShip($request, $client, \@menu);

	$request->setStatusDone();

}

sub playerTextAdjustCommand {

	my $request = shift;
	my $client  = $request->client();
	my $newVal  = $request->getParam('value');

	my $val = $client->textSize($newVal);

	$request->setStatusDone();

}

sub browseMusicFolder {
	$log->info("Begin function");
	my $client = shift;
	my $batch = shift;

	# first we decide if $audiodir has been configured. If not, don't show this
	my $audiodir = $prefs->get('audiodir');

	my $return = 0;
	if (defined($audiodir) && -d $audiodir) {
		$log->info("Adding Browse Music Folder");
		$return = {
				text           => $client->string('BROWSE_MUSIC_FOLDER'),
				id             => 'myMusicMusicFolder',
				node           => 'myMusic',
				weight         => 70,
				actions        => {
					go => {
						cmd    => ['musicfolder'],
						params => {
							menu => 'musicfolder',
						},
					},
				},
				window        => {
					titleStyle => 'musicfolder',
				},
			};
	} else {
		# if it disappeared, send a notification to get rid of it if it exists
		$log->info("Removing Browse Music Folder from Jive menu via notification");
		deleteMenuItem('myMusicMusicFolder', $client);
	}

	if ($batch) {
		return $return;
	} else {
		_notifyJive( [ $return ], $client);
	}
}

sub repeatSettings {
	my $client = shift;
	my $batch = shift;

	my $repeat_setting = Slim::Player::Playlist::repeat($client);
	my @repeat_strings = ('OFF', 'SONG', 'PLAYLIST',);
	my @translated_repeat_strings = map { ucfirst($client->string($_)) } @repeat_strings;
	my @repeatChoiceActions;
	for my $i (0..$#repeat_strings) {
		push @repeatChoiceActions, 
		{
			player => 0,
			cmd    => ['playlist', 'repeat', "$i"],
		};
	}
	my $return = {
		text           => $client->string("REPEAT"),
		id             => 'settingsRepeat',
		node           => 'settings',
		weight         => 20,
		choiceStrings  => [ @translated_repeat_strings ],
		selectedIndex  => $repeat_setting + 1, # 1 is added to make it count like Lua
		actions        => {
			do => { 
				choices => [ 
					@repeatChoiceActions 
				], 
			},
		},
	};
	if ($batch) {
		return $return;
	} else {
		_notifyJive( [ $return ], $client);
	}
}

sub shuffleSettings {
	my $client = shift;
	my $batch = shift;

	my $shuffle_setting = Slim::Player::Playlist::shuffle($client);
	my @shuffle_strings = ( 'OFF', 'SONG', 'ALBUM',);
	my @translated_shuffle_strings = map { ucfirst($client->string($_)) } @shuffle_strings;
	my @shuffleChoiceActions;
	for my $i (0..$#shuffle_strings) {
		push @shuffleChoiceActions, 
		{
			player => 0,
			cmd => ['playlist', 'shuffle', "$i"],
		};
	}
	my $return = {
		text           => $client->string("SHUFFLE"),
		id             => 'settingsShuffle',
		node           => 'settings',
		selectedIndex  => $shuffle_setting + 1,
		weight         => 10,
		choiceStrings  => [ @translated_shuffle_strings ],
		actions        => {
			do => {
				choices => [
					@shuffleChoiceActions
				],
			},
		},
		window         => { titleStyle => 'settings' },
	};

	if ($batch) {
		return $return;
	} else {
		_notifyJive( [ $return ], $client);
	}
}

sub _clientId {
	my $client = shift;
	my $id = 'all';
	if ( blessed($client) && $client->id() ) {
		$id = $client->id();
	}
	return $id;
}
	
sub _notifyJive {
	my $menu = shift;
	my $client = shift || undef;
	my $id = _clientId($client);
	my $menuForExport = _purgeMenu($menu);
	Slim::Control::Request::notifyFromArray( $client, [ 'menustatus', $menuForExport, 'add', $id ] );
}

sub howManyPlayersToSyncWith {
	my $client = shift;
	my @playerSyncList = Slim::Player::Client::clients();
	my $synchablePlayers = 0;
	
	# Restrict based on players with same userid on SN
	my $userid;
	if ( main::SLIM_SERVICE ) {
		$userid = $client->playerData->userid;
	}
	
	for my $player (@playerSyncList) {
		# skip ourself
		next if ($client eq $player);
		# we only sync slimproto devices
		next if (!$player->isPlayer());
		
		# On SN, only sync with players on the current account
		if ( main::SLIM_SERVICE ) {
			next if $userid == 1;
			next if $userid != $player->playerData->userid;
			
			# Skip players with old firmware
			if (
				( $player->model eq 'squeezebox2' && $player->revision < 82 )
				||
				( $player->model eq 'transporter' && $player->revision < 32 )
			) {
				next;
			}
		}
		
		$synchablePlayers++;
	}
	return $synchablePlayers;
}

sub getPlayersToSyncWith() {
	my $client = shift;
	my @playerSyncList = Slim::Player::Client::clients();
	my @return = ();
	
	# Restrict based on players with same userid on SN
	my $userid;
	if ( main::SLIM_SERVICE ) {
		$userid = $client->playerData->userid;
	}
	
	for my $player (@playerSyncList) {
		# skip ourself
		next if ($client eq $player);
		# we only sync slimproto devices
		next if (!$player->isPlayer());
		
		# On SN, only sync with players on the current account
		if ( main::SLIM_SERVICE ) {
			next if $userid == 1;
			next if $userid != $player->playerData->userid;
			
			# Skip players with old firmware
			if (
				( $player->model eq 'squeezebox2' && $player->revision < 82 )
				||
				( $player->model eq 'transporter' && $player->revision < 32 )
			) {
				next;
			}
		}
		
		my $val = Slim::Player::Sync::isSyncedWith($client, $player); 
		push @return, { 
			text => $player->name(), 
			checkbox => ($val == 1) + 0,
			actions  => {
				on  => {
					player => 0,
					cmd    => ['sync', $player->id()],
				},
				off => {
					player => $player->id(),
					cmd    => ['sync', '-'],
				},
			},		
		};
	}
	return \@return;
}

sub dateQuery {
	my $request = shift;

	if ( $request->isNotQuery([['date']]) ) {
		$request->setStatusBadDispatch();
		return;
	}
	
	if ( main::SLIM_SERVICE ) {
		# Use timezone on user's account
		my $client = $request->client;
		
		my $tz 
			=  preferences('server')->client($client)->get('timezone')
			|| $client->playerData->userid->timezone 
			|| 'America/Los_Angeles';
		
		my $datestr = DateTime->now( time_zone => $tz )->strftime("%Y-%m-%dT%H:%M:%S%z");
		$datestr =~ s/(\d\d)$/:$1/; # change -0500 to -05:00
		
		$request->addResult( 'date', $datestr );
		
		$request->setStatusDone();
		
		return;
	}
	
	# Calculate the time zone offset, taken from Time::Timezone
	my $time = time();
	my @l    = localtime($time);
	my @g    = gmtime($time);

	my $off 
		= $l[0] - $g[0]
		+ ( $l[1] - $g[1] ) * 60
		+ ( $l[2] - $g[2] ) * 3600;

	# subscript 7 is yday.

	if ( $l[7] == $g[7] ) {
		# done
	}
	elsif ( $l[7] == $g[7] + 1 ) {
		$off += 86400;
	}
	elsif ( $l[7] == $g[7] - 1 ) {
			$off -= 86400;
	} 
	elsif ( $l[7] < $g[7] ) {
		# crossed over a year boundry!
		# localtime is beginning of year, gmt is end
		# therefore local is ahead
		$off += 86400;
	}
	else {
		$off -= 86400;
	}

	my $hour = int($off / 3600);
	if ( $hour > -10 && $hour < 10 ) {
		$hour = "0" . abs($hour);
	}
	else {
		$hour = abs($hour);
	}

	my $tzoff = ( $off >= 0 ) ? '+' : '-';
	$tzoff .= sprintf( "%s:%02d", $hour, int( $off % 3600 / 60 ) );

	# Return time in http://www.w3.org/TR/NOTE-datetime format
	$request->addResult( 'date', strftime("%Y-%m-%dT%H:%M:%S", localtime) . $tzoff );

	$request->setStatusDone();
}

sub firmwareUpgradeQuery {
	my $request = shift;

	if ( $request->isNotQuery([['firmwareupgrade']]) ) {
		$request->setStatusBadDispatch();
		return;
	}

	my $firmwareVersion = $request->getParam('firmwareVersion');
	
	# always send the upgrade url this is also used if the user opts to upgrade
	if ( my $url = Slim::Utils::Firmware->jive_url() ) {
		# Bug 6828, Send relative firmware URLs for Jive versions which support it
		my ($cur_rev) = $firmwareVersion =~ m/\sr(\d+)/;
		if ( $cur_rev >= 1659 ) {
			$request->addResult( relativeFirmwareUrl => URI->new($url)->path );
		}
		else {
			$request->addResult( firmwareUrl => $url );
		}
	}
	
	if ( Slim::Utils::Firmware->jive_needs_upgrade( $firmwareVersion ) ) {
		# if this is true a firmware upgrade is forced
		$request->addResult( firmwareUpgrade => 1 );
	}
	else {
		$request->addResult( firmwareUpgrade => 0 );
	}

	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
		$request->registerAutoExecute($timeout, \&firmwareUpgradeQuery);
	}

	$request->setStatusDone();

}

sub playerPower {

	my $client = shift;
	my $batch = shift;

	return [] unless blessed($client)
		&& $client->isPlayer() && $client->canPowerOff();

	my $name  = $client->name();
	my $power = $client->power();
	my @return; 
	my ($text, $action);

	if ($power == 1) {
		$text = sprintf($client->string('JIVE_TURN_PLAYER_OFF'), $name);
		$action = 0;
	} else {
		$text = sprintf($client->string('JIVE_TURN_PLAYER_ON'), $name);
		$action = 1;
	}

	push @return, {
		text           => $text,
		id             => 'playerpower',
		node           => 'home',
		weight         => 100,
		actions        => {
			do  => {
				player => 0,
				cmd    => ['power', $action],
				},
			},
	};

	if ($batch) {
		return \@return;
	} else {
		# send player power info by notification
		_notifyJive(\@return, $client);
	}

}

sub sleepInXHash {
	$log->info("Begin function");
	my ($client, $val, $sleepTime) = @_;
	my $text = $sleepTime == 0 ? 
		$client->string("SLEEP_CANCEL") :
		$client->string('X_MINUTES', $sleepTime);
	my %return = ( 
		text    => $text,
		actions => {
			go => {
				player => 0,
				cmd => ['sleep', $sleepTime*60 ],
			},
		},
		nextWindow => 'refresh',
	);
	return \%return;
}

sub transitionHash {
	
	my ($client, $val, $prefs, $strings, $thisValue) = @_;
	my %return = (
		text    => $client->string($strings->[$thisValue]),
		radio	=> ($val == $thisValue) + 0, # 0 is added to force the data type to number
		actions => {
			do => {
				player => 0,
				cmd => ['playerpref', 'transitionType', "$thisValue" ],
			},
		},
	);
	return \%return;
}

sub replayGainHash {
	
	my ($client, $val, $prefs, $strings, $thisValue) = @_;
	my %return = (
		text    => $client->string($strings->[$thisValue]),
		radio	=> ($val == $thisValue) + 0, # 0 is added to force the data type to number
		actions => {
			do => {
				player => 0,
				cmd => ['playerpref', 'replayGainMode', "$thisValue"],
			},
		},
	);
	return \%return;
}

sub myMusicMenu {
	$log->info("Begin function");
	my $batch = shift;
	my $client = shift || undef;
	my $sort   = $prefs->get('jivealbumsort') || 'artistalbum';
	my @myMusicMenu = (
			{
				text           => $client->string('BROWSE_BY_ARTIST'),
				homeMenuText   => $client->string('BROWSE_ARTISTS'),
				id             => 'myMusicArtists',
				node           => 'myMusic',
				weight         => 10,
				actions        => {
					go => {
						cmd    => ['artists'],
						params => {
							menu => 'album',
						},
					},
				},
				window        => {
					titleStyle => 'artists',
				},
			},		
			{
				text           => $client->string('BROWSE_BY_ALBUM'),
				homeMenuText   => $client->string('BROWSE_ALBUMS'),
				id             => 'myMusicAlbums',
				node           => 'myMusic',
				weight         => 20,
				actions        => {
					go => {
						cmd    => ['albums'],
						params => {
							menu     => 'track',
							sort     => $sort,
						},
					},
				},
				window         => {
					menuStyle => 'album',
					menuStyle => 'album',
					titleStyle => 'albumlist',
				},
			},
			{
				text           => $client->string('BROWSE_BY_GENRE'),
				homeMenuText   => $client->string('BROWSE_GENRES'),
				id             => 'myMusicGenres',
				node           => 'myMusic',
				weight         => 30,
				actions        => {
					go => {
						cmd    => ['genres'],
						params => {
							menu => 'artist',
						},
					},
				},
				window        => {
					titleStyle => 'genres',
				},
			},
			{
				text           => $client->string('BROWSE_BY_YEAR'),
				homeMenuText   => $client->string('BROWSE_YEARS'),
				id             => 'myMusicYears',
				node           => 'myMusic',
				weight         => 40,
				actions        => {
					go => {
						cmd    => ['years'],
						params => {
							menu => 'album',
						},
					},
				},
				window        => {
					titleStyle => 'years',
				},
			},
			{
				text           => $client->string('BROWSE_NEW_MUSIC'),
				id             => 'myMusicNewMusic',
				node           => 'myMusic',
				weight         => 50,
				actions        => {
					go => {
						cmd    => ['albums'],
						params => {
							menu => 'track',
							sort => 'new',
						},
					},
				},
				window        => {
					menuStyle => 'album',
					titleStyle => 'newmusic',
				},
			},
			{
				text           => $client->string('SAVED_PLAYLISTS'),
				id             => 'myMusicPlaylists',
				node           => 'myMusic',
				weight         => 80,
				actions        => {
					go => {
						cmd    => ['playlists'],
						params => {
							menu => 'track',
						},
					},
				},
				window        => {
					titleStyle => 'playlist',
				},
			},
			{
				text           => $client->string('SEARCH'),
				id             => 'myMusicSearch',
				node           => 'myMusic',
				isANode        => 1,
				weight         => 90,
				window         => { titleStyle => 'search', },
			},
		);
	# add the items for under mymusicSearch
	my $searchMenu = searchMenu(1, $client);
	@myMusicMenu = (@myMusicMenu, @$searchMenu);

	if (my $browseMusicFolder = browseMusicFolder($client, 1)) {
		push @myMusicMenu, $browseMusicFolder;
	}

	if ($batch) {
		return \@myMusicMenu;
	} else {
		_notifyJive(\@myMusicMenu, $client);
	}

}

sub searchMenu {
	$log->info("Begin function");
	my $batch = shift;
	my $client = shift || undef;
	my @searchMenu = (
		{
		text           => $client->string('ARTISTS'),
		homeMenuText   => $client->string('ARTIST_SEARCH'),
		id             => 'myMusicSearchArtists',
		node           => 'myMusicSearch',
		weight         => 10,
		input => {
			len  => 1, #bug 5318
			processingPopup => {
				text => $client->string('SEARCHING'),
			},
			help => {
				text => $client->string('JIVE_SEARCHFOR_HELP')
			},
		},
		actions => {
			go => {
				cmd => ['artists'],
				params => {
					menu     => 'album',
					menu_all => '1',
					search   => '__TAGGEDINPUT__',
					_searchType => 'artists',
				},
                        },
		},
                window => {
                        text => $client->string('SEARCHFOR_ARTISTS'),
                        titleStyle => 'search',
                },
	},
	{
		text           => $client->string('ALBUMS'),
		homeMenuText   => $client->string('ALBUM_SEARCH'),
		id             => 'myMusicSearchAlbums',
		node           => 'myMusicSearch',
		weight         => 20,
		input => {
			len  => 1, #bug 5318
			processingPopup => {
				text => $client->string('SEARCHING'),
			},
			help => {
				text => $client->string('JIVE_SEARCHFOR_HELP')
			},
		},
		actions => {
			go => {
				cmd => ['albums'],
				params => {
					menu     => 'track',
					menu_all => '1',
					search   => '__TAGGEDINPUT__',
					_searchType => 'albums',
				},
			},
		},
		window => {
			text => $client->string('SEARCHFOR_ALBUMS'),
			titleStyle => 'search',
			menuStyle  => 'album',
		},
	},
	{
		text           => $client->string('SONGS'),
		homeMenuText   => $client->string('TRACK_SEARCH'),
		id             => 'myMusicSearchSongs',
		node           => 'myMusicSearch',
		weight         => 30,
		input => {
			len  => 1, #bug 5318
			processingPopup => {
				text => $client->string('SEARCHING'),
			},
			help => {
				text => $client->string('JIVE_SEARCHFOR_HELP')
			},
		},
		actions => {
			go => {
				cmd => ['tracks'],
				params => {
					menu     => 'track',
					menuStyle => 'album',
					menu_all => '1',
					search   => '__TAGGEDINPUT__',
					_searchType => 'tracks',
				},
                        },
		},
		window => {
			text => $client->string('SEARCHFOR_SONGS'),
			titleStyle => 'search',
			menuStyle => 'album',
		},
	},
	{
		text           => $client->string('PLAYLISTS'),
		homeMenuText   => $client->string('PLAYLIST_SEARCH'),
		id             => 'myMusicSearchPlaylists',
		node           => 'myMusicSearch',
		weight         => 40,
		input => {
			len  => 1, #bug 5318
			processingPopup => {
				text => $client->string('SEARCHING'),
			},
			help => {
				text => $client->string('JIVE_SEARCHFOR_HELP')
			},
		},
		actions => {
			go => {
				cmd => ['playlists'],
				params => {
					menu     => 'track',
					menu_all => '1',
					search   => '__TAGGEDINPUT__',
				},
                        },
		},
		window => {
			text => $client->string('SEARCHFOR_PLAYLISTS'),
			titleStyle => 'search',
		},
	},

	);

	if ($batch) {
		return \@searchMenu;
	} else {
		_notifyJive(\@searchMenu, $client);
	}

}
# send a notification for menustatus
sub menuNotification {
	$log->warn("Menustatus notification sent.");
	# the lines below are needed as menu notifications are done via notifyFromArray, but
	# if you wanted to debug what's getting sent over the Comet interface, you could do it here
	my $request  = shift;
	my $dataRef          = $request->getParam('_data')   || return;
	my $action   	     = $request->getParam('_action') || 'add';
#	$log->warn(Data::Dump::dump($dataRef));
}

sub jivePlayTrackAlbumCommand {

	$log->info("Begin function");

	my $request    = shift;
	my $client     = $request->client || return;
	my $albumID    = $request->getParam('album_id');
	my $folder     = $request->getParam('folder')|| undef;
	my $listIndex  = $request->getParam('list_index');
	
	$client->execute( ["playlist", "clear"] );

	# Database album browse is the simple case
	if ( $albumID ) {

		$client->execute( ["playlist", "addtracks", { 'album.id' => $albumID } ] );
		$client->execute( ["playlist", "jump", $listIndex] );

	}

	# hard case is Browse Music Folder - re-create the playlist, starting playback with the current item
	elsif ( $folder && defined $listIndex ) {

		my $wasShuffled = Slim::Player::Playlist::shuffle($client);
		Slim::Player::Playlist::shuffle($client, 0);

		my ($topLevelObj, $items, $count) = Slim::Utils::Misc::findAndScanDirectoryTree( {
			url => $folder,
		} );

		$log->info("Playing all in folder, starting with $listIndex");

		my @playlist = ();

		# iterate through list in reverse order, so that dropped items don't affect the index as we subtract.
		for my $i (reverse (0..scalar @{$items}-1)) {

			if (!ref $items->[$i]) {
				$items->[$i] =  Slim::Utils::Misc::fixPath($items->[$i], $folder);
			}

			if (!Slim::Music::Info::isSong($items->[$i])) {

				$log->info("Dropping $items->[$i] from play all in folder at index $i");

				if ($i < $listIndex) {
					$listIndex--;
				}

				next;
			}

			unshift (@playlist, $items->[$i]);
		}

		$log->info("Load folder playlist, now starting at index: $listIndex");

		$client->execute(['playlist', 'clear']);
		$client->execute(['playlist', 'addtracks', 'listref', \@playlist]);
		$client->execute(['playlist', 'jump', $listIndex]);

		if ($wasShuffled) {
			$client->execute(['playlist', 'shuffle', 1]);
		}
	}

	$request->setStatusDone();
}

sub jivePlaylistsCommand {

	$log->info("Begin function");
	my $request    = shift;
	my $client     = $request->client || return;
	my $title      = $request->getParam('title');
	my $url        = $request->getParam('url');
	my $command    = $request->getParam('_cmd');
	my $playlistID = $request->getParam('playlist_id');
	my $token      = uc($command); 
	my @delete_menu= (
		{
			text    => $client->string('CANCEL'),
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jiveblankcommand' ],
				},
			},
			nextWindow => 'parent',
		}
	);
	my $actionItem = {
		text    => $client->string($token) . ' ' . $title,
		actions => {
			go => {
				player => 0,
				cmd    => ['playlists', 'delete'],
				params => {
					playlist_id    => $playlistID,
					title          => $title,
					url            => $url,
				},
			},
		},
		nextWindow => 'grandparent',
	};
	push @delete_menu, $actionItem;

	$request->addResult('offset', 0);
	$request->addResult('count', 2);
	$request->addResult('item_loop', \@delete_menu);
	$request->addResult('window', { titleStyle => 'playlist' } );

	$request->setStatusDone();

}

sub jiveUnmixableMessage {
	my $request = shift;
	my $service = $request->getParam('contextToken');
	my $serviceString = $request->string($service);
	$request->client->showBriefly(
		{ 'jive' =>
			{
				'type'    => 'popupplay',
				'text'    => [ $request->string('UNMIXABLE', $serviceString) ],
			},
		}
	);
        $request->setStatusDone();
}

sub jiveFavoritesCommand {

	$log->info("Begin function");
	my $request = shift;
	my $client  = $request->client || shift;
	my $title   = $request->getParam('title');
	my $url     = $request->getParam('url');
	my $icon    = $request->getParam('icon');
	my $command = $request->getParam('_cmd');
	my $token   = uc($command); # either ADD or DELETE
	my $action = $command eq 'add' ? 'parent' : 'grandparent';
	my $favIndex = defined($request->getParam('item_id'))? $request->getParam('item_id') : undef;
	my @favorites_menu = (
		{
			text    => $client->string('CANCEL'),
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jiveblankcommand' ],
				},
			},
			nextWindow => 'parent',
		}
	);
	my $actionItem = {
		text    => $client->string($token) . ' ' . $title,
		actions => {
			go => {
				player => 0,
				cmd    => ['favorites', $command ],
				params => {
						title => $title,
						url   => $url,
				},
			},
		},
		nextWindow => $action,
	};
	$actionItem->{'actions'}{'go'}{'params'}{'icon'} = $icon if $icon;
	$actionItem->{'actions'}{'go'}{'params'}{'item_id'} = $favIndex if defined($favIndex);
	push @favorites_menu, $actionItem;

	$request->addResult('offset', 0);
	$request->addResult('count', 2);
	$request->addResult('item_loop', \@favorites_menu);
	$request->addResult('window', { titleStyle => 'favorites' } );


	$request->setStatusDone();

}

sub _jiveNoResults {
	my $request = shift;
	$request->addResult('count', '1');
	$request->addResult('offset', 0);
	$request->addResultLoop('item_loop', 0, 'text', $request->string('EMPTY'));
	$request->addResultLoop('item_loop', 0, 'style', 'itemNoAction');
	$request->addResultLoop('item_loop', 0, 'action', 'none');
}

sub cacheSearch {
	my $request = shift;
	my $search  = shift;

	if (defined($search) && $search->{text} && $search->{actions}{go}{cmd}) {
		unshift (@recentSearches, $search);
	}
	recentSearchMenu($request->client, 0);
}

sub recentSearchMenu {
	my $client  = shift;
	my $batch   = shift;

	my @recentSearchMenu = ();
	return \@recentSearchMenu unless $client;

	if (scalar(@recentSearches) == 1) {
		push @recentSearchMenu,
		{
			text           => $client->string('RECENT_SEARCHES'),
			id             => 'homeSearchRecent',
			node           => 'home',
			weight         => 80,
			actions => {
				go => {
					cmd => ['jiverecentsearches'],
       	                 },
			},
			window => {
				text => $client->string('RECENT_SEARCHES'),
				titleStyle => 'search',
			},
		};
		push @recentSearchMenu,
		{
			text           => $client->string('RECENT_SEARCHES'),
			id             => 'myMusicSearchRecent',
			node           => 'myMusicSearch',
			noCustom       => 1,
			weight         => 50,
			actions => {
				go => {
					cmd => ['jiverecentsearches'],
       	                 	},
			},
			window => {
				text => $client->string('RECENT_SEARCHES'),
				titleStyle => 'search',
			},
		};	
		if (!$batch) {
			_notifyJive(\@recentSearchMenu, $client);
		}
	}
	return \@recentSearchMenu;

}

sub jiveRecentSearchQuery {

	my $request = shift;
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['jiverecentsearches']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $totalCount = scalar(@recentSearches);
	if ($totalCount == 0) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		my $maxCount = 200;
		$totalCount = $totalCount > $maxCount ? ($maxCount - 1) : $totalCount;
		$request->addResult('count', $totalCount);
		$request->addResult('offset', 0);
		for my $i (0..$totalCount) {
			last unless $recentSearches[$i];
			my $href = $recentSearches[$i];
			for my $key (keys %$href) {
				$request->addResultLoop('item_loop', $i, $key, $href->{$key});
			}
		}
	}
	$request->setStatusDone();
}

# The following allow download of applets, wallpaper and sounds from SC to jive
# Files may be packaged in a plugin or can be added individually via the api below.
#
# In the case of downloads packaged as a plugin, each downloadable file should be 
# available in the 'jive' folder of a plugin and the plugin install.xml file should refer
# to it in the following format:
#
# <jive>
#    <applet>
#       <version>0.1</version>
#       <name>Applet1</name>
#       <file>Applet1.zip</file>
#    </applet>
#    <wallpaper>
#       <name>Wallpaper1</name>
#       <file>Wallpaper1.png</file>
#    </wallpaper>			
#    <wallpaper>
#       <name>Wallpaper2</name>
#       <file>Wallpaper2.png</file>
#    </wallpaper>	
#    <sound>
#       <name>Sound1</name>
#       <file>Sound1.wav</file>
#    </sound>	
# </jive>
#
# Alternatively individual wallpaper and sound files may be registered by the 
# registerDownload and deleteDownload api calls.

# file types allowed for downloading to jive
my %filetypes = (
	applet    => qr/\.zip$/,
	wallpaper => qr/\.(bmp|jpg|jpeg|png|BMP|JPG|JPEG|PNG)$|^http:\/\//,
	sound     => qr/\.wav$/,
);

# addditional downloads
my %extras = (
	wallpaper => {},
	sound     => {},
	applet    => {},
);

=head2 registerDownload()

Register a local file or url for downloading to jive as a wallpaper, sound file or applet
$type : either 'wallpaper', 'sound' or 'applet'
$name : description to show on jive
$path : fullpath for file on server or http:// url
$key  : (optional) unique key for this type to avoid using file's basename
$vers : version (applets only)

=cut

sub registerDownload {
	my $type = shift;
	my $name = shift;
	my $path = shift;
	my $key  = shift;
	my $vers = shift;

	my $file = $key || ($path ? basename($path) : '');

	if ($type =~ /wallpaper|sound|applet/ && $path =~ $filetypes{$type} && (-r $path || $path =~ /^http:\/\//)) {

		$log->info("registering download for $type $name $file $path");

		$extras{$type}->{$file} = {
			'name'    => $name,
			'path'    => $path,
			'file'    => $file,
		};

		if ($type eq 'applet') {
			$extras{$type}->{$file}->{'version'} = $vers;
		}

	} else {
		$log->warn("unable to register download for $name $type $file");
	}
}

=head2 deleteDownload()

Remove previously registered download entry.
$type : either 'wallpaper', 'sound' or 'applet'
$path : fullpath for file on server or http:// url
$key  : (optional) unique key for this type to avoid using file's basename

=cut

sub deleteDownload {
	my $type = shift;
	my $path = shift;
	my $key  = shift;

	my $file = $key || basename($path);

	if ($type =~ /wallpaper|sound|applet/ && $extras{$type}->{$file}) {

		$log->info("removing download for $type $file");
		delete $extras{$type}->{$file};

	} else {
		$log->warn("unable remove download for $type $file");
	}
}

# downloadable file info from the plugin instal.xml and any registered additions
sub _downloadInfo {
	my $type = shift;

	my $plugins = Slim::Utils::PluginManager::allPlugins();
	my $ret = {};

	for my $key (keys %$plugins) {

		if ($plugins->{$key}->{'jive'} && $plugins->{$key}->{'jive'}->{$type}) {

			my $info = $plugins->{$key}->{'jive'}->{$type};
			my $dir  = $plugins->{$key}->{'basedir'};

			if ($info->{'name'}) {

				my $file = $info->{'file'};

				if ( $file =~ $filetypes{$type} && -r catdir($dir, 'jive', $file) ) {

					if ($ret->{$file}) {
						$log->warn("duplicate filename for download: $file");
					}

					$ret->{$file} = {
						'name'    => $info->{'name'},
						'path'    => catdir($dir, 'jive', $file),
						'file'    => $file,
						'version' => $info->{'version'},
					};

				} else {
					$log->warn("unable to make $key:$file available for download");
				}

			} elsif (ref $info eq 'HASH') {

				for my $name (keys %$info) {

					my $file = $info->{$name}->{'file'};

					if ( $file =~ $filetypes{$type} && -r catdir($dir, 'jive', $file) ) {

						if ($ret->{$file}) {
							$log->warn("duplicate filename for download: $file [$key]");
						}

						$ret->{$file} = {
							'name'    => $name,
							'path'    => catdir($dir, 'jive', $file),
							'file'    => $file,
							'version' => $info->{$name}->{'version'},
						};

					} else {
						$log->warn("unable to make $key:$file available for download");
					}
				}
			}
		}
	}

	# add extra downloads as registered via api
	for my $key (keys %{$extras{$type}}) {
		$ret->{$key} = $extras{$type}->{$key};
	}

	return $ret;
}

# return all files available for download based on query type
sub downloadQuery {
	my $request = shift;
 
	my $client = $request->client;
	my ($type) = $request->getRequest(0) =~ /jive(applet|wallpaper|sound)s/;

	if (!defined $type) {
		$request->setStatusBadDispatch();
		return;
	}


	my $cnt = 0;
	my $urlBase = 'http://' . Slim::Utils::Network::serverAddr() . ':' . $prefs->get('httpport') . "/jive$type/";

	for my $val ( sort { $a->{'name'} cmp $b->{'name'} } values %{_downloadInfo($type)} ) {

		my $url = $val->{'path'} =~ /^http:\/\// ? $val->{'path'} : $urlBase . $val->{'file'};

		my $entry = {
			$type     => $val->{'name'},
			'name'    => Slim::Utils::Strings::getString($val->{'name'}),
			'url'     => $url,
			'file'    => $val->{'file'},
		};

		if ($val->{'path'} !~ /^http:\/\//) {
			$entry->{'relurl'} = URI->new($url)->path;
		}

		if ($type eq 'applet') {
			$entry->{'version'} = $val->{'version'};
		}

		$request->setResultLoopHash('item_loop', $cnt++, $entry);
	}	

	$request->addResult("count", $cnt);

	$request->setStatusDone();
}

sub jiveDummyCommand {
	return;
}

# convert path to location for download
sub downloadFile {
	my $path = shift;

	my ($type, $file) = $path =~ /^jive(applet|wallpaper|sound)\/(.*)/;

	my $info = _downloadInfo($type);

	if ($info->{$file}) {

		return $info->{$file}->{'path'};

	} else {

		$log->warn("unable to find file: $file for type: $type");
	}
}

1;
